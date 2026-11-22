#!/usr/bin/env python3
"""Send synthesized AAC through Syncthing and verify its Tailscale route.

Reads the existing local Syncthing API key without displaying it. Leaves test
artifacts in the synced folder, and never changes device or folder settings.
By default it targets the isolated ``lecture-test-inbox`` folder and
``/data/lectures-test`` server tree; pass ``--environment production`` only
when an end-to-end production check is intentional.
Optionally verify this fresh fixture's local transcript artifacts and Drive
publication using read-only checks. Grok ingestion is always a separate check.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import re
import shlex
import shutil
import subprocess
import tempfile
import time
from datetime import datetime
from urllib.parse import urlencode
from urllib.request import Request, urlopen
import uuid
import xml.etree.ElementTree as ET


# Keep transport fixtures out of the production worker's inbox and vault by
# default.  Production checks remain available through the explicit
# ``--environment production`` option (or by supplying all of the lower-level
# path/folder overrides directly).
ENVIRONMENT_DEFAULTS = {
    "test": {
        "folder": "lecture-test-inbox",
        "remote_inbox": "/data/lectures-test/inbox",
        "remote_vault": "/data/lectures-test/vault",
    },
    "production": {
        "folder": "lecture-inbox",
        "remote_inbox": "/data/lectures/inbox",
        "remote_vault": "/data/lectures/vault",
    },
}


# Kept self-contained so the worker needs only system Python for this read-only
# probe. The worker owns all processing and writes; the probe only observes it.
TRANSCRIPT_PROBE = r'''
import hashlib
import json
from pathlib import Path
import re
import sys
import time

vault = Path(sys.argv[1])
filename, source_sha256 = sys.argv[2:4]
timeout = float(sys.argv[4])
course = filename.rsplit("_", 2)[0]
stem = Path(filename).stem
paths = {suffix: vault / course / (stem + suffix) for suffix in (".md", ".txt", ".srt")}
jobs = vault.parent / "state" / "jobs"
started = time.monotonic()
deadline = started + timeout
evidence = {"verified": False, "filename": filename, "source_sha256": source_sha256,
            "vault": str(vault), "job_directory": str(jobs)}

while True:
    try:
        missing = [str(path) for path in paths.values() if not path.is_file() or path.is_symlink()]
        if missing:
            raise ValueError("Waiting for transcript artifacts: " + ", ".join(missing))
        matching = []
        for path in jobs.glob("*.json"):
            if path.is_symlink() or not path.is_file():
                continue
            try:
                state = json.loads(path.read_text())
            except (OSError, ValueError):
                continue
            if not isinstance(state, dict):
                continue
            identity = state.get("identity", {})
            if (isinstance(identity, dict) and identity.get("filename") == filename
                    and identity.get("sha256") == source_sha256):
                matching.append((path, state))
        ready = [(path, state) for path, state in matching
                 if state.get("stage") in {"local_ready", "published"}]
        if not ready:
            stages = [state.get("stage") for _, state in matching]
            raise ValueError("Waiting for matching completed durable job; stages: " + repr(stages))

        content = {suffix: path.read_bytes() for suffix, path in paths.items()}
        if any(not data for data in content.values()):
            raise ValueError("Waiting for nonempty transcript artifacts")
        text = content[".txt"].decode("utf-8")
        headers, separator, body = text.partition("\n\n")
        if (not separator or "Source-SHA256: " + source_sha256 not in headers.splitlines()
                or "Source: " + filename not in headers.splitlines()):
            raise ValueError("TXT source identity headers do not match the fixture")
        normalized = re.sub(r"\[\d+:\d+\]", " ", body).casefold()
        normalized = re.sub(r"[^a-z0-9]+", " ", normalized)
        phrase = re.search(r"\bblue bicycle (?:seven|7)\b", normalized)
        if phrase is None:
            raise ValueError("Expected code phrase 'blue bicycle seven' (or '7') is absent")
        hashes = {paths[suffix].name: hashlib.sha256(data).hexdigest()
                  for suffix, data in content.items()}
        accepted = [(path, state) for path, state in ready
                    if all(state.get("artifacts", {}).get(name) == digest
                           for name, digest in hashes.items())]
        if not accepted:
            raise ValueError("Transcript artifact checksums do not match the completed job")
        job_path, state = accepted[-1]
        evidence.update({
            "verified": True,
            "job_state": str(job_path),
            "stage": state["stage"],
            "settings": state["identity"].get("settings"),
            "published": state.get("published", False),
            "grok_ingested": state.get("grok_ingested", False),
            "last_error": state.get("last_error"),
            "matched_phrase": phrase.group(),
            "source_header_verified": True,
            "artifacts": {suffix: {"path": str(paths[suffix]), "size_bytes": len(data),
                                   "sha256": hashes[paths[suffix].name]}
                          for suffix, data in content.items()},
            "elapsed_seconds": round(time.monotonic() - started, 3),
        })
        print(json.dumps(evidence))
        sys.exit(0)
    except (OSError, ValueError, TypeError, AttributeError) as error:
        evidence["last_observation"] = str(error)
        if isinstance(error, PermissionError):
            evidence["error"] = "Permission denied reading remote transcript evidence"
            print(json.dumps(evidence))
            sys.exit(1)
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        evidence["error"] = "Timed out waiting for verified local transcription"
        evidence["elapsed_seconds"] = round(time.monotonic() - started, 3)
        print(json.dumps(evidence))
        sys.exit(1)
    time.sleep(min(2, remaining))
'''


PUBLICATION_PROBE = r'''
import hashlib
import json
from pathlib import Path
import subprocess
import sys
import time

vault = Path(sys.argv[1])
filename, source_sha256 = sys.argv[2:4]
timeout = float(sys.argv[4])
remote, root_folder_id, executable = sys.argv[5:8]
expected = json.loads(sys.argv[8])
course = filename.rsplit("_", 2)[0]
stem = Path(filename).stem
paths = {suffix: vault / course / (stem + suffix) for suffix in (".md", ".txt", ".srt")}
job_path = Path(expected["job_state"])
started = time.monotonic()
deadline = started + timeout
evidence = {"verified": False, "filename": filename, "source_sha256": source_sha256,
            "drive_remote": remote, "drive_root_folder_id": root_folder_id,
            "job_state": str(job_path), "grok_verified": False}

def read_remote(action, destination, *arguments):
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        raise TimeoutError("Publication verification deadline reached")
    command = [executable, action, destination, *arguments,
               "--drive-root-folder-id", root_folder_id, "--contimeout", "10s",
               "--timeout", "30s", "--retries", "1"]
    try:
        result = subprocess.run(command, capture_output=True, timeout=min(45, remaining))
    except subprocess.TimeoutExpired:
        raise TimeoutError("rclone " + action + " exceeded its bounded read timeout") from None
    except OSError:
        raise RuntimeError("Cannot execute the configured remote rclone") from None
    if result.returncode:
        # Do not expose stderr: authorization errors can include account details.
        raise RuntimeError("rclone " + action + " failed with exit status " + str(result.returncode))
    return result.stdout

while True:
    try:
        if (job_path.parent != vault.parent / "state" / "jobs"
                or job_path.is_symlink() or not job_path.is_file()):
            raise ValueError("Waiting for the expected regular durable job file")
        state = json.loads(job_path.read_text())
        identity = state.get("identity", {})
        if identity.get("filename") != filename or identity.get("sha256") != source_sha256:
            raise ValueError("Durable publication job source identity does not match")
        if state.get("stage") != "published" or state.get("published") is not True:
            raise ValueError("Waiting for durable publication success; stage: " + repr(state.get("stage")))

        local = {}
        for suffix, path in paths.items():
            if path.is_symlink() or not path.is_file():
                raise ValueError("Local transcript is missing or not a regular file")
            content = path.read_bytes()
            digest = hashlib.sha256(content).hexdigest()
            reference = expected["artifacts"][suffix]
            if (len(content) != reference["size_bytes"] or digest != reference["sha256"]
                    or state.get("artifacts", {}).get(path.name) != digest):
                raise ValueError("Local transcript no longer matches verified transcription and published state")
            local[suffix] = {"path": str(path), "size_bytes": len(content), "sha256": digest}

        verified = {}
        for suffix, reference in local.items():
            path = paths[suffix]
            destination = remote + ":" + course + "/" + path.name
            metadata = json.loads(read_remote("lsjson", destination, "--stat"))
            if (not isinstance(metadata, dict) or metadata.get("IsDir") is not False
                    or type(metadata.get("Size")) is not int
                    or metadata["Size"] != reference["size_bytes"]):
                raise ValueError("Drive transcript size or file metadata does not match: " + suffix)
            content = read_remote("cat", destination)
            if (len(content) != reference["size_bytes"]
                    or hashlib.sha256(content).hexdigest() != reference["sha256"]):
                raise ValueError("Drive transcript checksum does not match: " + suffix)
            current = path.read_bytes()
            if (len(current) != reference["size_bytes"]
                    or hashlib.sha256(current).hexdigest() != reference["sha256"]):
                raise ValueError("Local transcript changed during Drive verification")
            verified[suffix] = {**reference, "destination": destination, "remote_size_verified": True,
                                "remote_sha256_verified": True}

        final_state = json.loads(job_path.read_text())
        if (final_state.get("identity") != identity or final_state.get("stage") != "published"
                or final_state.get("published") is not True
                or final_state.get("artifacts") != state.get("artifacts")):
            raise ValueError("Durable job changed during Drive verification")
        evidence.update({"verified": True, "stage": "published", "artifacts": verified,
                         "publication_key": state.get("publication_key"),
                         "elapsed_seconds": round(time.monotonic() - started, 3)})
        print(json.dumps(evidence))
        sys.exit(0)
    except (OSError, ValueError, TypeError, AttributeError, KeyError, RuntimeError) as error:
        evidence["last_observation"] = str(error)
        if isinstance(error, PermissionError):
            evidence["error"] = "Permission denied reading local publication evidence"
            print(json.dumps(evidence))
            sys.exit(1)
    remaining = deadline - time.monotonic()
    if remaining <= 0:
        evidence["error"] = "Timed out waiting for independently verified Drive publication"
        evidence["elapsed_seconds"] = round(time.monotonic() - started, 3)
        print(json.dumps(evidence))
        sys.exit(1)
    time.sleep(min(2, remaining))
'''


class Syncthing:
    def __init__(self, config: Path) -> None:
        self.config = ET.parse(config).getroot()
        gui = self.config.find("gui")
        if gui is None:
            raise ValueError("Syncthing GUI configuration is missing")
        self.base = ("https" if gui.get("tls") == "true" else "http") + "://" + gui.findtext("address", "")
        self.key = gui.findtext("apikey", "")

    def request(self, endpoint: str, method: str = "GET", **query: str) -> dict:
        url = self.base + "/rest/" + endpoint
        if query:
            url += "?" + urlencode(query)
        request = Request(url, method=method)
        request.add_unredirected_header("X-API-Key", self.key)
        with urlopen(request, timeout=15) as response:
            body = response.read()
        return json.loads(body) if body else {}


def run(args: list[str], *, timeout: int = 30) -> str:
    return subprocess.run(args, check=True, capture_output=True, text=True, timeout=timeout).stdout


def atomic_copy(source: Path, target: Path) -> None:
    temporary = target.with_name("." + target.name + "." + uuid.uuid4().hex + ".tmp")
    try:
        shutil.copyfile(source, temporary)
        os.replace(temporary, target)
    finally:
        temporary.unlink(missing_ok=True)


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--peer", help="Syncthing device name and Tailscale hostname; inferred for a single remote device")
    parser.add_argument(
        "--environment",
        choices=tuple(ENVIRONMENT_DEFAULTS),
        default="test",
        help=(
            "Transport environment to exercise (default: test). The production "
            "environment must be selected explicitly."
        ),
    )
    parser.add_argument(
        "--folder",
        help="Syncthing folder ID; defaults to the selected environment",
    )
    parser.add_argument("--ssh-target", help="Worker SSH host or alias (defaults to the selected peer name)")
    parser.add_argument(
        "--remote-inbox",
        help="Remote Syncthing inbox; defaults to the selected environment",
    )
    parser.add_argument("--wait-for-transcript", action="store_true",
                        help="After SSH checksum verification, wait for matching local MD/TXT/SRT and durable job state (no Drive/Grok check)")
    parser.add_argument("--transcription-timeout", type=int, default=180,
                        help="Maximum seconds to wait for local transcript verification (default: 180)")
    parser.add_argument(
        "--remote-vault",
        help=(
            "Remote transcript vault; defaults to the selected environment. "
            "Durable jobs must be in its sibling state/jobs directory"
        ),
    )
    parser.add_argument("--wait-for-publication", action="store_true",
                        help="Also wait for published job state and independently verify Drive MD/TXT/SRT bytes; implies --wait-for-transcript")
    parser.add_argument("--drive-root-folder-id",
                        help="Required with --wait-for-publication; read only exact course subdirectories under this Drive parent")
    parser.add_argument("--publication-timeout", type=int, default=180,
                        help="Maximum seconds for publication verification after transcription (default: 180)")
    parser.add_argument("--drive-remote", default="gdrive",
                        help="Configured server rclone Drive remote name (default: gdrive)")
    parser.add_argument("--remote-rclone", default="rclone",
                        help="Server rclone executable used only for read-only lsjson/cat verification")
    parser.add_argument("--timeout", type=int, default=90)
    parser.add_argument("--report", type=Path, required=True)
    parser.add_argument("--syncthing-config", type=Path, default=Path.home() / "Library/Application Support/Syncthing/config.xml")
    args = parser.parse_args()
    supplied_paths = (args.folder is not None, args.remote_inbox is not None, args.remote_vault is not None)
    if any(supplied_paths) and not all(supplied_paths):
        parser.error("--folder, --remote-inbox, and --remote-vault must be supplied together")
    defaults = ENVIRONMENT_DEFAULTS[args.environment]
    args.folder = args.folder or defaults["folder"]
    args.remote_inbox = args.remote_inbox or defaults["remote_inbox"]
    args.remote_vault = args.remote_vault or defaults["remote_vault"]
    if args.environment == "test" and (
        args.folder == ENVIRONMENT_DEFAULTS["production"]["folder"]
        or args.remote_inbox == ENVIRONMENT_DEFAULTS["production"]["remote_inbox"]
        or args.remote_vault == ENVIRONMENT_DEFAULTS["production"]["remote_vault"]
    ):
        parser.error("test environment cannot target production Syncthing or vault paths; use --environment production explicitly")
    if args.transcription_timeout <= 0:
        parser.error("--transcription-timeout must be positive")
    if args.publication_timeout <= 0:
        parser.error("--publication-timeout must be positive")
    if args.wait_for_publication:
        if not args.drive_root_folder_id or not re.fullmatch(r"[A-Za-z0-9_-]+", args.drive_root_folder_id):
            parser.error("--wait-for-publication requires a valid --drive-root-folder-id")
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*:?", args.drive_remote):
            parser.error("--drive-remote must name a configured rclone remote without a path")
        if not args.remote_rclone:
            parser.error("--remote-rclone must be nonempty")
        args.drive_remote = args.drive_remote.rstrip(":")
        args.wait_for_transcript = True
    report: dict = {
        "tested_at": datetime.now().astimezone().isoformat(),
        "environment": args.environment,
        "peer": args.peer,
        "folder": args.folder,
        "remote_inbox": args.remote_inbox,
        "remote_vault": args.remote_vault,
    }
    if args.wait_for_transcript:
        report.update({"transcription_requested": True, "transcription_verified": False})
    if args.wait_for_publication:
        report.update({"publication_requested": True, "publication_verified": False,
                       "grok_verified": False})
    exit_code = 1
    try:
        api = Syncthing(args.syncthing_config)
        folder = next((item for item in api.config.findall("folder") if item.get("id") == args.folder), None)
        if folder is None:
            raise ValueError("The selected Syncthing folder is missing from the local configuration")
        local_id = api.request("system/status")["myID"]
        shared_ids = {item.get("id") for item in folder.findall("device")} - {local_id}
        devices = [item for item in api.config.findall("device") if item.get("id") in shared_ids
                   and (args.peer is None or item.get("name") == args.peer)]
        if len(devices) != 1 or not devices[0].get("name"):
            raise ValueError("Choose one shared Syncthing device by name with --peer")
        args.peer = devices[0].get("name")
        args.ssh_target = args.ssh_target or args.peer
        report["peer"] = args.peer
        device_id = devices[0].get("id")
        if folder.get("type") != "sendonly":
            raise ValueError("The transport fixture requires the configured Send Only folder")
        incoming = Path(folder.get("path", "")).expanduser()
        tailnet = json.loads(run(["tailscale", "status", "--json"]))
        peer = next(peer for peer in tailnet.get("Peer", {}).values() if peer.get("HostName") == args.peer)
        if tailnet.get("BackendState") != "Running" or not peer.get("Online"):
            raise ValueError("Tailscale or the requested peer is offline")
        connection = api.request("system/connections")["connections"][device_id]
        address = connection.get("address", "")
        if not connection.get("connected") or not any(address in {f"{ip}:22000", f"[{ip}]:22000"} for ip in peer.get("TailscaleIPs", [])):
            raise ValueError(f"Syncthing is not connected to {args.peer} through its Tailscale address (current: {address or 'disconnected'})")
        report["connection"] = {key: connection.get(key) for key in ("address", "type", "crypto", "clientVersion")}
        phrase = "Lecture capture pipeline test. The code phrase is blue bicycle seven. This recording verifies synchronization and transcription."
        name = f"LCPTESTSYNC{uuid.uuid4().hex[:6].upper()}_{datetime.now():%Y-%m-%d_%H%M}.m4a"
        with tempfile.TemporaryDirectory(prefix="lcp-transport-") as scratch:
            source = Path(scratch) / name
            run(["say", "-o", str(source), "--file-format=m4af", "--data-format=aac@16000", "--channels=1", "--bit-rate=32000", phrase])
            audio_info = json.loads(run(["ffprobe", "-v", "error", "-show_entries", "stream=codec_name,sample_rate,channels,bit_rate:format=duration", "-of", "json", str(source)]))
            stream = audio_info["streams"][0]
            if stream.get("codec_name") != "aac" or stream.get("sample_rate") != "16000" or stream.get("channels") != 1:
                raise ValueError(f"Synthesized fixture has the wrong audio format: {stream}")
            digest = hashlib.sha256(source.read_bytes()).hexdigest()
            manifest = {"version": 1, "filename": name, "size_bytes": source.stat().st_size, "sha256": digest}
            marker = Path(scratch) / (name + ".ready.json")
            marker.write_text(json.dumps(manifest, indent=2) + "\n")
            atomic_copy(source, incoming / name)
            atomic_copy(marker, incoming / marker.name)
        report.update({"filename": name, "manifest": manifest, "audio": audio_info, "expected_phrase": phrase})
        api.request("db/scan", method="POST", folder=args.folder)
        print(f"Published {name} and completion manifest; waiting for {args.peer}'s Syncthing acknowledgement.", flush=True)
        deadline = time.monotonic() + args.timeout
        acknowledged = False
        while time.monotonic() < deadline:
            try:
                indexed = [api.request("db/file", folder=args.folder, file=file) for file in (name, name + ".ready.json")]
                acknowledged = all(any(item.get("id") == device_id and not item.get("fromTemporary") for item in (data.get("availability") or [])) for data in indexed)
                if acknowledged:
                    report.pop("last_index_error", None)
                    break
            except Exception as error:
                report["last_index_error"] = str(error)
            time.sleep(3)
        report["syncthing_peer_acknowledged"] = acknowledged
        report["completion"] = api.request("db/completion", folder=args.folder, device=device_id)
        if not acknowledged:
            raise TimeoutError("The peer did not acknowledge both files before the deadline")
        connection = api.request("system/connections")["connections"][device_id]
        report["connection_after_transfer"] = {key: connection.get(key) for key in ("address", "type", "crypto", "outBytesTotal", "inBytesTotal")}
        if not connection.get("connected") or not any(
            connection.get("address") in {f"{ip}:22000", f"[{ip}]:22000"}
            for ip in peer.get("TailscaleIPs", [])
        ):
            raise ValueError("Syncthing's connection changed away from Tailscale during verification")
        print(f"Syncthing confirms {args.peer} has both files over the Tailscale connection.", flush=True)
        remote_audio = args.remote_inbox.rstrip("/") + "/" + name
        verify_code = "import hashlib,json,pathlib,sys; p=pathlib.Path(sys.argv[1]); m=json.loads(pathlib.Path(str(p)+'.ready.json').read_text()); d=hashlib.sha256(p.read_bytes()).hexdigest(); print(json.dumps({'sha256':d,'size_bytes':p.stat().st_size,'manifest_matches':m['sha256']==d and m['size_bytes']==p.stat().st_size}))"
        remote_command = "python3 -c " + shlex.quote(verify_code) + " " + shlex.quote(remote_audio)
        result = subprocess.run(["ssh", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes", "-o", "ConnectTimeout=8", args.ssh_target, remote_command], capture_output=True, text=True, timeout=20)
        if result.returncode:
            report.update({"remote_disk_verified": False, "ssh_error": result.stderr.strip(), "status": "syncthing_confirmed_ssh_unverified"})
            if args.wait_for_transcript:
                raise RuntimeError("Transcript verification requires successful SSH disk verification")
            exit_code = 2
        else:
            remote = json.loads(result.stdout)
            report["remote_verification"] = remote
            if remote.get("sha256") != digest or remote.get("size_bytes") != manifest["size_bytes"] or not remote.get("manifest_matches"):
                raise ValueError("The remote disk checksum or manifest does not match")
            report.update({"remote_disk_verified": True, "status": "passed"})
            if args.wait_for_transcript:
                print("Remote audio verified; waiting for matching local transcription.", flush=True)
                arguments = [args.remote_vault, name, digest, str(args.transcription_timeout)]
                probe_command = "python3 -c " + shlex.quote(TRANSCRIPT_PROBE) + " " + " ".join(map(shlex.quote, arguments))
                try:
                    probe = subprocess.run(
                        ["ssh", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
                         "-o", "ConnectTimeout=8", args.ssh_target, probe_command],
                        capture_output=True, text=True, timeout=args.transcription_timeout + 20,
                    )
                except subprocess.TimeoutExpired:
                    report["transcription_verification"] = {
                        "verified": False, "error": "SSH transcript probe exceeded its bounded timeout",
                    }
                    raise TimeoutError("SSH transcript probe exceeded its bounded timeout") from None
                try:
                    transcription = json.loads(probe.stdout)
                except (ValueError, TypeError):
                    message = "Remote transcript probe returned no valid evidence: " + probe.stderr.strip()
                    report["transcription_verification"] = {"verified": False, "error": message}
                    raise RuntimeError(message) from None
                report["transcription_verification"] = transcription
                if (probe.returncode != 0 or transcription.get("verified") is not True
                        or transcription.get("filename") != name
                        or transcription.get("source_sha256") != digest):
                    raise RuntimeError(transcription.get("error", "Remote transcript verification failed"))
                report["transcription_verified"] = True
            if args.wait_for_publication:
                print("Local transcript verified; waiting for independently verified Drive publication.", flush=True)
                arguments = [args.remote_vault, name, digest, str(args.publication_timeout),
                             args.drive_remote, args.drive_root_folder_id, args.remote_rclone,
                             json.dumps(transcription)]
                probe_command = "python3 -c " + shlex.quote(PUBLICATION_PROBE) + " " + " ".join(map(shlex.quote, arguments))
                try:
                    probe = subprocess.run(
                        ["ssh", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
                         "-o", "ConnectTimeout=8", args.ssh_target, probe_command],
                        capture_output=True, text=True, timeout=args.publication_timeout + 20,
                    )
                except subprocess.TimeoutExpired:
                    report["publication_verification"] = {
                        "verified": False, "error": "SSH publication probe exceeded its bounded timeout",
                    }
                    raise TimeoutError("SSH publication probe exceeded its bounded timeout") from None
                try:
                    publication = json.loads(probe.stdout)
                except (ValueError, TypeError):
                    message = "Remote publication probe returned no valid evidence"
                    report["publication_verification"] = {"verified": False, "error": message}
                    raise RuntimeError(message) from None
                report["publication_verification"] = publication
                if (probe.returncode != 0 or publication.get("verified") is not True
                        or publication.get("filename") != name
                        or publication.get("source_sha256") != digest
                        or publication.get("drive_root_folder_id") != args.drive_root_folder_id
                        or publication.get("drive_remote") != args.drive_remote):
                    raise RuntimeError(publication.get("error", "Remote publication verification failed"))
                report["publication_verified"] = True
            exit_code = 0
    except Exception as error:
        report.update({"status": "failed", "error": str(error)})
        exit_code = 1
    finally:
        args.report.parent.mkdir(parents=True, exist_ok=True)
        args.report.write_text(json.dumps(report, indent=2) + "\n")
        print(json.dumps(report, indent=2))
    return exit_code


if __name__ == "__main__":
    raise SystemExit(main())
