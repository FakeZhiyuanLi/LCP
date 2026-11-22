import json
import sys
import threading
from pathlib import Path
from types import ModuleType, SimpleNamespace

import pytest

from lcp_server.cli import main
from lcp_server.models import Segment, Transcript
from lcp_server.worker import WorkerBusy
from lcp_server.watching import relevant_event, watch

from test_worker import FakePublisher, finalized, make_worker


@pytest.fixture
def adapters(monkeypatch):
    module = ModuleType("lcp_server.adapters")
    module.WhisperTranscriber = lambda **kwargs: SimpleNamespace(
        transcribe=lambda _: Transcript(2, (Segment(0, 2, "Hello."),)))
    module.ElevenLabsTranscriber = lambda **kwargs: SimpleNamespace(
        transcribe=lambda _: Transcript(2, (Segment(0, 2, "Hello.", "speaker_0"),)))
    module.CitationFallbackTranscriber = lambda primary, fallback: SimpleNamespace(
        transcribe=lambda _: Transcript(2, (Segment(0, 2, "Fallback.",),)),
        last_transcription_metadata={
            "backend": "local-whisper", "fallback_enabled": True,
            "fallback_attempted": True, "fallback_used": True,
            "speaker_diarization": False,
        },
    )
    module.RclonePublisher = lambda **kwargs: FakePublisher()
    monkeypatch.setitem(sys.modules, "lcp_server.adapters", module)
    return module


def test_help_works_without_ml_runtime():
    with pytest.raises(SystemExit) as error:
        main(["--help"])
    assert error.value.code == 0


def test_cli_once_local_only(tmp_path, adapters):
    audio, _ = finalized(tmp_path)
    assert main(["once", "--root", str(tmp_path), "--transcriber", "local"]) == 0
    assert audio.exists()
    assert (tmp_path / "vault" / "CS182" / f"{audio.stem}.md").exists()


def test_cli_defaults_to_elevenlabs_backend(tmp_path, adapters):
    finalized(tmp_path)
    assert main(["once", "--root", str(tmp_path)]) == 0
    state = json.loads(next((tmp_path / "state" / "jobs").glob("*.json")).read_text())
    assert state["identity"]["settings"]["transcriber"] == "elevenlabs"


def test_cli_local_fallback_is_explicit_and_recorded(tmp_path, adapters):
    finalized(tmp_path)
    assert main([
        "once", "--root", str(tmp_path), "--elevenlabs-local-fallback",
    ]) == 0
    state = json.loads(next((tmp_path / "state" / "jobs").glob("*.json")).read_text())
    assert state["identity"]["settings"]["elevenlabs_local_fallback"] is True
    assert state["transcription"]["backend"] == "local-whisper"
    assert state["transcription"]["fallback_used"] is True
    assert state["transcription"]["speaker_diarization"] is False


def test_cli_citation_repair_enables_tail_preserving_bounded_timestamp_recovery(tmp_path, adapters):
    finalized(tmp_path)
    settings = []

    def whisper(**kwargs):
        settings.append(kwargs)
        return SimpleNamespace(transcribe=lambda _: Transcript(2, (Segment(0, 2, "Hello."),)))

    adapters.WhisperTranscriber = whisper
    assert main(["once", "--root", str(tmp_path), "--elevenlabs-local-fallback"]) == 0

    assert len(settings) == 1
    assert settings[0]["vad_filter"] is False
    assert settings[0]["recover_timestamps"] is True


def test_cli_rejects_fallback_flag_with_direct_local_backend():
    with pytest.raises(SystemExit) as error:
        main(["once", "--transcriber", "local", "--elevenlabs-local-fallback"])
    assert error.value.code == 2


def test_cli_reprocess_dry_run_and_archive_backup(tmp_path, adapters):
    audio, _ = finalized(tmp_path)
    assert main(["once", "--root", str(tmp_path)]) == 0
    state_path = next((tmp_path / "state" / "jobs").glob("*.json"))
    before_state = state_path.read_bytes()

    assert main([
        "reprocess", "--root", str(tmp_path), "--filename", audio.name, "--dry-run",
    ]) == 0
    assert state_path.read_bytes() == before_state
    assert not (tmp_path / "state" / "reprocess-backups").exists()

    assert main(["reprocess", "--root", str(tmp_path), "--filename", audio.name]) == 0
    backups = list((tmp_path / "state" / "reprocess-backups").iterdir())
    assert len(backups) == 1
    assert (backups[0] / "metadata.json").exists()
    assert audio.read_bytes() == b"final AAC bytes"


