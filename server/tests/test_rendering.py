from datetime import datetime
import json

import pytest

from lcp_server.manifest import RecordingManifest
from lcp_server.models import AudioEvent, Segment, Transcript
from lcp_server.rendering import render_artifacts, transcript_from_dict, transcript_to_dict, validate_transcript


def manifest():
    return RecordingManifest(
        filename="CS182_2026-10-18_1430.m4a",
        size_bytes=3,
        sha256="ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
        course="CS182",
        captured_at=datetime(2026, 10, 18, 14, 30),
    )


def test_validate_transcript_rejects_zero_length_and_out_of_range_segments():
    with pytest.raises(ValueError, match="Invalid transcript segment"):
        validate_transcript(Transcript(10, (Segment(2, 2, "hello"),)))
    with pytest.raises(ValueError, match="Invalid transcript segment"):
        validate_transcript(Transcript(10, (Segment(2, 11, "hello"),)))


def test_audio_events_roundtrip_exactly_and_stay_out_of_spoken_formats():
    speech = (Segment(1.125, 2.625, "Unique spoken explanation.", "speaker_0"),)
    label = " \tPRIVATE_EVENT\n[01:23] is an event label, not a cue. \u96e8 "
    events = (AudioEvent(0.0, 120.125, label), AudioEvent(1.0, 2.0, "overlap"))
    transcript = Transcript(120.125, speech, audio_events=events)

    restored = transcript_from_dict(transcript_to_dict(transcript))
    assert restored == transcript
    assert restored.audio_events[0].text == label
    artifacts = render_artifacts(manifest(), restored)
    speech_only = render_artifacts(manifest(), Transcript(120.125, speech))
    for suffix, prefix in (("md", "- **Audio events JSON:** "), ("txt", "Audio-Events-JSON: ")):
        rendered = artifacts[f"CS182_2026-10-18_1430.{suffix}"].decode()
        line = next(line for line in rendered.splitlines() if line.startswith(prefix))
        assert json.loads(line.removeprefix(prefix)) == list(transcript_to_dict(transcript)["audio_events"])
        assert "event labels are not spoken lecture claims" in rendered
        assert rendered.count("Unique spoken explanation.") == 1
    assert artifacts["CS182_2026-10-18_1430.srt"] == speech_only["CS182_2026-10-18_1430.srt"]
    assert b"PRIVATE_EVENT" not in artifacts["CS182_2026-10-18_1430.srt"]


def test_legacy_cache_without_event_track_remains_conservatively_spoken():
    transcript = transcript_from_dict({
        "duration": 90, "language": "en",
        "segments": [{"start": 0, "end": 80, "text": "[background noise] unique speech"}],
    })
    assert transcript.audio_events == ()
    assert transcript.segments == (Segment(0, 80, "[background noise] unique speech"),)


@pytest.mark.parametrize("events", [
    None, {}, "PRIVATE_EVENT", [None], [{"start": 0, "end": 3, "text": "PRIVATE_EVENT"}],
    [{"start": 0, "end": 3, "text": "PRIVATE_EVENT", "type": "word"}],
    [{"start": 0, "end": 3, "text": "PRIVATE_EVENT", "type": "audio_event", "extra": True}],
    [{"start": False, "end": 3, "text": "PRIVATE_EVENT", "type": "audio_event"}],
    [{"start": -1, "end": 3, "text": "PRIVATE_EVENT", "type": "audio_event"}],
    [{"start": 3, "end": 3, "text": "PRIVATE_EVENT", "type": "audio_event"}],
    [{"start": 0, "end": 10.001, "text": "PRIVATE_EVENT", "type": "audio_event"}],
    [{"start": float("nan"), "end": 3, "text": "PRIVATE_EVENT", "type": "audio_event"}],
])
def test_bad_cached_event_metadata_fails_without_reclassification_or_label_disclosure(events):
    with pytest.raises(ValueError, match="^Invalid transcript audio events?$") as raised:
        transcript_from_dict({
            "duration": 10, "language": "en", "audio_events": events,
            "segments": [{"start": 0, "end": 1, "text": "Valid speech."}],
        })
    assert "PRIVATE_EVENT" not in str(raised.value)


def test_event_only_transcript_renders_retained_annotations_with_no_spoken_cues():
    transcript = Transcript(120, (), audio_events=(AudioEvent(0, 120, "Sound only."),))
    artifacts = render_artifacts(manifest(), transcript)
    assert b"Audio-Events-JSON:" in artifacts["CS182_2026-10-18_1430.txt"]
    assert b"Relevance: likely_lecture" not in artifacts["CS182_2026-10-18_1430.txt"]
    assert b"do not ingest" in artifacts["CS182_2026-10-18_1430.md"]
    assert artifacts["CS182_2026-10-18_1430.srt"] == b"\n"


def test_render_artifacts_preserves_speaker_labels_and_valid_srt_cues():
    artifacts = render_artifacts(
        manifest(),
        Transcript(
            10,
            (
                Segment(0.25, 1.5, "Hello class.", "speaker_0"),
                Segment(2.0, 3.25, "Professor here.", "speaker_1"),
            ),
        ),
    )

    assert b"**speaker_0:** Hello class." in artifacts["CS182_2026-10-18_1430.md"]
    assert b"**Speaker labels:** anonymous provider IDs (roles unassigned)" in artifacts["CS182_2026-10-18_1430.md"]
    assert b"**Professor speaker:** unknown (requires calibration)" in artifacts["CS182_2026-10-18_1430.md"]
    assert b"**Agent guidance:** Preserve speaker labels as turn markers; do not infer professor identity; IDs are scoped to this recording." in artifacts["CS182_2026-10-18_1430.md"]
    assert b"[speaker_1] Professor here." in artifacts["CS182_2026-10-18_1430.txt"]
    assert b"Speaker-Labels: anonymous provider IDs (roles unassigned)" in artifacts["CS182_2026-10-18_1430.txt"]
    assert b"Speaker-Count: 2" in artifacts["CS182_2026-10-18_1430.txt"]
    assert b"Professor-Speaker: unknown" in artifacts["CS182_2026-10-18_1430.txt"]
    srt = artifacts["CS182_2026-10-18_1430.srt"].decode()
    assert "00:00:00,250 --> 00:00:01,500" in srt
    assert "00:00:02,000 --> 00:00:03,250" in srt


