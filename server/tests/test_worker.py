import hashlib
import json
import os
from datetime import datetime, timedelta, timezone
from pathlib import Path

import pytest

from lcp_server.models import AudioEvent, Segment, Transcript, TranscriptionSettings
from lcp_server.worker import Worker, WorkerBusy


class FakeTranscriber:
    def __init__(self):
        self.calls = []
        self.error = None

    def transcribe(self, audio):
        self.calls.append(audio.read_bytes())
        if self.error:
            raise self.error
        return Transcript(90.5, (Segment(0, 2, "Hello class."), Segment(75, 79, "A theorem.")))


class CollapsedTranscriber:
    def transcribe(self, audio):
        return Transcript(90, (Segment(0, 90, DENSE_COLLAPSED_TEXT, "speaker_0"),))


# A timestamp-only failure must have enough speech to avoid a separate sparse
# recording-tail relevance gate. That distinction matters for automatic repair.
DENSE_COLLAPSED_TEXT = (
    "This lecture introduces graph representations and the relationships between vertices and edges. "
    "We compare adjacency lists with adjacency matrices, discuss their storage costs, and examine "
    "how traversal algorithms use queues or stacks to visit each reachable vertex while recording "
    "a parent relationship and a discovery order before answering questions."
)


class RepairingTranscriber:
    def __init__(self):
        self.calls = []

    def transcribe(self, audio):
        self.calls.append(audio.read_bytes())
        if len(self.calls) == 1:
            return Transcript(90, (Segment(0, 90, DENSE_COLLAPSED_TEXT, "speaker_0"),))
        return Transcript(90, (
            Segment(0, 12, "Opening lecture point."),
            Segment(72, 88, "A timestamp-safe repair."),
        ))


class SafeTranscriber:
    def __init__(self):
        self.calls = []

    def transcribe(self, audio):
        self.calls.append(audio.read_bytes())
        return Transcript(90, (
            Segment(0, 12, "Opening lecture point."),
            Segment(72, 88, "A timestamp-safe repair."),
        ))


class LateEndedTranscriber:
    def transcribe(self, audio):
        return Transcript(300, (
            Segment(0, 20, "Lecture content.", "speaker_0"),
            Segment(200, 220, "Final point.", "speaker_0"),
        ))


class AccidentalTranscriber:
    def transcribe(self, audio):
        return Transcript(600, (Segment(0, 4, "Testing one two three", "speaker_0"),))


class FakePublisher:
    def __init__(self):
        self.calls = []
        self.error = None

    def publish(self, course, artifacts):
        self.calls.append((course, {p.suffix: p.read_text() for p in artifacts}))
        if self.error:
            raise self.error


def finalized(root, data=b"final AAC bytes", name="CS182_2026-10-18_1430.m4a"):
    inbox = root / "inbox"
    inbox.mkdir(parents=True, exist_ok=True)
    audio = inbox / name
    audio.write_bytes(data)
    marker = inbox / f"{name}.ready.json"
    marker.write_text(json.dumps({"version": 1, "filename": name, "size_bytes": len(data),
                                  "sha256": hashlib.sha256(data).hexdigest()}))
    return audio, marker


def make_worker(root, **kwargs):
    return Worker(root, FakeTranscriber(), **kwargs)


@pytest.mark.parametrize("marker", ["provider-control.json", "provider-repairs.json", "stt-retry-limits.json"])
def test_newer_worker_state_is_preserved_before_initialization(tmp_path, marker):
    state = tmp_path / "state"
    state.mkdir()
    (state / marker).write_text("{}")
    with pytest.raises(ValueError, match="provider controls from a newer worker"):
        make_worker(tmp_path)
    assert sorted(tmp_path.iterdir()) == [state]
    assert sorted(state.iterdir()) == [state / marker]


def test_existing_worker_rechecks_state_version_under_lock(tmp_path):
    worker = make_worker(tmp_path)
    finalized(tmp_path)
    (tmp_path / "state/stt-retry-limits.json").write_text("{}")
    with pytest.raises(ValueError, match="provider controls from a newer worker"):
        worker.run_once()
    assert worker.transcriber.calls == []
    assert list(worker.jobs.iterdir()) == []


def test_accepted_worker_job_exports_to_desktop_feed(tmp_path, monkeypatch):
    exporter = Path(__file__).resolve().parents[1] / "desktop_exporter"
    monkeypatch.syspath_prepend(str(exporter))
    from lcp_desktop_exporter.desktop_export import export_feed

    source = tmp_path / "lectures"
    audio, marker = finalized(source, name="Lab 101_2024-01-15_0900.m4a")
    worker = Worker(source, SafeTranscriber())
    assert worker.run_once().processed == 1
    head = json.loads(worker.heads_path.read_text())[audio.name]["job_id"]
    feed = tmp_path / "feed"
    feed.mkdir(mode=0o700)
    export_feed(source, feed)
    index = json.loads((feed / "index.json").read_text())
    recording, = index["recordings"]
    assert recording["accepted_job_id"] == head
    assert recording["sha256"] == json.loads(marker.read_text())["sha256"]
    assert recording["status"]["quality"] == "eligible"
    reference = recording["transcript"]
    payload = (feed / reference["path"]).read_bytes()
    assert hashlib.sha256(payload).hexdigest() == reference["sha256"]
    assert json.loads(payload)["cues"][-1]["text"] == "A timestamp-safe repair."


