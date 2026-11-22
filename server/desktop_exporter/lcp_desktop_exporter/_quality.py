"""Dependency-free transcript quality checks.

The worker treats transcription as a successful local operation even when the
provider returns a transcript that needs review.  This module makes those
signals explicit and gives publication a conservative gate for catastrophic
timestamp failures and sustained identical cue repetition. It deliberately uses
only the transcript model and the Python standard library so it can run before
optional STT packages are loaded.
"""

from __future__ import annotations

import math
import re
from dataclasses import dataclass, field
from typing import Any, Mapping

from ._models import Segment, Transcript, validate_audio_events


@dataclass(frozen=True)
class QualityThresholds:
    """Thresholds used by :func:`assess_transcript`.

    A cue longer than 30 seconds is unsafe for downstream citation and a
    single cue covering a recording longer than 30 seconds is treated as the
    known provider collapse failure. Sustained identical multiword cues also
    block publication when they dominate recording time or transcript words.
    Diarization, silence, density, and
    noise checks remain advisory: a normal one-speaker lecture is publishable.
    """

    max_cue_seconds: float = 30.0
    trailing_silence_seconds: float = 60.0
    trailing_silence_ratio: float = 0.20
    low_density_min_duration_seconds: float = 60.0
    low_speech_density: float = 0.10
    low_diarization_coverage: float = 0.50
    low_density_tail_min_seconds: float = 60.0
    low_density_tail_words_per_minute: float = 30.0
    repetition_min_words: int = 2
    repetition_min_cues: int = 12
    repetition_min_span_seconds: float = 120.0
    repetition_min_duration_ratio: float = 0.20
    repetition_min_text_ratio: float = 0.25
    repetition_min_local_cue_ratio: float = 0.80
    repetition_max_gap_seconds: float = 30.0


@dataclass(frozen=True)
class QualityWarning:
    """A machine-readable quality finding suitable for durable job state."""

    code: str
    message: str
    severity: str = "warning"
    blocking: bool = False
    details: Mapping[str, Any] = field(default_factory=dict)

    def to_dict(self) -> dict[str, Any]:
        return {
            "code": self.code,
            "message": self.message,
            "severity": self.severity,
            "blocking": self.blocking,
            "details": dict(self.details),
        }


@dataclass(frozen=True)
class TranscriptQualityReport:
    """Summary metrics and warnings for one finalized transcript.

    ``publishable`` is false only for findings that can make a transcript
    unusable for timestamped downstream ingestion. ``relevance_status`` is a
    separate conservative corpus gate for accidental captures and recorder
    tails. The worker still stores local artifacts and the complete report
    when either gate blocks publication.
    """

    cue_count: int
    speaker_count: int
    duration_seconds: float
    speech_seconds: float
    speech_density: float
    trailing_silence_seconds: float
    tail_word_count: int
    tail_words_per_minute: float
    diarization_coverage: float
    noise_marker_count: int
    noise_markers: tuple[str, ...]
    warnings: tuple[QualityWarning, ...]
    publishable: bool
    # Relevance is deliberately a conservative, machine-readable decision.
    # It does not attempt to decide what course content means; it only keeps
    # obvious accidental recordings and recordings with a long open tail out
    # of the Drive corpus until a human reviews them.
    relevance_status: str = "likely_lecture"
    relevance_reasons: tuple[str, ...] = ()
    audio_event_count: int = 0
    audio_event_seconds: float = 0.0

    @property
    def status(self) -> str:
        if not self.publishable:
            return "blocked"
        return "warn" if self.warnings else "pass"

    @property
    def blocking(self) -> bool:
        return not self.publishable

    @property
    def relevant(self) -> bool:
        """Whether this recording is safe to include in the Grok corpus."""

        return self.relevance_status == "likely_lecture"

    @property
    def publication_allowed(self) -> bool:
        """Whether timestamp quality and relevance gates both pass."""

        return self.publishable and self.relevant

    def to_dict(self) -> dict[str, Any]:
        """Return JSON-compatible durable state without exposing dataclasses."""
        return {
            "status": self.status,
            "publishable": self.publishable,
            "blocking": self.blocking,
            "cue_count": self.cue_count,
            "speaker_count": self.speaker_count,
            "duration_seconds": self.duration_seconds,
            "speech_seconds": self.speech_seconds,
            "speech_density": self.speech_density,
            "trailing_silence_seconds": self.trailing_silence_seconds,
            "tail_word_count": self.tail_word_count,
            "tail_words_per_minute": self.tail_words_per_minute,
            "diarization_coverage": self.diarization_coverage,
            "noise_marker_count": self.noise_marker_count,
            "noise_markers": list(self.noise_markers),
            "audio_event_count": self.audio_event_count,
            "audio_event_seconds": self.audio_event_seconds,
            "relevance": self.relevance_status,
            "relevance_status": self.relevance_status,
            "relevance_reasons": list(self.relevance_reasons),
            "publication_allowed": self.publication_allowed,
            "warnings": [warning.to_dict() for warning in self.warnings],
        }