def test_render_artifacts_marks_explicitly_calibrated_professor_in_all_cues():
    artifacts = render_artifacts(
        manifest(),
        Transcript(
            10,
            (
                Segment(0.25, 1.5, "Hello class.", "speaker_0"),
                Segment(2.0, 3.25, "Question?", "speaker_1"),
            ),
        ),
        professor_speaker="speaker_0",
    )
    markdown = artifacts["CS182_2026-10-18_1430.md"].decode()
    text = artifacts["CS182_2026-10-18_1430.txt"].decode()
    srt = artifacts["CS182_2026-10-18_1430.srt"].decode()
    assert "Professor-Speaker: speaker_0" in text
    assert "speaker_0=Professor" in text
    assert "**speaker_0 (Professor):** Hello class." in markdown
    assert "[speaker_0 (Professor)] Hello class." in text
    assert "[speaker_0 (Professor)] Hello class." in srt


def test_render_artifacts_rejects_calibration_for_missing_speaker():
    with pytest.raises(ValueError, match="not present in the transcript"):
        render_artifacts(
            manifest(), Transcript(2, (Segment(0, 1, "Hello.", "speaker_0"),)),
            professor_speaker="speaker_1",
        )


def test_render_artifacts_exposes_noise_and_relevance_for_downstream_agents():
    artifacts = render_artifacts(
        manifest(),
        Transcript(600, (Segment(0, 4, "[background noise] test", "speaker_0"),)),
    )

    markdown = artifacts["CS182_2026-10-18_1430.md"].decode()
    text = artifacts["CS182_2026-10-18_1430.txt"].decode()
    assert "- **Professor speaker:** unknown (requires calibration)" in markdown
    assert "- **Speaker roles:** unassigned; anonymous IDs are recording-scoped" in markdown
    assert "- **Background noise:** detected markers:" in markdown
    assert "- **Relevance:** likely_accidental" in markdown
    assert "- **Grok ingestion:** do not ingest until an operator reviews the relevance flag" in markdown
    assert "Professor-Speaker: unknown" in text
    assert "Speaker-Roles: unassigned; explicit user calibration required" in text
    assert "Background-Noise: detected markers:" in text
    assert "Relevance: likely_accidental" in text
    assert "Grok-Use: do not ingest until an operator reviews the relevance flag" in text


def test_render_artifacts_keeps_submillisecond_cue_nonzero_in_srt():
    artifacts = render_artifacts(
        manifest(), Transcript(1, (Segment(0.25, 0.2501, "tiny"),))
    )
    assert "00:00:00,250 --> 00:00:00,251" in artifacts["CS182_2026-10-18_1430.srt"].decode()


def test_transcript_from_dict_skips_only_empty_zero_duration_formatting_markers():
    transcript = transcript_from_dict({
        "duration": 10,
        "language": "en",
        "segments": [
            {"start": 1, "end": 1, "text": " \t\n", "speaker": "speaker_0"},
            {"start": 2, "end": 3, "text": "Hello."},
        ],
    })
    assert [(item.start, item.end, item.text) for item in transcript.segments] == [
        (2, 3, "Hello."),
    ]


@pytest.mark.parametrize("text", ["Unique private speech.", "[background noise]", None, 42, False])
def test_transcript_from_dict_rejects_nonempty_or_malformed_zero_duration_cues(text):
    with pytest.raises(ValueError, match="^Invalid transcript segment$") as raised:
        transcript_from_dict({
            "duration": 10,
            "language": "en",
            "segments": [
                {"start": 1, "end": 1, "text": text},
                {"start": 2, "end": 3, "text": "Valid speech."},
            ],
        })
    assert "Unique private speech" not in str(raised.value)


def test_validate_transcript_rejects_overlapping_segments_and_bad_persisted_numbers():
    with pytest.raises(ValueError, match="Invalid transcript segment"):
        validate_transcript(Transcript(
            10,
            (Segment(0, 5, "first"), Segment(3, 4, "overlap")),
        ))
    with pytest.raises(ValueError, match="Invalid transcript duration"):
        validate_transcript(Transcript("ten", (Segment(0, 1, "hello"),)))


def test_transcript_from_dict_does_not_publish_an_empty_legacy_transcript():
    with pytest.raises(ValueError, match="no speech"):
        transcript_from_dict({
            "duration": 10,
            "language": "en",
            "segments": [{"start": 1, "end": 1, "text": " \t"}],
        })


def test_render_artifacts_marks_speaker_identity_unavailable_without_diarization():
    artifacts = render_artifacts(manifest(), Transcript(1, (Segment(0, 1, "Welcome."),)))
    markdown = artifacts["CS182_2026-10-18_1430.md"]
    text = artifacts["CS182_2026-10-18_1430.txt"]
    assert b"**Speaker labels:** unavailable" in markdown
    assert b"**Speaker count:** 0" in markdown
    assert b"**Professor speaker:** unknown (requires calibration)" in markdown
    assert b"**Agent guidance:** No speaker labels are available; do not infer speaker identity." in markdown
    assert b"Speaker-Labels: unavailable" in text
    assert b"Professor-Speaker: unknown" in text
