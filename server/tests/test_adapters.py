"""Offline checks for local transcription and explicitly scoped publication."""

import json
import subprocess
from pathlib import Path
from types import SimpleNamespace
from unittest.mock import Mock

import pytest

from lcp_server.adapters import (
    CitationFallbackTranscriber,
    ElevenLabsTranscriber,
    PublicationError,
    RclonePublisher,
    TranscriptionError,
    WhisperValidationError,
    WhisperTranscriber,
)
from lcp_server.models import AudioEvent, Segment, Transcript


@pytest.fixture
def audio(tmp_path):
    path = tmp_path / "CS182_2026-10-18_1430.m4a"
    path.write_bytes(b"independent worker audio")
    return path


def whisper_result(*segments, duration=90.125, language="en"):
    return iter(segments), SimpleNamespace(duration=duration, language=language)


def segment(start=0.0, end=12.0, text=" Lecture speech. "):
    return SimpleNamespace(start=start, end=end, text=text)


def transcriber_for(result):
    model = Mock()
    model.transcribe.return_value = result
    factory = Mock(return_value=model)
    checker = Mock(return_value={"int8_float32", "float32"})
    engine = WhisperTranscriber(
        model_factory=factory, supported_compute_types=checker
    )
    return engine, model, factory, checker


def test_whisper_loads_lazily_reuses_model_and_preserves_duration(audio):
    engine, model, factory, checker = transcriber_for(whisper_result(segment()))
    factory.assert_not_called()
    checker.assert_not_called()

    transcript = engine.transcribe(audio)
    model.transcribe.return_value = whisper_result(segment())
    engine.transcribe(audio)

    factory.assert_called_once_with(
        "medium.en", device="cuda", compute_type="int8_float32"
    )
    checker.assert_called_once_with("cuda")
    assert transcript.duration == 90.125  # Original duration, not VAD duration.
    assert transcript.language == "en"
    assert transcript.segments[0].text == "Lecture speech."
    assert transcript.segments[0].end == 12.0
    assert model.transcribe.call_args.kwargs == {
        "language": "en",
        "vad_filter": True,
        "vad_parameters": {"min_silence_duration_ms": 500},
    }
    assert model.transcribe.call_args.args == (str(audio),)


def test_whisper_can_disable_vad_for_tail_preserving_repair(audio):
    engine, model, *_ = transcriber_for(whisper_result(segment()))
    engine.vad_filter = False

    transcript = engine.transcribe(audio)

    assert transcript.duration == 90.125
    assert model.transcribe.call_args.kwargs == {
        "language": "en",
        "vad_filter": False,
    }
    assert engine.last_transcription_metadata == {
        "backend": "local-whisper",
        "model": "medium.en",
        "device": "cuda",
        "compute_type": "int8_float32",
        "vad_filter": False,
        "min_silence_duration_ms": None,
    }


def test_unsupported_gpu_compute_never_loads_or_falls_back(audio):
    factory = Mock()
    engine = WhisperTranscriber(
        model_factory=factory,
        supported_compute_types=lambda device: {"float32"},
    )
    with pytest.raises(TranscriptionError, match="int8_float32.*float32"):
        engine.transcribe(audio)
    factory.assert_not_called()


def test_capability_probe_failure_is_actionable(audio):
    checker = Mock(side_effect=RuntimeError("CUDA initialization failed"))
    engine = WhisperTranscriber(supported_compute_types=checker)
    with pytest.raises(TranscriptionError, match="CUDA|driver"):
        engine.transcribe(audio)


def test_missing_runtime_is_reported_only_when_transcribing(audio, monkeypatch):
    loader = Mock(side_effect=ModuleNotFoundError("ctranslate2"))
    monkeypatch.setattr("lcp_server.adapters.importlib.import_module", loader)
    engine = WhisperTranscriber()
    loader.assert_not_called()
    with pytest.raises(TranscriptionError, match="install|Install"):
        engine.transcribe(audio)


def test_default_runtime_imports_then_loads_the_probed_model(audio, monkeypatch):
    model = Mock()
    model.transcribe.return_value = whisper_result(segment())
    factory = Mock(return_value=model)
    checker = Mock(return_value={"int8_float32"})
    modules = {
        "ctranslate2": SimpleNamespace(get_supported_compute_types=checker),
        "faster_whisper": SimpleNamespace(WhisperModel=factory),
    }
    loader = Mock(side_effect=modules.__getitem__)
    monkeypatch.setattr("lcp_server.adapters.importlib.import_module", loader)
    engine = WhisperTranscriber()
    assert engine.transcribe(audio).duration == 90.125
    assert [call.args[0] for call in loader.call_args_list] == [
        "ctranslate2", "faster_whisper"
    ]
    checker.assert_called_once_with("cuda")
    factory.assert_called_once()


@pytest.mark.parametrize("error", [ModuleNotFoundError("faster_whisper"), RuntimeError("CUDA")])
def test_model_load_failures_retain_actionable_context(audio, error):
    engine = WhisperTranscriber(
        model_factory=Mock(side_effect=error),
        supported_compute_types=lambda device: {"int8_float32"},
    )
    with pytest.raises(TranscriptionError, match="Install|Cannot load"):
        engine.transcribe(audio)


def test_missing_audio_never_loads_the_model(tmp_path):
    factory = Mock()
    with pytest.raises(TranscriptionError, match="audio.*missing"):
        WhisperTranscriber(model_factory=factory).transcribe(tmp_path / "missing.m4a")
    factory.assert_not_called()


@pytest.mark.parametrize("duration", [float("nan"), float("inf"), -1.0, 0.0])
def test_invalid_source_duration_rejected(audio, duration):
    engine, *_ = transcriber_for(whisper_result(segment(), duration=duration))
    with pytest.raises(TranscriptionError, match="duration"):
        engine.transcribe(audio)


@pytest.mark.parametrize(
    "bad_segment",
    [
        segment(start=float("nan")),
        segment(end=float("inf")),
        segment(start=-1),
        segment(start=20, end=10),
    ],
)
def test_invalid_segment_timestamps_rejected(audio, bad_segment):
    engine, *_ = transcriber_for(whisper_result(bad_segment))
    with pytest.raises(TranscriptionError, match="timestamp"):
        engine.transcribe(audio)


@pytest.mark.parametrize(
    ("segments", "code", "index"),
    [
        ((segment(start=2, end=2),), "zero_duration", 0),
        ((segment(start=0, end=5), segment(start=4, end=6)), "overlapping_timestamps", 1),
        ((segment(start=4, end=5), segment(start=2, end=3)), "unordered_timestamps", 1),
        ((segment(start=89, end=91),), "past_source_duration", 0),
    ],
)
def test_whisper_rejects_uncitable_model_timestamps_without_success_metadata(audio, segments, code, index):
    engine, *_ = transcriber_for(whisper_result(*segments))

    with pytest.raises(WhisperValidationError) as raised:
        engine.transcribe(audio)

    assert raised.value.code == code
    assert raised.value.segment_index == index
    assert engine.last_transcription_metadata is None
    assert "Lecture speech" not in str(raised.value)


def test_whisper_preserves_real_timestamps_at_encoder_padding_boundary(audio):
    engine, *_ = transcriber_for(whisper_result(
        segment(start=0.025, end=1.375),
        segment(start=1.375, end=10.5),
        duration=10.0,
    ))

    transcript = engine.transcribe(audio)

    assert [(item.start, item.end) for item in transcript.segments] == [(0.025, 1.375), (1.375, 10.5)]
    assert transcript.duration == 10.0


