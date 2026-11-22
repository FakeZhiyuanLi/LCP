"""Timestamped local notes and publication artifacts, without inferred numbering."""

import math
import json
import re
from dataclasses import asdict
from typing import Any

from .manifest import RecordingManifest
from .models import AudioEvent, Segment, Transcript, validate_audio_events
from .quality import TranscriptQualityReport, assess_transcript


def validate_transcript(transcript: Transcript) -> Transcript:
    if not isinstance(transcript, Transcript):
        raise ValueError("Invalid transcript duration")
    if (isinstance(transcript.duration, bool)
            or not isinstance(transcript.duration, (int, float))
            or not math.isfinite(float(transcript.duration))
            or transcript.duration <= 0):
        raise ValueError("Invalid transcript duration")
    if not isinstance(transcript.language, str) or not transcript.language.strip():
        raise ValueError("Invalid transcript language")
    validate_audio_events(transcript.audio_events, transcript.duration)
    if not transcript.segments and not transcript.audio_events:
        raise ValueError("Transcript contains no speech segments")
    previous = 0.0
    previous_end = 0.0
    for segment in transcript.segments:
        if (not isinstance(segment, Segment)
                or isinstance(segment.start, bool) or not isinstance(segment.start, (int, float))
                or isinstance(segment.end, bool) or not isinstance(segment.end, (int, float))
                or not math.isfinite(float(segment.start)) or not math.isfinite(float(segment.end))
                or segment.start < previous or segment.start < previous_end or segment.end <= segment.start
                # A small encoder-padding tolerance is useful, but a cue
                # materially beyond the declared source duration indicates a
                # malformed provider timestamp.
                or segment.end > transcript.duration + 0.5
                or not isinstance(segment.text, str)):
            raise ValueError("Invalid transcript segment")
        if not segment.text.strip():
            raise ValueError("Invalid transcript segment text")
        if segment.speaker is not None and (
                not isinstance(segment.speaker, str) or not segment.speaker.strip()
        ):
            raise ValueError("Invalid transcript speaker")
        previous = segment.start
        previous_end = segment.end
    return transcript


def transcript_from_dict(data: dict[str, Any]) -> Transcript:
    # Older durable jobs may contain empty zero-duration formatting markers.
    # Only those carry no speech to preserve. Nonempty zero-duration cues must
    # fail validation so unique cached text is never silently discarded.
    segments = []
    for segment in data["segments"]:
        item = Segment(
            start=segment["start"], end=segment["end"], text=segment["text"],
            speaker=segment.get("speaker"),
        )
        if item.end == item.start and isinstance(item.text, str) and not item.text.strip():
            continue
        segments.append(item)
    raw_events = data.get("audio_events", ())
    if not isinstance(raw_events, (list, tuple)):
        raise ValueError("Invalid transcript audio events")
    events = []
    for event in raw_events:
        if not isinstance(event, dict) or set(event) != {"start", "end", "text", "type"}:
            raise ValueError("Invalid transcript audio event")
        events.append(AudioEvent(**event))
    return validate_transcript(Transcript(
        duration=data["duration"], language=data["language"],
        # ``speaker`` was added after the first local-only state files were
        # written; accepting its absence keeps those cached jobs resumable.
        segments=tuple(segments),
        audio_events=tuple(events),
    ))


def transcript_to_dict(transcript: Transcript) -> dict[str, Any]:
    return asdict(validate_transcript(transcript))


def timestamp(seconds: float) -> str:
    total = int(seconds)
    return f"{total // 60:02d}:{total % 60:02d}"


def srt_timestamp(seconds: float) -> str:
    milliseconds = round(seconds * 1000)
    hours, remainder = divmod(milliseconds, 3_600_000)
    minutes, remainder = divmod(remainder, 60_000)
    secs, millis = divmod(remainder, 1000)
    return f"{hours:02d}:{minutes:02d}:{secs:02d},{millis:03d}"


