import json

import pytest

from lcp_server.models import AudioEvent, Segment, Transcript
from lcp_server.quality import QualityThresholds, assess_transcript


def codes(report):
    return {warning.code for warning in report.warnings}


def test_explicit_overlapping_events_do_not_inflate_speech_or_hide_a_real_tail():
    speech = (Segment(0, 10, "First.", "speaker_0"), Segment(80, 90, "Last.", "speaker_0"))
    baseline = assess_transcript(Transcript(120, speech))
    report = assess_transcript(Transcript(120, speech, audio_events=(
        AudioEvent(0, 120, "PRIVATE_EVENT"), AudioEvent(20, 80, "second event"),
    )))

    assert report.speech_seconds == baseline.speech_seconds == 20
    assert report.speech_density == baseline.speech_density
    assert report.trailing_silence_seconds == baseline.trailing_silence_seconds == 30
    assert report.tail_word_count == baseline.tail_word_count == 1
    assert report.diarization_coverage == baseline.diarization_coverage == 1
    assert report.audio_event_count == 2
    assert report.audio_event_seconds == 120  # Union, not 180 overlapping seconds.
    assert "cue_over_30s" not in codes(report)
    assert "excessive_trailing_silence" in codes(report)
    assert report.relevance_status == baseline.relevance_status == "needs_review"
    assert "PRIVATE_EVENT" not in json.dumps(report.to_dict())


def test_short_spoken_cue_plus_long_event_is_not_a_speech_collapse_but_stays_relevance_blocked():
    report = assess_transcript(Transcript(600, (Segment(0, 2, "Actual speech."),), audio_events=(
        AudioEvent(0, 600, "long ambient sound"),
    )))
    assert "one_cue_collapse" not in codes(report)
    assert "cue_over_30s" not in codes(report)
    assert report.speech_seconds == 2
    assert report.trailing_silence_seconds == 598
    assert report.relevance_status == "likely_accidental"
    assert report.publication_allowed is False


@pytest.mark.parametrize("duration", [10, 120, 600])
def test_sound_only_transcript_is_never_lecture_ready(duration):
    report = assess_transcript(Transcript(duration, (), audio_events=(AudioEvent(0, duration, "sound"),)))
    assert report.cue_count == report.speech_seconds == report.speaker_count == 0
    assert "no_speech" in codes(report)
    assert report.publishable is False
    assert report.publication_allowed is False
    assert report.relevance_status != "likely_lecture"
    assert "no_spoken_transcript" in report.relevance_reasons


def test_quality_gate_detects_provider_collapse_and_advisory_signals():
    report = assess_transcript(Transcript(
        200,
        (Segment(0, 40, "[noise] crosstalk", None),),
    ))

    assert report.publishable is False
    assert report.status == "blocked"
    assert {"one_cue_collapse", "cue_over_30s"} <= codes(report)
    assert {"diarization_missing", "excessive_trailing_silence",
            "noise_or_crosstalk_markers"} <= codes(report)
    assert report.noise_marker_count == 2
    assert report.to_dict()["blocking"] is True
    assert all("blocking" in warning for warning in report.to_dict()["warnings"])


def test_quality_report_flags_low_density_and_partial_diarization_without_blocking():
    report = assess_transcript(Transcript(
        300,
        (
            Segment(0, 5, "Opening", "speaker_0"),
            Segment(10, 20, "[inaudible]", None),
        ),
    ))

    assert report.publishable is True
    assert report.speech_density == 0.05
    assert report.diarization_coverage == 0.3333333333333333
    assert {"diarization_low", "low_speech_density", "excessive_trailing_silence",
            "noise_or_crosstalk_markers"} <= codes(report)


def test_quality_report_detects_qualified_provider_sound_markers():
    report = assess_transcript(Transcript(
        30,
        (Segment(0, 5, "[upbeat music] [machine whirring] Welcome.", "speaker_0"),),
    ))
    assert report.noise_marker_count == 2
    assert "[music]" in report.noise_markers
    assert "[environmental sound]" in report.noise_markers