def test_whisper_ignores_empty_zero_duration_event_without_moving_speech(audio):
    engine, *_ = transcriber_for(whisper_result(
        segment(start=0, end=0, text=" "),
        segment(start=0.32, end=1.64, text="Actual speech."),
    ))

    transcript = engine.transcribe(audio)

    assert transcript.segments == (Segment(0.32, 1.64, "Actual speech."),)


@pytest.mark.parametrize("segments", [(), (segment(text="  "),)])
def test_empty_transcripts_are_retryable_failures(audio, segments):
    engine, *_ = transcriber_for(whisper_result(*segments))
    with pytest.raises(TranscriptionError, match="speech|empty"):
        engine.transcribe(audio)


def test_whisper_generator_failures_are_propagated(audio):
    def failed_decode():
        yield segment()
        raise RuntimeError("GPU decode failed")

    engine, *_ = transcriber_for(
        (failed_decode(), SimpleNamespace(duration=90.0, language="en"))
    )
    with pytest.raises(TranscriptionError, match="transcription|Transcription"):
        engine.transcribe(audio)


@pytest.mark.parametrize(
    "result",
    [
        whisper_result(segment(text=None)),
        whisper_result(segment(), language=""),
        whisper_result(segment(start="not-a-timestamp")),
    ],
)
def test_malformed_whisper_results_fail_before_publication(audio, result):
    engine, *_ = transcriber_for(result)
    with pytest.raises(TranscriptionError, match="Invalid|invalid"):
        engine.transcribe(audio)


@pytest.mark.parametrize(
    "settings", [{"device": "auto"}, {"model": ""}, {"compute_type": ""}]
)
def test_whisper_requires_explicit_supported_settings(settings):
    with pytest.raises(ValueError):
        WhisperTranscriber(**settings)


class StaticTranscriber:
    def __init__(self, result=None, error=None):
        self.result = result
        self.error = error
        self.calls = []

    def transcribe(self, audio):
        self.calls.append(audio)
        if self.error:
            raise self.error
        return self.result


def test_citation_fallback_uses_local_whisper_only_for_blocking_provider_timestamps(audio):
    primary = StaticTranscriber(
        Transcript(180.0, (Segment(0.0, 180.0, "A collapsed lecture.", "speaker_0"),))
    )
    fallback_transcript = Transcript(
        180.0,
        (Segment(0.0, 10.0, "Opening."), Segment(120.0, 130.0, "Conclusion.")),
    )
    fallback = StaticTranscriber(fallback_transcript)

    engine = CitationFallbackTranscriber(primary, fallback)
    result = engine.transcribe(audio)

    assert result is fallback_transcript
    assert primary.calls == [audio]
    assert fallback.calls == [audio]
    assert [(item.start, item.end) for item in result.segments] == [(0.0, 10.0), (120.0, 130.0)]
    assert engine.last_transcription_metadata == {
        "backend": "local-whisper",
        "fallback_enabled": True,
        "fallback_attempted": True,
        "fallback_used": True,
        "speaker_diarization": False,
        "fallback_reason": "citation_unsafe_timestamps",
        "fallback_warning_codes": ["one_cue_collapse", "cue_over_30s"],
        "fallback_publishable": True,
    }


def test_citation_fallback_persists_tail_repair_settings(audio):
    primary = StaticTranscriber(
        Transcript(180.0, (Segment(0.0, 180.0, "A collapsed lecture.", "speaker_0"),))
    )
    fallback = WhisperTranscriber(
        vad_filter=False,
        model_factory=Mock(return_value=Mock(transcribe=Mock(return_value=whisper_result(
            segment(start=0.0, end=10.0), segment(start=120.0, end=130.0, text="Tail."), duration=180.0
        )))),
        supported_compute_types=lambda device: {"int8_float32"},
    )
    engine = CitationFallbackTranscriber(primary, fallback)

    result = engine.transcribe(audio)

    assert result.segments[0].text == "Lecture speech."
    assert engine.last_transcription_metadata["fallback_settings"]["vad_filter"] is False
    assert engine.last_transcription_metadata["fallback_settings"]["min_silence_duration_ms"] is None


def test_citation_fallback_does_not_run_for_advisory_or_provider_failures(audio):
    safe_without_speakers = Transcript(
        90.0, (Segment(0.0, 10.0, "Opening."), Segment(40.0, 50.0, "Conclusion."))
    )
    fallback = StaticTranscriber(
        Transcript(90.0, (Segment(0.0, 5.0, "Should not run."),))
    )
    engine = CitationFallbackTranscriber(StaticTranscriber(safe_without_speakers), fallback)

    assert engine.transcribe(audio) is safe_without_speakers
    assert fallback.calls == []
    assert engine.last_transcription_metadata["fallback_attempted"] is False
    assert engine.last_transcription_metadata["backend"] == "elevenlabs"

    provider = StaticTranscriber(error=TranscriptionError("ElevenLabs request failed"))
    engine = CitationFallbackTranscriber(provider, fallback)
    with pytest.raises(TranscriptionError, match="ElevenLabs"):
        engine.transcribe(audio)
    assert fallback.calls == []
    assert engine.last_transcription_metadata is None


def test_citation_fallback_retains_unsafe_provider_result_when_local_runtime_fails(audio):
    primary_transcript = Transcript(
        180.0, (Segment(0.0, 180.0, "A collapsed lecture.", "speaker_0"),)
    )
    primary = StaticTranscriber(primary_transcript)
    fallback = StaticTranscriber(error=RuntimeError("Cannot load local Whisper model"))
    engine = CitationFallbackTranscriber(primary, fallback)

    assert engine.transcribe(audio) is primary_transcript
    metadata = engine.last_transcription_metadata
    assert metadata["backend"] == "elevenlabs"
    assert metadata["fallback_attempted"] is True
    assert metadata["fallback_used"] is False
    assert metadata["fallback_error"] == "RuntimeError"
    assert "fallback_error_message" not in metadata


def test_citation_fallback_keeps_provider_and_logs_only_sanitized_failure(audio, caplog):
    primary_transcript = Transcript(
        180.0, (Segment(0.0, 180.0, "A collapsed lecture.", "speaker_0"),)
    )
    fallback = StaticTranscriber(error=RuntimeError("/private/audio secret transcript token=hidden"))
    engine = CitationFallbackTranscriber(StaticTranscriber(primary_transcript), fallback)

    assert engine.transcribe(audio) is primary_transcript

    assert "RuntimeError" in caplog.text
    assert "/private/audio" not in caplog.text
    assert "secret transcript" not in caplog.text
    assert "token=" not in caplog.text


def test_citation_fallback_records_safe_local_timestamp_failure_reason(audio):
    primary_transcript = Transcript(
        180.0, (Segment(0.0, 180.0, "A collapsed lecture.", "speaker_0"),)
    )
    fallback, *_ = transcriber_for(whisper_result(segment(start=1, end=1, text="Private speech.")))
    engine = CitationFallbackTranscriber(StaticTranscriber(primary_transcript), fallback)

    assert engine.transcribe(audio) is primary_transcript

    metadata = engine.last_transcription_metadata
    assert metadata["fallback_used"] is False
    assert metadata["fallback_validation"] == {
        "code": "zero_duration", "segment_index": 0, "recovery_attempted": False,
    }
    assert "Private speech" not in json.dumps(metadata)


