import hashlib
import json
from dataclasses import asdict
from datetime import datetime

import pytest

from lcp_server.cli import main
from lcp_server.grok_contract import audit_grok_contract
from lcp_server.manifest import RecordingManifest
from lcp_server.models import AudioEvent, Segment, Transcript
from lcp_server.rendering import render_artifacts, transcript_to_dict


def _synthetic_transcript():
    return Transcript(12, (
        Segment(0.25, 1.5, "Hello class.", "speaker_0"),
        Segment(3.0, 4.25, "Questions?", "speaker_1"),
    ))


def _state(root, manifest, artifacts, *, job_id="1" * 64, published=True, current=True,
           transcript=None, professor_speaker=None):
    jobs = root / "state" / "jobs"
    jobs.mkdir(parents=True, exist_ok=True)
    identity = {
        "filename": manifest.filename, "sha256": manifest.sha256,
        "size_bytes": manifest.size_bytes, "settings": {"transcriber": "elevenlabs"},
    }
    state = {
        "identity": identity,
        "stage": "published" if published else "transcribing",
        "published": published,
        "grok_ingested": False,
        "artifacts": {name: hashlib.sha256(content).hexdigest() for name, content in artifacts.items()},
        "transcript": transcript_to_dict(transcript or _synthetic_transcript()),
        "speaker_calibration": {"professor": professor_speaker},
    }
    (jobs / f"{job_id}.json").write_text(json.dumps(state))
    if current:
        (root / "state" / "heads.json").write_text(json.dumps({manifest.filename: {
            "job_id": job_id, "identity": identity,
            "manifest": {
                "version": 1, "filename": manifest.filename,
                "size_bytes": manifest.size_bytes, "sha256": manifest.sha256,
            },
        }}))
    return state


def _bundle(root, *, transcript=None, quality=None):
    manifest = RecordingManifest(
        "CS 201_2026-10-20_1531.m4a", 7, "a" * 64, "CS 201", datetime(2026, 10, 20, 15, 31)
    )
    course = root / "vault" / manifest.course
    course.mkdir(parents=True)
    transcript = transcript or _synthetic_transcript()
    artifacts = render_artifacts(manifest, transcript, quality)
    for name, content in artifacts.items():
        (course / name).write_bytes(content)
    _state(root, manifest, artifacts, transcript=transcript)
    return manifest, artifacts


def test_grok_contract_audit_accepts_complete_bundle_and_matches_state(tmp_path):
    manifest, artifacts = _bundle(tmp_path)

    result = audit_grok_contract(tmp_path, filename=manifest.filename)

    assert result.errors == ()
    assert result.failed_count == 0
    report = result.reports[0]
    assert report.published is True
    assert report.grok_ingested is False
    assert report.state_artifacts_match is True
    assert report.cached_transcript_matches is True
    assert report.current_quality["publication_allowed"] is True
    assert result.external_ingestion_verified is False


def test_grok_contract_state_flags_follow_matching_revision(tmp_path):
    manifest, artifacts = _bundle(tmp_path)
    # The same source can have several job identities/settings. Publication
    # flags from the historical job must not satisfy the current head.
    _state(tmp_path, manifest, artifacts, job_id="2" * 64, published=False)

    report = audit_grok_contract(tmp_path, filename=manifest.filename).reports[0]

    assert report.job_ids == ("2" * 64,)
    assert report.state_artifacts_match is True
    assert report.published is False
    assert report.grok_ingested is False
    assert "durable job has not been published to Drive" in report.errors


def test_grok_contract_audit_reports_missing_and_mismatched_artifacts(tmp_path):
    manifest, artifacts = _bundle(tmp_path)
    course = tmp_path / "vault" / manifest.course
    srt = tmp_path / "vault" / manifest.course / (manifest.filename[:-4] + ".srt")
    srt.unlink()
    txt = tmp_path / "vault" / manifest.course / (manifest.filename[:-4] + ".txt")
    txt.write_text(txt.read_text().replace("[speaker_1] Questions?", "[speaker_1] Different text"))

    result = audit_grok_contract(tmp_path, filename=manifest.filename)

    assert result.failed_count == 1
    assert "missing or non-regular .srt artifact" in result.reports[0].errors

    # Once the SRT exists, the same audit catches a text mismatch between the
    # two timestamped artifacts that a downstream parser would otherwise see.
    srt.write_bytes(artifacts[manifest.filename[:-4] + ".srt"])
    result = audit_grok_contract(tmp_path, filename=manifest.filename)
    assert "SRT cue text does not match TXT cue text" in result.reports[0].errors