# Provider and human transcripts use a few different spellings.  Restrict
# broad words such as "noise" to bracketed markers so a lecture discussing
# signal noise does not trigger a false positive.
_NOISE_MARKER_PATTERNS: tuple[tuple[str, re.Pattern[str]], ...] = (
    ("inaudible", re.compile(r"\binaudible\b", re.IGNORECASE)),
    ("unintelligible", re.compile(r"\bunintelligible\b", re.IGNORECASE)),
    ("background noise", re.compile(r"\bbackground\s+noise\b", re.IGNORECASE)),
    ("crosstalk", re.compile(r"\bcross[- ]?talk\b|\bcrosstalk\b", re.IGNORECASE)),
    ("overlapping speech", re.compile(r"\boverlapping\s+(?:speech|speakers?)\b", re.IGNORECASE)),
    ("static", re.compile(r"\bstatic\b", re.IGNORECASE)),
    ("distortion", re.compile(r"\bdistortion\b", re.IGNORECASE)),
    ("[noise]", re.compile(r"\[\s*noise\s*\]", re.IGNORECASE)),
    # Providers often qualify a sound marker (for example, ``[upbeat music]``
    # or ``[machine whirring]``). Keep these separate from ordinary prose so
    # an agent can exclude the annotated span without treating every mention
    # of a sound-related word as background noise.
    ("[music]", re.compile(r"\[[^\]\r\n]*\bmusic\b[^\]\r\n]*\]", re.IGNORECASE)),
    ("[laughter]", re.compile(r"\[[^\]\r\n]*\blaughter\b[^\]\r\n]*\]", re.IGNORECASE)),
    ("[applause]", re.compile(r"\[[^\]\r\n]*\bapplause\b[^\]\r\n]*\]", re.IGNORECASE)),
    ("[environmental sound]", re.compile(
        r"\[[^\]\r\n]*(?:machine\s+whirr|whirr|ringing|cough|beep|door|car\s+horn|phone|wind|traffic|keyboard)[^\]\r\n]*\]",
        re.IGNORECASE,
    )),
)


def _validate_thresholds(thresholds: QualityThresholds) -> None:
    values = (
        ("max_cue_seconds", thresholds.max_cue_seconds),
        ("trailing_silence_seconds", thresholds.trailing_silence_seconds),
        ("trailing_silence_ratio", thresholds.trailing_silence_ratio),
        ("low_density_min_duration_seconds", thresholds.low_density_min_duration_seconds),
        ("low_speech_density", thresholds.low_speech_density),
        ("low_diarization_coverage", thresholds.low_diarization_coverage),
        ("low_density_tail_min_seconds", thresholds.low_density_tail_min_seconds),
        ("low_density_tail_words_per_minute", thresholds.low_density_tail_words_per_minute),
        ("repetition_min_span_seconds", thresholds.repetition_min_span_seconds),
        ("repetition_max_gap_seconds", thresholds.repetition_max_gap_seconds),
    )
    for name, value in values:
        if (isinstance(value, bool) or not isinstance(value, (int, float))
                or not math.isfinite(float(value)) or value < 0):
            raise ValueError(f"{name} must be a finite nonnegative number")
    for name in ("repetition_min_words", "repetition_min_cues"):
        value = getattr(thresholds, name)
        if type(value) is not int or value < 1:
            raise ValueError(f"{name} must be a positive integer")
    for name in ("repetition_min_duration_ratio", "repetition_min_text_ratio", "repetition_min_local_cue_ratio"):
        value = getattr(thresholds, name)
        if (isinstance(value, bool) or not isinstance(value, (int, float))
                or not math.isfinite(float(value)) or not 0 <= value <= 1):
            raise ValueError(f"{name} must be a finite ratio between zero and one")