@pytest.mark.parametrize("invalid", [
    whisper_result(segment(start=4, end=4)),
    whisper_result(segment(start=0, end=5), segment(start=4, end=6)),
    whisper_result(segment(start=80, end=92)),
])
def test_whisper_timestamp_recovery_uses_one_fresh_aligned_decode(audio, invalid):
    engine, model, *_ = transcriber_for(invalid)
    engine.recover_timestamps = True
    model.transcribe.side_effect = [invalid, whisper_result(
        segment(start=0.125, end=10.875, text="Aligned speech."),
        segment(start=50.375, end=60.625, text="Aligned tail."),
    )]

    transcript = engine.transcribe(audio)

    assert len(model.transcribe.call_args_list) == 2
    assert "word_timestamps" not in model.transcribe.call_args_list[0].kwargs
    assert model.transcribe.call_args_list[1].kwargs["word_timestamps"] is True
    assert [(item.start, item.end) for item in transcript.segments] == [
        (0.125, 10.875), (50.375, 60.625),
    ]
    assert engine.last_transcription_metadata["word_timestamps"] is True
    assert engine.last_transcription_metadata["timestamp_recovery_attempted"] is True


def test_whisper_timestamp_recovery_closes_failed_decoder_before_retry(audio):
    closed = []

    def invalid_decode():
        try:
            yield segment(start=1, end=1)
            raise AssertionError("Invalid decode must not continue after failed validation")
        finally:
            closed.append(True)

    engine, model, *_ = transcriber_for(None)
    engine.recover_timestamps = True

    def decode(*args, **kwargs):
        if not kwargs.get("word_timestamps"):
            return invalid_decode(), SimpleNamespace(duration=90.0, language="en")
        assert closed == [True]
        return whisper_result(segment(start=1.25, end=2.75), duration=90.0)

    model.transcribe.side_effect = decode

    assert engine.transcribe(audio).segments[0].start == 1.25
    assert closed == [True]


def test_whisper_timestamp_recovery_does_not_repeat_valid_decode_or_runtime_failure(audio):
    engine, model, *_ = transcriber_for(whisper_result(segment()))
    engine.recover_timestamps = True
    engine.transcribe(audio)
    assert model.transcribe.call_count == 1
    assert engine.last_transcription_metadata["timestamp_recovery_attempted"] is False

    model.transcribe.side_effect = RuntimeError("Private runtime path")
    with pytest.raises(TranscriptionError, match="did not complete"):
        engine.transcribe(audio)
    assert model.transcribe.call_count == 2
    assert engine.last_transcription_metadata is None


def test_whisper_timestamp_recovery_rejects_nonfinite_data_without_retry(audio):
    engine, model, *_ = transcriber_for(whisper_result(segment(start=float("nan"))))
    engine.recover_timestamps = True

    with pytest.raises(WhisperValidationError) as raised:
        engine.transcribe(audio)

    assert raised.value.code == "invalid_timestamp"
    assert raised.value.recovery_attempted is False
    assert model.transcribe.call_count == 1


def test_whisper_timestamp_recovery_rejects_changed_source_duration(audio):
    engine, model, *_ = transcriber_for(None)
    engine.recover_timestamps = True
    model.transcribe.side_effect = [
        whisper_result(segment(start=0, end=5), segment(start=4, end=6), duration=180.0),
        whisper_result(segment(start=0, end=5), duration=10.0),
    ]

    with pytest.raises(WhisperValidationError) as raised:
        engine.transcribe(audio)

    assert raised.value.code == "source_duration_changed"
    assert raised.value.recovery_attempted is True
    assert engine.last_transcription_metadata is None
    assert model.transcribe.call_count == 2


def test_citation_fallback_keeps_provider_when_aligned_decode_runtime_fails(audio, caplog):
    primary_transcript = Transcript(
        180.0, (Segment(0, 180, "Provider transcript.", "speaker_0"),)
    )
    fallback, model, *_ = transcriber_for(None)
    fallback.recover_timestamps = True
    model.transcribe.side_effect = [
        whisper_result(segment(start=0, end=5), segment(start=4, end=6)),
        RuntimeError("/private/lecture token=hidden"),
    ]
    engine = CitationFallbackTranscriber(StaticTranscriber(primary_transcript), fallback)

    assert engine.transcribe(audio) is primary_transcript

    assert model.transcribe.call_count == 2
    assert engine.last_transcription_metadata["fallback_validation"] == {
        "code": "word_alignment_failed", "segment_index": None,
        "recovery_attempted": True, "initial_code": "overlapping_timestamps",
    }
    assert "/private/lecture" not in caplog.text
    assert "token=" not in caplog.text


def test_citation_fallback_rejects_invalid_aligned_retry_and_keeps_provider(audio):
    primary_transcript = Transcript(
        180.0, (Segment(0, 180, "Provider transcript.", "speaker_0"),)
    )
    fallback, model, *_ = transcriber_for(None)
    fallback.recover_timestamps = True
    model.transcribe.side_effect = [
        whisper_result(segment(start=0, end=5), segment(start=4, end=6)),
        whisper_result(segment(start=90, end=92)),
    ]
    engine = CitationFallbackTranscriber(StaticTranscriber(primary_transcript), fallback)

    assert engine.transcribe(audio) is primary_transcript

    assert model.transcribe.call_count == 2
    assert fallback.last_transcription_metadata is None
    assert engine.last_transcription_metadata["fallback_used"] is False
    assert engine.last_transcription_metadata["fallback_validation"] == {
        "code": "past_source_duration", "segment_index": 0,
        "recovery_attempted": True, "initial_code": "overlapping_timestamps",
    }


def test_citation_fallback_retains_provider_when_local_repair_is_still_blocked(audio):
    primary_transcript = Transcript(
        180.0, (Segment(0.0, 180.0, "A collapsed lecture.", "speaker_0"),)
    )
    primary = StaticTranscriber(primary_transcript)
    fallback = StaticTranscriber(
        Transcript(180.0, (Segment(0.0, 180.0, "A still collapsed repair."),))
    )
    engine = CitationFallbackTranscriber(primary, fallback)

    assert engine.transcribe(audio) is primary_transcript
    metadata = engine.last_transcription_metadata
    assert metadata["backend"] == "elevenlabs"
    assert metadata["fallback_attempted"] is True
    assert metadata["fallback_used"] is False
    assert metadata["fallback_rejected"] is True
    assert metadata["fallback_rejection_codes"] == ["one_cue_collapse", "cue_over_30s"]


def test_citation_fallback_rejects_sustained_repeated_content_and_keeps_primary(audio):
    primary_transcript = Transcript(
        600, (Segment(0, 600, "Original provider transcript.", "speaker_0"),)
    )
    local = Transcript(600, tuple(
        Segment(index * 20, (index + 1) * 20, "Repeated filler phrase.")
        for index in range(30)
    ))
    engine = CitationFallbackTranscriber(StaticTranscriber(primary_transcript), StaticTranscriber(local))

    assert engine.transcribe(audio) is primary_transcript

    assert engine.last_transcription_metadata["fallback_used"] is False
    assert engine.last_transcription_metadata["fallback_rejected"] is True
    assert engine.last_transcription_metadata["fallback_rejection_codes"] == ["sustained_text_repetition"]


class FakeHTTPResponse:
    def __init__(self, status=200, body=b"{}"):
        self.status = status
        self._body = body
        self._offset = 0
        self.closed = False

    def read(self, limit=-1):
        if self._offset >= len(self._body):
            return b""
        end = len(self._body) if limit < 0 else min(len(self._body), self._offset + limit)
        chunk = self._body[self._offset:end]
        self._offset = end
        return chunk

    def close(self):
        self.closed = True


class ChunkedHTTPResponse(FakeHTTPResponse):
    def __init__(self, status=200, body=b"{}", chunk_size=1024 * 1024):
        super().__init__(status=status, body=body)
        self.chunk_size = chunk_size

    def read(self, limit=-1):
        size = self.chunk_size if limit < 0 else min(limit, self.chunk_size)
        return super().read(size)


