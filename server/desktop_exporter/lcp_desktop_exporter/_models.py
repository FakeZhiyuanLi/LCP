"""Small, dependency-free interfaces shared by the worker and adapters."""

from dataclasses import dataclass
import math


@dataclass(frozen=True)
class Segment:
    start: float
    end: float
    text: str
    # Optional provider speaker identifier.  Providers such as local Whisper
    # do not populate this field; ElevenLabs can return anonymous diarization
    # IDs (for example, ``speaker_0``).
    speaker: str | None = None


@dataclass(frozen=True)
class AudioEvent:
    """An explicitly typed provider sound annotation, never a speech cue."""

    start: float
    end: float
    text: str
    type: str = "audio_event"


@dataclass(frozen=True)
class Transcript:
    duration: float
    segments: tuple[Segment, ...]
    language: str = "en"
    # Legacy caches have no event types; their segments remain speech. Only
    # explicit provider audio_event entries belong in this separate track.
    audio_events: tuple[AudioEvent, ...] = ()


def validate_audio_events(events: tuple[AudioEvent, ...], duration: float) -> None:
    """Validate exact event endpoints without requiring speech/event ordering.

    Sounds may overlap one another and spoken words. Never sort, trim, infer
    types from labels, or include private event text in validation errors.
    """

    if not isinstance(events, tuple):
        raise ValueError("Invalid transcript audio events")
    for event in events:
        if (not isinstance(event, AudioEvent)
                or event.type != "audio_event"
                or isinstance(event.start, bool) or not isinstance(event.start, (int, float))
                or isinstance(event.end, bool) or not isinstance(event.end, (int, float))
                or event.start < 0 or event.end <= event.start or event.end > duration
                or not isinstance(event.text, str) or not event.text.strip()):
            raise ValueError("Invalid transcript audio event")
        try:
            finite = math.isfinite(event.start) and math.isfinite(event.end)
        except (OverflowError, ValueError, TypeError):
            finite = False
        if not finite:
            raise ValueError("Invalid transcript audio event")