def _marker_hits(text: str) -> list[str]:
    hits: list[str] = []
    for label, pattern in _NOISE_MARKER_PATTERNS:
        hits.extend([label] * len(pattern.findall(text)))
    return hits


def _word_count(text: str) -> int:
    """Count lexical tokens for endpoint-density diagnostics."""
    return len(re.findall(r"(?u)\b[\w][\w'’\-]*\b", text))


def _repetition_warning(
    segments: tuple[Segment, ...], duration: float, thresholds: QualityThresholds,
) -> QualityWarning | None:
    """Find sustained identical whole-cue text without exposing the phrase.

    Normalizing case and punctuation is deliberately narrower than semantic
    similarity: repeated terminology inside otherwise different sentences is
    not evidence. A qualifying run must dominate a nearby sequence of cues,
    persist for minutes, and account for substantial recording time or words.
    No speech or timestamps are changed, even when publication is blocked.
    """
    tokens = [tuple(re.findall(r"(?u)\b\w+\b", segment.text.casefold())) for segment in segments]
    total_words = sum(len(item) for item in tokens)
    if not total_words:
        return None
    runs: dict[tuple[str, ...], list[int]] = {}
    findings: list[dict[str, float | int]] = []

    def consider(key: tuple[str, ...], indices: list[int]) -> None:
        count = len(indices)
        if count < thresholds.repetition_min_cues:
            return
        first, last = indices[0], indices[-1]
        span = float(segments[last].end) - float(segments[first].start)
        if span < thresholds.repetition_min_span_seconds:
            return
        local_ratio = count / (last - first + 1)
        duration_ratio = min(1.0, span / duration)
        text_ratio = count * len(key) / total_words
        if (local_ratio < thresholds.repetition_min_local_cue_ratio
                or (duration_ratio < thresholds.repetition_min_duration_ratio
                    and text_ratio < thresholds.repetition_min_text_ratio)):
            return
        findings.append({
            "count": count, "words_per_cue": len(key), "span_seconds": span,
            "duration_ratio": duration_ratio, "text_ratio": text_ratio,
            "local_cue_ratio": local_ratio,
        })

    for index, key in enumerate(tokens):
        if len(key) < thresholds.repetition_min_words:
            continue
        run = runs.get(key)
        if run:
            previous = run[-1]
            nearby = (index - previous <= 2 and float(segments[index].start) - float(segments[previous].end)
                      <= thresholds.repetition_max_gap_seconds)
            candidate_ratio = (len(run) + 1) / (index - run[0] + 1)
            if not nearby or candidate_ratio < thresholds.repetition_min_local_cue_ratio:
                consider(key, run)
                run = None
        if run is None:
            run = []
            runs[key] = run
        run.append(index)
    for key, run in runs.items():
        consider(key, run)
    if not findings:
        return None
    strongest = max(findings, key=lambda item: (item["duration_ratio"], item["text_ratio"]))
    return QualityWarning(
        code="sustained_text_repetition",
        message="Identical multiword cues repeat for a sustained, substantial portion of the transcript.",
        severity="error", blocking=True,
        details={
            **strongest, "qualifying_runs": len(findings),
            "minimum_cues": thresholds.repetition_min_cues,
            "minimum_span_seconds": thresholds.repetition_min_span_seconds,
            "minimum_duration_ratio": thresholds.repetition_min_duration_ratio,
            "minimum_text_ratio": thresholds.repetition_min_text_ratio,
            "minimum_local_cue_ratio": thresholds.repetition_min_local_cue_ratio,
        },
    )