@pytest.mark.parametrize("sound_only", [False, True])
def test_worker_retains_typed_events_durably_but_never_publishes_sound_only(tmp_path, sound_only):
    finalized(tmp_path)
    label = "  PRIVATE_EVENT\n\t[ambient sound]  "
    event = AudioEvent(0.125, 90, label)
    speech = () if sound_only else (
        Segment(0, 12, "Opening point.", "speaker_0"),
        Segment(72, 88, "Closing point.", "speaker_0"),
    )

    class EventTranscriber:
        calls = 0

        def transcribe(self, audio):
            self.calls += 1
            return Transcript(90, speech, audio_events=(event,))

    transcriber = EventTranscriber()
    publisher = FakePublisher()
    worker = Worker(tmp_path, transcriber, publisher=publisher)
    result = worker.run_once()
    assert result.failures == ()
    state_path = next((tmp_path / "state" / "jobs").glob("*.json"))
    state = json.loads(state_path.read_text())
    assert state["transcript"]["audio_events"] == [{
        "type": "audio_event", "start": 0.125, "end": 90, "text": label,
    }]
    text = (tmp_path / "vault" / "CS182" / "CS182_2026-10-18_1430.txt").read_text()
    event_line = next(line for line in text.splitlines() if line.startswith("Audio-Events-JSON: "))
    assert json.loads(event_line.removeprefix("Audio-Events-JSON: ")) == state["transcript"]["audio_events"]
    subtitles = (tmp_path / "vault" / "CS182" / "CS182_2026-10-18_1430.srt").read_text()
    assert "PRIVATE_EVENT" not in subtitles
    if sound_only:
        assert result.quality_blocked == 1
        assert state["publication_blocked"] is True
        assert state["quality"]["publication_allowed"] is False
        assert publisher.calls == []
        assert subtitles == "\n"
    else:
        assert result.processed == 1
        assert len(publisher.calls) == 1
        assert state["quality"]["speech_seconds"] == 28
        assert state["quality"]["audio_event_count"] == 1
    worker.run_once()
    assert transcriber.calls == 1


def test_quality_gate_blocks_drive_publication_but_keeps_local_artifacts(tmp_path):
    finalized(tmp_path)
    publisher = FakePublisher()
    worker = Worker(tmp_path, CollapsedTranscriber(), publisher=publisher)

    report = worker.run_once()

    assert report.quality_blocked == 1
    assert report.failures == ()
    assert publisher.calls == []
    course = tmp_path / "vault" / "CS182"
    assert (course / "CS182_2026-10-18_1430.md").exists()
    state = json.loads(next((tmp_path / "state" / "jobs").glob("*.json")).read_text())
    assert state["stage"] == "quality_blocked"
    assert state["publication_blocked"] is True
    assert state["quality"]["publishable"] is False
    assert {warning["code"] for warning in state["quality"]["warnings"]} >= {
        "one_cue_collapse", "cue_over_30s",
    }

    # The unattended worker treats the quality decision as terminal until an
    # operator explicitly enables the override; it must not re-log or retry
    # the same cached transcript every reconciliation interval.
    quiet_retry = Worker(tmp_path, CollapsedTranscriber(), publisher=publisher)
    quiet_report = quiet_retry.run_once()
    assert quiet_report.skipped == 1
    assert quiet_report.quality_blocked == 0
    assert quiet_report.failures == ()
    assert publisher.calls == []

    override = Worker(tmp_path, CollapsedTranscriber(), publisher=publisher,
                      quality_override=True)
    assert override.run_once().processed == 1
    assert len(publisher.calls) == 1
    state = json.loads(next((tmp_path / "state" / "jobs").glob("*.json")).read_text())
    assert state["published"] is True
    assert state["publication_blocked"] is False


def test_automatic_repair_retranscribes_from_verified_archive_once(tmp_path):
    finalized(tmp_path)
    publisher = FakePublisher()
    transcriber = RepairingTranscriber()
    worker = Worker(
        tmp_path,
        transcriber,
        publisher=publisher,
        automatic_repair=True,
    )

    first = worker.run_once()
    assert first.quality_blocked == 1
    assert transcriber.calls == [b"final AAC bytes"]
    assert publisher.calls == []

    second = worker.run_once()
    assert second.processed == 1
    assert second.failures == ()
    assert transcriber.calls == [b"final AAC bytes", b"final AAC bytes"]
    assert len(publisher.calls) == 1
    state = json.loads(next((tmp_path / "state" / "jobs").glob("*.json")).read_text())
    assert state["stage"] == "published"
    assert state["automatic_repair_attempts"] == 1
    assert state["automatic_repair_history"][0]["previous_quality"]["status"] == "blocked"


def test_automatic_repair_is_bounded_when_replacement_remains_unsafe(tmp_path):
    finalized(tmp_path)
    publisher = FakePublisher()
    transcriber = CollapsedTranscriber()
    worker = Worker(tmp_path, transcriber, publisher=publisher, automatic_repair=True)

    assert worker.run_once().quality_blocked == 1
    assert worker.run_once().quality_blocked == 1
    assert worker.run_once().skipped == 1
    assert publisher.calls == []
    state = json.loads(next((tmp_path / "state" / "jobs").glob("*.json")).read_text())
    assert state["stage"] == "quality_blocked"
    assert state["automatic_repair_attempts"] == 1