class FakeHTTPConnection:
    def __init__(self, response):
        self.response = response
        self.headers = []
        self.request = None
        self.body = bytearray()
        self.closed = False

    def putrequest(self, method, path):
        self.request = (method, path)

    def putheader(self, name, value):
        self.headers.append((name, value))

    def endheaders(self):
        pass

    def send(self, data):
        self.body.extend(data)

    def getresponse(self):
        return self.response

    def close(self):
        self.closed = True


def event_engine(words, *, duration=120.0, declared_duration=120.0):
    response = FakeHTTPResponse(body=json.dumps({
        "language_code": "en", "audio_duration_secs": declared_duration, "words": words,
    }).encode())
    connection = FakeHTTPConnection(response)
    probe = Mock(return_value=duration)
    return ElevenLabsTranscriber(
        api_key="test-key", connection_factory=lambda *args, **kwargs: connection,
        duration_probe=probe,
    ), probe


@pytest.mark.parametrize("declared_duration", [None, 1, 9999])
def test_elevenlabs_keeps_long_overlapping_events_out_of_spoken_cue_grouping(audio, declared_duration):
    label = "  [private ambient sound]\n\t\u96e8  "
    engine, probe = event_engine([
        {"type": "word", "text": "First", "start": 1.125, "end": 1.5, "speaker_id": "speaker_0"},
        {"type": "audio_event", "text": label, "start": 0.0, "end": 120.0, "speaker_id": "ignored"},
        {"type": "word", "text": "point.", "start": 1.5, "end": 2.125, "speaker_id": "speaker_0"},
        {"type": "audio_event", "text": "second annotation", "start": 10.0, "end": 90.0},
        {"type": "word", "text": "Next.", "start": 5.25, "end": 6.75, "speaker_id": "speaker_1"},
    ], declared_duration=declared_duration)

    transcript = engine.transcribe(audio)

    probe.assert_called_once_with(audio)
    assert transcript.duration == 120.0  # Source probe, not provider event/header maxima.
    assert transcript.segments == (
        Segment(1.125, 2.125, "First point.", "speaker_0"),
        Segment(5.25, 6.75, "Next.", "speaker_1"),
    )
    assert transcript.audio_events == (
        AudioEvent(0.0, 120.0, label), AudioEvent(10.0, 90.0, "second annotation"),
    )


@pytest.mark.parametrize("word_type", ["word", "unknown_future_type", None])
def test_elevenlabs_never_reclassifies_spoken_or_unknown_noise_text(audio, word_type):
    engine, _ = event_engine([
        {"type": "audio_event", "text": "sound", "start": 0.0, "end": 120.0},
        {"type": word_type, "text": "[background noise] unique explanation.", "start": 1.0, "end": 2.0},
    ])
    transcript = engine.transcribe(audio)
    assert transcript.segments == (Segment(1.0, 2.0, "[background noise] unique explanation."),)
    assert len(transcript.audio_events) == 1


@pytest.mark.parametrize("updates", [
    {"start": None}, {"start": True}, {"start": -0.01}, {"start": "0"},
    {"start": float("nan")}, {"end": float("inf")}, {"end": 0}, {"end": 120.001},
    {"text": None}, {"text": ""}, {"text": " \t"},
])
def test_elevenlabs_invalid_explicit_event_fails_without_leaking_or_dropping_it(audio, updates):
    event = {"type": "audio_event", "text": "PRIVATE_EVENT_CONTENT", "start": 0.0, "end": 120.0}
    event.update(updates)
    engine, _ = event_engine([
        {"type": "word", "text": "Keep unique speech.", "start": 1.0, "end": 2.0}, event,
    ])
    with pytest.raises(TranscriptionError, match="^Invalid ElevenLabs audio event metadata\\.$") as raised:
        engine.transcribe(audio)
    assert "PRIVATE_EVENT_CONTENT" not in str(raised.value)


@pytest.mark.parametrize("duration", [None, 0, -1, True, float("nan"), float("inf"), "120"])
def test_elevenlabs_event_response_requires_independent_finite_source_duration(audio, duration):
    engine, _ = event_engine([
        {"type": "audio_event", "text": "sound", "start": 0.0, "end": 120.0},
    ], duration=duration)
    with pytest.raises(TranscriptionError, match="source duration"):
        engine.transcribe(audio)


def test_elevenlabs_event_aware_path_does_not_silently_drop_invalid_unique_words(audio):
    engine, _ = event_engine([
        {"type": "audio_event", "text": "sound", "start": 0.0, "end": 120.0},
        {"type": "word", "text": "UNIQUE_PRIVATE_SPEECH", "start": 2.0, "end": 2.0},
        {"type": "word", "text": "Other speech.", "start": 3.0, "end": 4.0},
    ])
    with pytest.raises(TranscriptionError, match="spoken word timestamp") as raised:
        engine.transcribe(audio)
    assert "UNIQUE_PRIVATE_SPEECH" not in str(raised.value)


@pytest.mark.parametrize("declared_duration", [None, 1, 9999])
def test_elevenlabs_sound_only_result_is_retained_without_spoken_cues(audio, declared_duration):
    engine, _ = event_engine([
        {"type": "audio_event", "text": "  sound annotation  ", "start": 0.0, "end": 120.0},
    ], declared_duration=declared_duration)
    transcript = engine.transcribe(audio)
    assert transcript.segments == ()
    assert transcript.audio_events == (AudioEvent(0.0, 120.0, "  sound annotation  "),)


def test_elevenlabs_without_explicit_events_does_not_probe_or_infer_types(audio):
    engine, probe = event_engine([
        {"type": "word", "text": "[noise] remains speech.", "start": 1.0, "end": 2.0},
    ])
    transcript = engine.transcribe(audio)
    probe.assert_not_called()
    assert transcript.audio_events == ()
    assert transcript.segments == (Segment(1.0, 2.0, "[noise] remains speech."),)


def test_elevenlabs_audio_duration_probe_uses_source_container_and_closes_it(audio, monkeypatch):
    container = Mock()
    container.__enter__ = Mock(return_value=SimpleNamespace(duration=120_125_000))
    container.__exit__ = Mock(return_value=False)
    av = SimpleNamespace(open=Mock(return_value=container), time_base=1_000_000)
    monkeypatch.setattr("lcp_server.adapters.importlib.import_module", lambda name: av)
    assert ElevenLabsTranscriber._source_audio_duration(audio) == 120.125
    av.open.assert_called_once_with(str(audio))
    container.__exit__.assert_called_once()


def test_elevenlabs_audio_probe_failure_is_safe(audio, monkeypatch):
    def fail(name):
        raise RuntimeError("PRIVATE_PROBE_DETAILS")
    monkeypatch.setattr("lcp_server.adapters.importlib.import_module", fail)
    with pytest.raises(TranscriptionError, match="source duration") as raised:
        ElevenLabsTranscriber._source_audio_duration(audio)
    assert "PRIVATE_PROBE_DETAILS" not in str(raised.value)


def test_citation_fallback_preserves_exact_provider_audio_events(audio):
    events = (AudioEvent(0, 60, " [private sound] "),)
    primary = StaticTranscriber(Transcript(60, (Segment(0, 60, "Collapsed speech."),), audio_events=events))
    fallback = StaticTranscriber(Transcript(60, (Segment(0, 10, "First."), Segment(50, 60, "Last."))))
    result = CitationFallbackTranscriber(primary, fallback).transcribe(audio)
    assert result.segments == fallback.result.segments
    assert result.audio_events == events