def _relevance_assessment(
    *,
    duration: float,
    speech_seconds: float,
    speech_density: float,
    warnings: list[QualityWarning],
) -> tuple[str, tuple[str, ...]]:
    """Classify recording usefulness without pretending to understand content.

    ``likely_accidental`` is reserved for very little speech in a recording
    long enough to be a lecture.  A long tail is ``needs_review`` because it
    may be an ordinary early stop or an app left recording; either way, it is
    unsafe to let the tail silently enter the agent's corpus.  These checks
    intentionally do not use speaker count or speaking order to identify a
    professor.
    """

    reasons: list[str] = []
    # Relative endpoint checks are useful on short fixtures, but a short
    # recording often ends naturally after a brief sentence.  Relevance
    # gating therefore applies the tail signal only once the recording is at
    # least a minute long; the warning remains visible in the quality report.
    has_excessive_tail = duration >= 60.0 and any(
        warning.code == "excessive_trailing_silence" for warning in warnings
    )
    has_low_density_tail = any(
        warning.code == "low_density_tail" for warning in warnings
    )
    has_low_density = any(
        warning.code == "low_speech_density" for warning in warnings
    )

    # A recording with under five seconds of speech after two minutes, or
    # under two percent speech after five minutes, is a strong accidental-
    # capture signal.  The deliberately high durations avoid classifying
    # short fixtures and short office-hour recordings as accidental.
    likely_accidental = (
        (duration >= 120.0 and speech_seconds < 5.0)
        or (duration >= 300.0 and speech_density < 0.02)
    )
    if likely_accidental:
        reasons.append("minimal_speech_for_recording_duration")

    # Any endpoint warning means the recorder ran materially past the final
    # speech cue.  Keep this separate from accidental capture so an operator
    # can distinguish a valid lecture with an open microphone from no lecture.
    if has_excessive_tail:
        reasons.append("excessive_trailing_silence")
    if has_low_density_tail:
        reasons.append("low_density_recording_tail")
    # The advisory low-density threshold is intentionally less strict than
    # the publication relevance gate.  Short recordings and office-hour
    # snippets can be sparse while still being intentional; only lecture-
    # length recordings get this additional review signal.
    if has_low_density and duration >= 300.0 and not likely_accidental:
        reasons.append("low_speech_density")
    if likely_accidental:
        status = "likely_accidental"
    elif reasons:
        status = "needs_review"
    else:
        status = "likely_lecture"
    return status, tuple(dict.fromkeys(reasons))