@pytest.mark.parametrize("failure", ["mixed_repetition", "relevance"])
def test_automatic_repair_does_not_retry_non_citation_or_relevance_blockers(tmp_path, failure):
    finalized(tmp_path)

    class UnsafeTranscriber:
        calls = 0

        def transcribe(self, audio):
            self.calls += 1
            if failure == "mixed_repetition":
                return Transcript(480, tuple(
                    Segment(index * 40, (index + 1) * 40, "Repeated filler phrase.", "speaker_0")
                    for index in range(12)
                ))
            return Transcript(90, (Segment(0, 90, "Sparse tail.", "speaker_0"),))

    transcriber = UnsafeTranscriber()
    publisher = FakePublisher()
    worker = Worker(tmp_path, transcriber, publisher=publisher, automatic_repair=True)

    assert worker.run_once().quality_blocked == 1
    assert worker.run_once().skipped == 1
    assert transcriber.calls == 1
    assert publisher.calls == []
    state = json.loads(next((tmp_path / "state" / "jobs").glob("*.json")).read_text())
    assert state.get("automatic_repair_attempts", 0) == 0


def test_new_quality_gate_blocks_old_published_cache_without_retranscription_or_upload(tmp_path):
    finalized(tmp_path)

    class RepetitiveTranscriber:
        calls = 0

        def transcribe(self, audio):
            self.calls += 1
            return Transcript(600, tuple(
                Segment(index * 20, (index + 1) * 20, "Repeated filler phrase.", "speaker_0")
                for index in range(30)
            ))

    transcriber = RepetitiveTranscriber()
    publisher = FakePublisher()
    assert Worker(tmp_path, transcriber, publisher=publisher, quality_override=True).run_once().processed == 1
    path = next((tmp_path / "state" / "jobs").glob("*.json"))
    old = json.loads(path.read_text())
    old["quality"] = {"status": "pass", "publishable": True, "publication_allowed": True, "warnings": []}
    path.write_text(json.dumps(old))
    artifacts_before = {item.name: item.read_bytes() for item in (tmp_path / "vault" / "CS182").iterdir()}
    worker = Worker(tmp_path, transcriber, publisher=publisher, automatic_repair=True)

    assert worker.run_once().quality_blocked == 1

    state = json.loads(path.read_text())
    assert state["stage"] == "quality_blocked"
    assert state["publication_blocked"] is True
    assert state["published"] is True  # A prior Drive upload is not revoked or erased.
    assert any(item["code"] == "sustained_text_repetition" for item in state["quality"]["warnings"])
    assert transcriber.calls == 1
    assert len(publisher.calls) == 1
    assert artifacts_before == {item.name: item.read_bytes() for item in (tmp_path / "vault" / "CS182").iterdir()}
    stable = path.read_bytes(), path.stat().st_mtime_ns
    assert worker.run_once().skipped == 1
    assert (path.read_bytes(), path.stat().st_mtime_ns) == stable


def test_cached_unique_zero_duration_speech_is_rejected_without_state_loss_or_upload(tmp_path):
    finalized(tmp_path)
    publisher = FakePublisher()
    transcriber = FakeTranscriber()
    worker = Worker(tmp_path, transcriber, publisher=publisher)
    assert worker.run_once().processed == 1
    path = next((tmp_path / "state" / "jobs").glob("*.json"))
    state = json.loads(path.read_text())
    state["transcript"]["segments"].insert(1, {
        "start": 2, "end": 2, "text": "Unique private cached speech.",
    })
    path.write_text(json.dumps(state))
    before = path.read_bytes()
    archive = next((tmp_path / "archive" / "CS182").glob("*.m4a"))
    archived = archive.read_bytes()

    result = worker.run_once()

    assert len(result.failures) == 1
    assert "Invalid transcript segment" in result.failures[0]
    assert "Unique private cached speech" not in result.failures[0]
    assert path.read_bytes() == before
    assert archive.read_bytes() == archived
    assert transcriber.calls == [b"final AAC bytes"]
    assert len(publisher.calls) == 1


def test_archive_reprocess_does_not_publish_repetitive_replacement(tmp_path):
    finalized(tmp_path)
    publisher = FakePublisher()
    assert Worker(tmp_path, FakeTranscriber(), publisher=publisher).run_once().processed == 1

    class RepetitiveTranscriber:
        def transcribe(self, audio):
            return Transcript(600, tuple(
                Segment(index * 20, (index + 1) * 20, "Repeated filler phrase.", "speaker_0")
                for index in range(30)
            ))

    worker = Worker(tmp_path, RepetitiveTranscriber(), publisher=publisher)
    result = worker.reprocess_archived(filename="CS182_2026-10-18_1430.m4a")

    assert result.status == "quality_blocked"
    assert len(publisher.calls) == 1
    state = json.loads((tmp_path / "state" / "jobs" / (result.job_id + ".json")).read_text())
    assert state["quality"]["publication_allowed"] is False