def test_citation_fallback_retains_primary_when_exact_events_exceed_local_source_bounds(audio):
    primary_result = Transcript(60, (Segment(0, 60, "Collapsed speech."),), audio_events=(AudioEvent(0, 60, "sound"),))
    primary = StaticTranscriber(primary_result)
    fallback = StaticTranscriber(Transcript(59.999, (Segment(0, 10, "First."), Segment(50, 59, "Last."))))
    engine = CitationFallbackTranscriber(primary, fallback)
    assert engine.transcribe(audio) is primary_result
    assert engine.last_transcription_metadata["fallback_used"] is False


def test_elevenlabs_streams_multipart_audio_and_builds_speaker_segments(audio):
    response_payload = {
        "language_code": "en",
        "audio_duration_secs": 2.25,
        "words": [
            {"text": "Hello", "type": "word", "start": 0, "end": 0.4, "speaker_id": "speaker_0"},
            {"text": " ", "type": "spacing", "start": 0.4, "end": 0.4, "speaker_id": "speaker_0"},
            {"text": "class", "type": "word", "start": 0.4, "end": 0.8, "speaker_id": "speaker_0"},
            {"text": "Professor", "type": "word", "start": 1.2, "end": 1.7, "speaker_id": "speaker_1"},
        ],
    }
    response = FakeHTTPResponse(body=json.dumps(response_payload).encode())
    connection = FakeHTTPConnection(response)
    engine = ElevenLabsTranscriber(
        api_key="test-key",
        connection_factory=lambda *args, **kwargs: connection,
    )

    transcript = engine.transcribe(audio)

    assert transcript.duration == 2.25
    assert [(item.start, item.end, item.text, item.speaker) for item in transcript.segments] == [
        (0.0, 0.8, "Hello class", "speaker_0"),
        (1.2, 1.7, "Professor", "speaker_1"),
    ]
    assert connection.request[0] == "POST"
    assert connection.request[1] == "/v1/speech-to-text"
    headers = dict(connection.headers)
    assert headers["xi-api-key"] == "test-key"
    assert b'name="model_id"' in connection.body
    assert b"scribe_v2" in connection.body
    assert b'name="diarize"' in connection.body
    assert b'name="file"' in connection.body
    assert audio.read_bytes() in connection.body
    assert int(headers["Content-Length"]) == len(connection.body)
    assert connection.closed and response.closed


def test_elevenlabs_streams_a_response_larger_than_legacy_limit(audio):
    long_text = "lecture " + ("term " * (1024 * 1024))
    response_payload = {
        "language_code": "en",
        "audio_duration_secs": 2.0,
        "words": [{"text": long_text, "type": "word", "start": 0.0, "end": 1.0}],
    }
    body = json.dumps(response_payload).encode()
    assert len(body) > 4 * 1024 * 1024
    response = ChunkedHTTPResponse(body=body, chunk_size=131072)
    connection = FakeHTTPConnection(response)
    engine = ElevenLabsTranscriber(
        api_key="test-key",
        connection_factory=lambda *args, **kwargs: connection,
    )

    transcript = engine.transcribe(audio)

    assert transcript.segments[0].text == long_text.strip()
    assert connection.closed and response.closed


def test_elevenlabs_rejects_response_above_configured_bound(audio):
    response = ChunkedHTTPResponse(body=b"x" * 65, chunk_size=7)
    connection = FakeHTTPConnection(response)
    engine = ElevenLabsTranscriber(
        api_key="test-key",
        connection_factory=lambda *args, **kwargs: connection,
    )
    engine.MAX_RESPONSE_BYTES = 64

    with pytest.raises(TranscriptionError, match="response is too large"):
        engine.transcribe(audio)
    assert connection.closed and response.closed


def test_elevenlabs_prefers_words_over_one_broad_provider_segment(audio):
    """Detailed word timestamps must survive a broad provider segment."""
    response_payload = {
        "language_code": "en",
        "audio_duration_secs": 4.0,
        "segments": [{
            "start": 0.0,
            "end": 4.0,
            "text": "Hello class. Professor here.",
            "speaker_id": "speaker_0",
        }],
        "words": [
            {"text": "Hello", "type": "word", "start": 0.0, "end": 0.4, "speaker_id": "speaker_0"},
            {"text": " ", "type": "spacing", "start": 0.4, "end": 0.4, "speaker_id": "speaker_0"},
            {"text": "class.", "type": "word", "start": 0.4, "end": 0.8, "speaker_id": "speaker_0"},
            {"text": "Professor", "type": "word", "start": 1.8, "end": 2.2, "speaker_id": "speaker_1"},
            {"text": " ", "type": "spacing", "start": 2.2, "end": 2.2, "speaker_id": "speaker_1"},
            {"text": "here.", "type": "word", "start": 2.2, "end": 2.6, "speaker_id": "speaker_1"},
        ],
    }
    response = FakeHTTPResponse(body=json.dumps(response_payload).encode())
    connection = FakeHTTPConnection(response)
    engine = ElevenLabsTranscriber(
        api_key="test-key",
        connection_factory=lambda *args, **kwargs: connection,
    )

    transcript = engine.transcribe(audio)

    assert [(item.start, item.end, item.text, item.speaker) for item in transcript.segments] == [
        (0.0, 0.8, "Hello class.", "speaker_0"),
        (1.8, 2.6, "Professor here.", "speaker_1"),
    ]


def test_elevenlabs_uses_valid_segments_when_words_are_unusable(audio):
    """A malformed optional word array must not hide safe segment timestamps."""
    response_payload = {
        "language_code": "en",
        "audio_duration_secs": 8.0,
        "segments": [{
            "start": 0.0,
            "end": 2.4,
            "text": "A short fallback segment.",
            "speaker_id": "speaker_0",
        }],
        "words": [{
            "text": "fallback",
            "type": "word",
            "start": "unusable",
            "end": 0.8,
            "speaker_id": "speaker_0",
        }],
    }
    response = FakeHTTPResponse(body=json.dumps(response_payload).encode())
    connection = FakeHTTPConnection(response)
    engine = ElevenLabsTranscriber(
        api_key="test-key", connection_factory=lambda *args, **kwargs: connection,
    )

    transcript = engine.transcribe(audio)

    assert [(item.start, item.end, item.text, item.speaker) for item in transcript.segments] == [
        (0.0, 2.4, "A short fallback segment.", "speaker_0"),
    ]


def test_elevenlabs_preserves_broad_fallback_segment_for_quality_gate(audio):
    """A broad segment remains exact so an opt-in local fallback can recover it."""
    response_payload = {
        "language_code": "en",
        "audio_duration_secs": 180.0,
        "segments": [{"start": 0.0, "end": 180.0, "text": "A whole lecture."}],
        "words": [{"text": "bad", "type": "word", "start": "unusable", "end": 0.8}],
    }
    response = FakeHTTPResponse(body=json.dumps(response_payload).encode())
    connection = FakeHTTPConnection(response)
    engine = ElevenLabsTranscriber(
        api_key="test-key", connection_factory=lambda *args, **kwargs: connection,
    )

    transcript = engine.transcribe(audio)
    assert [(item.start, item.end, item.text) for item in transcript.segments] == [
        (0.0, 180.0, "A whole lecture.")
    ]


def test_elevenlabs_spacing_duration_does_not_hide_a_pause(audio):
    response_payload = {
        "language_code": "en",
        "audio_duration_secs": 5.0,
        "words": [
            {"text": "First", "type": "word", "start": 0.0, "end": 0.4, "speaker_id": "speaker_0"},
            {"text": " ", "type": "spacing", "start": 0.4, "end": 2.0, "speaker_id": "speaker_0"},
            {"text": "second", "type": "word", "start": 2.0, "end": 2.4, "speaker_id": "speaker_0"},
        ],
    }
    response = FakeHTTPResponse(body=json.dumps(response_payload).encode())
    connection = FakeHTTPConnection(response)
    engine = ElevenLabsTranscriber(
        api_key="test-key", connection_factory=lambda *args, **kwargs: connection,
    )

    transcript = engine.transcribe(audio)

    assert [(item.start, item.end, item.text) for item in transcript.segments] == [
        (0.0, 0.4, "First"), (2.0, 2.4, "second"),
    ]