def assess_transcript(
    transcript: Transcript,
    thresholds: QualityThresholds | None = None,
) -> TranscriptQualityReport:
    """Assess transcript structure and return quality findings.

    The transcript has already passed structural validation by the worker.  A
    defensive check still keeps this function safe for direct callers and
    makes malformed values produce a clear error instead of a misleading
    quality score.
    """

    thresholds = thresholds or QualityThresholds()
    _validate_thresholds(thresholds)
    if not isinstance(transcript, Transcript):
        raise ValueError("Expected a Transcript")
    if (isinstance(transcript.duration, bool)
            or not isinstance(transcript.duration, (int, float))
            or not math.isfinite(float(transcript.duration))
            or transcript.duration <= 0):
        raise ValueError("Transcript duration must be positive")
    validate_audio_events(transcript.audio_events, transcript.duration)
    if not transcript.segments and not transcript.audio_events:
        raise ValueError("Transcript contains no speech segments")

    duration = float(transcript.duration)
    segments = tuple(transcript.segments)
    if any(
        not isinstance(segment, Segment)
        or isinstance(segment.start, bool)
        or not isinstance(segment.start, (int, float))
        or not math.isfinite(float(segment.start))
        or isinstance(segment.end, bool)
        or not isinstance(segment.end, (int, float))
        or not math.isfinite(float(segment.end))
        or segment.end <= segment.start
        or segment.end > duration + 0.5
        or not isinstance(segment.text, str)
        or not segment.text.strip()
        for segment in segments
    ):
        raise ValueError("Transcript contains an invalid segment")
    cue_durations = [max(0.0, float(segment.end) - float(segment.start)) for segment in segments]
    speech_seconds = sum(cue_durations)
    last_end = max((float(segment.end) for segment in segments), default=0.0)
    trailing_silence = max(0.0, duration - last_end)
    speech_density = min(1.0, speech_seconds / duration) if duration else 0.0
    last_segment = max(segments, key=lambda segment: float(segment.end)) if segments else None
    tail_duration = max(0.0, float(last_segment.end) - float(last_segment.start)) if last_segment else 0.0
    tail_word_count = _word_count(last_segment.text) if last_segment else 0
    tail_words_per_minute = (
        tail_word_count / tail_duration * 60.0 if tail_duration > 0 else 0.0
    )

    speaker_durations: dict[str, float] = {}
    marker_hits: list[str] = []
    for segment, cue_duration in zip(segments, cue_durations):
        speaker = segment.speaker.strip() if isinstance(segment.speaker, str) else None
        if speaker:
            speaker_durations[speaker] = speaker_durations.get(speaker, 0.0) + cue_duration
        marker_hits.extend(_marker_hits(segment.text))
    diarization_coverage = (
        min(1.0, sum(speaker_durations.values()) / speech_seconds)
        if speech_seconds else 0.0
    )
    warnings: list[QualityWarning] = []
    if not segments:
        warnings.append(QualityWarning(
            code="no_speech",
            message="The provider returned sound annotations without spoken transcript cues.",
            severity="error", blocking=True, details={"cue_count": 0},
        ))

    # Report only bounded counts/timing, never provider event labels. Compute
    # their union so overlapping events cannot inflate the duration metric.
    event_seconds = 0.0
    event_end = 0.0
    for event in sorted(transcript.audio_events, key=lambda event: event.start):
        event_seconds += max(0.0, event.end - max(event.start, event_end))
        event_end = max(event_end, event.end)
    if transcript.audio_events:
        warnings.append(QualityWarning(
            code="non_speech_audio_events",
            message="Explicit provider sound annotations are retained separately from spoken cues.",
            details={"count": len(transcript.audio_events), "duration_seconds": event_seconds},
        ))

    if (len(segments) == 1 and duration > thresholds.max_cue_seconds
            # A separate sound track may span a long recording containing a
            # short, correctly timed spoken cue. It is not a speech collapse;
            # the unchanged density/tail/relevance gates still assess it.
            and (not transcript.audio_events or cue_durations[0] > thresholds.max_cue_seconds)):
        warnings.append(QualityWarning(
            code="one_cue_collapse",
            message=(
                "The transcript contains one cue for a recording longer than "
                f"{thresholds.max_cue_seconds:g} seconds."
            ),
            severity="error",
            blocking=True,
            details={"cue_count": 1, "duration_seconds": duration},
        ))

    long_cues = [cue_duration for cue_duration in cue_durations
                 if cue_duration > thresholds.max_cue_seconds]
    if long_cues:
        warnings.append(QualityWarning(
            code="cue_over_30s",
            message=(
                "One or more transcript cues exceed the "
                f"{thresholds.max_cue_seconds:g}-second citation limit."
            ),
            severity="error",
            blocking=True,
            details={
                "count": len(long_cues),
                "max_seconds": max(long_cues),
                "threshold_seconds": thresholds.max_cue_seconds,
            },
        ))

    repetition = _repetition_warning(segments, duration, thresholds)
    if repetition is not None:
        warnings.append(repetition)

    if not speaker_durations:
        warnings.append(QualityWarning(
            code="diarization_missing",
            message="No transcript cues include a speaker identifier.",
            details={"speaker_count": 0, "coverage": 0.0},
        ))
    elif diarization_coverage < thresholds.low_diarization_coverage:
        warnings.append(QualityWarning(
            code="diarization_low",
            message="Speaker identifiers cover only a small portion of spoken time.",
            details={
                "speaker_count": len(speaker_durations),
                "coverage": diarization_coverage,
                "threshold": thresholds.low_diarization_coverage,
            },
        ))

    absolute_silence_limit = float(thresholds.trailing_silence_seconds)
    relative_silence_limit = duration * float(thresholds.trailing_silence_ratio)
    exceeds_absolute_limit = trailing_silence > absolute_silence_limit
    exceeds_relative_limit = trailing_silence > relative_silence_limit
    if exceeds_absolute_limit or exceeds_relative_limit:
        warnings.append(QualityWarning(
            code="excessive_trailing_silence",
            message="The last speech cue ends well before the declared recording duration.",
            details={
                "trailing_silence_seconds": trailing_silence,
                # Keep the effective limit for consumers that only need one
                # value, while exposing both checks so the finding is
                # explainable when the recording is long or short.
                "limit_seconds": min(absolute_silence_limit, relative_silence_limit),
                "absolute_limit_seconds": absolute_silence_limit,
                "relative_limit_seconds": relative_silence_limit,
                "relative_limit_ratio": float(thresholds.trailing_silence_ratio),
                "exceeded_absolute": exceeds_absolute_limit,
                "exceeded_relative": exceeds_relative_limit,
            },
        ))

    if duration >= thresholds.low_density_min_duration_seconds and speech_density < thresholds.low_speech_density:
        warnings.append(QualityWarning(
            code="low_speech_density",
            message="Timestamped speech covers only a small fraction of the recording.",
            details={
                "speech_density": speech_density,
                "threshold": thresholds.low_speech_density,
                "speech_seconds": speech_seconds,
            },
        ))

    if (
        tail_duration >= thresholds.low_density_tail_min_seconds
        and last_end >= duration - 2.0
        and tail_words_per_minute < thresholds.low_density_tail_words_per_minute
    ):
        warnings.append(QualityWarning(
            code="low_density_tail",
            message="The final timestamped cue contains unusually little speech for its duration.",
            details={
                "tail_duration_seconds": tail_duration,
                "tail_word_count": tail_word_count,
                "tail_words_per_minute": tail_words_per_minute,
                "threshold_words_per_minute": thresholds.low_density_tail_words_per_minute,
            },
        ))

    if marker_hits:
        unique_markers = tuple(dict.fromkeys(marker_hits))
        warnings.append(QualityWarning(
            code="noise_or_crosstalk_markers",
            message="Transcript text contains provider or human markers for noise/crosstalk.",
            details={"count": len(marker_hits), "markers": list(unique_markers)},
        ))
    else:
        unique_markers = ()

    relevance_status, relevance_reasons = _relevance_assessment(
        duration=duration,
        speech_seconds=speech_seconds,
        speech_density=speech_density,
        warnings=warnings,
    )
    if not segments:
        if relevance_status == "likely_lecture":
            relevance_status = "needs_review"
        relevance_reasons = (*relevance_reasons, "no_spoken_transcript")

    return TranscriptQualityReport(
        cue_count=len(segments),
        speaker_count=len(speaker_durations),
        duration_seconds=duration,
        speech_seconds=speech_seconds,
        speech_density=speech_density,
        trailing_silence_seconds=trailing_silence,
        tail_word_count=tail_word_count,
        tail_words_per_minute=tail_words_per_minute,
        diarization_coverage=diarization_coverage,
        noise_marker_count=len(marker_hits),
        noise_markers=unique_markers,
        warnings=tuple(warnings),
        publishable=not any(warning.blocking for warning in warnings),
        relevance_status=relevance_status,
        relevance_reasons=relevance_reasons,
        audio_event_count=len(transcript.audio_events),
        audio_event_seconds=event_seconds,
    )

