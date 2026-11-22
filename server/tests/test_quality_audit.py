import hashlib
import json
from pathlib import Path

from lcp_server.cli import main
from lcp_server.quality_audit import audit_quality_jobs


def write_job(root: Path, job_id: str, filename: str, transcript: dict, **extra):
    jobs = root / "state" / "jobs"
    jobs.mkdir(parents=True, exist_ok=True)
    state = {
        "version": 1,
        "identity": {"filename": filename, "size_bytes": 1, "sha256": "a" * 64,
                      "settings": {}},
        "stage": "local_ready",
        "published": False,
        "publication_blocked": False,
        "transcript": transcript,
        **extra,
    }
    path = jobs / f"{job_id}.json"
    path.write_text(json.dumps(state))
    return path


def collapsed_transcript():
    return {"duration": 90, "language": "en", "segments": [
        {"start": 0, "end": 90, "text": "One collapsed cue.", "speaker": "speaker_0"},
    ]}


def normal_transcript():
    return {"duration": 20, "language": "en", "segments": [
        {"start": 0, "end": 10, "text": "Welcome.", "speaker": "speaker_0"},
        {"start": 10, "end": 20, "text": "Questions?", "speaker": "speaker_0"},
    ]}


def test_quality_audit_recomputes_selected_cached_transcript_without_writing(tmp_path):
    first = write_job(tmp_path, "1" * 64, "CS201_2026-10-20_1000.m4a", collapsed_transcript())
    write_job(tmp_path, "2" * 64, "LIT101_2026-10-20_1100.m4a", normal_transcript())
    state_dir = tmp_path / "state" / "jobs"
    before = {
        path.name: (hashlib.sha256(path.read_bytes()).hexdigest(), path.stat().st_mtime_ns)
        for path in state_dir.glob("*.json")
    }

    result = audit_quality_jobs(tmp_path, filename="CS201_2026-10-20_1000.m4a")

    assert result.errors == ()
    assert len(result.reports) == 1
    assert result.reports[0].report.publishable is False
    assert {warning.code for warning in result.reports[0].report.warnings} >= {
        "one_cue_collapse", "cue_over_30s",
    }
    after = {
        path.name: (hashlib.sha256(path.read_bytes()).hexdigest(), path.stat().st_mtime_ns)
        for path in state_dir.glob("*.json")
    }
    assert after == before

    all_jobs = audit_quality_jobs(tmp_path)
    assert len(all_jobs.reports) == 2
    assert all_jobs.blocked_count == 1
    selected_by_job = audit_quality_jobs(tmp_path, job_id="1" * 64)
    assert [record.job_id for record in selected_by_job.reports] == ["1" * 64]


def test_quality_audit_reports_missing_cached_transcript_as_structured_error(tmp_path):
    write_job(tmp_path, "3" * 64, "MATH_2026-10-20_1200.m4a", None)

    result = audit_quality_jobs(tmp_path, job_id="3" * 64)

    assert len(result.reports) == 0
    assert len(result.errors) == 1
    assert "no cached transcript" in result.errors[0].message
    assert result.to_dict()["errors"][0]["job_id"] == "3" * 64


def test_quality_audit_cli_json_is_read_only_and_does_not_load_transcriber(tmp_path, capsys):
    write_job(tmp_path, "4" * 64, "CS201_2026-10-20_1000.m4a", collapsed_transcript())

    assert main([
        "quality-audit", "--root", str(tmp_path), "--filename",
        "CS201_2026-10-20_1000.m4a", "--json",
    ]) == 0
    output = json.loads(capsys.readouterr().out)
    assert output["count"] == 1
    assert output["blocked_count"] == 1
    assert output["reports"][0]["quality"]["status"] == "blocked"

