"""All tests create synthetic roots. Never use a production worker/root."""

import ast
from dataclasses import replace
import hashlib
import importlib
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest
from unittest.mock import patch

from lcp_desktop_exporter import desktop_export as de


SYNTHETIC_NAME = "SYNTHETIC Demo_2026-11-19_1200.m4a"
SYNTHETIC_SHA = hashlib.sha256(b"synthetic-audio-identity-no-real-audio").hexdigest()


def write(path, value):
    path.parent.mkdir(exist_ok=True, parents=True)
    path.write_bytes(de.encoded(value))


def seed(root, *, name=SYNTHETIC_NAME, job="opaque-job-A", settings=None, text="Synthetic lecture on binary trees."):
    identity = {"filename": name, "size_bytes": 37, "sha256": SYNTHETIC_SHA}
    job_identity = {**identity, "settings": settings or {"transcriber": "SYNTHETIC-DO-NOT-CALL", "revision": 1}}
    manifest = {"version": 1, **identity}
    head = {"job_id": job, "identity": job_identity, "manifest": manifest}
    state = {"version": 1, "identity": job_identity, "stage": "local_ready", "published": False,
             "publication_blocked": False, "last_error": None,
             "archive": "/SECRET-SOURCE-PATH/never-export", "grok_ingested": True,
             "provider_failure": {"message": "SECRET-PROVIDER-MESSAGE"},
             "transcript": {"duration": 12, "language": "en", "segments": [
                 {"start": 0, "end": 6, "text": text, "speaker": "speaker_0"},
                 {"start": 6, "end": 12, "text": "Synthetic second sentence, with café and 日本語.", "speaker": None}],
                 "audio_events": [{"start": 3, "end": 4, "text": "[synthetic chime]", "type": "audio_event"}]}}
    write(root / "state/heads.json", {name: head})
    write(root / "state/jobs" / (job + ".json"), state)
    write(root / "inbox" / (name + ".ready.json"), manifest)
    # Unrelated controls are canaries. Exporter may not even read them.
    write(root / "state/provider-control.json", {"private": "DO-NOT-READ-OR-MUTATE"})
    write(root / "state/stt-retry-limits.json", {"private": "DO-NOT-READ-OR-MUTATE"})
    return identity, head, state


def tree_digest(root):
    return {str(p.relative_to(root)): (p.read_bytes(), p.stat().st_mtime_ns, p.stat().st_mode)
            for p in root.rglob("*") if p.is_file() and not p.is_symlink()}


class ExportTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix="lcp-desktop-SYNTHETIC-")
        self.addCleanup(self.temp.cleanup)
        # macOS may return /var/... while the real directory is /private/var/...
        # Keep fixtures canonical instead of weakening the no-symlink root gate.
        self.base = Path(self.temp.name).resolve()
        self.source = self.base / "source"
        self.source.mkdir(mode=0o700)
        self.output = self.base / "feed"
        self.output.mkdir(mode=0o700)
        self.identity, self.head, self.state = seed(self.source)

    @property
    def job_path(self):
        return self.source / "state/jobs/opaque-job-A.json"

    def run_export(self, **kw):
        return de.export_feed(self.source, self.output, environment="synthetic-test", **kw)

    def index(self):
        return json.loads((self.output / "index.json").read_bytes())

    def payload(self):
        ref = self.index()["recordings"][0]["transcript"]
        return json.loads((self.output / ref["path"]).read_bytes())

    def fail_preserving_index(self, **kw):
        before = (self.output / "index.json").read_bytes() if (self.output / "index.json").exists() else None
        with self.assertRaises(de.ExportError):
            self.run_export(**kw)
        after = (self.output / "index.json").read_bytes() if (self.output / "index.json").exists() else None
        self.assertEqual(before, after)

    def test_exact_contract_unicode_events_and_source_unchanged(self):
        before = tree_digest(self.source)
        self.run_export()
        self.assertEqual(before, tree_digest(self.source))
        index = self.index()
        self.assertEqual(set(index), de.INDEX_KEYS)
        self.assertEqual(index["schema_version"], 1)
        self.assertIs(index["complete"], True)
        record = index["recordings"][0]
        self.assertEqual(set(record), de.RECORD_KEYS)
        self.assertEqual(set(record["status"]), de.STATUS_KEYS)
        self.assertEqual(record["status"], de.status("local_ready", "eligible", "not_published"))
        self.assertEqual(record["status"]["external_ingestion"], "unknown")
        ref = record["transcript"]
        self.assertEqual(set(ref), {"path", "sha256", "size_bytes", "accepted_job_id"})
        data = (self.output / ref["path"]).read_bytes()
        self.assertEqual(ref["sha256"], hashlib.sha256(data).hexdigest())
        self.assertEqual(ref["size_bytes"], len(data))
        self.assertEqual(ref["path"], "payloads/" + ref["sha256"] + ".json")
        payload = json.loads(data)
        self.assertEqual(set(payload), de.PAYLOAD_KEYS)
        self.assertEqual(set(payload["cues"][0]), {"start", "end", "text", "speaker"})
        self.assertEqual(set(payload["audio_events"][0]), {"start", "end", "text"})
        self.assertEqual(payload["audio_events"][0]["start"], 3)
        self.assertIn("日本語".encode(), data)
        joined = (self.output / "index.json").read_bytes() + data
        for private in [b"SECRET", b"archive", b"provider_failure", b"grok_ingested", b"settings"]:
            self.assertNotIn(private, joined)

    def test_repeated_generation_reuses_exact_payload_bytes(self):
        self.run_export()
        first = self.index()
        data = self.payload()
        self.run_export()
        self.assertNotEqual(first["generation_id"], self.index()["generation_id"])
        self.assertEqual(first["recordings"][0]["transcript"], self.index()["recordings"][0]["transcript"])
        self.assertEqual(data, self.payload())

    def test_same_job_repair_changes_digest_and_keeps_old_payload(self):
        self.run_export()
        old = self.index()["recordings"][0]["transcript"]
        self.state["transcript"]["segments"][0]["text"] = "Synthetic corrected same-job content."
        write(self.job_path, self.state)
        self.run_export()
        new = self.index()["recordings"][0]["transcript"]
        self.assertEqual(old["accepted_job_id"], new["accepted_job_id"])
        self.assertNotEqual(old["sha256"], new["sha256"])
        self.assertTrue((self.output / old["path"]).is_file())

    def test_settings_job_selects_head_only_and_never_opens_history(self):
        old_state = json.loads(json.dumps(self.state))
        old_state["transcript"]["segments"][0]["text"] = "OLD HISTORICAL TEXT"
        write(self.source / "state/jobs/old-history.json", old_state)
        self.head["identity"]["settings"] = {"transcriber": "DIFFERENT-SYNTHETIC-SETTINGS"}
        self.state["identity"] = self.head["identity"]
        self.head["job_id"] = "opaque-settings-revision.B"
        write(self.source / "state/heads.json", {SYNTHETIC_NAME: self.head})
        write(self.source / "state/jobs/opaque-settings-revision.B.json", self.state)
        actual = de.Tree.read
        def guarded(tree, relative, *args, **kwargs):
            self.assertNotIn(relative, {"state/jobs/old-history.json", "state/jobs/opaque-job-A.json", "state/provider-control.json", "state/stt-retry-limits.json"})
            return actual(tree, relative, *args, **kwargs)
        with patch.object(de.Tree, "read", guarded):
            self.run_export()
        self.assertEqual(self.index()["recordings"][0]["accepted_job_id"], "opaque-settings-revision.B")
        self.assertNotIn("OLD HISTORICAL", json.dumps(self.payload()))

    def test_missing_heads_never_falls_back(self):
        self.run_export()
        (self.source / "state/heads.json").unlink()
        self.fail_preserving_index()

    def test_empty_heads_produces_status_only_unaccepted(self):
        write(self.source / "state/heads.json", {})
        self.run_export()
        row = self.index()["recordings"][0]
        self.assertIsNone(row["accepted_job_id"])
        self.assertIsNone(row["transcript"])
        self.assertEqual(row["status"]["processing"], "unaccepted")
        self.assertIs(row["status"]["server_received"], False)

    def test_missing_job_status_only(self):
        self.job_path.unlink()
        self.run_export()
        self.assertIsNone(self.index()["recordings"][0]["transcript"])
        self.assertEqual(self.index()["recordings"][0]["status"]["processing"], "inconsistent")

    def test_missing_marker_status_only(self):
        (self.source / "inbox" / (SYNTHETIC_NAME + ".ready.json")).unlink()
        self.run_export()
        self.assertIsNone(self.index()["recordings"][0]["transcript"])

    def test_inconsistent_head_identity_fail_closed(self):
        self.head["identity"]["size_bytes"] += 1
        write(self.source / "state/heads.json", {SYNTHETIC_NAME: self.head})
        self.fail_preserving_index()

    def test_job_source_mismatch_status_only(self):
        for field, changed in [("filename", "SYNTHETIC Other_2026-11-19_1200.m4a"), ("size_bytes", 38), ("sha256", "b" * 64)]:
            with self.subTest(field=field):
                state = json.loads(json.dumps(self.state))
                state["identity"][field] = changed
                write(self.job_path, state)
                self.run_export()
                self.assertIsNone(self.index()["recordings"][0]["transcript"])

    def test_marker_source_replacement_does_not_disclose_old_head(self):
        self.run_export()
        manifest = {"version": 1, **self.identity, "sha256": "b" * 64}
        write(self.source / "inbox" / (SYNTHETIC_NAME + ".ready.json"), manifest)
        self.run_export()
        row = self.index()["recordings"][0]
        self.assertEqual(row["sha256"], "b" * 64)
        self.assertIsNone(row["transcript"])
        self.assertIsNone(row["accepted_job_id"])
        self.assertEqual(self.index()["retirements"], [{**self.identity, "reason": "source_replaced"}])
        self.run_export()
        self.assertEqual(len(self.index()["retirements"]), 1)

    def test_removed_source_retirement_is_explicit_and_persistent(self):
        self.run_export()
        write(self.source / "state/heads.json", {})
        (self.source / "inbox" / (SYNTHETIC_NAME + ".ready.json")).unlink()
        self.run_export()
        self.assertEqual(self.index()["recordings"], [])
        self.assertEqual(self.index()["retirements"], [{**self.identity, "reason": "no_longer_present"}])

    def test_blocked_and_pending_never_export_content(self):
        cases = [
            {"publication_blocked": True}, {"stage": "quality_blocked"},
            {"stage": "transcribed"}, {"last_error": "SECRET ERROR"},
            {"quality": {"publication_allowed": False}},
            {"quality": {"relevance_status": "needs_review"}},
            {"quality": {"blocking": True}}, {"superseded_by": "another-job"},
        ]
        for change in cases:
            with self.subTest(change=change):
                write(self.job_path, {**self.state, **change})
                self.run_export()
                self.assertIsNone(self.index()["recordings"][0]["transcript"])

    def test_current_quality_reassessed_despite_cached_pass(self):
        self.state["quality"] = {"status": "pass", "publication_allowed": True}
        self.state["transcript"] = {"duration": 120, "segments": [{"start": 0, "end": 120, "text": "Synthetic collapsed cue."}]}
        write(self.job_path, self.state)
        self.run_export()
        self.assertIsNone(self.index()["recordings"][0]["transcript"])
        self.assertEqual(self.index()["recordings"][0]["status"]["quality"], "blocked")

    def test_relevance_gate_and_repetition_gate(self):
        for value in [
            {"duration": 600, "segments": [{"start": 0, "end": 2, "text": "Sparse synthetic."}]},
            {"duration": 180, "segments": [{"start": i*15, "end": (i+1)*15, "text": "Repeated synthetic phrase."} for i in range(12)]},
            {"duration": 12, "segments": [], "audio_events": [{"start": 0, "end": 12, "text": "[synthetic sound]", "type": "audio_event"}]},
        ]:
            with self.subTest(value=value):
                write(self.job_path, {**self.state, "transcript": value})
                self.run_export()
                self.assertIsNone(self.index()["recordings"][0]["transcript"])
                self.assertEqual(self.index()["recordings"][0]["status"]["quality"], "blocked")

    def test_bad_cues_events_speakers_and_nonfinite(self):
        cases = [
            {"start": -1}, {"end": 13}, {"end": 0}, {"end": True}, {"start": float("nan")},
            {"end": float("inf")}, {"text": ""}, {"speaker": "../speaker"}, {"text": "x" * 16385},
        ]
        for change in cases:
            with self.subTest(change=change):
                state = json.loads(json.dumps(self.state))
                state["transcript"]["segments"][0].update(change)
                # Deliberately malformed JSON nonfinite cases bypass safe writer.
                self.job_path.write_text(json.dumps(state))
                try:
                    self.run_export()
                except de.ExportError:
                    continue
                self.assertIsNone(self.index()["recordings"][0]["transcript"])
        state = json.loads(json.dumps(self.state))
        state["transcript"]["audio_events"][0]["end"] = 15
        write(self.job_path, state)
        self.run_export()
        self.assertIsNone(self.index()["recordings"][0]["transcript"])

    def test_no_sort_or_timestamp_repair(self):
        self.state["transcript"]["segments"].reverse()
        write(self.job_path, self.state)
        self.run_export()
        self.assertIsNone(self.index()["recordings"][0]["transcript"])

    def test_mutating_head_job_marker_or_directory_never_commits(self):
        self.run_export()
        baseline = tree_digest(self.source)
        for target in ["head", "job", "marker", "directory"]:
            with self.subTest(target=target):
                def mutate(phase):
                    if phase != "payload_durable":
                        return
                    if target == "head":
                        (self.source / "state/heads.json").write_bytes(b"{}\n")
                    elif target == "job":
                        write(self.job_path, {**self.state, "published": True})
                    elif target == "marker":
                        p = self.source / "inbox" / (SYNTHETIC_NAME + ".ready.json")
                        p.write_bytes(p.read_bytes() + b" ")
                    else:
                        (self.source / "inbox/new-unrelated-name").write_bytes(b"synthetic")
                self.fail_preserving_index(checkpoint=mutate)
                for p in self.source.rglob("*"):
                    if p.is_file() and str(p.relative_to(self.source)) not in baseline:
                        p.unlink()
                for relative, (data, _, _) in baseline.items():
                    (self.source / relative).write_bytes(data)

    def test_crash_after_payload_preserves_previous_complete_index(self):
        self.run_export()
        self.state["transcript"]["segments"][0]["text"] = "Synthetic crash checkpoint revision."
        write(self.job_path, self.state)
        before = (self.output / "index.json").read_bytes()
        def crash(phase):
            if phase == "payload_durable":
                raise RuntimeError("SYNTHETIC crash")
        with self.assertRaises(RuntimeError):
            self.run_export(checkpoint=crash)
        self.assertEqual(before, (self.output / "index.json").read_bytes())
        self.assertEqual(len(list((self.output / "payloads").glob("*.json"))), 2)
        self.run_export()
        self.assertIn("checkpoint", self.payload()["cues"][0]["text"])

    def test_partial_write_failure_keeps_old_index(self):
        self.run_export()
        original = de.os.replace
        def fail_index(src, dst, **kw):
            if dst == "index.json":
                raise OSError("SYNTHETIC disk fault")
            return original(src, dst, **kw)
        with patch.object(de.os, "replace", fail_index):
            self.fail_preserving_index()
        self.assertEqual(list(self.output.glob(".desktop-*.tmp")), [])

    def test_immutable_payload_corruption_not_overwritten(self):
        self.run_export()
        ref = self.index()["recordings"][0]["transcript"]
        path = self.output / ref["path"]
        path.write_bytes(b"synthetic corruption")
        self.fail_preserving_index()
        self.assertEqual(path.read_bytes(), b"synthetic corruption")

    def test_previous_index_cannot_traverse_payload_path(self):
        self.run_export()
        index = self.index()
        index["recordings"][0]["transcript"]["path"] = "../source/state/heads.json"
        write(self.output / "index.json", index)
        self.fail_preserving_index()

    def test_symlink_in_source_ancestor_or_selected_file_denied(self):
        for relative in ["state/heads.json", "state/jobs/opaque-job-A.json", "inbox/" + SYNTHETIC_NAME + ".ready.json"]:
            with self.subTest(relative=relative):
                path = self.source / relative
                data = path.read_bytes()
                saved = self.base / "outside-synthetic.json"
                saved.write_bytes(data)
                path.unlink()
                path.symlink_to(saved)
                self.fail_preserving_index()
                path.unlink()
                path.write_bytes(data)
        alias = self.base / "source-alias"
        alias.symlink_to(self.source, target_is_directory=True)
        with self.assertRaises(de.ExportError):
            de.export_feed(alias, self.output)

    def test_symlink_output_index_or_payloads_denied(self):
        self.run_export()
        (self.output / "index.json").unlink()
        target = self.base / "do-not-touch"
        target.write_bytes(b"SYNTHETIC canary")
        (self.output / "index.json").symlink_to(target)
        with self.assertRaises(de.ExportError):
            self.run_export()
        self.assertEqual(target.read_bytes(), b"SYNTHETIC canary")

    def test_traversal_job_filename_and_overlap_denied(self):
        for job in ["../escape", "/tmp/escape", "a/evil", "a\\evil", ".", "..", "a\x00b"]:
            with self.subTest(job=job):
                write(self.source / "state/heads.json", {SYNTHETIC_NAME: {**self.head, "job_id": job}})
                self.fail_preserving_index()
        for name in ["../Bad_2026-11-19_1200.m4a", "A:B_2026-11-19_1200.m4a", "A\\B_2026-11-19_1200.m4a"]:
            with self.subTest(name=name):
                head = json.loads(json.dumps(self.head))
                head["manifest"]["filename"] = name
                write(self.source / "state/heads.json", {name: head})
                self.fail_preserving_index()
        for output in [self.source, self.source / "subdir", self.base]:
            with self.assertRaises(de.ExportError):
                de.export_feed(self.source, output)

    def test_bounded_input_output_counts_and_storage(self):
        for change in [{"job_bytes": 10}, {"heads_bytes": 10}, {"marker_bytes": 10}, {"payload_bytes": 10},
                       {"index_bytes": 10}, {"total_read_bytes": 10}, {"generation_bytes": 10},
                       {"retained_bytes": 10}, {"retained_files": 0}, {"recordings": 0},
                       {"directory_entries": 0}]:
            with self.subTest(change=change):
                self.fail_preserving_index(bounds=replace(de.Bounds(), **change))

    def test_duplicate_json_key_denied(self):
        (self.source / "state/heads.json").write_bytes(b'{"a":1,"a":2}')
        self.fail_preserving_index()

    def test_no_worker_adapter_provider_or_network_imports(self):
        package = Path(de.__file__).parent
        allowed = {"__future__", "argparse", "contextlib", "fcntl", "hashlib", "json", "math", "os", "pathlib", "re", "stat", "sys", "unicodedata", "uuid", "dataclasses", "datetime", "typing", "_models", "_quality"}
        for file in package.glob("*.py"):
            for node in ast.walk(ast.parse(file.read_text())):
                if isinstance(node, ast.Import):
                    self.assertTrue(all(item.name.split(".")[0] in allowed for item in node.names))
                if isinstance(node, ast.ImportFrom):
                    self.assertIn(node.module, allowed)

    def test_cli_in_subprocess_synthetic_only(self):
        p = subprocess.run([sys.executable, "-B", "-m", "lcp_desktop_exporter.desktop_export", "--source-root", str(self.source), "--output-root", str(self.output), "--environment", "synthetic-cli"], capture_output=True, text=True)
        self.assertEqual(p.returncode, 0, p.stderr)
        self.assertEqual(json.loads(p.stdout)["transcripts"], 1)
        self.assertNotIn(SYNTHETIC_NAME, p.stdout)


if __name__ == "__main__":
    unittest.main()