def render_artifacts(
    manifest: RecordingManifest,
    transcript: Transcript,
    quality: TranscriptQualityReport | None = None,
    professor_speaker: str | None = None,
) -> dict[str, bytes]:
    validate_transcript(transcript)
    # Rendering is also used by audits and tests, so compute the same
    # machine-readable relevance decision when the worker has not already
    # supplied its cached report.
    quality = quality or assess_transcript(transcript)
    stem = manifest.filename[:-4]
    minutes = f"{transcript.duration / 60:.2f}"
    speaker_count = len({
        segment.speaker.strip()
        for segment in transcript.segments
        if isinstance(segment.speaker, str) and segment.speaker.strip()
    })
    speaker_ids = {
        segment.speaker.strip()
        for segment in transcript.segments
        if isinstance(segment.speaker, str) and segment.speaker.strip()
    }
    if professor_speaker is not None:
        if (not isinstance(professor_speaker, str)
                or re.fullmatch(r"speaker_[A-Za-z0-9_.-]+", professor_speaker) is None):
            raise ValueError("Professor speaker calibration must be an anonymous speaker ID")
        if professor_speaker not in speaker_ids:
            raise ValueError(
                f"Professor speaker calibration {professor_speaker!r} is not present in the transcript"
            )
    if speaker_count:
        if professor_speaker:
            speaker_labels = "anonymous provider IDs; professor role explicitly calibrated"
            agent_guidance = (
                f"Treat {professor_speaker} as the Professor because it was explicitly calibrated; "
                "preserve all other IDs as non-professor turn markers. IDs are scoped to this recording."
            )
            professor_label = f"{professor_speaker} (explicit operator calibration)"
            speaker_roles = f"{professor_speaker}=Professor; other anonymous IDs=non-professor/unassigned"
            text_speaker_roles = speaker_roles
        else:
            speaker_labels = "anonymous provider IDs (roles unassigned)"
            agent_guidance = (
                "Preserve speaker labels as turn markers; do not infer professor identity; "
                "IDs are scoped to this recording."
            )
            professor_label = "unknown (requires calibration)"
            speaker_roles = "unassigned; anonymous IDs are recording-scoped"
            text_speaker_roles = "unassigned; explicit user calibration required"
    else:
        speaker_labels = "unavailable"
        agent_guidance = "No speaker labels are available; do not infer speaker identity."
        professor_label = "unknown (requires calibration)"
        speaker_roles = "unavailable; explicit calibration cannot be applied without speaker IDs"
        text_speaker_roles = speaker_roles
    relevance_reasons = ", ".join(quality.relevance_reasons) or "none"
    if quality.noise_markers:
        background_noise = (
            "detected markers: " + ", ".join(quality.noise_markers)
            + "; exclude marked spans from lecture claims"
        )
    else:
        background_noise = "no transcript noise markers detected; audio noise remains unknown"
    if transcript.audio_events:
        background_noise += (
            f"; {len(transcript.audio_events)} explicit provider non-speech audio event(s) "
            "retained separately; event labels are not spoken lecture claims"
        )
    # JSON escaping preserves event labels (including whitespace/newlines)
    # exactly and keeps them out of the spoken-cue grammar in all formats.
    event_json = json.dumps(
        [asdict(event) for event in transcript.audio_events],
        ensure_ascii=True, separators=(",", ":"),
    )
    markdown_events = f"- **Audio events JSON:** {event_json}\n" if transcript.audio_events else ""
    text_events = f"Audio-Events-JSON: {event_json}\n" if transcript.audio_events else ""
    grok_guidance = (
        "include in lecture corpus"
        if quality.relevance_status == "likely_lecture"
        else "do not ingest until an operator reviews the relevance flag"
    )
    markdown = (f"# Lecture Notes: {stem}\n\n- **Course:** {manifest.course}\n"
                f"- **Duration:** {minutes} minutes\n"
                f"- **Speaker labels:** {speaker_labels}\n"
                f"- **Speaker count:** {speaker_count}\n"
                f"- **Professor speaker:** {professor_label}\n"
                f"- **Speaker roles:** {speaker_roles}\n"
                f"- **Background noise:** {background_noise}\n"
                f"{markdown_events}"
                f"- **Relevance:** {quality.relevance_status}\n"
                f"- **Relevance reasons:** {relevance_reasons}\n"
                f"- **Agent guidance:** {agent_guidance}\n"
                f"- **Grok ingestion:** {grok_guidance}\n\n## Transcript\n\n")
    markdown += "\n\n".join(
        f"**[{timestamp(s.start)}]** {speaker_prefix(s, markdown=True, professor_speaker=professor_speaker)}{s.text.strip()}"
        for s in transcript.segments
    ) + "\n"
    text = (f"Course: {manifest.course}\nDate: {manifest.captured_at:%Y-%m-%d}\n"
            f"Time: {manifest.captured_at:%H:%M}\nLecture: unknown\nSource: {manifest.filename}\n"
            f"Duration: {minutes} minutes\nLanguage: {transcript.language}\n"
            f"Speaker-Labels: {speaker_labels}\nSpeaker-Count: {speaker_count}\n"
            f"Professor-Speaker: {professor_speaker or 'unknown'}\n"
            f"Speaker-Roles: {text_speaker_roles}\n"
            f"Background-Noise: {background_noise}\n"
            f"{text_events}"
            f"Relevance: {quality.relevance_status}\n"
            f"Relevance-Reasons: {relevance_reasons}\n"
            f"Grok-Use: {grok_guidance}\n"
            f"Agent-Guidance: {agent_guidance}\nSource-SHA256: {manifest.sha256}\n\n")
    text += "\n\n".join(
        f"[{timestamp(s.start)}] {speaker_prefix(s, professor_speaker=professor_speaker)}{s.text.strip()}"
        for s in transcript.segments
    ) + "\n"
    subtitles = "\n\n".join(
        f"{number}\n{srt_timestamp(s.start)} --> {srt_timestamp(max(s.end, s.start + 0.001))}\n"
        f"{speaker_prefix(s, professor_speaker=professor_speaker)}{s.text.strip()}"
        for number, s in enumerate(transcript.segments, start=1)
    ) + "\n"
    return {f"{stem}.md": markdown.encode(), f"{stem}.txt": text.encode(), f"{stem}.srt": subtitles.encode()}


def speaker_prefix(
    segment: Segment,
    *,
    markdown: bool = False,
    professor_speaker: str | None = None,
) -> str:
    """Render an optional anonymous provider speaker label consistently."""
    if not segment.speaker:
        return ""
    label = segment.speaker
    if professor_speaker and segment.speaker == professor_speaker:
        label += " (Professor)"
    return f"**{label}:** " if markdown else f"[{label}] "