def test_grok_contract_cli_json_is_read_only_and_explicit_about_external_ingestion(tmp_path, capsys):
    manifest, _ = _bundle(tmp_path)
    before = sorted(path.read_bytes() for path in (tmp_path / "vault" / manifest.course).iterdir())

    assert main([
        "grok-audit", "--root", str(tmp_path), "--filename", manifest.filename, "--json",
    ]) == 0
    result = json.loads(capsys.readouterr().out)

    assert result["external_ingestion_verified"] is False
    assert result["reports"][0]["status"] == "pass"
    after = sorted(path.read_bytes() for path in (tmp_path / "vault" / manifest.course).iterdir())
    assert after == before


def test_grok_contract_rejects_stale_markdown_cue_text(tmp_path):
    manifest, _ = _bundle(tmp_path)
    markdown = tmp_path / "vault" / manifest.course / f"{manifest.filename[:-4]}.md"
    markdown.write_text(markdown.read_text().replace("Hello class.", "Stale lecture text."))

    result = audit_grok_contract(tmp_path, filename=manifest.filename)

    assert result.failed_count == 1
    assert "Markdown cue text or timestamps do not match TXT cue text" in result.reports[0].errors


def test_grok_contract_reports_orphan_artifact_without_txt(tmp_path):
    manifest, _ = _bundle(tmp_path)
    txt = tmp_path / "vault" / manifest.course / f"{manifest.filename[:-4]}.txt"
    txt.unlink()

    result = audit_grok_contract(tmp_path)

    assert result.failed_count == 1
    report = result.reports[0]
    assert report.source_filename == manifest.filename
    assert "missing or non-regular .txt artifact" in report.errors


def test_grok_contract_rejects_stale_recording_date_metadata(tmp_path):
    manifest, _ = _bundle(tmp_path)
    txt = tmp_path / "vault" / manifest.course / f"{manifest.filename[:-4]}.txt"
    txt.write_text(txt.read_text().replace("Date: 2026-10-20", "Date: 2026-10-19"))

    result = audit_grok_contract(tmp_path, filename=manifest.filename)

    assert result.failed_count == 1
    assert "TXT Date does not match the recording filename" in result.reports[0].errors


def test_grok_contract_rejects_nonlecture_relevance_flag(tmp_path):
    manifest, _ = _bundle(tmp_path)
    txt = tmp_path / "vault" / manifest.course / f"{manifest.filename[:-4]}.txt"
    txt.write_text(txt.read_text().replace("Relevance: likely_lecture", "Relevance: needs_review"))

    result = audit_grok_contract(tmp_path, filename=manifest.filename)

    assert result.failed_count == 1
    assert "TXT Relevance is needs_review; do not ingest this bundle into Grok" in result.reports[0].errors


def test_grok_contract_requires_explicit_speaker_and_noise_metadata(tmp_path):
    manifest, _ = _bundle(tmp_path)
    txt = tmp_path / "vault" / manifest.course / f"{manifest.filename[:-4]}.txt"
    txt.write_text(txt.read_text().replace("Professor-Speaker: unknown\n", ""))

    result = audit_grok_contract(tmp_path, filename=manifest.filename)

    assert result.failed_count == 1
    assert "TXT metadata missing: Professor-Speaker" in result.reports[0].errors