def test_normal_single_speaker_lecture_remains_publishable():
    report = assess_transcript(Transcript(
        90,
        (
            Segment(0, 25, "Welcome to class.", "speaker_0"),
            Segment(26, 55, "Today we cover graphs.", "speaker_0"),
            Segment(56, 85, "Questions?", "speaker_0"),
        ),
    ))

    assert report.publishable is True
    assert report.status == "pass"
    assert report.warnings == ()
    assert report.speaker_count == 1
    assert report.diarization_coverage == 1.0


def test_thresholds_can_be_tuned_for_fixture_or_provider_variants():
    report = assess_transcript(
        Transcript(40, (Segment(0, 35, "Long but accepted", "speaker_0"),)),
        QualityThresholds(max_cue_seconds=40),
    )
    assert report.publishable is True
    assert "cue_over_30s" not in codes(report)


def test_quality_report_flags_low_density_endpoint_tail():
    report = assess_transcript(
        Transcript(180, (Segment(0, 20, "Opening remarks", "speaker_0"),
                         Segment(120, 180, "The end.", "speaker_0"))),
        QualityThresholds(max_cue_seconds=120),
    )

    assert report.publishable is True
    assert "low_density_tail" in codes(report)
    assert report.tail_word_count == 2
    assert report.tail_words_per_minute == 2.0


def test_trailing_silence_warns_when_absolute_limit_is_exceeded_on_long_recording():
    # A 90-second tail is over the absolute 60-second limit, but below the
    # old max(absolute, relative) limit of 15 minutes for this recording.
    report = assess_transcript(
        Transcript(4_500, (Segment(0, 4_410, "Lecture content", "speaker_0"),)),
        QualityThresholds(max_cue_seconds=5_000),
    )

    warning = next(warning for warning in report.warnings
                   if warning.code == "excessive_trailing_silence")
    assert warning.details["exceeded_absolute"] is True
    assert warning.details["exceeded_relative"] is False
    assert warning.details["absolute_limit_seconds"] == 60.0
    assert warning.details["relative_limit_seconds"] == 900.0


def test_trailing_silence_warns_when_relative_limit_is_exceeded():
    # The tail is below a deliberately high absolute limit but over 20% of
    # the recording, so the relative check must still produce a warning.
    report = assess_transcript(
        Transcript(1_000, (Segment(0, 750, "Lecture content", "speaker_0"),)),
        QualityThresholds(max_cue_seconds=1_000, trailing_silence_seconds=300),
    )

    warning = next(warning for warning in report.warnings
                   if warning.code == "excessive_trailing_silence")
    assert warning.details["exceeded_absolute"] is False
    assert warning.details["exceeded_relative"] is True
    assert warning.details["absolute_limit_seconds"] == 300.0
    assert warning.details["relative_limit_seconds"] == 200.0


def test_relevance_flags_a_very_sparse_long_recording_as_likely_accidental():
    report = assess_transcript(Transcript(
        600,
        (Segment(0, 4, "Testing one two three", "speaker_0"),),
    ))

    assert report.relevance_status == "likely_accidental"
    assert report.relevant is False
    assert report.publication_allowed is False
    assert "minimal_speech_for_recording_duration" in report.relevance_reasons
    payload = report.to_dict()
    assert payload["relevance"] == "likely_accidental"
    assert payload["publication_allowed"] is False


def test_relevance_flags_a_late_ended_recording_for_review_without_guessing_roles():
    report = assess_transcript(Transcript(
        300,
        (
            Segment(0, 25, "The lecture content ends here.", "speaker_0"),
            Segment(200, 220, "One final point.", "speaker_0"),
        ),
    ))

    assert report.relevance_status == "needs_review"
    assert "excessive_trailing_silence" in report.relevance_reasons
    assert report.publication_allowed is False


def test_sustained_identical_cues_block_publication_without_exposing_phrase():
    import json

    transcript = Transcript(600, tuple(
        Segment(index * 20, (index + 1) * 20, "Private repeated filler phrase!", "speaker_0")
        for index in range(30)
    ))
    original = transcript.segments

    report = assess_transcript(transcript)

    warning = next(item for item in report.warnings if item.code == "sustained_text_repetition")
    assert warning.blocking is True
    assert warning.details["count"] == 30
    assert warning.details["span_seconds"] == 600
    assert report.publishable is False
    assert report.publication_allowed is False
    assert transcript.segments == original
    assert "Private repeated filler" not in json.dumps(report.to_dict())
    assert all(isinstance(value, (int, float)) for value in warning.details.values())