def test_elevenlabs_long_spacing_is_silence_not_an_overlong_word(audio):
    response_payload = {
        "language_code": "en", "audio_duration_secs": 40.0,
        "words": [
            {"text": "Before", "type": "word", "start": 0.0, "end": 0.4},
            {"text": " ", "type": "spacing", "start": 0.4, "end": 35.0},
            {"text": "after", "type": "word", "start": 35.0, "end": 35.4},
        ],
    }
    response = FakeHTTPResponse(body=json.dumps(response_payload).encode())
    connection = FakeHTTPConnection(response)
    engine = ElevenLabsTranscriber(
        api_key="test-key", connection_factory=lambda *args, **kwargs: connection,
    )

    transcript = engine.transcribe(audio)

    assert [(item.start, item.end, item.text) for item in transcript.segments] == [
        (0.0, 0.4, "Before"), (35.0, 35.4, "after"),
    ]


def test_elevenlabs_skips_untimestamped_spacing_tokens(audio):
    response_payload = {
        "language_code": "en", "audio_duration_secs": 1.0,
        "words": [
            {"text": "Hello", "type": "word", "start": 0.0, "end": 0.4},
            {"text": " ", "type": "spacing", "start": None, "end": None},
            {"text": "world", "type": "word", "start": 0.4, "end": 0.8},
        ],
    }
    response = FakeHTTPResponse(body=json.dumps(response_payload).encode())
    connection = FakeHTTPConnection(response)
    engine = ElevenLabsTranscriber(
        api_key="test-key", connection_factory=lambda *args, **kwargs: connection,
    )

    assert engine.transcribe(audio).segments[0].text == "Hello world"


def test_elevenlabs_uses_legacy_duration_when_primary_duration_is_null(audio):
    response_payload = {
        "language_code": "en",
        "audio_duration_secs": None,
        "duration": 3.0,
        "words": [{"text": "Hello.", "type": "word", "start": 0.0, "end": 0.4}],
    }
    response = FakeHTTPResponse(body=json.dumps(response_payload).encode())
    connection = FakeHTTPConnection(response)
    engine = ElevenLabsTranscriber(
        api_key="test-key", connection_factory=lambda *args, **kwargs: connection,
    )

    assert engine.transcribe(audio).duration == 3.0


def test_elevenlabs_splits_long_same_speaker_runs(audio):
    words = []
    for index in range(80):
        start = index * 0.5
        words.append({
            "text": f"word{index}", "type": "word", "start": start,
            "end": start + 0.25, "speaker_id": "speaker_0",
        })
        words.append({
            "text": " ", "type": "spacing", "start": start + 0.25,
            "end": start + 0.25, "speaker_id": "speaker_0",
        })
    response_payload = {
        "language_code": "en", "audio_duration_secs": 40.0, "words": words,
    }
    response = FakeHTTPResponse(body=json.dumps(response_payload).encode())
    connection = FakeHTTPConnection(response)
    engine = ElevenLabsTranscriber(
        api_key="test-key", connection_factory=lambda *args, **kwargs: connection,
    )

    transcript = engine.transcribe(audio)

    assert len(transcript.segments) >= 2
    assert all(item.end > item.start for item in transcript.segments)
    assert max(item.end - item.start for item in transcript.segments) <= engine.MAX_SEGMENT_SECONDS


def test_elevenlabs_drops_zero_duration_word_only_cues(audio):
    response_payload = {
        "language_code": "en", "audio_duration_secs": 1.0,
        "words": [
            {"text": "noise", "type": "word", "start": 0.0, "end": 0.0, "speaker_id": "speaker_0"},
            {"text": "Hello.", "type": "word", "start": 0.2, "end": 0.6, "speaker_id": "speaker_0"},
        ],
    }
    response = FakeHTTPResponse(body=json.dumps(response_payload).encode())
    connection = FakeHTTPConnection(response)
    engine = ElevenLabsTranscriber(
        api_key="test-key", connection_factory=lambda *args, **kwargs: connection,
    )

    transcript = engine.transcribe(audio)

    assert [(item.start, item.end, item.text) for item in transcript.segments] == [
        (0.2, 0.6, "Hello."),
    ]


def test_elevenlabs_preserves_overlong_segment_without_word_timestamps(audio):
    response_payload = {
        "language_code": "en",
        "audio_duration_secs": 180.0,
        "segments": [{"start": 0.0, "end": 180.0, "text": "A whole lecture."}],
    }
    response = FakeHTTPResponse(body=json.dumps(response_payload).encode())
    connection = FakeHTTPConnection(response)
    engine = ElevenLabsTranscriber(
        api_key="test-key", connection_factory=lambda *args, **kwargs: connection,
    )

    transcript = engine.transcribe(audio)
    assert transcript.segments[0].end == 180.0


def test_elevenlabs_preserves_overlong_single_word_timestamp(audio):
    response_payload = {
        "language_code": "en", "audio_duration_secs": 40.0,
        "words": [{"text": "bad", "type": "word", "start": 0.0, "end": 31.0}],
    }
    response = FakeHTTPResponse(body=json.dumps(response_payload).encode())
    connection = FakeHTTPConnection(response)
    engine = ElevenLabsTranscriber(
        api_key="test-key", connection_factory=lambda *args, **kwargs: connection,
    )

    transcript = engine.transcribe(audio)

    assert transcript.segments[0].text == "bad"
    # Clipping to 30 seconds would change the provider citation interval and
    # hide the quality gate signal used by the explicit local fallback.
    assert transcript.segments[0].end - transcript.segments[0].start == 31.0


@pytest.mark.parametrize(
    "bad_word",
    [
        {"text": "lost", "type": "word", "start": "bad", "end": 0.8},
        {"text": "lost", "type": "word", "start": 0.1, "end": 0.05},
        {"text": "lost", "type": "word", "start": None, "end": 0.2},
    ],
)
def test_elevenlabs_skips_isolated_malformed_word_timestamps(audio, bad_word):
    response_payload = {
        "language_code": "en",
        "audio_duration_secs": 3.0,
        "words": [
            {"text": "Before", "type": "word", "start": 0.0, "end": 0.4},
            bad_word,
            {"text": "after", "type": "word", "start": 2.0, "end": 2.4},
        ],
    }
    response = FakeHTTPResponse(body=json.dumps(response_payload).encode())
    connection = FakeHTTPConnection(response)
    engine = ElevenLabsTranscriber(
        api_key="test-key", connection_factory=lambda *args, **kwargs: connection,
    )

    transcript = engine.transcribe(audio)

    assert [item.text for item in transcript.segments] == ["Before", "after"]


def test_elevenlabs_still_rejects_a_response_with_no_usable_word_timestamps(audio):
    response_payload = {
        "language_code": "en",
        "audio_duration_secs": 2.0,
        "words": [{"text": "lost", "type": "word", "start": "bad", "end": 0.8}],
    }
    response = FakeHTTPResponse(body=json.dumps(response_payload).encode())
    connection = FakeHTTPConnection(response)
    engine = ElevenLabsTranscriber(
        api_key="test-key", connection_factory=lambda *args, **kwargs: connection,
    )

    with pytest.raises(TranscriptionError, match="empty transcript"):
        engine.transcribe(audio)


