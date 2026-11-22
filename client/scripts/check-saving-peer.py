#!/usr/bin/env python3
"""Run two generated-audio native hosts. Print the private fixture/receipt path."""
from datetime import datetime, timezone
import hashlib
import json
import os
from pathlib import Path
import platform
import subprocess
import tempfile


def require(condition, message):
    if not condition:
        raise RuntimeError(message)


def digest(path):
    return hashlib.sha256(path.read_bytes()).hexdigest()


def read(path):
    return json.loads(path.read_text())


def main():
    require((platform.system(), platform.machine()) == ("Darwin", "arm64"), "Run on the Apple Silicon Mac")
    os.umask(0o077)
    client = Path(__file__).resolve().parents[1]
    root = Path(tempfile.mkdtemp(prefix="LCPSavingPeer-", dir="/private/tmp"))
    print(root, flush=True)
    inputs = sorted((client / "Sources").rglob("*.swift"))
    harness = client / "Acceptance/SavingPeerCheck.swift"
    def hashes():
        return {str(path.relative_to(client.parent)): digest(path) for path in inputs}
    source_hashes = hashes()
    binary = root / "SavingPeerCheck"
    subprocess.run(["xcrun", "swiftc", "-swift-version", "5", "-strict-concurrency=complete",
                    "-warnings-as-errors", "-parse-as-library", "-target", "arm64-apple-macosx14.0",
                    *inputs, harness, "-o", binary], check=True)
    require(source_hashes == hashes(), "Capture source changed during build")
    (root / "classes.json").write_text(json.dumps({
        "version": 1, "source": "google_drive", "root_folder_id": "synthetic_saving",
        "generated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
        "classes": [{"name": f"SavingPeer{host}", "drive_folder_id": f"fixture_{host}"} for host in "AB"],
    }))
    with subprocess.Popen([binary, "B", root]) as b, subprocess.Popen([binary, "A", root]) as a:
        require(a.wait(timeout=45) == 0 and b.wait(timeout=45) == 0, "Native acceptance host failed")

    order = ["A-recording", "A-saving", "B-blocked", "A-closing", "A-finalized", "B-recording", "B-finalized"]
    events = {name: read(root / f"{name}.json") for name in order}
    pids = {"A": a.pid, "B": b.pid}
    require(a.pid != b.pid and all(e["pid"] == pids[name[0]] for name, e in events.items()), "Host identity mismatch")
    times = [events[name]["uptimeNs"] for name in order]
    require(all(t1 < t2 for t1, t2 in zip(times, times[1:])), "Events out of order")
    blocked = events["B-blocked"]
    require(times[1] < blocked["attemptedAtNs"] < times[2], "Start did not occur inside Saving")
    require(blocked["error"] == "CaptureError.captureInUse" and len(blocked["stageEntries"]) == 1,
            "Failed to verify busy error or isolated stage")
    incoming = root / "Incoming"
    expected_outputs = set()
    for host in "AB":
        finalized = events[host + "-finalized"]
        name = finalized["filename"]
        require(Path(name).name == name and name.startswith(f"SavingPeer{host}_"), "Unexpected name")
        audio = incoming / name
        marker = read(incoming / (name + ".ready.json"))
        require(marker == {"version": 1, "filename": name, "size_bytes": audio.stat().st_size, "sha256": digest(audio)},
                "Marker/bytes mismatch")
        require(finalized["sizeBytes"] == marker["size_bytes"] and finalized["sha256"] == marker["sha256"],
                "Coordinator identity differs from saved bytes")
        expected_outputs.update([name, name + ".ready.json"])
    require({f.name for f in incoming.iterdir()} == expected_outputs, "Unexpected staging artifact")
    receipt = {
        "passed": True, "checkedAt": datetime.now(timezone.utc).isoformat(), "macOS": platform.mac_ver()[0],
        "architecture": platform.machine(), "fixture": str(root), "binarySha256": digest(binary),
        "captureSourcesSha256": source_hashes, "harnessSha256": digest(harness), "driverSha256": digest(Path(__file__)),
        "events": events, "verifiedFinalizedAudioAndMarkerPairs": 2, "sameBProcessRetried": True,
        "firstHostAliveThroughPeerReuse": True, "microphoneUsed": False,
        "scope": "Native service in separate processes. Generated AAC, simulated granted permission and controlled encoder close.",
    }
    target = root / "receipt.json"
    target.write_text(json.dumps(receipt, indent=2, sort_keys=True) + "\n")
    print(target)


if __name__ == "__main__":
    main()