def test_grok_contract_surfaces_calibrated_professor_and_requires_matching_cue(tmp_path):
    manifest = RecordingManifest(
        "CS 201_2026-10-20_1531.m4a", 7, "a" * 64, "CS 201", datetime(2026, 10, 20, 15, 31)
    )
    course = tmp_path / "vault" / manifest.course
    course.mkdir(parents=True)
    artifacts = render_artifacts(
        manifest,
        Transcript(12, (Segment(0.25, 1.5, "Hello class.", "speaker_0"),)),
        professor_speaker="speaker_0",
    )
    for name, content in artifacts.items():
        (course / name).write_bytes(content)
    _state(
        tmp_path, manifest, artifacts,
        transcript=Transcript(12, (Segment(0.25, 1.5, "Hello class.", "speaker_0"),)),
        professor_speaker="speaker_0",
    )
    result = audit_grok_contract(tmp_path, filename=manifest.filename)
    assert result.reports[0].professor_speaker == "speaker_0"
    assert result.reports[0].passed

    txt = course / f"{manifest.filename[:-4]}.txt"
    txt.write_text(txt.read_text().replace("[speaker_0 (Professor)]", "[speaker_0]"))
    result = audit_grok_contract(tmp_path, filename=manifest.filename)
    assert "TXT Professor-Speaker calibration is not present in any transcript cue" in result.reports[0].errors


def test_current_processing_head_cannot_pass_using_a_historical_published_bundle(tmp_path):
    manifest, artifacts = _bundle(tmp_path)
    replacement = RecordingManifest(
        manifest.filename, manifest.size_bytes + 1, "b" * 64,
        manifest.course, manifest.captured_at,
    )
    _state(tmp_path, replacement, {}, job_id="2" * 64, published=False)

    result = audit_grok_contract(tmp_path)

    assert result.errors == ()
    assert len(result.reports) == 1
    report = result.reports[0]
    assert report.passed is False
    assert report.job_ids == ("2" * 64,)
    assert report.published is False
    assert report.state_artifacts_match is False
    assert "TXT Source-SHA256 does not match the current accepted recording" in report.errors
    assert "durable job has not been published to Drive" in report.errors
    assert result.external_ingestion_verified is False


def test_all_accepted_recordings_are_audited_even_before_any_bundle_exists(tmp_path):
    manifest = RecordingManifest(
        "CS 201_2026-10-22_1539.m4a", 7, "c" * 64, "CS 201", datetime(2026, 10, 22, 15, 39)
    )
    _state(tmp_path, manifest, {}, published=False)

    result = audit_grok_contract(tmp_path)

    assert result.errors == ()
    assert result.failed_count == 1
    report = result.reports[0]
    assert report.source_filename == manifest.filename
    assert report.published is False
    assert report.artifact_hashes == {}
    assert all(f"missing or non-regular {suffix} artifact" in report.errors for suffix in (".md", ".txt", ".srt"))


def test_current_head_with_missing_state_cannot_use_a_historical_state(tmp_path):
    manifest, artifacts = _bundle(tmp_path)
    _state(tmp_path, manifest, artifacts, job_id="2" * 64)
    (tmp_path / "state" / "jobs" / ("2" * 64 + ".json")).unlink()

    report = audit_grok_contract(tmp_path).reports[0]

    assert report.passed is False
    assert report.job_ids == ("2" * 64,)
    assert report.published is None
    assert "current accepted durable job state was not found" in report.errors


def test_current_head_identity_must_match_its_exact_state(tmp_path):
    manifest, _ = _bundle(tmp_path)
    state_path = tmp_path / "state" / "jobs" / ("1" * 64 + ".json")
    state = json.loads(state_path.read_text())
    state["identity"]["sha256"] = "b" * 64
    state_path.write_text(json.dumps(state))

    report = audit_grok_contract(tmp_path, filename=manifest.filename).reports[0]

    assert report.passed is False
    assert "current accepted durable job state is invalid or does not match its head" in report.errors


def test_historical_job_selection_cannot_report_current_bundle_as_its_own(tmp_path):
    manifest, artifacts = _bundle(tmp_path)
    _state(tmp_path, manifest, artifacts, job_id="2" * 64)

    result = audit_grok_contract(tmp_path, job_id="1" * 64)

    assert result.reports == ()
    assert result.errors[0].message == "selected durable job is not the current accepted recording head"