def test_elevenlabs_splits_before_word_that_would_cross_max_cue_length(audio):
    response_payload = {
        "language_code": "en", "audio_duration_secs": 31.0,
        "words": [
            {"text": "start", "type": "word", "start": 0.0, "end": 0.1},
            {"text": "later", "type": "word", "start": 1.0, "end": 30.2},
        ],
    }
    response = FakeHTTPResponse(body=json.dumps(response_payload).encode())
    connection = FakeHTTPConnection(response)
    engine = ElevenLabsTranscriber(
        api_key="test-key", connection_factory=lambda *args, **kwargs: connection,
    )

    transcript = engine.transcribe(audio)

    assert [(item.start, item.end) for item in transcript.segments] == [
        (0.0, 0.1), (1.0, 30.2),
    ]
    assert max(item.end - item.start for item in transcript.segments) <= 30.0


def test_elevenlabs_keeps_zero_duration_sentence_punctuation_as_boundary(audio):
    response_payload = {
        "language_code": "en", "audio_duration_secs": 2.0,
        "words": [
            {"text": "Hello", "type": "word", "start": 0.0, "end": 0.4, "speaker_id": "speaker_0"},
            {"text": ".", "type": "punctuation", "start": 0.4, "end": 0.4, "speaker_id": "speaker_0"},
            {"text": "world", "type": "word", "start": 0.5, "end": 0.9, "speaker_id": "speaker_0"},
        ],
    }
    response = FakeHTTPResponse(body=json.dumps(response_payload).encode())
    connection = FakeHTTPConnection(response)
    engine = ElevenLabsTranscriber(
        api_key="test-key", connection_factory=lambda *args, **kwargs: connection,
    )

    transcript = engine.transcribe(audio)

    assert [item.text for item in transcript.segments] == ["Hello.", "world"]


def test_elevenlabs_rejects_non_string_word_text(audio):
    response_payload = {
        "language_code": "en", "audio_duration_secs": 1.0,
        "words": [{"text": None, "type": "word", "start": "bad", "end": 0.2}],
    }
    response = FakeHTTPResponse(body=json.dumps(response_payload).encode())
    connection = FakeHTTPConnection(response)
    engine = ElevenLabsTranscriber(
        api_key="test-key", connection_factory=lambda *args, **kwargs: connection,
    )

    with pytest.raises(TranscriptionError, match="word text"):
        engine.transcribe(audio)


def test_elevenlabs_joins_contractions_without_an_extra_space(audio):
    response_payload = {
        "language_code": "en", "audio_duration_secs": 1.0,
        "words": [
            {"text": "it", "type": "word", "start": 0.0, "end": 0.2},
            {"text": " ", "type": "spacing", "start": 0.2, "end": 0.2},
            {"text": "'", "type": "punctuation", "start": 0.2, "end": 0.2},
            {"text": "s", "type": "word", "start": 0.2, "end": 0.4},
        ],
    }
    response = FakeHTTPResponse(body=json.dumps(response_payload).encode())
    connection = FakeHTTPConnection(response)
    engine = ElevenLabsTranscriber(
        api_key="test-key", connection_factory=lambda *args, **kwargs: connection,
    )

    transcript = engine.transcribe(audio)

    assert transcript.segments[0].text == "it's"


def test_elevenlabs_requires_api_key_without_loading_audio(audio, monkeypatch):
    monkeypatch.delenv("ELEVENLABS_API_KEY", raising=False)
    engine = ElevenLabsTranscriber()
    with pytest.raises(TranscriptionError, match="API key"):
        engine.transcribe(audio)


def test_elevenlabs_http_failures_are_retryable_and_do_not_expose_response(audio):
    response = FakeHTTPResponse(status=401, body=b'{"detail":"secret key"}')
    connection = FakeHTTPConnection(response)
    engine = ElevenLabsTranscriber(
        api_key="test-key",
        connection_factory=lambda *args, **kwargs: connection,
    )
    with pytest.raises(TranscriptionError, match="HTTP status 401") as error:
        engine.transcribe(audio)
    assert "secret" not in str(error.value)


@pytest.fixture
def artifacts(tmp_path):
    result = []
    for extension in ("md", "txt", "srt"):
        path = tmp_path / f"CS182_2026-10-18_1430.{extension}"
        path.write_text("[00:00] Test lecture content.\n", encoding="utf-8")
        result.append(path)
    return result


class FakeRclone:
    """Small in-memory remote; commands remain real argument vectors."""

    def __init__(self):
        self.objects = {}
        self.commands = []

    def __call__(self, command, **kwargs):
        self.commands.append((command, kwargs))
        action = command[1]
        if action == "copyto":
            self.objects[command[3]] = Path(command[2]).read_bytes()
            output = b""
        elif action == "lsjson":
            content = self.objects[command[2]]
            output = json.dumps(
                {"Size": len(content), "IsDir": False}, indent=2
            ).encode()
        elif action == "cat":
            output = self.objects[command[2]]
        else:
            raise AssertionError(f"Unexpected remote operation: {action}")
        return subprocess.CompletedProcess(command, 0, output, b"")


def publisher_for(runner):
    return RclonePublisher(
        "lecture-drive:", {"CS182": "course-folder-id"}, runner=runner
    )


def test_publish_uploads_only_explicit_files_to_scoped_course_folder(artifacts):
    remote = FakeRclone()
    publisher_for(remote).publish("cs182", artifacts)
    assert len(remote.objects) == 3
    for artifact in artifacts:
        assert remote.objects[f"lecture-drive:{artifact.name}"] == artifact.read_bytes()
    for command, kwargs in remote.commands:
        assert command[0] == "rclone"
        assert command[1] in {"copyto", "lsjson", "cat"}
        assert command[command.index("--drive-root-folder-id") + 1] == "course-folder-id"
        assert kwargs["shell"] is False
        assert kwargs["timeout"] > 0
        assert kwargs["check"] is False


def test_root_folder_mode_uploads_into_exact_course_subdirectory(artifacts):
    remote = FakeRclone()
    RclonePublisher(
        "lecture-drive:", root_folder_id="lectures-root-id", runner=remote
    ).publish("CS182", artifacts)

    assert set(remote.objects) == {
        f"lecture-drive:CS182/{artifact.name}" for artifact in artifacts
    }
    for command, _ in remote.commands:
        assert command[command.index("--drive-root-folder-id") + 1] == "lectures-root-id"


@pytest.mark.parametrize("course", ["CS182", "bio_101", "MATH-1", "研究", "Cafe\u0301", "ÉTUDES", "A B"])
def test_root_folder_course_names_preserve_manifest_unicode_policy(artifacts, course):
    remote = FakeRclone()
    RclonePublisher("drive", root_folder_id="root-id", runner=remote).publish(
        course, artifacts[:1]
    )
    assert f"drive:{course}/{artifacts[0].name}" in remote.objects


@pytest.mark.parametrize(
    "course", ["", ".", "..", "../escape", "A/B", "A\\B", "C:remote", "A\nB", "📚"]
)
def test_root_folder_refuses_unsafe_course_path_before_upload(artifacts, course):
    runner = Mock()
    publisher = RclonePublisher("drive", root_folder_id="root-id", runner=runner)
    with pytest.raises(PublicationError, match="course"):
        publisher.publish(course, artifacts)
    runner.assert_not_called()


@pytest.mark.parametrize(
    "settings",
    [{}, {"folder_ids": {"CS182": "folder-id"}, "root_folder_id": "root-id"}],
)
def test_publisher_requires_exactly_one_destination_mode(settings):
    with pytest.raises(ValueError, match="exactly one"):
        RclonePublisher("drive", **settings)


@pytest.mark.parametrize("root", ["", "../outside", "root/id", "root\nother", 123])
def test_root_folder_id_is_validated(root):
    with pytest.raises(ValueError, match="root.*folder ID"):
        RclonePublisher("drive", root_folder_id=root)


