#!/usr/bin/env python3
"""Read-only manual capture evidence audit. Never creates a marker or plays audio.

No audio or speech is copied to the report. This audits structural evidence;
human audibility, permission UI, clicks, login and rollback remain manual checks.
"""
from __future__ import annotations

import argparse
import datetime as dt
import hashlib
import json
from pathlib import Path
import re
import stat
import subprocess


def regular(path: Path, limit: int | None = None) -> None:
    info = path.lstat()
    if not stat.S_ISREG(info.st_mode) or path.resolve() != path:
        raise ValueError("Expected a regular fixture file without symlinks")
    if limit is not None and info.st_size > limit:
        raise ValueError("Fixture evidence exceeds its size bound")


def audit(run_id: str) -> dict:
    if not re.fullmatch(r"[A-Za-z0-9_-]{1,64}", run_id):
        raise ValueError("Invalid run ID")
    root = Path.home() / "Library/Application Support/LCP Capture/Acceptance" / run_id
    if root.resolve() != root or not root.is_dir():
        raise ValueError("Isolated fixture is missing or uses symlinks")
    regular(root / "fixture.json", 1_048_576)
    fixture = json.loads((root / "fixture.json").read_text())
    if fixture.get("schemaVersion") != 1 or fixture.get("fictional") is not True or fixture.get("runID") != run_id:
        raise ValueError("Fixture identity does not match")
    entries = {e["courseCode"]: e for e in fixture["entries"]}
    event_files = sorted((root / "Events").glob("*.jsonl"))
    if len(event_files) > 256:
        raise ValueError("Too many receipt files")
    events = []
    for file in event_files:
        regular(file, 8_388_608)
        for line in file.read_text().splitlines():
            if len(line.encode()) > 65_536:
                raise ValueError("Receipt entry exceeds its bound")
            value = json.loads(line)
            if value.get("schemaVersion") != 1 or value.get("runID") != run_id or value.get("host") not in {"A", "B"}:
                raise ValueError("Receipt identity does not match")
            if not isinstance(value.get("monotonicNanoseconds"), int):
                raise ValueError("Receipt lacks a monotonic event timestamp")
            events.append(value)
    events.sort(key=lambda e: e["monotonicNanoseconds"])
    results, intervals, failures = [], [], []
    started = {e["sessionID"]: e for e in events if e["event"] == "started" and e.get("sessionID")}
    finalized = [e for e in events if e["event"] == "finalized"]
    seen = set()
    for event in finalized:
        session = event.get("sessionID")
        name = event.get("filename", "")
        if session in seen or session not in started or Path(name).name != name or not name.endswith(".m4a"):
            failures.append("Finalized receipt lacks a unique matching started session")
            continue
        seen.add(session)
        first = started[session]
        course = event.get("courseCode")
        entry = entries.get(course, {})
        if entry.get("host") != event["host"] or entry.get("classID", "").lower() != event.get("academicClassID", "").lower():
            failures.append("Finalized session does not match its synthetic class identity")
            continue
        audio = root / "Incoming" / name
        marker = root / "Incoming" / (name + ".ready.json")
        try:
            regular(audio)
            regular(marker, 16_384)
            before = audio.stat()
            digest = hashlib.sha256()
            with audio.open("rb") as handle:
                for block in iter(lambda: handle.read(1_048_576), b""):
                    digest.update(block)
            after = audio.stat()
            identity = (before.st_ino, before.st_size, before.st_mtime_ns)
            if identity != (after.st_ino, after.st_size, after.st_mtime_ns):
                raise ValueError("Audio changed during read-only validation")
            sidecar = json.loads(marker.read_text())
            actual = digest.hexdigest()
            bytes_match = type(sidecar.get("size_bytes")) is int and sidecar["size_bytes"] == after.st_size == event.get("sizeBytes")
            marker_valid = (sidecar.get("version") == 1 and sidecar.get("filename") == name and bytes_match
                            and sidecar.get("sha256") == actual == event.get("sha256") and after.st_size > 0)
            info = subprocess.run(["/usr/bin/afinfo", str(audio)], capture_output=True, text=True, timeout=20)
            # Read only fixed format fields; do not copy the file path or arbitrary metadata.
            format_line = next((line.strip() for line in info.stdout.splitlines() if line.strip().startswith("Data format:")), "")
            format_valid = (info.returncode == 0 and re.search(r"\b1\s+ch\b", format_line) is not None
                            and re.search(r"\b16000\s+Hz\b", format_line) is not None
                            and "aac" in format_line.lower())
            result = {"host": event["host"], "sessionID": session, "filename": name, "sizeBytes": after.st_size,
                      "sha256": actual, "markerMatchesActualBytes": marker_valid, "aac16kMono": format_valid,
                      "formatDescription": format_line, "passed": marker_valid and format_valid}
            results.append(result)
            if not result["passed"]:
                failures.append("A finalized fixture failed byte/marker/audio-format validation")
            intervals.append((first["monotonicNanoseconds"], event["monotonicNanoseconds"], event["host"], session))
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            failures.append("A finalized fixture could not be validated: " + type(error).__name__)
    overlaps = []
    for index, left in enumerate(intervals):
        for right in intervals[index + 1:]:
            if max(left[0], right[0]) < min(left[1], right[1]):
                overlaps.append([left[3], right[3]])
    blocked = [e for e in events if e["event"] == "start_blocked"]
    excluded_during_peer_capture = sorted({e["host"] for e in blocked if any(
        host != e["host"] and start <= e["monotonicNanoseconds"] <= finish
        and "Another LCP recording" in e.get("detail", "") for start, finish, host, _ in intervals)})
    unfinalized = sorted(p.name for p in (root / "Incoming").glob("*.m4a") if not Path(str(p) + ".ready.json").exists())
    ordinary = sorted({e["host"] for e in events if e["event"] == "ordinary_quit"})
    hardware_evidence = bool(results) and all(r["passed"] for r in results) and not failures and not overlaps
    both_orders = excluded_during_peer_capture == ["A", "B"]
    return {"schemaVersion": 1, "checkedAt": dt.datetime.now(dt.timezone.utc).isoformat(), "runID": run_id,
            "fixtureRoot": str(root), "metadataOnly": True, "eventCount": len(events), "receiptFileCount": len(event_files),
            "finalizedRecordings": results, "blockedAttemptCount": len(blocked), "ordinaryQuitHosts": ordinary,
            "peerExclusionObservedForHosts": excluded_during_peer_capture, "overlappingStartedToFinalizedSessions": overlaps,
            "unmarkedFixtureAudio": unfinalized, "failures": failures, "hardwareStructuralEvidencePassed": hardware_evidence,
            "bothLaunchOrdersExclusionObserved": both_orders,
            "manualCheckpointComplete": False,
            "limits": ["This report does not establish human-audible speech, permission UI, exact click order, finalization-race coverage, login relaunch or cold rollback.",
                       "Crash-left audio is listed without manufacturing a completion marker.",
                       "No transcript, audio bytes, provider request or upload is produced by this verifier."]}


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--run-id", required=True)
    args = parser.parse_args()
    report = audit(args.run_id)
    print(json.dumps(report, indent=2))
    return 0 if report["hardwareStructuralEvidencePassed"] and report["bothLaunchOrdersExclusionObserved"] else 2


if __name__ == "__main__":
    raise SystemExit(main())