def test_artifact_only_bundle_cannot_prove_current_publication(tmp_path):
    manifest, _ = _bundle(tmp_path)
    (tmp_path / "state" / "heads.json").unlink()

    result = audit_grok_contract(tmp_path)

    assert result.failed_count == 1
    assert result.reports[0].published is None
    assert "current accepted recording head was not found or is invalid" in result.reports[0].errors
    assert result.errors[0].message == "accepted recording index was not found or is not regular"


def test_invalid_accepted_index_is_reported_without_passes(tmp_path):
    _bundle(tmp_path)
    (tmp_path / "state" / "heads.json").write_text("[]")

    result = audit_grok_contract(tmp_path)

    assert result.failed_count == 1
    assert result.errors[0].message == "accepted recording index is invalid"


def test_inconsistent_published_flag_cannot_hide_incomplete_stage(tmp_path):
    manifest, _ = _bundle(tmp_path)
    state_path = tmp_path / "state" / "jobs" / ("1" * 64 + ".json")
    state = json.loads(state_path.read_text())
    state["stage"] = "transcribing"
    state_path.write_text(json.dumps(state))

    report = audit_grok_contract(tmp_path, filename=manifest.filename).reports[0]

    assert report.published is True
    assert report.passed is False
    assert "current accepted durable job has not completed publication" in report.errors


def test_current_head_audit_is_read_only_for_state_and_artifacts(tmp_path):
    _bundle(tmp_path)
    before = {path.relative_to(tmp_path): path.read_bytes() for path in tmp_path.rglob("*") if path.is_file()}

    result = audit_grok_contract(tmp_path)

    assert result.failed_count == 0
    after = {path.relative_to(tmp_path): path.read_bytes() for path in tmp_path.rglob("*") if path.is_file()}
    assert after == before


def test_head_changed_during_audit_cannot_return_a_stale_pass(tmp_path, monkeypatch):
    from lcp_server import grok_contract

    manifest, _ = _bundle(tmp_path)
    original_read = grok_contract.read_json

    def read_and_accept_replacement(path):
        value = original_read(path)
        if path.name == "1" * 64 + ".json":
            heads_path = tmp_path / "state" / "heads.json"
            heads = json.loads(heads_path.read_text())
            heads[manifest.filename]["job_id"] = "2" * 64
            heads_path.write_text(json.dumps(heads))
        return value

    monkeypatch.setattr(grok_contract, "read_json", read_and_accept_replacement)

    result = audit_grok_contract(tmp_path)

    assert result.failed_count == 1
    assert result.errors[0].message == "accepted recording index changed during audit; retry for current completeness"


def test_published_bundle_requires_a_valid_current_cached_transcript(tmp_path):
    manifest, _ = _bundle(tmp_path)
    state_path = tmp_path / "state" / "jobs" / ("1" * 64 + ".json")
    state = json.loads(state_path.read_text())
    state.pop("transcript")
    state["quality"] = {"publication_allowed": True, "status": "pass"}
    state_path.write_text(json.dumps(state))

    report = audit_grok_contract(tmp_path, filename=manifest.filename).reports[0]

    assert report.published is True
    assert report.state_artifacts_match is True
    assert report.passed is False
    assert "current accepted cached transcript is missing or invalid" in report.errors


def test_invalid_cached_transcript_errors_never_echo_private_values(tmp_path):
    manifest, _ = _bundle(tmp_path)
    state_path = tmp_path / "state" / "jobs" / ("1" * 64 + ".json")
    state = json.loads(state_path.read_text())
    state["transcript"]["segments"][0]["start"] = "private provider diagnostic text"
    state_path.write_text(json.dumps(state))

    result = audit_grok_contract(tmp_path, filename=manifest.filename)

    assert result.failed_count == 1
    assert "current accepted cached transcript is missing or invalid" in result.reports[0].errors
    assert "private provider diagnostic text" not in json.dumps(result.to_dict())