def test_repetition_normalizes_case_punctuation_and_allows_sparse_interruptions():
    segments = []
    at = 0
    for index in range(30):
        phrase = "THANK YOU!" if index % 2 else "Thank, you."
        segments.append(Segment(at, at + 10, phrase, "speaker_0"))
        at += 10
        if index % 6 == 5:
            segments.append(Segment(at, at + 2, f"An isolated aside number {index}.", "speaker_0"))
            at += 2

    assert "sustained_text_repetition" in codes(assess_transcript(Transcript(at, tuple(segments))))


def test_ordinary_course_terminology_in_different_sentences_does_not_trigger_repetition():
    transcript = Transcript(600, tuple(
        Segment(index * 20, (index + 1) * 20,
                f"Graph traversal example {index} explores a different edge relationship.", "speaker_0")
        for index in range(30)
    ))

    assert "sustained_text_repetition" not in codes(assess_transcript(transcript))


def test_a_few_exact_repeats_or_single_word_cues_are_not_a_repetition_blocker():
    for text, count in (("Please repeat that.", 4), ("Okay.", 40)):
        transcript = Transcript(count * 20, tuple(
            Segment(index * 20, (index + 1) * 20, text, "speaker_0")
            for index in range(count)
        ))
        assert "sustained_text_repetition" not in codes(assess_transcript(transcript))


def test_distant_recurrence_of_identical_cues_does_not_trigger_repetition():
    segments = []
    for index in range(60):
        text = "Recall the invariant." if index % 6 == 0 else f"Distinct worked example number {index}."
        segments.append(Segment(index * 20, (index + 1) * 20, text, "speaker_0"))

    assert "sustained_text_repetition" not in codes(assess_transcript(Transcript(1200, tuple(segments))))


def test_small_repeated_section_does_not_dominate_an_otherwise_varied_lecture():
    segments = [
        Segment(index * 20, (index + 1) * 20,
                f"Distinct lecture point {index} explains a separate useful concept.", "speaker_0")
        for index in range(200)
    ]
    segments.extend(
        Segment(4000 + index * 10, 4010 + index * 10, "Please continue.", "speaker_0")
        for index in range(12)
    )

    assert "sustained_text_repetition" not in codes(assess_transcript(Transcript(4120, tuple(segments))))


def test_duration_share_catches_long_low_word_count_repetitive_tail():
    segments = [
        Segment(index * 20, (index + 1) * 20,
                " ".join(f"topic{index}_{word}" for word in range(100)), "speaker_0")
        for index in range(3)
    ]
    segments.extend(
        Segment(60 + index * 20, 80 + index * 20, "Thank you.", "speaker_0")
        for index in range(12)
    )

    report = assess_transcript(Transcript(300, tuple(segments)))

    warning = next(item for item in report.warnings if item.code == "sustained_text_repetition")
    assert warning.details["text_ratio"] < 0.25
    assert warning.details["duration_ratio"] == 0.8


def test_quality_audit_reassesses_old_published_quality_without_mutating_state(tmp_path):
    import json
    from lcp_server.quality_audit import audit_quality_jobs
    from lcp_server.rendering import transcript_to_dict

    transcript = Transcript(600, tuple(
        Segment(index * 20, (index + 1) * 20, "Repeated review phrase.", "speaker_0")
        for index in range(30)
    ))
    jobs = tmp_path / "state" / "jobs"
    jobs.mkdir(parents=True)
    path = jobs / ("1" * 64 + ".json")
    path.write_text(json.dumps({
        "identity": {"filename": "CS201_2026-10-27_1532.m4a"},
        "stage": "published", "published": True, "quality": {"status": "pass"},
        "transcript": transcript_to_dict(transcript),
    }))
    before = path.read_bytes()

    audit = audit_quality_jobs(tmp_path)

    assert audit.errors == ()
    assert audit.reports[0].published is True
    assert audit.reports[0].report.publication_allowed is False
    assert "sustained_text_repetition" in codes(audit.reports[0].report)
    assert path.read_bytes() == before