def test_cli_selects_elevenlabs_and_records_backend_settings(tmp_path, adapters):
    finalized(tmp_path)
    assert main([
        "once", "--root", str(tmp_path), "--transcriber", "elevenlabs",
        "--elevenlabs-model", "scribe_v2", "--no-elevenlabs-diarize",
    ]) == 0
    state = json.loads(next((tmp_path / "state" / "jobs").glob("*.json")).read_text())
    assert state["identity"]["settings"]["transcriber"] == "elevenlabs"
    assert state["identity"]["settings"]["elevenlabs_model"] == "scribe_v2"
    assert state["identity"]["settings"]["elevenlabs_diarize"] is False
    assert state["identity"]["settings"]["elevenlabs_language_code"] == "en"
    assert "[speaker_0]" in (tmp_path / "vault" / "CS182" / "CS182_2026-10-18_1430.txt").read_text()


def test_cli_applies_recording_specific_professor_calibration(tmp_path, adapters):
    finalized(tmp_path)
    calibration = tmp_path / "professor-speakers.json"
    calibration.write_text(json.dumps({"CS182_2026-10-18_1430": "speaker_0"}))
    assert main([
        "once", "--root", str(tmp_path), "--professor-speakers", str(calibration),
    ]) == 0
    text = (tmp_path / "vault" / "CS182" / "CS182_2026-10-18_1430.txt").read_text()
    assert "Professor-Speaker: speaker_0" in text
    assert "[speaker_0 (Professor)]" in text


def test_cli_returns_failure_for_invalid_marker(tmp_path, adapters):
    _, marker = finalized(tmp_path)
    marker.write_text("invalid")
    assert main(["once", "--root", str(tmp_path)]) == 1


def test_cli_explicit_publication(tmp_path, adapters):
    finalized(tmp_path)
    config = tmp_path / "drive.json"
    config.write_text(json.dumps({"CS182": "drive-folder-id"}))
    assert main(["once", "--root", str(tmp_path), "--publish", "--drive-folders", str(config)]) == 0
    state = json.loads(next((tmp_path / "state" / "jobs").glob("*.json")).read_text())
    assert state["published"] is True and state["grok_ingested"] is False


def test_cli_root_folder_publication_needs_no_course_mapping(tmp_path, adapters):
    finalized(tmp_path)
    publisher = FakePublisher()
    settings = []

    def build_publisher(**kwargs):
        settings.append(kwargs)
        return publisher

    adapters.RclonePublisher = build_publisher
    assert main([
        "once", "--root", str(tmp_path), "--publish",
        "--drive-root-folder-id", "lectures-root-id",
    ]) == 0
    assert settings[0]["root_folder_id"] == "lectures-root-id"
    assert settings[0].get("folder_ids") is None
    assert len(publisher.calls) == 1


def test_root_mapping_and_root_id_changes_invalidate_publication_destination(tmp_path, adapters):
    finalized(tmp_path)
    publisher = FakePublisher()
    adapters.RclonePublisher = lambda **kwargs: publisher
    config = tmp_path / "drive.json"
    config.write_text(json.dumps({"CS182": "first-root-id"}))
    common = ["once", "--root", str(tmp_path), "--publish"]

    assert main([*common, "--drive-folders", str(config)]) == 0
    state_path = next((tmp_path / "state" / "jobs").glob("*.json"))
    mapping_key = json.loads(state_path.read_text())["publication_key"]
    assert main([*common, "--drive-root-folder-id", "first-root-id"]) == 0
    root_key = json.loads(state_path.read_text())["publication_key"]
    assert mapping_key != root_key
    assert main([*common, "--drive-root-folder-id", "second-root-id"]) == 0
    changed_root_key = json.loads(state_path.read_text())["publication_key"]
    assert changed_root_key != root_key
    assert len(publisher.calls) == 3
    assert main([*common, "--drive-root-folder-id", "second-root-id"]) == 0
    assert len(publisher.calls) == 3


def test_cli_refuses_combining_root_folder_and_course_mapping():
    with pytest.raises(SystemExit) as error:
        main(["--publish", "--drive-folders", "courses.json",
              "--drive-root-folder-id", "root-id"])
    assert error.value.code == 2


def test_cli_root_folder_argument_alone_does_not_enable_upload(tmp_path, adapters):
    def unexpected(**kwargs):
        raise AssertionError("No publication requested")

    adapters.RclonePublisher = unexpected
    assert main(["once", "--root", str(tmp_path), "--drive-root-folder-id", "root-id"]) == 0