def test_cached_transcript_must_match_artifacts_even_when_stored_hashes_match(tmp_path):
    manifest, _ = _bundle(tmp_path)
    state_path = tmp_path / "state" / "jobs" / ("1" * 64 + ".json")
    state = json.loads(state_path.read_text())
    state["transcript"]["segments"][0]["text"] = "A different synthetic current phrase."
    state_path.write_text(json.dumps(state))

    report = audit_grok_contract(tmp_path, filename=manifest.filename).reports[0]

    assert report.state_artifacts_match is True
    assert report.cached_transcript_matches is False
    assert report.passed is False
    assert "current cached transcript does not match rendered publication artifacts" in report.errors


def test_current_quality_is_recomputed_instead_of_trusting_a_stored_pass(tmp_path):
    transcript = Transcript(120, (Segment(0, 119, "Synthetic full lecture cue.", "speaker_0"),))
    manifest, _ = _bundle(tmp_path, transcript=transcript)
    state_path = tmp_path / "state" / "jobs" / ("1" * 64 + ".json")
    state = json.loads(state_path.read_text())
    state["quality"] = {"publication_allowed": True, "status": "pass", "warnings": []}
    state_path.write_text(json.dumps(state))

    report = audit_grok_contract(tmp_path, filename=manifest.filename).reports[0]

    assert report.published is True
    assert report.state_artifacts_match is True
    assert report.cached_transcript_matches is True
    assert report.current_quality["publication_allowed"] is False
    assert "cue_over_30s" in report.current_quality["warning_codes"]
    assert any("current cached transcript fails current quality/relevance gates" in error for error in report.errors)
    assert report.passed is False


def test_current_relevance_is_recomputed_when_artifact_and_state_metadata_are_stale(tmp_path):
    from lcp_server.quality import assess_transcript

    # Simulate an old rendered bundle whose metadata claimed likely_lecture
    # even though the cached recording has a long untranscribed tail.
    transcript = Transcript(120, (
        Segment(0, 1, "Synthetic opening.", "speaker_0"),
        Segment(10, 12, "Synthetic continuation.", "speaker_0"),
    ))
    manifest, _ = _bundle(tmp_path, transcript=transcript, quality=assess_transcript(_synthetic_transcript()))

    report = audit_grok_contract(tmp_path, filename=manifest.filename).reports[0]

    assert report.relevance == "likely_lecture"
    assert report.current_quality["relevance"] == "likely_accidental"
    assert report.current_quality["publication_allowed"] is False
    assert report.cached_transcript_matches is False
    assert report.passed is False


def test_stale_quality_pass_cannot_accept_sustained_repetitive_transcript(tmp_path):
    transcript = Transcript(210, tuple(
        Segment(index * 10, (index + 1) * 10, "Synthetic repeated phrase.", "speaker_0")
        for index in range(20)
    ))
    manifest, _ = _bundle(tmp_path, transcript=transcript)
    state_path = tmp_path / "state" / "jobs" / ("1" * 64 + ".json")
    state = json.loads(state_path.read_text())
    state["quality"] = {"publication_allowed": True, "status": "pass", "warnings": []}
    state_path.write_text(json.dumps(state))

    result = audit_grok_contract(tmp_path, filename=manifest.filename)
    report = result.reports[0]

    assert report.published is True
    assert report.state_artifacts_match is True
    assert report.cached_transcript_matches is True
    assert report.current_quality["publication_allowed"] is False
    assert "sustained_text_repetition" in report.current_quality["warning_codes"]
    assert report.passed is False
    assert "Synthetic repeated phrase." not in json.dumps(result.to_dict())


def _event_transcript():
    return Transcript(
        12, _synthetic_transcript().segments,
        audio_events=(AudioEvent(0.5, 2.75, 'Private synthetic "event"\nlabel \u2028 text.'),),
    )


def _rewrite_event_metadata(path, events):
    value = json.dumps(events, ensure_ascii=True, separators=(",", ":"))
    prefix = "- **Audio events JSON:** " if path.suffix == ".md" else "Audio-Events-JSON: "
    lines = path.read_text().splitlines()
    path.write_text("\n".join(prefix + value if line.startswith(prefix) else line for line in lines) + "\n")