@pytest.mark.parametrize("suffix", [".m4a", ".mp4", ".wav", ".aac", ".json"])
def test_publish_preflights_all_artifacts_before_uploading(artifacts, tmp_path, suffix):
    media = tmp_path / f"lecture{suffix}"
    media.write_bytes(b"not a transcript")
    runner = Mock()
    with pytest.raises(PublicationError, match="transcript"):
        publisher_for(runner).publish("CS182", [*artifacts, media])
    runner.assert_not_called()


def test_unknown_course_does_not_upload_or_guess_destination(artifacts):
    runner = Mock()
    with pytest.raises(PublicationError, match="course"):
        publisher_for(runner).publish("CS999", artifacts)
    runner.assert_not_called()


def test_shell_metacharacters_are_inert_filename_characters(tmp_path):
    artifact = tmp_path / "$(touch bad);`echo nope`.txt"
    artifact.write_text("[00:00] Sample", encoding="utf-8")
    remote = FakeRclone()
    publisher_for(remote).publish("CS182", [artifact])
    assert remote.commands[0][0][2] == str(artifact)
    assert remote.commands[0][0][3] == f"lecture-drive:{artifact.name}"


def test_publication_rejects_same_size_remote_corruption(artifacts):
    remote = FakeRclone()

    def corrupt(command, **kwargs):
        result = remote(command, **kwargs)
        if command[1] == "cat":
            return subprocess.CompletedProcess(command, 0, b"x" * len(result.stdout), b"")
        return result

    with pytest.raises(PublicationError, match="checksum|content"):
        publisher_for(corrupt).publish("CS182", artifacts)


def test_corrected_transcript_overwrites_remote_despite_equal_size_and_timestamp(tmp_path):
    artifact = tmp_path / "CS182_2026-10-18_1430.txt"
    artifact.write_bytes(b"new transcript")
    remote = FakeRclone()
    destination = f"lecture-drive:{artifact.name}"
    remote.objects[destination] = b"old transcript"

    def metadata_skip(command, **kwargs):
        # rclone's default same-size/same-mtime shortcut must not suppress the
        # revised content merely because metadata still matches the old file.
        if command[1] == "copyto" and "--ignore-times" not in command:
            return subprocess.CompletedProcess(command, 0, b"", b"")
        return remote(command, **kwargs)

    publisher_for(metadata_skip).publish("CS182", [artifact])
    assert remote.objects[destination] == b"new transcript"


@pytest.mark.parametrize("value", [b"not JSON", b'[]', b'{"Size": true}', b'{"Size": 99}'])
def test_invalid_or_mismatched_remote_size_never_marks_success(artifacts, value):
    remote = FakeRclone()

    def bad_listing(command, **kwargs):
        result = remote(command, **kwargs)
        if command[1] == "lsjson":
            return subprocess.CompletedProcess(command, 0, value, b"")
        return result

    with pytest.raises(PublicationError, match="metadata|size|JSON"):
        publisher_for(bad_listing).publish("CS182", artifacts)


@pytest.mark.parametrize("action", ["copyto", "lsjson", "cat"])
def test_failed_remote_command_redacts_external_output(artifacts, action):
    remote = FakeRclone()

    def failure(command, **kwargs):
        if command[1] == action:
            return subprocess.CompletedProcess(command, 5, b"", b"secret access token")
        return remote(command, **kwargs)

    with pytest.raises(PublicationError, match="exit.*5") as error:
        publisher_for(failure).publish("CS182", artifacts)
    assert "secret" not in str(error.value)
    assert error.value.__cause__ is None


@pytest.mark.parametrize(
    "error",
    [FileNotFoundError("secret executable path"), subprocess.TimeoutExpired("rclone", 120)],
)
def test_missing_or_stalled_rclone_is_actionable_without_leaking(artifacts, error):
    with pytest.raises(PublicationError, match="rclone|timeout") as caught:
        publisher_for(Mock(side_effect=error)).publish("CS182", artifacts)
    assert "secret" not in str(caught.value)
    assert caught.value.__cause__ is None


def test_empty_publication_is_not_success():
    with pytest.raises(PublicationError, match="artifact"):
        publisher_for(Mock()).publish("CS182", [])


def test_duplicate_basenames_cannot_overwrite_one_another(artifacts):
    runner = Mock()
    with pytest.raises(PublicationError, match="unique"):
        publisher_for(runner).publish("CS182", [artifacts[0], artifacts[0]])
    runner.assert_not_called()


def test_symlinks_and_missing_artifacts_are_rejected_before_upload(artifacts, tmp_path):
    link = tmp_path / "linked.txt"
    link.symlink_to(artifacts[0])
    runner = Mock()
    for path in (link, tmp_path / "missing.txt"):
        with pytest.raises(PublicationError, match="regular"):
            publisher_for(runner).publish("CS182", [path])
    runner.assert_not_called()


def test_changed_local_artifact_during_upload_is_not_success(artifacts):
    remote = FakeRclone()

    def mutate(command, **kwargs):
        result = remote(command, **kwargs)
        if command[1] == "copyto":
            Path(command[2]).write_text("replacement", encoding="utf-8")
        return result

    with pytest.raises(PublicationError, match="changed"):
        publisher_for(mutate).publish("CS182", artifacts)


@pytest.mark.parametrize("when", ["initial", "recheck"])
def test_unreadable_local_artifact_is_retryable_without_details(artifacts, monkeypatch, when):
    remote = FakeRclone()
    publisher = publisher_for(remote)
    real_fingerprint = publisher._fingerprint
    fingerprints = Mock(side_effect=OSError("secret path"))
    if when == "recheck":
        fingerprints.side_effect = [real_fingerprint(artifacts[0]), OSError("secret path")]
    monkeypatch.setattr(publisher, "_fingerprint", fingerprints)
    with pytest.raises(PublicationError, match="Cannot.*local") as error:
        publisher.publish("CS182", artifacts[:1])
    assert "secret" not in str(error.value)


def test_failed_multi_artifact_upload_can_be_retried_without_deleting(artifacts):
    remote = FakeRclone()
    uploads = 0

    def fail_second_upload(command, **kwargs):
        nonlocal uploads
        if command[1] == "copyto":
            uploads += 1
            if uploads == 2:
                return subprocess.CompletedProcess(command, 1, b"", b"offline")
        return remote(command, **kwargs)

    with pytest.raises(PublicationError):
        publisher_for(fail_second_upload).publish("CS182", artifacts)
    assert len(remote.objects) == 1
    publisher_for(remote).publish("CS182", artifacts)
    assert len(remote.objects) == len(artifacts)
    assert not any("delete" in command for command, _ in remote.commands)


def test_conflicting_casefold_course_mapping_is_rejected():
    with pytest.raises(ValueError, match="course"):
        RclonePublisher("drive", {"CS182": "first", "cs182": "second"})


@pytest.mark.parametrize("remote", [":local:", "drive:path", "--bad", "drive\nother"])
def test_remote_must_be_a_configured_name(remote):
    with pytest.raises(ValueError, match="remote"):
        RclonePublisher(remote, {"CS182": "course-folder-id"})


@pytest.mark.parametrize("timeout", [0, float("nan"), float("inf")])
def test_rclone_requires_a_finite_positive_timeout(timeout):
    with pytest.raises(ValueError, match="timeout"):
        RclonePublisher("drive", {"CS182": "folder-id"}, timeout=timeout)


def test_rclone_rejects_unscoped_folder_mapping():
    with pytest.raises(ValueError, match="folder ID"):
        RclonePublisher("drive", {"CS182": "../../somewhere"})