@pytest.mark.parametrize("remove_inputs", [False, True])
def test_legacy_provider_head_migrates_for_automatic_repair(tmp_path, remove_inputs):
    finalized(tmp_path)
    publisher = FakePublisher()
    legacy = Worker(
        tmp_path,
        CollapsedTranscriber(),
        publisher=publisher,
        settings=TranscriptionSettings(elevenlabs_local_fallback=False),
    )
    assert legacy.run_once().quality_blocked == 1
    old_state_path = next((tmp_path / "state" / "jobs").glob("*.json"))
    old_job_id = old_state_path.stem
    if remove_inputs:
        (tmp_path / "inbox" / "CS182_2026-10-18_1430.m4a").unlink()
        (tmp_path / "inbox" / "CS182_2026-10-18_1430.m4a.ready.json").unlink()

    repaired_transcriber = SafeTranscriber()
    repaired = Worker(
        tmp_path,
        repaired_transcriber,
        publisher=publisher,
        settings=TranscriptionSettings(elevenlabs_local_fallback=True),
        automatic_repair=True,
    )
    result = repaired.run_once()

    assert result.processed == 1
    assert repaired_transcriber.calls == [b"final AAC bytes"]
    assert len(publisher.calls) == 1
    states = [json.loads(path.read_text()) for path in (tmp_path / "state" / "jobs").glob("*.json")]
    assert len(states) == 2
    current = next(state for state in states if state.get("superseded_from") == old_job_id)
    current_job_id = hashlib.sha256(json.dumps(current["identity"], sort_keys=True).encode()).hexdigest()
    historical = next(state for state in states if state.get("superseded_by") == current_job_id)
    assert current["identity"]["settings"]["elevenlabs_local_fallback"] is True
    assert current["stage"] == "published"
    assert historical["identity"]["settings"].get("elevenlabs_local_fallback") is None
    heads = json.loads((tmp_path / "state" / "heads.json").read_text())
    assert heads["CS182_2026-10-18_1430.m4a"]["job_id"] == current_job_id


def test_legacy_migration_clears_stale_failure_before_resume(tmp_path):
    finalized(tmp_path)
    publisher = FakePublisher()
    legacy = Worker(
        tmp_path,
        CollapsedTranscriber(),
        publisher=publisher,
        settings=TranscriptionSettings(elevenlabs_local_fallback=False),
    )
    assert legacy.run_once().quality_blocked == 1
    old_state_path = next((tmp_path / "state" / "jobs").glob("*.json"))
    old_state = json.loads(old_state_path.read_text())
    old_state["last_error"] = "TranscriptionError: stale provider failure"
    old_state["retry_count"] = 7
    old_state["retry_after"] = (datetime.now(timezone.utc) + timedelta(hours=1)).isoformat()
    old_state_path.write_text(json.dumps(old_state))

    class InspectingTranscriber(FakeTranscriber):
        active_state = None

        def transcribe(self, audio):
            states = [json.loads(path.read_text()) for path in (tmp_path / "state" / "jobs").glob("*.json")]
            self.active_state = next(state for state in states if state.get("superseded_from"))
            return super().transcribe(audio)

    transcriber = InspectingTranscriber()
    transcriber.error = RuntimeError("new provider failure")
    repaired = Worker(
        tmp_path,
        transcriber,
        publisher=publisher,
        settings=TranscriptionSettings(elevenlabs_local_fallback=True),
        automatic_repair=True,
    )
    report = repaired.run_once()

    assert len(report.failures) == 1
    assert transcriber.calls == [b"final AAC bytes"]
    assert transcriber.active_state["stage"] == "accepted"
    assert transcriber.active_state["last_error"] is None
    assert "retry_count" not in transcriber.active_state
    assert "retry_after" not in transcriber.active_state
    states = [json.loads(path.read_text()) for path in (tmp_path / "state" / "jobs").glob("*.json")]
    current = next(state for state in states if state.get("superseded_from"))
    historical = next(state for state in states if state.get("superseded_by"))
    assert current["stage"] == "accepted"
    assert "new provider failure" in current["last_error"]
    assert current["retry_count"] == 1
    assert historical["last_error"] == "TranscriptionError: stale provider failure"
    assert historical["retry_count"] == 7


@pytest.mark.parametrize("transcriber", [LateEndedTranscriber, AccidentalTranscriber])
def test_relevance_gate_blocks_accidental_or_late_recording_from_drive(tmp_path, transcriber):
    finalized(tmp_path)
    publisher = FakePublisher()
    worker = Worker(tmp_path, transcriber(), publisher=publisher)

    report = worker.run_once()

    assert report.quality_blocked == 1
    assert publisher.calls == []
    state = json.loads(next((tmp_path / "state" / "jobs").glob("*.json")).read_text())
    assert state["stage"] == "quality_blocked"
    assert state["publication_blocked"] is True
    assert state["quality"]["relevance"] in {"needs_review", "likely_accidental"}
    assert state["quality"]["publication_allowed"] is False
    assert (tmp_path / "vault" / "CS182" / "CS182_2026-10-18_1430.txt").exists()

    # A human can explicitly review and override the gate. The default worker
    # remains conservative and never sends the bundle to Drive on its own.
    override = Worker(tmp_path, transcriber(), publisher=publisher, quality_override=True)
    assert override.run_once().processed == 1
    assert len(publisher.calls) == 1