def test_grok_contract_accepts_exact_audio_events_separate_from_speech(tmp_path):
    transcript = _event_transcript()
    manifest, artifacts = _bundle(tmp_path, transcript=transcript)

    result = audit_grok_contract(tmp_path, filename=manifest.filename)

    assert result.failed_count == 0
    assert result.reports[0].cached_transcript_matches is True
    # Speech-only SRT keeps the original cues; event labels are metadata,
    # including embedded newlines and Unicode separators, never speech cues.
    speech_artifacts = render_artifacts(manifest, _synthetic_transcript())
    assert artifacts[manifest.filename[:-4] + ".srt"] == speech_artifacts[manifest.filename[:-4] + ".srt"]
    assert transcript.audio_events[0].text not in json.dumps(result.to_dict())
    assert "Private synthetic" not in json.dumps(result.to_dict())


def test_grok_contract_validates_event_tail_against_exact_cached_duration(tmp_path):
    duration = 12.0123
    transcript = Transcript(
        duration, _synthetic_transcript().segments,
        audio_events=(AudioEvent(11.9, duration, "Synthetic tail event."),),
    )
    manifest, _ = _bundle(tmp_path, transcript=transcript)

    result = audit_grok_contract(tmp_path, filename=manifest.filename)

    # The human duration header is rounded to two decimal minutes. Its
    # rounded value must not reject an event with a valid exact source tail.
    assert result.failed_count == 0
    assert result.reports[0].cached_transcript_matches is True


def test_grok_contract_rejects_different_audio_events_between_markdown_and_txt(tmp_path):
    transcript = _event_transcript()
    manifest, _ = _bundle(tmp_path, transcript=transcript)
    markdown = tmp_path / "vault" / manifest.course / f"{manifest.filename[:-4]}.md"
    changed = [asdict(transcript.audio_events[0]) | {"text": "Different private event label"}]
    _rewrite_event_metadata(markdown, changed)

    result = audit_grok_contract(tmp_path, filename=manifest.filename)

    assert result.failed_count == 1
    assert "Markdown and TXT audio-event metadata do not match" in result.reports[0].errors
    assert "published audio-event metadata does not match current cached transcript" in result.reports[0].errors
    assert "Different private event label" not in json.dumps(result.to_dict())


@pytest.mark.parametrize("suffixes", [(".md",), (".txt",), (".md", ".txt")])
def test_grok_contract_requires_declared_events_in_both_publication_headers(tmp_path, suffixes):
    manifest, _ = _bundle(tmp_path, transcript=_event_transcript())
    for suffix in suffixes:
        path = tmp_path / "vault" / manifest.course / f"{manifest.filename[:-4]}{suffix}"
        prefix = "- **Audio events JSON:** " if suffix == ".md" else "Audio-Events-JSON: "
        path.write_text("\n".join(line for line in path.read_text().splitlines() if not line.startswith(prefix)) + "\n")

    result = audit_grok_contract(tmp_path, filename=manifest.filename)

    assert result.failed_count == 1
    assert "audio-event metadata is missing from publication artifacts" in result.reports[0].errors
    if len(suffixes) == 1:
        assert "Markdown and TXT audio-event metadata do not match" in result.reports[0].errors


def test_grok_contract_binds_event_timing_to_current_cached_duration(tmp_path):
    transcript = _event_transcript()
    manifest, _ = _bundle(tmp_path, transcript=transcript)
    changed = [asdict(transcript.audio_events[0]) | {"end": 13.0}]
    for suffix in (".md", ".txt"):
        path = tmp_path / "vault" / manifest.course / f"{manifest.filename[:-4]}{suffix}"
        _rewrite_event_metadata(path, changed)

    result = audit_grok_contract(tmp_path, filename=manifest.filename)

    assert result.failed_count == 1
    assert "published audio-event timing exceeds current cached transcript duration" in result.reports[0].errors
    assert "Markdown and TXT audio-event metadata do not match" not in result.reports[0].errors
    assert "Private synthetic" not in json.dumps(result.to_dict())


