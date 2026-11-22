import json

import pytest

from lcp_server import dashboard
from lcp_server.dashboard import DashboardHandler, build_dashboard_payload


def _write_job(root, job_id, filename, *, stage="local_ready", published=False,
               publication_blocked=False):
    jobs = root / "state" / "jobs"
    jobs.mkdir(parents=True, exist_ok=True)
    state = {
        "version": 1,
        "identity": {
            "filename": filename,
            "size_bytes": 123,
            "sha256": "a" * 64,
            "settings": {"transcriber": "elevenlabs", "elevenlabs_model": "scribe_v2"},
        },
        "stage": stage,
        "published": published,
        "publication_blocked": publication_blocked,
        "grok_ingested": False,
        "attempts": 1,
        "artifacts": {
            "CS 201_2026-10-27_1532.md": "b" * 64,
            "CS 201_2026-10-27_1532.txt": "c" * 64,
            "CS 201_2026-10-27_1532.srt": "d" * 64,
        },
        "transcript": {
            "duration": 3720,
            "language": "en",
            "segments": [
                {"start": 0, "end": 18, "text": "Private lecture content.", "speaker": "speaker_0"},
                {"start": 18, "end": 30, "text": "More private lecture content.", "speaker": "speaker_0"},
            ],
        },
    }
    (jobs / f"{job_id}.json").write_text(json.dumps(state))


def test_dashboard_payload_exposes_status_without_transcript_text(tmp_path):
    _write_job(
        tmp_path,
        "1" * 64,
        "CS 201_2026-10-27_1532.m4a",
        stage="quality_blocked",
        publication_blocked=True,
    )

    payload = build_dashboard_payload(tmp_path)

    assert payload["service"]["provider"] == "ElevenLabs Scribe v2"
    assert payload["summary"]["total"] == 1
    assert payload["summary"]["blocked"] == 1
    record = payload["transcripts"][0]
    assert record["course"] == "CS 201"
    assert record["status"] == "blocked"
    assert record["quality"]["cue_count"] == 2
    assert record["artifacts"] == {"md": True, "txt": True, "srt": True}
    assert "transcript" not in record
    assert "Private lecture content" not in json.dumps(payload)


@pytest.mark.parametrize("cached_quality", [False, True], ids=["recomputed", "cached"])
def test_dashboard_snapshot_and_api_hide_private_audio_events(tmp_path, monkeypatch, cached_quality):
    job_id = "1" * 64
    _write_job(tmp_path, job_id, "CS 201_2026-10-27_1532.m4a")
    path = tmp_path / "state" / "jobs" / f"{job_id}.json"
    state = json.loads(path.read_text())
    private_event_text = "PRIVATE_EVENT_not_for_dashboard"
    state["transcript"]["audio_events"] = [{
        "type": "audio_event",
        "start": 30,
        "end": 90,
        "text": private_event_text,
    }]
    if cached_quality:
        state["quality"] = {
            "status": "ok",
            "cue_count": 2,
            "speaker_count": 1,
            "duration_seconds": 3720,
            "audio_event_count": 1,
            "audio_event_seconds": 60,
        }
    path.write_text(json.dumps(state))
    state_before = path.read_bytes()

    assess_calls = []
    original_assess = dashboard.assess_transcript

    def track_assessment(transcript):
        assess_calls.append(True)
        return original_assess(transcript)

    monkeypatch.setattr(dashboard, "assess_transcript", track_assessment)
    snapshot = build_dashboard_payload(tmp_path)
    assert snapshot["transcripts"][0]["quality"]["cue_count"] == 2

    # Exercise the status route and its JSON serialization without a server,
    # socket, or access to any real worker state.
    responses = []
    handler = object.__new__(DashboardHandler)
    handler.root = tmp_path
    handler.path = "/api/status"
    monkeypatch.setattr(handler, "_send", lambda *response: responses.append(response))
    handler.do_GET()

    assert len(responses) == 1
    status, content_type, body = responses[0]
    assert status == 200
    assert content_type == "application/json; charset=utf-8"
    api_payload = json.loads(body)
    assert api_payload["transcripts"][0]["quality"]["cue_count"] == 2
    for payload in (snapshot, api_payload):
        serialized = json.dumps(payload)
        assert private_event_text not in serialized
        assert '"audio_events"' not in serialized
        assert "Private lecture content" not in serialized
    assert len(assess_calls) == (0 if cached_quality else 2)
    assert path.read_bytes() == state_before


def test_dashboard_payload_sanitizes_worker_error_details(tmp_path):
    _write_job(tmp_path, "1" * 64, "CS 201_2026-10-27_1532.m4a", stage="local_ready")
    path = tmp_path / "state" / "jobs" / ("1" * 64 + ".json")
    state = json.loads(path.read_text())
    state["last_error"] = "PublicationError: /private/secret/rclone.conf token=hidden"
    path.write_text(json.dumps(state))

    record = build_dashboard_payload(tmp_path)["transcripts"][0]

    assert record["last_error"] == "PublicationError"
    assert "secret" not in json.dumps(record)


