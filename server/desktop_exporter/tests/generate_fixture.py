"""Generate deliberate synthetic cross-language fixture bytes, never real data."""
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from lcp_desktop_exporter.desktop_export import export_feed
from test_desktop_export import seed, write


def generate(destination):
    if destination.exists():
        raise ValueError("Fixture destination must be new")
    with tempfile.TemporaryDirectory(prefix="lcp-SYNTHETIC-fixture-") as folder:
        source, feed = Path(folder) / "source", Path(folder) / "feed"
        source.mkdir(mode=0o700)
        feed.mkdir(mode=0o700)
        heads = {}
        for label, job in [("Eligible", "synthetic-eligible-job"), ("Blocked", "synthetic-blocked-job"),
                           ("Missing", "synthetic-missing-job"), ("Unaccepted", "synthetic-unaccepted-job")]:
            name = "SYNTHETIC " + label + "_2026-11-19_1200.m4a"
            identity, head, state = seed(source, name=name, job=job)
            if label != "Unaccepted":
                heads[name] = head
            if label == "Blocked":
                state["publication_blocked"] = True
                state["stage"] = "quality_blocked"
                write(source / "state/jobs" / (job + ".json"), state)
            if label == "Missing":
                (source / "state/jobs" / (job + ".json")).unlink()
        write(source / "state/heads.json", heads)
        result = export_feed(source, feed, producer_id="lcp-synthetic-fixture", environment="synthetic-only")
        destination.mkdir(mode=0o700, parents=True)
        shutil.copy2(feed / "index.json", destination / "index.json")
        shutil.copytree(feed / "payloads", destination / "payloads")
        index = json.loads((destination / "index.json").read_bytes())
        assert sum(r["transcript"] is not None for r in index["recordings"]) == 1
        manifest = {"synthetic_only": True, "export_result": result,
                    "files": {str(p.relative_to(destination)): {"sha256": hashlib.sha256(p.read_bytes()).hexdigest(), "size_bytes": p.stat().st_size}
                              for p in sorted(destination.rglob("*")) if p.is_file()}}
        return manifest


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("destination", type=Path)
    args = parser.parse_args()
    print(json.dumps(generate(args.destination), indent=2))