@pytest.mark.parametrize("value", [
    '{"private synthetic malformed label":',
    '{"start":0,"end":1,"text":"private synthetic label","type":"audio_event"}',
    '[{"start":true,"end":1,"text":"private synthetic label","type":"audio_event"}]',
    '[{"start":0,"end":NaN,"text":"private synthetic label","type":"audio_event"}]',
    '[{"start":0,"end":1,"text":"private synthetic label","type":"speech"}]',
    '[{"start":0,"end":1,"text":"private synthetic label","type":"audio_event","extra":1}]',
    '[{"start":0,"start":0.5,"end":1,"text":"private synthetic label","type":"audio_event"}]',
    '[{"start":0,"end":1,"text":" ","type":"audio_event"}]',
])
@pytest.mark.parametrize("suffix", [".md", ".txt"])
def test_grok_contract_rejects_malformed_event_metadata_without_echoing_labels(tmp_path, value, suffix):
    manifest, _ = _bundle(tmp_path, transcript=_event_transcript())
    path = tmp_path / "vault" / manifest.course / f"{manifest.filename[:-4]}{suffix}"
    prefix = "- **Audio events JSON:** " if suffix == ".md" else "Audio-Events-JSON: "
    path.write_text("\n".join(prefix + value if line.startswith(prefix) else line for line in path.read_text().splitlines()) + "\n")

    result = audit_grok_contract(tmp_path, filename=manifest.filename)

    assert result.failed_count == 1
    artifact = "Markdown" if suffix == ".md" else "TXT"
    assert f"{suffix} contract error: {artifact} audio-event metadata is malformed" in result.reports[0].errors
    assert "private synthetic" not in json.dumps(result.to_dict())
    assert "Private synthetic" not in json.dumps(result.to_dict())


def test_grok_contract_rejects_duplicate_markdown_audio_event_header(tmp_path):
    manifest, _ = _bundle(tmp_path, transcript=_event_transcript())
    path = tmp_path / "vault" / manifest.course / f"{manifest.filename[:-4]}.md"
    lines = path.read_text().splitlines()
    event_line = next(line for line in lines if line.startswith("- **Audio events JSON:** "))
    path.write_text("\n".join([*lines[:2], event_line, *lines[2:]]) + "\n")

    result = audit_grok_contract(tmp_path, filename=manifest.filename)

    assert result.failed_count == 1
    assert ".md contract error: Markdown audio-event metadata is malformed" in result.reports[0].errors


def test_grok_contract_invalid_cached_events_never_echo_private_values(tmp_path):
    manifest, _ = _bundle(tmp_path, transcript=_event_transcript())
    path = tmp_path / "state" / "jobs" / ("1" * 64 + ".json")
    state = json.loads(path.read_text())
    state["transcript"]["audio_events"][0]["start"] = "Private synthetic invalid event value"
    path.write_text(json.dumps(state))

    result = audit_grok_contract(tmp_path, filename=manifest.filename)

    assert result.failed_count == 1
    assert "current accepted cached transcript is missing or invalid" in result.reports[0].errors
    assert "Private synthetic" not in json.dumps(result.to_dict())


def test_grok_contract_never_accepts_event_only_publication_or_exposes_its_label(tmp_path):
    transcript = Transcript(120, (), audio_events=(AudioEvent(0, 120, "Private synthetic event-only label"),))
    manifest, _ = _bundle(tmp_path, transcript=transcript)

    result = audit_grok_contract(tmp_path, filename=manifest.filename)

    report = result.reports[0]
    assert result.failed_count == 1
    assert report.passed is False
    assert report.current_quality["publication_allowed"] is False
    assert report.current_quality["relevance"] != "likely_lecture"
    assert "no_speech" in report.current_quality["warning_codes"]
    assert ".md contract error: Markdown artifact contains no timestamped cues" in report.errors
    assert ".txt contract error: TXT artifact contains no timestamped cues" in report.errors
    assert ".srt contract error: SRT artifact contains no cues" in report.errors
    assert "audio-event metadata is missing from publication artifacts" not in report.errors
    assert "Markdown and TXT audio-event metadata do not match" not in report.errors
    assert "Private synthetic" not in json.dumps(result.to_dict())