def test_unmarked_recording_is_never_transcribed(tmp_path):
    worker = make_worker(tmp_path)
    (tmp_path / "inbox" / "CS182_2026-10-18_1430.m4a").write_bytes(b"still recording")
    assert worker.run_once().processed == 0
    assert worker.transcriber.calls == []


def test_finalized_recording_produces_timestamped_outputs_and_preserves_inputs(tmp_path):
    audio, marker = finalized(tmp_path)
    worker = make_worker(tmp_path)
    result = worker.run_once()
    assert result.processed == 1
    assert result.failures == ()
    assert audio.read_bytes() == b"final AAC bytes"
    assert marker.exists()
    course = tmp_path / "vault" / "CS182"
    markdown = (course / f"{audio.stem}.md").read_text()
    text = (course / f"{audio.stem}.txt").read_text()
    subtitles = (course / f"{audio.stem}.srt").read_text()
    assert markdown.startswith(f"# Lecture Notes: {audio.stem}\n\n- **Course:** CS182\n")
    assert "**[01:15]** A theorem." in markdown
    assert "Date: 2026-10-18" in text and "Lecture: unknown" in text
    assert "[01:15] A theorem." in text
    assert "00:01:15,000 --> 00:01:19,000" in subtitles
    archives = list((tmp_path / "archive" / "CS182").glob("*.m4a"))
    assert len(archives) == 1 and archives[0].read_bytes() == audio.read_bytes()
    assert list((tmp_path / "work").glob("*/*.m4a")) == []


def test_explicit_professor_calibration_updates_cached_transcript_without_retranscribing(tmp_path):
    finalized(tmp_path)
    first = Worker(tmp_path, CollapsedTranscriber())
    # This fixture has one provider speaker, so calibration is unambiguous.
    assert first.run_once().processed == 1
    calibrated = Worker(
        tmp_path,
        CollapsedTranscriber(),
        professor_speakers={"CS182_2026-10-18_1430": "speaker_0"},
    )
    assert calibrated.run_once().processed == 1
    text = (tmp_path / "vault" / "CS182" / "CS182_2026-10-18_1430.txt").read_text()
    assert "Professor-Speaker: speaker_0" in text
    assert "[speaker_0 (Professor)]" in text


def test_invalid_professor_calibration_is_rejected_before_processing(tmp_path):
    with pytest.raises(ValueError, match="Invalid professor calibration speaker ID"):
        Worker(tmp_path, FakeTranscriber(), professor_speakers={"CS182": "speaker"})


def test_restart_deduplicates_without_retranscribing(tmp_path):
    finalized(tmp_path)
    assert make_worker(tmp_path).run_once().processed == 1
    worker = make_worker(tmp_path)
    assert worker.run_once().skipped == 1
    assert worker.transcriber.calls == []


def test_upload_failure_retries_cached_transcript_after_restart(tmp_path):
    finalized(tmp_path)
    publisher = FakePublisher()
    publisher.error = RuntimeError("Drive unavailable")
    first = make_worker(tmp_path, publisher=publisher)
    assert len(first.run_once().failures) == 1
    state = json.loads(next((tmp_path / "state" / "jobs").glob("*.json")).read_text())
    assert state["attempts"] == 1 and "Drive unavailable" in state["last_error"]
    assert state["published"] is False and state["grok_ingested"] is False
    publisher.error = None
    second = make_worker(tmp_path, publisher=publisher)
    assert second.run_once().processed == 1
    assert second.transcriber.calls == []
    assert second.run_once().skipped == 1
    assert len(publisher.calls) == 2


def test_watch_mode_persists_exponential_backoff_for_provider_failures(tmp_path):
    finalized(tmp_path)
    now = datetime(2026, 10, 21, 12, 0, tzinfo=timezone.utc)
    worker = Worker(
        tmp_path,
        FakeTranscriber(),
        respect_retry_after=True,
        clock=lambda: now,
    )
    worker.transcriber.error = RuntimeError("ElevenLabs unavailable")

    assert len(worker.run_once().failures) == 1
    state_path = next((tmp_path / "state" / "jobs").glob("*.json"))
    state = json.loads(state_path.read_text())
    assert state["retry_count"] == 1
    assert datetime.fromisoformat(state["retry_after"]) == now + timedelta(seconds=60)

    # The watcher reconciles every 30 seconds, but must not call the provider
    # again while the durable retry window is active.
    assert worker.run_once().skipped == 1
    assert len(worker.transcriber.calls) == 1

    # Once the window has elapsed, the same cached source is retried and a
    # successful completion clears the backoff metadata.
    state["retry_after"] = (now - timedelta(seconds=1)).isoformat()
    state_path.write_text(json.dumps(state))
    worker.transcriber.error = None
    assert worker.run_once().processed == 1
    state = json.loads(state_path.read_text())
    assert "retry_after" not in state and "retry_count" not in state