def test_dashboard_payload_exposes_sanitized_repair_progress(tmp_path):
    _write_job(tmp_path, "1" * 64, "CS 201_2026-10-27_1532.m4a", stage="quality_blocked",
               publication_blocked=True)
    path = tmp_path / "state" / "jobs" / ("1" * 64 + ".json")
    state = json.loads(path.read_text())
    state["automatic_repair_attempts"] = 1
    state["automatic_repair_history"] = [{
        "attempt": 1,
        "at": "2026-10-28T12:00:00+00:00",
        "previous_quality": {
            "warnings": [{"code": "cue_over_30s", "message": "private"}],
        },
    }]
    state["transcription"] = {
        "backend": "local-whisper",
        "fallback_used": True,
        "fallback_attempted": True,
        "fallback_settings": {
            "model": "medium.en",
            "device": "cuda",
            "compute_type": "int8_float32",
            "vad_filter": False,
            "min_silence_duration_ms": None,
            "secret": "must not appear",
        },
    }
    path.write_text(json.dumps(state))

    record = build_dashboard_payload(tmp_path)["transcripts"][0]
    repair = record["repair"]
    assert repair["attempts"] == 1
    assert repair["backend"] == "local-whisper"
    assert repair["fallback_settings"] == {
        "model": "medium.en",
        "device": "cuda",
        "compute_type": "int8_float32",
        "vad_filter": False,
    }
    assert repair["history"] == [{
        "attempt": 1,
        "at": "2026-10-28T12:00:00+00:00",
        "warning_codes": ["cue_over_30s"],
    }]
    assert "private" not in json.dumps(record)
    assert "secret" not in json.dumps(record)


def test_dashboard_payload_distinguishes_drive_and_local_jobs(tmp_path):
    _write_job(tmp_path, "1" * 64, "CS182_2026-10-18_1430.m4a", stage="published", published=True)
    (tmp_path / "state" / "jobs" / ("1" * 64 + ".json")).touch()
    _write_job(tmp_path, "2" * 64, "MATH_2026-10-18_1500.m4a", stage="local_ready")

    payload = build_dashboard_payload(tmp_path)

    by_name = {record["filename"]: record for record in payload["transcripts"]}
    assert by_name["CS182_2026-10-18_1430.m4a"]["delivery"] == "drive"
    assert by_name["MATH_2026-10-18_1500.m4a"]["delivery"] == "local"
    assert payload["summary"]["published"] == 1
    assert payload["summary"]["local"] == 1


def test_dashboard_payload_uses_accepted_head_for_duplicate_recordings(tmp_path):
    filename = "CS 201_2026-10-27_1532.m4a"
    _write_job(tmp_path, "1" * 64, filename, stage="published", published=True)
    _write_job(tmp_path, "2" * 64, filename, stage="quality_blocked", publication_blocked=True)
    heads = tmp_path / "state" / "heads.json"
    heads.write_text(json.dumps({filename: {"job_id": "2" * 64}}))

    payload = build_dashboard_payload(tmp_path)

    assert payload["summary"]["total"] == 1
    assert payload["summary"]["blocked"] == 1
    assert payload["transcripts"][0]["id"] == "2" * 64


def test_dashboard_payload_hides_superseded_revision_without_head_index(tmp_path):
    filename = "CS 201_2026-10-27_1532.m4a"
    _write_job(tmp_path, "1" * 64, filename, stage="published", published=True)
    old_path = tmp_path / "state" / "jobs" / ("1" * 64 + ".json")
    old_state = json.loads(old_path.read_text())
    old_state["superseded_by"] = "2" * 64
    old_path.write_text(json.dumps(old_state))
    _write_job(tmp_path, "2" * 64, filename, stage="quality_blocked", publication_blocked=True)

    payload = build_dashboard_payload(tmp_path)

    assert payload["summary"]["total"] == 1
    assert payload["transcripts"][0]["id"] == "2" * 64
    assert "_superseded_by" not in json.dumps(payload)


def test_dashboard_summary_counts_errors_separately_from_processing(tmp_path):
    _write_job(tmp_path, "1" * 64, "CS 201_2026-10-27_1532.m4a", stage="local_ready")
    path = tmp_path / "state" / "jobs" / ("1" * 64 + ".json")
    state = json.loads(path.read_text())
    state["last_error"] = "TranscriptionError: private provider detail"
    path.write_text(json.dumps(state))

    payload = build_dashboard_payload(tmp_path)

    assert payload["summary"]["errors"] == 1
    assert payload["summary"]["processing"] == 0