def test_cli_does_not_publish_without_explicit_flag(tmp_path, adapters):
    def unexpected(**kwargs):
        raise AssertionError("No publication requested")
    adapters.RclonePublisher = unexpected
    assert main(["once", "--root", str(tmp_path), "--drive-folders", "/missing"]) == 0


@pytest.mark.parametrize("arguments", [["--publish"], ["--reconcile-seconds", "0"],
                                       ["--reconcile-seconds", "nan"], ["--reconcile-seconds", "inf"]])
def test_cli_rejects_invalid_configuration(arguments):
    with pytest.raises(SystemExit) as error:
        main(arguments)
    assert error.value.code == 2


@pytest.mark.parametrize("name,expected", [
    ("CS182_2026-10-18_1430.m4a", True),
    ("CS182_2026-10-18_1430.m4a.ready.json", True),
    (".syncthing.tmp", False), ("file.wav", False),
])
def test_watcher_selects_relevant_final_paths(tmp_path, name, expected):
    assert relevant_event(str(tmp_path / name), tmp_path) == expected
    assert relevant_event(str(tmp_path / "nested" / name), tmp_path) is False


@pytest.mark.parametrize("interval", [0, float("nan"), float("inf")])
def test_watcher_rejects_busy_loop_interval(tmp_path, interval):
    with pytest.raises(ValueError):
        watch(make_worker(tmp_path), reconcile_seconds=interval)


def test_watch_reconciles_startup_and_handles_close_and_move_events(tmp_path, monkeypatch):
    finalized(tmp_path)
    worker = make_worker(tmp_path)
    stop = threading.Event()
    handlers = []

    class FakeObserver:
        def schedule(self, handler, path, recursive):
            handlers.append(handler)

        def start(self):
            handlers[0].on_closed(SimpleNamespace(is_directory=False, src_path=str(worker.inbox / "test.m4a")))
            handlers[0].on_moved(SimpleNamespace(is_directory=False, dest_path=str(worker.inbox / "test.m4a.ready.json")))

        def stop(self):
            pass

        def join(self):
            pass

    events = ModuleType("watchdog.events")
    events.FileSystemEventHandler = object
    observers = ModuleType("watchdog.observers")
    observers.Observer = FakeObserver
    monkeypatch.setitem(sys.modules, "watchdog", ModuleType("watchdog"))
    monkeypatch.setitem(sys.modules, "watchdog.events", events)
    monkeypatch.setitem(sys.modules, "watchdog.observers", observers)
    original = worker._reconcile

    def once():
        report = original()
        stop.set()
        return report

    monkeypatch.setattr(worker, "_reconcile", once)
    watch(worker, reconcile_seconds=0.01, stop=stop)
    assert len(worker.transcriber.calls) == 1


def test_watch_releases_lock_between_reconciliation_passes(tmp_path, monkeypatch):
    """A live watcher must not block operator reprocess commands while idle."""
    worker = make_worker(tmp_path)
    entered = threading.Event()
    release = threading.Event()

    class FakeObserver:
        def schedule(self, handler, path, recursive):
            pass

        def start(self):
            pass

        def stop(self):
            pass

        def join(self):
            pass

    events = ModuleType("watchdog.events")
    events.FileSystemEventHandler = object
    observers = ModuleType("watchdog.observers")
    observers.Observer = FakeObserver
    monkeypatch.setitem(sys.modules, "watchdog", ModuleType("watchdog"))
    monkeypatch.setitem(sys.modules, "watchdog.events", events)
    monkeypatch.setitem(sys.modules, "watchdog.observers", observers)

    def one_pass():
        entered.set()
        release.wait(1)
        return SimpleNamespace(processed=0, quality_blocked=0, failures=())

    monkeypatch.setattr(worker, "_reconcile", one_pass)
    stop = threading.Event()
    thread = threading.Thread(target=watch, args=(worker,), kwargs={"reconcile_seconds": 1, "stop": stop})
    thread.start()
    assert entered.wait(1)
    with pytest.raises(WorkerBusy):
        worker.run_once()

    release.set()
    acquired = False
    for _ in range(100):
        try:
            with worker.lock():
                acquired = True
                break
        except WorkerBusy:
            threading.Event().wait(0.01)
    stop.set()
    thread.join(2)
    assert acquired
    assert not thread.is_alive()