def test_retry_backoff_caps_malformedly_large_retry_count(tmp_path):
    finalized(tmp_path)
    now = datetime(2026, 10, 21, 12, 0, tzinfo=timezone.utc)
    worker = Worker(tmp_path, FakeTranscriber(), respect_retry_after=True, clock=lambda: now)
    worker.transcriber.error = RuntimeError("provider unavailable")
    state_path = tmp_path / "state" / "jobs"
    assert len(worker.run_once().failures) == 1
    state_file = next(state_path.glob("*.json"))
    state = json.loads(state_file.read_text())
    state["retry_count"] = 10 ** 1000
    state.pop("retry_after", None)
    state_file.write_text(json.dumps(state))

    assert len(worker.run_once().failures) == 1
    state = json.loads(state_file.read_text())
    assert datetime.fromisoformat(state["retry_after"]) == now + timedelta(hours=1)


def test_local_only_work_can_be_published_later_without_transcription(tmp_path):
    finalized(tmp_path)
    make_worker(tmp_path).run_once()
    publisher = FakePublisher()
    worker = make_worker(tmp_path, publisher=publisher)
    assert worker.run_once().processed == 1
    assert worker.transcriber.calls == []
    assert publisher.calls[0][0] == "CS182"
    assert set(publisher.calls[0][1]) == {".md", ".txt", ".srt"}


def test_corrected_source_invalidates_transcript_and_keeps_both_archives(tmp_path):
    finalized(tmp_path, b"first")
    worker = make_worker(tmp_path)
    worker.run_once()
    finalized(tmp_path, b"corrected")
    assert worker.run_once().processed == 1
    assert worker.transcriber.calls == [b"first", b"corrected"]
    assert {p.read_bytes() for p in (tmp_path / "archive" / "CS182").glob("*.m4a")} == {
        b"first", b"corrected"}


def test_changed_model_settings_invalidate_transcript(tmp_path):
    finalized(tmp_path)
    make_worker(tmp_path).run_once()
    worker = make_worker(tmp_path, settings=TranscriptionSettings(model="large-v3"))
    assert worker.run_once().processed == 1
    assert len(worker.transcriber.calls) == 1


@pytest.mark.parametrize("change", ["missing", "size", "hash"])
def test_out_of_order_or_unmatched_manifest_waits_for_matching_audio(tmp_path, change):
    audio, marker = finalized(tmp_path)
    if change == "missing":
        audio.unlink()
    elif change == "size":
        audio.write_bytes(b"short")
    else:
        audio.write_bytes(b"wrong AAC bytes")
    worker = make_worker(tmp_path)
    assert worker.run_once().pending == 1
    assert worker.transcriber.calls == []
    finalized(tmp_path)
    assert worker.run_once().processed == 1


@pytest.mark.parametrize("changes", [
    {"version": 2}, {"size_bytes": -1}, {"size_bytes": True}, {"sha256": "no"},
    {"filename": "../outside.m4a"}, {"filename": "/tmp/outside.m4a"},
    {"filename": "OTHER_2026-10-18_1430.m4a"},
])
def test_invalid_manifest_is_rejected(tmp_path, changes):
    _, marker = finalized(tmp_path)
    content = json.loads(marker.read_text())
    content.update(changes)
    marker.write_text(json.dumps(content))
    worker = make_worker(tmp_path)
    assert len(worker.run_once().failures) == 1
    assert worker.transcriber.calls == []


@pytest.mark.parametrize("which", ["audio", "marker"])
def test_symlink_inputs_are_rejected(tmp_path, which):
    audio, marker = finalized(tmp_path)
    victim = audio if which == "audio" else marker
    outside = tmp_path / "outside"
    victim.rename(outside)
    victim.symlink_to(outside)
    worker = make_worker(tmp_path)
    assert len(worker.run_once().failures) == 1
    assert worker.transcriber.calls == []


def test_symlink_output_course_cannot_escape_vault(tmp_path):
    finalized(tmp_path)
    worker = make_worker(tmp_path)
    outside = tmp_path / "outside"
    outside.mkdir()
    (tmp_path / "vault" / "CS182").symlink_to(outside, target_is_directory=True)
    assert len(worker.run_once().failures) == 1
    assert list(outside.iterdir()) == []


def test_archive_corruption_is_not_overwritten_and_scratch_is_preserved(tmp_path):
    finalized(tmp_path)
    worker = make_worker(tmp_path)
    worker.run_once()
    archive = next((tmp_path / "archive" / "CS182").glob("*.m4a"))
    archive.write_bytes(b"unrelated data")
    result = worker.run_once()
    assert len(result.failures) == 1
    assert archive.read_bytes() == b"unrelated data"
    assert len(list((tmp_path / "work").glob("*/*.m4a"))) == 1


def test_transcription_failure_retains_verified_copy_then_retries(tmp_path):
    finalized(tmp_path)
    worker = make_worker(tmp_path)
    worker.transcriber.error = RuntimeError("CUDA unavailable")
    assert len(worker.run_once().failures) == 1
    assert len(list((tmp_path / "work").glob("*/*.m4a"))) == 1
    worker.transcriber.error = None
    assert worker.run_once().processed == 1


def test_missing_artifact_is_rebuilt_from_cache_and_republished(tmp_path):
    finalized(tmp_path)
    publisher = FakePublisher()
    worker = make_worker(tmp_path, publisher=publisher)
    worker.run_once()
    next((tmp_path / "vault" / "CS182").glob("*.txt")).unlink()
    assert worker.run_once().processed == 1
    assert len(worker.transcriber.calls) == 1
    assert len(publisher.calls) == 2


def test_worker_excludes_a_concurrent_process(tmp_path):
    worker = make_worker(tmp_path)
    with worker.lock():
        with pytest.raises(WorkerBusy):
            make_worker(tmp_path).run_once()


def test_one_bad_marker_does_not_prevent_other_courses(tmp_path):
    _, bad = finalized(tmp_path)
    bad.write_text("not JSON")
    finalized(tmp_path, name="MATH_2026-10-18_1530.m4a")
    result = make_worker(tmp_path).run_once()
    assert result.processed == 1 and len(result.failures) == 1


@pytest.mark.parametrize("change", ["audio_removed", "both_removed", "audio_replaced", "archive_only"])
def test_failed_publication_resumes_after_synced_inputs_disappear(tmp_path, change):
    audio, marker = finalized(tmp_path)
    publisher = FakePublisher()
    publisher.error = RuntimeError("Drive unavailable")
    assert len(make_worker(tmp_path, publisher=publisher).run_once().failures) == 1
    if change == "audio_replaced":
        audio.write_bytes(b"different incoming version")
    else:
        audio.unlink()
    if change in {"both_removed", "archive_only"}:
        marker.unlink()
    if change == "archive_only":
        next((tmp_path / "work").glob("*/*.m4a")).unlink()
    publisher.error = None
    worker = make_worker(tmp_path, publisher=publisher)
    assert worker.run_once().processed == 1
    assert worker.transcriber.calls == []
    assert len(publisher.calls) == 2


def test_failed_transcription_resumes_verified_scratch_without_inbox(tmp_path):
    audio, marker = finalized(tmp_path)
    worker = make_worker(tmp_path)
    worker.transcriber.error = RuntimeError("CUDA unavailable")
    assert len(worker.run_once().failures) == 1
    audio.unlink()
    marker.unlink()
    replacement = make_worker(tmp_path)
    assert replacement.run_once().processed == 1
    assert replacement.transcriber.calls == [b"final AAC bytes"]


def test_marker_without_matching_audio_never_creates_resumable_work(tmp_path):
    audio, marker = finalized(tmp_path)
    audio.unlink()
    worker = make_worker(tmp_path)
    assert worker.run_once().pending == 1
    marker.unlink()
    assert make_worker(tmp_path).run_once().processed == 0
    assert not (tmp_path / "state" / "heads.json").exists()
    assert list((tmp_path / "state" / "jobs").glob("*.json")) == []


def test_old_failed_job_cannot_publish_over_successful_correction_after_input_removal(tmp_path):
    finalized(tmp_path, b"original")
    publisher = FakePublisher()
    publisher.error = RuntimeError("Drive unavailable")
    first = make_worker(tmp_path, publisher=publisher)
    assert len(first.run_once().failures) == 1
    audio, marker = finalized(tmp_path, b"corrected")
    publisher.error = None
    corrected = make_worker(tmp_path, publisher=publisher)
    assert corrected.run_once().processed == 1
    current_state = next(state for path in (tmp_path / "state" / "jobs").glob("*.json")
                         if (state := json.loads(path.read_text()))["identity"]["sha256"] == hashlib.sha256(b"corrected").hexdigest())
    assert current_state["published"] is True
    audio.unlink()
    marker.unlink()
    restart = make_worker(tmp_path, publisher=publisher)
    report = restart.run_once()
    assert report.skipped == 1 and report.processed == 0 and report.failures == ()
    assert len(publisher.calls) == 2
    assert restart.transcriber.calls == []


def test_different_pending_marker_blocks_old_failed_publication(tmp_path):
    finalized(tmp_path, b"original")
    publisher = FakePublisher()
    publisher.error = RuntimeError("Drive unavailable")
    assert len(make_worker(tmp_path, publisher=publisher).run_once().failures) == 1
    audio, _ = finalized(tmp_path, b"corrected")
    audio.unlink()  # Replacement marker has arrived before replacement audio.
    publisher.error = None
    assert make_worker(tmp_path, publisher=publisher).run_once().pending == 1
    assert len(publisher.calls) == 1


def test_acceptance_head_recovers_crash_before_initial_job_state(tmp_path):
    audio, marker = finalized(tmp_path)
    worker = make_worker(tmp_path)
    worker.transcriber.error = RuntimeError("first attempt failed")
    assert len(worker.run_once().failures) == 1
    next((tmp_path / "state" / "jobs").glob("*.json")).unlink()
    audio.unlink()
    marker.unlink()
    recovery = make_worker(tmp_path)
    assert recovery.run_once().processed == 1
    assert len(recovery.transcriber.calls) == 1


@pytest.mark.parametrize("remove_inputs", [False, True])
def test_completed_reconciliation_does_not_read_or_copy_audio_or_rewrite_state(tmp_path, monkeypatch, remove_inputs):
    import lcp_server.worker as worker_module

    audio, marker = finalized(tmp_path)
    publisher = FakePublisher()
    make_worker(tmp_path, publisher=publisher).run_once()
    if remove_inputs:
        audio.unlink()
        marker.unlink()
    worker = make_worker(tmp_path, publisher=publisher)
    original_fingerprint = worker_module.fingerprint

    def small_artifacts_only(path):
        assert path.suffix != ".m4a", "Completed reconciliation must not reread lecture audio"
        return original_fingerprint(path)

    def unexpected_write(*args, **kwargs):
        raise AssertionError("Completed reconciliation must not copy audio or rewrite durable state")

    monkeypatch.setattr(worker_module, "fingerprint", small_artifacts_only)
    monkeypatch.setattr(worker_module, "copy_verified", unexpected_write)
    monkeypatch.setattr(worker_module, "atomic_json", unexpected_write)
    monkeypatch.setattr(worker_module, "atomic_bytes", unexpected_write)
    assert worker.run_once().skipped == 1
    assert worker.transcriber.calls == []
    assert len(publisher.calls) == 1


def test_archive_stat_change_forces_full_content_verification(tmp_path, monkeypatch):
    import lcp_server.filesystem as filesystem

    finalized(tmp_path)
    worker = make_worker(tmp_path)
    worker.run_once()
    archive = next((tmp_path / "archive" / "CS182").glob("*.m4a"))
    info = archive.stat()
    os.utime(archive, ns=(info.st_atime_ns, info.st_mtime_ns + 1_000_000))
    verified = []
    original_fingerprint = filesystem.fingerprint

    def track(path):
        verified.append(path)
        return original_fingerprint(path)

    monkeypatch.setattr(filesystem, "fingerprint", track)
    assert worker.run_once().failures == ()
    assert archive in verified
    assert len(worker.transcriber.calls) == 1


def test_missing_archive_is_repaired_from_source_without_retranscription(tmp_path):
    finalized(tmp_path)
    worker = make_worker(tmp_path)
    worker.run_once()
    archive = next((tmp_path / "archive" / "CS182").glob("*.m4a"))
    archive.unlink()
    assert worker.run_once().failures == ()
    assert archive.read_bytes() == b"final AAC bytes"
    assert len(worker.transcriber.calls) == 1


def test_changed_publication_destination_republishes_cached_transcript(tmp_path):
    finalized(tmp_path)
    publisher = FakePublisher()
    make_worker(tmp_path, publisher=publisher, publication_key="folder-a").run_once()
    worker = make_worker(tmp_path, publisher=publisher, publication_key="folder-b")
    assert worker.run_once().processed == 1
    assert worker.transcriber.calls == []
    assert len(publisher.calls) == 2


def test_fast_path_does_not_skip_interrupted_final_state_commit(tmp_path):
    finalized(tmp_path)
    make_worker(tmp_path).run_once()
    state_path = next((tmp_path / "state" / "jobs").glob("*.json"))
    state = json.loads(state_path.read_text())
    state["stage"] = "archived"  # Crash after writing artifacts, before local_ready.
    state_path.write_text(json.dumps(state))
    worker = make_worker(tmp_path)
    assert worker.run_once().failures == ()
    assert json.loads(state_path.read_text())["stage"] == "local_ready"
    assert worker.transcriber.calls == []


def test_malformed_head_isolated_from_healthy_durable_resume(tmp_path):
    first_audio, first_marker = finalized(tmp_path)
    second_audio, second_marker = finalized(
        tmp_path, name="MATH_2026-10-18_1530.m4a"
    )
    worker = make_worker(tmp_path)
    assert worker.run_once().processed == 2

    # The inbox is receive-only and may be cleaned up independently after the
    # worker has accepted both recordings.  Resume therefore has to use the
    # durable heads/state records.  Simulate one damaged head entry while the
    # other remains valid.
    first_audio.unlink()
    first_marker.unlink()
    second_audio.unlink()
    second_marker.unlink()
    heads_path = tmp_path / "state" / "heads.json"
    heads = json.loads(heads_path.read_text())
    heads[first_audio.name]["identity"] = None
    heads_path.write_text(json.dumps(heads))

    resumed = make_worker(tmp_path)
    report = resumed.run_once()

    assert report.processed == 0
    assert report.skipped == 1
    assert len(report.failures) == 1
    assert report.failures[0] == (
        f"{first_audio.name}: invalid accepted recording head (identity)"
    )
    assert resumed.transcriber.calls == []


@pytest.mark.parametrize("contents", ["not JSON", "[]"])
def test_malformed_heads_document_is_reported_without_processing(tmp_path, contents):
    finalized(tmp_path)
    (tmp_path / "state").mkdir(parents=True, exist_ok=True)
    (tmp_path / "state" / "heads.json").write_text(contents)

    worker = make_worker(tmp_path)
    report = worker.run_once()

    assert report.processed == 0
    assert len(report.failures) == 1
    assert "state/heads.json: invalid accepted recording index" in report.failures[0]
    if contents == "[]":
        assert report.failures[0].endswith("(expected an object)")
    assert worker.transcriber.calls == []


def test_matching_marker_repairs_malformed_head_entry(tmp_path):
    audio, _ = finalized(tmp_path)
    worker = make_worker(tmp_path)
    (tmp_path / "state" / "heads.json").write_text(
        json.dumps({audio.name: "damaged head"})
    )

    report = worker.run_once()

    assert report.processed == 1
    assert report.failures == ()
    assert worker.transcriber.calls == [b"final AAC bytes"]
    heads = json.loads((tmp_path / "state" / "heads.json").read_text())
    assert isinstance(heads[audio.name], dict)
    assert heads[audio.name]["identity"]["filename"] == audio.name
