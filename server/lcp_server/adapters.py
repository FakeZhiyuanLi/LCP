"""Local Whisper and transcript-only Google Drive publication adapters.

Importing this module needs neither CUDA nor faster-whisper. Runtime dependencies
and the model are loaded on the first actual transcription.
"""

from __future__ import annotations

import hashlib
import http.client
import importlib
import json
import logging
import math
import mimetypes
import re
import secrets
import subprocess
from collections.abc import Callable, Collection, Mapping, Sequence
from dataclasses import replace
from pathlib import Path
from typing import Any
from urllib.parse import urlsplit

from .manifest import is_safe_course_component
from .models import AudioEvent, Segment, Transcript, validate_audio_events
from .quality import assess_transcript
from .rendering import validate_transcript


LOGGER = logging.getLogger(__name__)


class AdapterError(RuntimeError):
    """A runtime adapter could not complete its operation."""


class TranscriptionError(AdapterError):
    """Local transcription failed; no complete transcript can be published."""


class WhisperValidationError(TranscriptionError):
    """A local result violates the transcript contract; diagnostics contain no text."""

    def __init__(self, code: str, segment_index: int | None = None) -> None:
        self.code = code
        self.segment_index = segment_index
        self.recovery_attempted = False
        self.initial_code: str | None = None
        label = "transcript" if segment_index is None else f"segment {segment_index}"
        super().__init__(f"Local Whisper {label} failed validation ({code}).")


class CitationFallbackTranscriber:
    """Use local Whisper only when a successful provider result is unsafe to cite.

    ElevenLabs remains the primary backend.  The local backend is called only
    after the provider returns a structurally valid transcript whose quality
    report contains a blocking timestamp finding (a collapsed cue or a cue
    longer than the citation limit).  Provider/API failures are intentionally
    propagated and never trigger a local request.  The fallback's real model
    timestamps are returned unchanged; this class never invents or interpolates
    timing.

    ``last_transcription_metadata`` is consumed by the durable worker so an
    operator can see whether the fallback was selected and whether it supplied
    the cached transcript.  The local result has no provider diarization, which
    is recorded explicitly and also appears in rendered artifacts through the
    absence of speaker IDs.
    """

    CITATION_WARNING_CODES = frozenset({"one_cue_collapse", "cue_over_30s"})

    def __init__(self, primary: Any, fallback: Any) -> None:
        if primary is fallback:
            raise ValueError("Primary and fallback transcribers must be distinct")
        if not callable(getattr(primary, "transcribe", None)):
            raise TypeError("Primary transcriber must provide transcribe(audio)")
        if not callable(getattr(fallback, "transcribe", None)):
            raise TypeError("Fallback transcriber must provide transcribe(audio)")
        self.primary = primary
        self.fallback = fallback
        self.last_transcription_metadata: dict[str, Any] | None = None

    def transcribe(self, audio: Path) -> Transcript:
        # Keep metadata scoped to one successful call.  If the primary raises,
        # the worker must not persist stale metadata from an earlier recording.
        self.last_transcription_metadata = None
        primary_transcript = self.primary.transcribe(audio)
        report = assess_transcript(primary_transcript)
        warning_codes = tuple(
            warning.code
            for warning in report.warnings
            if warning.blocking and warning.code in self.CITATION_WARNING_CODES
        )
        base_metadata: dict[str, Any] = {
            "backend": "elevenlabs",
            "fallback_enabled": True,
            "fallback_attempted": bool(warning_codes),
            "fallback_used": False,
            "speaker_diarization": any(
                isinstance(segment.speaker, str) and bool(segment.speaker.strip())
                for segment in primary_transcript.segments
            ),
        }
        if not warning_codes:
            self.last_transcription_metadata = base_metadata
            return primary_transcript

        base_metadata.update({
            "fallback_reason": "citation_unsafe_timestamps",
            "fallback_warning_codes": list(warning_codes),
        })
        try:
            fallback_transcript = self.fallback.transcribe(audio)
            # A speech-only fallback cannot replace or erase the provider's
            # independently timed sound annotations. Keep their exact values;
            # incompatible source bounds fail below and retain the primary.
            if primary_transcript.audio_events:
                fallback_transcript = replace(
                    fallback_transcript, audio_events=primary_transcript.audio_events,
                )
            # Validate the local result before returning it.  A malformed
            # fallback must never be treated as a successful recovery.
            validate_transcript(fallback_transcript)
            if any(segment.speaker is not None for segment in fallback_transcript.segments):
                raise ValueError("Local Whisper fallback must not claim speaker diarization")
            assess_transcript(fallback_transcript)
        except Exception as error:
            # Preserve the provider transcript for the worker's quality gate
            # and local review when the optional GPU/runtime path is unavailable.
            # This does not publish it: the same blocking quality report still
            # prevents Drive publication until a usable repair is accepted.
            base_metadata.update({
                "fallback_error": type(error).__name__,
            })
            if isinstance(error, WhisperValidationError):
                base_metadata["fallback_validation"] = {
                    "code": error.code,
                    "segment_index": error.segment_index,
                    "recovery_attempted": error.recovery_attempted,
                }
                if error.initial_code is not None:
                    base_metadata["fallback_validation"]["initial_code"] = error.initial_code
            self.last_transcription_metadata = base_metadata
            LOGGER.warning(
                "Local Whisper citation fallback failed; retaining the ElevenLabs transcript (%s)",
                error.code if isinstance(error, WhisperValidationError) else type(error).__name__,
            )
            return primary_transcript

        fallback_report = assess_transcript(fallback_transcript)
        fallback_blocking_codes = [
            warning.code for warning in fallback_report.warnings if warning.blocking
        ]
        if fallback_blocking_codes:
            # A repair that is still citation-unsafe must never replace the
            # provider transcript.  Keep the original result and its quality
            # finding for review; the worker's bounded automatic-repair budget
            # prevents an endless loop.
            base_metadata.update({
                "fallback_used": False,
                "fallback_publishable": False,
                "fallback_rejected": True,
                "fallback_rejection_codes": fallback_blocking_codes,
            })
            fallback_settings = getattr(self.fallback, "last_transcription_metadata", None)
            if isinstance(fallback_settings, dict):
                base_metadata["fallback_settings"] = dict(fallback_settings)
            self.last_transcription_metadata = base_metadata
            LOGGER.warning(
                "Local Whisper citation fallback remained unsafe; retaining the ElevenLabs transcript",
            )
            return primary_transcript
        base_metadata.update({
            "backend": "local-whisper",
            "fallback_used": True,
            "speaker_diarization": False,
            "fallback_publishable": fallback_report.publishable,
        })
        fallback_settings = getattr(self.fallback, "last_transcription_metadata", None)
        if isinstance(fallback_settings, dict):
            # Keep the exact local-repair settings in durable job metadata so
            # a later audit can explain why the citation timestamps differ
            # from the primary provider result.
            base_metadata["fallback_settings"] = dict(fallback_settings)
        self.last_transcription_metadata = base_metadata
        LOGGER.warning(
            "Using local Whisper citation fallback for provider warnings: %s",
            ", ".join(warning_codes),
        )
        return fallback_transcript


class PublicationError(AdapterError):
    """Transcript publication or verification failed and must be retried."""


class WhisperTranscriber:
    """Reuse one local model after explicitly checking the requested compute type.

    The factory and capability probe are injectable for offline tests. Production
    defaults call CTranslate2's runtime probe before constructing WhisperModel;
    unsupported CUDA configurations never silently fall back to another device.
    """

    TIMESTAMP_RECOVERY_CODES = frozenset({
        "zero_duration", "reversed_timestamps", "unordered_timestamps",
        "overlapping_timestamps", "past_source_duration",
    })

    def __init__(
        self,
        model: str = "medium.en",
        device: str = "cuda",
        compute_type: str = "int8_float32",
        vad_filter: bool = True,
        min_silence_duration_ms: int = 500,
        recover_timestamps: bool = False,
        *,
        model_factory: Callable[..., Any] | None = None,
        supported_compute_types: Callable[[str], Collection[str]] | None = None,
    ) -> None:
        if not model or not compute_type:
            raise ValueError("model and compute_type must be explicit, nonempty values")
        if device not in {"cuda", "cpu"}:
            raise ValueError("device must be explicitly 'cuda' or 'cpu'")
        if type(min_silence_duration_ms) is not int or min_silence_duration_ms < 0:
            raise ValueError("min_silence_duration_ms must be a nonnegative integer")
        self.model = model
        self.device = device
        self.compute_type = compute_type
        self.vad_filter = bool(vad_filter)
        self.min_silence_duration_ms = min_silence_duration_ms
        self.recover_timestamps = bool(recover_timestamps)
        self._model_factory = model_factory
        self._supported_compute_types = supported_compute_types
        self._model: Any = None
        self.last_transcription_metadata: dict[str, Any] | None = None

    def _load_model(self) -> Any:
        if self._model is not None:
            return self._model
        try:
            probe = self._supported_compute_types
            if probe is None:
                probe = importlib.import_module("ctranslate2").get_supported_compute_types
            supported = probe(self.device)
        except ImportError as error:
            raise TranscriptionError(
                "Install the server's runtime extra (pip install '.[runtime]') before transcribing."
            ) from error
        except (RuntimeError, OSError, ValueError) as error:
            raise TranscriptionError(
                f"Cannot probe {self.device} compute types; verify the Nvidia driver, "
                "CUDA/cuDNN libraries, and CTranslate2 compatibility on the transcription host."
            ) from error
        if self.compute_type not in supported:
            raise TranscriptionError(
                f"Requested compute type {self.compute_type!r} is unsupported on "
                f"{self.device}; supported types: {', '.join(sorted(supported)) or 'none'}. "
                "Validate the transcription runtime and explicitly configure a supported type."
            )
        try:
            factory = self._model_factory
            if factory is None:
                factory = importlib.import_module("faster_whisper").WhisperModel
            self._model = factory(
                self.model, device=self.device, compute_type=self.compute_type
            )
        except ImportError as error:
            raise TranscriptionError(
                "Install the server's runtime extra (pip install '.[runtime]') before transcribing."
            ) from error
        except (RuntimeError, OSError, ValueError) as error:
            raise TranscriptionError(
                f"Cannot load local Whisper model {self.model!r} on {self.device}; "
                "verify model availability and CUDA/cuDNN/CTranslate2 compatibility."
            ) from error
        return self._model

    def transcribe(self, audio: Path) -> Transcript:
        """Decode finalized worker audio and reject incomplete or invalid results."""
        audio = Path(audio)
        self.last_transcription_metadata = None
        if not audio.is_file():
            raise TranscriptionError("The independent audio copy is missing or not a file.")
        model = self._load_model()
        try:
            options: dict[str, Any] = {
                "language": "en",
                "vad_filter": self.vad_filter,
            }
            if self.vad_filter:
                options["vad_parameters"] = {
                    "min_silence_duration_ms": self.min_silence_duration_ms,
                }
            recovery: WhisperValidationError | None = None
            source_duration: float | None = None
            for attempt in range(2 if self.recover_timestamps else 1):
                if attempt:
                    # Ask the decoder to align words to the audio.  Its real
                    # aligned endpoints may resolve coarse segment boundaries;
                    # we never shift, clamp or interpolate those endpoints.
                    options["word_timestamps"] = True
                raw_segments = None
                try:
                    raw_segments, info = model.transcribe(str(audio), **options)
                    reported_duration = self._finite_number(info.duration, "duration")
                    if source_duration is None:
                        source_duration = reported_duration
                    elif not math.isclose(source_duration, reported_duration, rel_tol=0, abs_tol=1e-6):
                        raise WhisperValidationError("source_duration_changed")
                    transcript = self._decode_result(raw_segments, info)
                except WhisperValidationError as error:
                    close = getattr(raw_segments, "close", None)
                    if callable(close):
                        close()
                    if (not self.recover_timestamps or attempt
                            or error.code not in self.TIMESTAMP_RECOVERY_CODES):
                        error.recovery_attempted = bool(attempt)
                        error.initial_code = recovery.code if recovery is not None else None
                        raise
                    recovery = error
                    LOGGER.warning(
                        "Retrying local Whisper once with word alignment (%s, segment %s)",
                        error.code, error.segment_index,
                    )
                    continue
                except (RuntimeError, OSError, ValueError, TypeError, AttributeError) as error:
                    if attempt and recovery is not None:
                        failure = WhisperValidationError("word_alignment_failed")
                        failure.recovery_attempted = True
                        failure.initial_code = recovery.code
                        raise failure from error
                    raise
                break
            self.last_transcription_metadata = {
                "backend": "local-whisper",
                "model": self.model,
                "device": self.device,
                "compute_type": self.compute_type,
                "vad_filter": self.vad_filter,
                "min_silence_duration_ms": self.min_silence_duration_ms if self.vad_filter else None,
            }
            if self.recover_timestamps:
                self.last_transcription_metadata.update({
                    "timestamp_recovery_enabled": True,
                    "word_timestamps": recovery is not None,
                    "timestamp_recovery_attempted": recovery is not None,
                })
                if recovery is not None:
                    self.last_transcription_metadata["timestamp_recovery_reason"] = recovery.code
            return transcript
        except TranscriptionError:
            raise
        except (RuntimeError, OSError, ValueError, TypeError, AttributeError) as error:
            # faster-whisper decodes lazily while iterating raw_segments.
            raise TranscriptionError(
                "Local transcription did not complete; retain the source and retry."
            ) from error

    def _decode_result(self, raw_segments: Any, info: Any) -> Transcript:
        """Accept only actual, ordered decoder intervals, without retiming text."""
        duration = self._finite_number(info.duration, "duration")
        if duration <= 0:
            raise TranscriptionError("Source duration must be greater than zero.")
        segments = []
        previous_start = 0.0
        previous_end = 0.0
        for index, raw in enumerate(raw_segments):
            try:
                start = self._finite_number(raw.start, "segment timestamp")
                end = self._finite_number(raw.end, "segment timestamp")
            except TranscriptionError as error:
                raise WhisperValidationError("invalid_timestamp", index) from error
            if not isinstance(raw.text, str):
                raise TranscriptionError("Invalid transcript segment text.")
            text = raw.text.strip()
            if not text:
                continue
            if end < start:
                raise WhisperValidationError("reversed_timestamps", index)
            if end == start:
                raise WhisperValidationError("zero_duration", index)
            if start < previous_start:
                raise WhisperValidationError("unordered_timestamps", index)
            if start < previous_end:
                raise WhisperValidationError("overlapping_timestamps", index)
            if end > duration + 0.5:
                raise WhisperValidationError("past_source_duration", index)
            previous_start = start
            previous_end = end
            segments.append(Segment(start=start, end=end, text=text))
        if not segments:
            raise TranscriptionError("Whisper returned an empty transcript with no speech.")
        language = info.language
        if not isinstance(language, str) or not language:
            raise TranscriptionError("Whisper returned an invalid transcript language.")
        return validate_transcript(Transcript(
            duration=duration, segments=tuple(segments), language=language,
        ))

    @staticmethod
    def _finite_number(value: Any, label: str) -> float:
        try:
            number = float(value)
        except (TypeError, ValueError, OverflowError) as error:
            raise TranscriptionError(f"Invalid {label}.") from error
        if isinstance(value, bool) or not math.isfinite(number) or number < 0:
            raise TranscriptionError(f"Invalid {label}; expected a finite nonnegative value.")
        return number


class ElevenLabsTranscriber:
    """Transcribe audio with ElevenLabs Scribe, including optional diarization.

    The request is sent as a streaming multipart body with the Python standard
    library so the worker does not need another HTTP dependency or load a
    lecture into memory.  The API key is read from the environment at request
    time and is never included in exception messages or durable state.
    """

    DEFAULT_ENDPOINT = "https://api.elevenlabs.io/v1/speech-to-text"
    # Provider responses can contain word timestamps even when their optional
    # ``segments`` array collapses an entire lecture into one item.  Keep
    # emitted cues useful to students and downstream agents by bounding a
    # same-speaker run and splitting at natural speech boundaries.
    MAX_SEGMENT_SECONDS = 30.0
    PAUSE_SPLIT_SECONDS = 1.25
    # Kept as a compatibility constant for callers that inspect adapter
    # limits. Provider intervals are no longer rejected at this threshold;
    # citation safety belongs to the quality gate and optional fallback.
    MAX_PROVIDER_SEGMENT_SECONDS = 120.0
    # Long, diarized lectures can legitimately produce more than the old
    # 4 MiB JSON response. Read in bounded chunks and fail closed above this
    # limit; never call ``read()`` without a size or accept an unbounded body.
    MAX_RESPONSE_BYTES = 64 * 1024 * 1024
    RESPONSE_CHUNK_BYTES = 1024 * 1024

    def __init__(
        self,
        model: str = "scribe_v2",
        *,
        api_key: str | None = None,
        api_key_env: str = "ELEVENLABS_API_KEY",
        diarize: bool = True,
        language_code: str | None = "en",
        endpoint: str = DEFAULT_ENDPOINT,
        timeout: float = 600.0,
        connection_factory: Callable[..., Any] | None = None,
        duration_probe: Callable[[Path], float] | None = None,
    ) -> None:
        if not model or not isinstance(model, str):
            raise ValueError("ElevenLabs model must be a nonempty string")
        if not api_key_env or not isinstance(api_key_env, str):
            raise ValueError("ElevenLabs API-key environment name must be nonempty")
        if language_code is not None and (not isinstance(language_code, str) or not language_code):
            raise ValueError("language_code must be a nonempty string or None")
        if not math.isfinite(timeout) or timeout <= 0:
            raise ValueError("ElevenLabs timeout must be finite and positive")
        parsed = urlsplit(endpoint)
        if parsed.scheme != "https" or not parsed.netloc or parsed.query or parsed.fragment:
            raise ValueError("ElevenLabs endpoint must be an HTTPS URL without query parameters")
        self.model = model
        self._api_key = api_key
        self.api_key_env = api_key_env
        self.diarize = bool(diarize)
        self.language_code = language_code
        self.endpoint = endpoint
        self.timeout = timeout
        self._connection_factory = connection_factory or http.client.HTTPSConnection
        self._duration_probe = duration_probe or self._source_audio_duration

    def transcribe(self, audio: Path) -> Transcript:
        audio = Path(audio)
        if audio.is_symlink() or not audio.is_file():
            raise TranscriptionError("The independent audio copy is missing or not a file.")
        api_key = self._api_key
        if api_key is None:
            # Keep credentials out of settings/state and resolve them only for
            # the request, so rotating the key does not require a worker restart.
            import os

            api_key = os.environ.get(self.api_key_env)
        if not api_key:
            raise TranscriptionError(
                f"ElevenLabs API key is unavailable; set {self.api_key_env} on the worker."
            )
        try:
            payload = self._request(audio, api_key)
            words = payload.get("words")
            has_events = isinstance(words, list) and any(
                isinstance(item, dict) and item.get("type") == "audio_event" for item in words
            )
            # Provider event spans must not define their own source bounds.
            # Existing event-free responses retain their compatibility path.
            source_duration = self._duration_probe(audio) if has_events else None
            return self._transcript_from_response(payload, source_duration=source_duration)
        except TranscriptionError:
            raise
        except (OSError, ValueError, TypeError, KeyError, json.JSONDecodeError) as error:
            raise TranscriptionError(
                "ElevenLabs transcription did not complete; retain the source and retry."
            ) from error

    def _request(self, audio: Path, api_key: str) -> dict[str, Any]:
        parsed = urlsplit(self.endpoint)
        path = parsed.path or "/"
        if parsed.query:
            path += f"?{parsed.query}"
        boundary = f"lcp-{secrets.token_hex(16)}"
        field_parts = []

        def field(name: str, value: str) -> bytes:
            return (
                f"--{boundary}\r\n"
                f'Content-Disposition: form-data; name="{name}"\r\n\r\n'
                f"{value}\r\n"
            ).encode("utf-8")

        field_parts.append(field("model_id", self.model))
        field_parts.append(field("diarize", "true" if self.diarize else "false"))
        if self.language_code is not None:
            field_parts.append(field("language_code", self.language_code))
        # Scribe's word timestamps are needed to attach speaker IDs to
        # timestamped transcript segments.
        field_parts.append(field("timestamps_granularity", "word"))
        filename = audio.name.replace("\\", "_").replace('"', "'").replace("\r", "").replace("\n", "")
        content_type = mimetypes.guess_type(filename)[0] or "application/octet-stream"
        file_header = (
            f"--{boundary}\r\n"
            f'Content-Disposition: form-data; name="file"; filename="{filename}"\r\n'
            f"Content-Type: {content_type}\r\n\r\n"
        ).encode("utf-8")
        closing = f"\r\n--{boundary}--\r\n".encode("ascii")
        try:
            size = audio.stat().st_size
        except OSError as error:
            raise TranscriptionError("Cannot read the audio file for ElevenLabs upload.") from error
        if size < 0:
            raise TranscriptionError("Audio file has an invalid size.")
        content_length = sum(len(part) for part in field_parts) + len(file_header) + size + len(closing)
        connection = None
        response = None
        sent = 0
        try:
            connection = self._connection_factory(parsed.netloc, timeout=self.timeout)
            connection.putrequest("POST", path)
            connection.putheader("xi-api-key", api_key)
            connection.putheader("Content-Type", f"multipart/form-data; boundary={boundary}")
            connection.putheader("Content-Length", str(content_length))
            connection.putheader("Accept", "application/json")
            connection.endheaders()
            for part in field_parts:
                connection.send(part)
                sent += len(part)
            connection.send(file_header)
            sent += len(file_header)
            with audio.open("rb") as source:
                while True:
                    block = source.read(1024 * 1024)
                    if not block:
                        break
                    connection.send(block)
                    sent += len(block)
            connection.send(closing)
            sent += len(closing)
            if sent != content_length or audio.stat().st_size != size:
                raise TranscriptionError("Audio changed while it was uploaded to ElevenLabs.")
            response = connection.getresponse()
            body_buffer = bytearray()
            while len(body_buffer) <= self.MAX_RESPONSE_BYTES:
                remaining = self.MAX_RESPONSE_BYTES + 1 - len(body_buffer)
                chunk = response.read(min(self.RESPONSE_CHUNK_BYTES, remaining))
                if not chunk:
                    break
                if not isinstance(chunk, (bytes, bytearray)):
                    raise TranscriptionError("ElevenLabs returned an invalid response body.")
                body_buffer.extend(chunk)
                if len(body_buffer) > self.MAX_RESPONSE_BYTES:
                    raise TranscriptionError("ElevenLabs response is too large.")
            body = bytes(body_buffer)
            if response.status < 200 or response.status >= 300:
                raise TranscriptionError(
                    f"ElevenLabs request failed with HTTP status {response.status}."
                )
            try:
                result = json.loads(body.decode("utf-8"))
            except (UnicodeDecodeError, json.JSONDecodeError) as error:
                raise TranscriptionError("ElevenLabs returned an invalid JSON response.") from error
            if not isinstance(result, dict):
                raise TranscriptionError("ElevenLabs returned an invalid response object.")
            return result
        except TranscriptionError:
            raise
        except (OSError, http.client.HTTPException, ValueError, TypeError) as error:
            raise TranscriptionError(
                "ElevenLabs request failed; retain the source and retry."
            ) from error
        finally:
            if response is not None:
                response.close()
            if connection is not None:
                connection.close()

    def _transcript_from_response(
        self, payload: dict[str, Any], *, source_duration: float | None = None,
    ) -> Transcript:
        language = payload.get("language_code", "en")
        if not isinstance(language, str) or not language.strip():
            raise TranscriptionError("ElevenLabs returned an invalid transcript language.")
        raw_segments = payload.get("segments")
        # Prefer word timestamps whenever present.  Scribe can return a
        # one-item ``segments`` array for a long recording while still
        # providing detailed word timestamps and speaker IDs.  Choosing that
        # broad item would erase the timing and diarization the request asked
        # for (this occurred on a real 70-minute lecture).
        words = payload.get("words")
        audio_events: tuple[AudioEvent, ...] = ()
        if isinstance(words, list):
            event_items = [item for item in words
                           if isinstance(item, dict) and item.get("type") == "audio_event"]
            if event_items:
                if (isinstance(source_duration, bool)
                        or not isinstance(source_duration, (int, float))
                        or not math.isfinite(source_duration) or source_duration <= 0):
                    raise TranscriptionError("Cannot verify ElevenLabs audio event source duration.")
                try:
                    audio_events = tuple(
                        AudioEvent(start=item.get("start"), end=item.get("end"), text=item.get("text"))
                        for item in event_items
                    )
                    validate_audio_events(audio_events, source_duration)
                except (ValueError, TypeError, OverflowError) as error:
                    raise TranscriptionError("Invalid ElevenLabs audio event metadata.") from error
                # Event order and overlap are independent of spoken words.
                # Never let an event update a word's previous timestamp, cue
                # boundary, speaker, or text. Unknown types remain speech.
                words = [item for item in words
                         if not (isinstance(item, dict) and item.get("type") == "audio_event")]
        if isinstance(words, list) and words:
            word_error: TranscriptionError | None = None
            try:
                segments = self._segments_from_words(words, strict_words=bool(audio_events))
            except TranscriptionError as error:
                # A provider response can contain a malformed ``words`` array
                # and a usable segment-level fallback. Keep the fallback
                # available, but only accept it after the same timestamp and
                # ordering checks used for a normal segment response.
                segments = []
                word_error = error
            if not segments and not audio_events and isinstance(raw_segments, list) and raw_segments:
                try:
                    segments = self._segments_from_items(raw_segments)
                except TranscriptionError:
                    if word_error is not None:
                        raise word_error
                    raise
                if segments:
                    LOGGER.warning(
                        "ElevenLabs word timestamps were unusable; using validated segment timestamps"
                    )
            if not segments and word_error is not None:
                raise word_error
        elif audio_events:
            # Typed sound-only output is retained for review, but must never
            # be passed off as a usable spoken lecture by the quality gate.
            segments = []
        elif isinstance(raw_segments, list) and raw_segments:
            segments = self._segments_from_items(raw_segments)
        else:
            raise TranscriptionError("ElevenLabs response has no timestamped words.")
        if not segments and not audio_events:
            raise TranscriptionError("ElevenLabs returned an empty transcript with no speech.")
        # Scribe currently returns ``audio_duration_secs``.  Accept the
        # shorter ``duration`` spelling too for fixtures and compatible API
        # revisions, while retaining the last word as a safe lower bound.
        declared_duration = payload.get("audio_duration_secs")
        if audio_events:
            duration = source_duration
        else:
            if declared_duration is None:
                declared_duration = payload.get("duration")
            if declared_duration is None:
                duration = max(segment.end for segment in segments)
            else:
                duration = self._finite_timestamp(declared_duration, "duration")
                duration = max(duration, max(segment.end for segment in segments))
        if duration <= 0:
            raise TranscriptionError("Source duration must be greater than zero.")
        transcript = Transcript(
            duration=duration, segments=tuple(segments), language=language, audio_events=audio_events,
        )
        if audio_events:
            try:
                validate_transcript(transcript)
            except ValueError as error:
                raise TranscriptionError("Invalid ElevenLabs event-aware transcript.") from error
        return transcript

    @staticmethod
    def _source_audio_duration(audio: Path) -> float:
        """Read duration from the accepted source container, never event spans."""
        try:
            av = importlib.import_module("av")
            with av.open(str(audio)) as container:
                value = container.duration
                if isinstance(value, bool) or not isinstance(value, (int, float)):
                    raise ValueError("missing duration")
                duration = value / av.time_base
            if not math.isfinite(duration) or duration <= 0:
                raise ValueError("invalid duration")
            return duration
        except Exception as error:
            raise TranscriptionError("Cannot verify ElevenLabs audio event source duration.") from error

    def _segments_from_items(self, items: list[Any]) -> list[Segment]:
        result = []
        previous_start = 0.0
        for item in items:
            if not isinstance(item, dict):
                raise TranscriptionError("ElevenLabs returned an invalid transcript segment.")
            start = self._finite_timestamp(item.get("start"), "segment timestamp")
            end = self._finite_timestamp(item.get("end"), "segment timestamp")
            if end < start or start < previous_start:
                raise TranscriptionError("ElevenLabs returned unordered segment timestamps.")
            # Keep a broad provider segment intact when no usable word
            # timestamps exist.  The quality gate will mark it as unsafe for
            # citation, allowing an explicitly enabled local fallback to
            # recover with the model's real segment timestamps.  Truncating or
            # splitting this interval would invent timing.
            text = item.get("text")
            if not isinstance(text, str):
                raise TranscriptionError("ElevenLabs returned invalid segment text.")
            text = text.strip()
            if text and end > start:
                result.append(Segment(start=start, end=end, text=text, speaker=self._speaker(item)))
            previous_start = start
        return result

    def _segments_from_words(self, words: list[Any], *, strict_words: bool = False) -> list[Segment]:
        result: list[Segment] = []
        current_speaker: str | None = None
        current_start = current_end = 0.0
        current_tokens: list[str] = []
        previous_start = 0.0
        malformed_timestamp_count = 0

        def flush() -> None:
            nonlocal current_tokens, current_speaker, current_start, current_end
            if current_tokens:
                text = self._join_tokens(current_tokens).strip()
                # Zero-duration cues are not useful in Markdown or SRT and
                # are rejected by several subtitle consumers.  Spacing and
                # punctuation tokens may legitimately have equal timestamps,
                # so only emit a cue when it contains positive-duration text.
                if text and current_end > current_start:
                    result.append(Segment(current_start, current_end, text, current_speaker))
            current_tokens = []
            current_speaker = None
            current_start = current_end = 0.0

        for item in words:
            if not isinstance(item, dict):
                raise TranscriptionError("ElevenLabs returned an invalid word item.")
            text = item.get("text")
            if not isinstance(text, str):
                raise TranscriptionError("ElevenLabs returned invalid word text.")
            if not text:
                continue
            # Spacing tokens do not carry useful speaker changes.  Preserve
            # them in the current segment but skip them before the first word.
            is_spacing = item.get("type") == "spacing" or text.isspace()
            # Scribe may omit timestamps for formatting-only spacing tokens.
            # They cannot define a speech interval, so preserve the token only
            # when it has usable timing and otherwise skip it safely.
            if is_spacing and (item.get("start") is None or item.get("end") is None):
                continue
            # Scribe occasionally emits one malformed or out-of-order word in
            # an otherwise useful response.  Drop that token and continue with
            # the last trusted timestamp so a provider glitch cannot strand an
            # entire lecture in the retry loop.  A response with no usable
            # speech still fails below and remains retryable.
            try:
                start = self._finite_timestamp(item.get("start"), "word timestamp")
                end = self._finite_timestamp(item.get("end"), "word timestamp")
            except TranscriptionError:
                if strict_words:
                    raise TranscriptionError("Invalid ElevenLabs spoken word timestamp.") from None
                malformed_timestamp_count += 1
                continue
            if end < start or start < previous_start:
                if strict_words:
                    raise TranscriptionError("Invalid ElevenLabs spoken word timestamp.")
                malformed_timestamp_count += 1
                continue
            speaker = self._speaker(item)
            stripped_text = text.strip()
            is_punctuation = item.get("type") == "punctuation" or (
                bool(stripped_text)
                and all(not character.isalnum() and not character.isspace()
                        for character in stripped_text)
            )
            is_zero_duration_punctuation = (
                end == start and not is_spacing and is_punctuation
            )
            # A spacing token can represent a long pause. It is not speech,
            # so it must split the current cue rather than invalidate the
            # entire recording as an overlong word.
            if is_spacing:
                if current_tokens and end - current_end >= self.PAUSE_SPLIT_SECONDS:
                    flush()
                if current_tokens:
                    current_tokens.append(text)
                previous_start = max(previous_start, end)
                continue
            if end == start and not is_spacing and not is_zero_duration_punctuation:
                if strict_words:
                    raise TranscriptionError("Invalid ElevenLabs spoken word timestamp.")
                # Providers occasionally emit a zero-duration marker for
                # noise or punctuation.  It cannot form a useful cue and
                # must not extend the surrounding speech interval.
                previous_start = start
                continue
            # Keep an overlong provider word interval unchanged.  The quality
            # gate will mark the resulting cue as citation-unsafe and an
            # explicitly enabled local fallback may recover it.  Capping the
            # interval would alter the provider's timestamp.
            if current_tokens and not is_spacing and (
                speaker != current_speaker
                or start - current_end >= self.PAUSE_SPLIT_SECONDS
                or start - current_start >= self.MAX_SEGMENT_SECONDS
                or end - current_start > self.MAX_SEGMENT_SECONDS
            ):
                flush()
            if not current_tokens:
                current_speaker = speaker
                current_start = start
            # A spacing token can span a pause. Keep the cue's end anchored to
            # speech so the next word is split using the real pause length and
            # the rendered cue does not claim silence as spoken content.
            if not is_spacing:
                current_end = max(current_end, end)
            current_tokens.append(text)
            previous_start = start
            # Sentence punctuation is a reliable boundary for agent-facing
            # notes.  Flush after adding the token so punctuation remains in
            # the preceding cue.  A later word starts a fresh cue.
            if not is_spacing and text.rstrip().endswith((".", "?", "!")):
                flush()
        flush()
        if malformed_timestamp_count:
            LOGGER.warning(
                "ElevenLabs response omitted %d malformed or unordered word timestamp(s)",
                malformed_timestamp_count,
            )
        return result

    @staticmethod
    def _speaker(item: dict[str, Any]) -> str | None:
        value = item.get("speaker_id", item.get("speaker"))
        if value is None:
            return None
        if not isinstance(value, str) or not value.strip():
            raise TranscriptionError("ElevenLabs returned an invalid speaker identifier.")
        return value.strip()

    @staticmethod
    def _join_tokens(tokens: list[str]) -> str:
        result = ""
        punctuation = set(",.!?;:%)]}\u2019'\"")
        for token in tokens:
            if not result or token.isspace() or result.endswith((" ", "\n")):
                if token in {"'", "\u2019"} and result.endswith((" ", "\n")):
                    result = result.rstrip(" \n") + token
                else:
                    result += token
            elif token in punctuation or result.endswith(("(", "[", "{", "\"", "'")):
                result += token
            else:
                result += " " + token
        return result

    @staticmethod
    def _finite_timestamp(value: Any, label: str) -> float:
        try:
            number = float(value)
        except (TypeError, ValueError, OverflowError) as error:
            raise TranscriptionError(f"Invalid ElevenLabs {label}.") from error
        if isinstance(value, bool) or not math.isfinite(number) or number < 0:
            raise TranscriptionError(f"Invalid ElevenLabs {label}.")
        return number


class RclonePublisher:
    """Copy transcripts to explicit course folders or course paths under one root.

    Verification reads structured remote metadata and compares the downloaded
    content's SHA-256. A successful upload alone is never publication success.
    rclone's account credentials remain in its server-side configuration.
    """

    _TRANSCRIPT_SUFFIXES = frozenset({".md", ".txt", ".srt", ".vtt"})

    def __init__(
        self,
        remote: str,
        folder_ids: Mapping[str, str] | None = None,
        executable: str = "rclone",
        *,
        root_folder_id: str | None = None,
        timeout: float = 300.0,
        runner: Callable[..., subprocess.CompletedProcess[bytes]] | None = None,
    ) -> None:
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*:?", remote):
            raise ValueError("remote must name a configured rclone remote without a path")
        if not executable or not math.isfinite(timeout) or timeout <= 0:
            raise ValueError("rclone requires an executable and a finite positive timeout")
        if (folder_ids is None) == (root_folder_id is None):
            raise ValueError("Choose exactly one Drive destination: course folder IDs or a root folder ID")
        if root_folder_id is not None and (
            not isinstance(root_folder_id, str)
            or not re.fullmatch(r"[A-Za-z0-9_-]+", root_folder_id)
        ):
            raise ValueError("The root Drive folder ID must be a nonempty Google Drive folder ID")
        mapping = {}
        for course, folder_id in (folder_ids or {}).items():
            if not course or not re.fullmatch(r"[A-Za-z0-9_-]+", folder_id):
                raise ValueError("Each course requires an explicit Google Drive folder ID")
            key = course.casefold()
            if key in mapping:
                raise ValueError("Ambiguous case-insensitive course folder mapping")
            mapping[key] = folder_id
        self.remote = remote.rstrip(":")
        self.folder_ids = mapping
        self.root_folder_id = root_folder_id
        self.executable = executable
        self.timeout = timeout
        self._runner = runner or subprocess.run

    def publish(self, course: str, artifacts: Sequence[Path]) -> None:
        """Upload and verify all supplied artifacts, or raise for durable retry.

        A partial failure leaves any verified remote artifacts intact. Retrying
        these explicit copyto operations replaces the same names safely; it never
        synchronizes a directory or deletes files from Drive.
        """
        if self.root_folder_id is not None:
            # Match the recorder/manifest policy, including spaces in Drive
            # folder names such as ``PHIL 102``. Preserve exact spelling while
            # rejecting path separators, controls, and remote-name syntax.
            if not is_safe_course_component(course):
                raise PublicationError("Invalid course name for a Drive course subdirectory.")
            folder_id = self.root_folder_id
            prefix = f"{course}/"
        else:
            try:
                folder_id = self.folder_ids[course.casefold()]
            except KeyError:
                raise PublicationError("No Drive destination is configured for this course.") from None
            prefix = ""
        if not artifacts:
            raise PublicationError("At least one transcript artifact is required.")

        prepared = []
        names = set()
        for supplied_path in artifacts:
            path = Path(supplied_path)
            if path.suffix.lower() not in self._TRANSCRIPT_SUFFIXES:
                raise PublicationError("Only .md/.txt/.srt/.vtt transcript artifacts may be uploaded.")
            if path.is_symlink() or not path.is_file():
                raise PublicationError("Each transcript artifact must be a regular, independent file.")
            if path.name in names:
                raise PublicationError("Transcript artifact names must be unique.")
            names.add(path.name)
            try:
                digest, size = self._fingerprint(path)
            except OSError:
                raise PublicationError("Cannot read a local transcript artifact.") from None
            prepared.append((path.resolve(), digest, size))

        for path, expected_digest, expected_size in prepared:
            destination = f"{self.remote}:{prefix}{path.name}"
            # Corrected transcripts can retain a previous size and modification
            # time. The worker already decides whether publication is needed;
            # do not let rclone's metadata shortcut skip these explicit uploads.
            self._run("copyto", [str(path), destination, "--ignore-times"], folder_id)
            metadata = self._run("lsjson", [destination, "--stat"], folder_id)
            try:
                item = json.loads(metadata)
            except (ValueError, UnicodeError):
                raise PublicationError("rclone returned invalid JSON remote metadata.") from None
            if (
                not isinstance(item, dict)
                or type(item.get("Size")) is not int
                or item.get("IsDir") is not False
                or item["Size"] != expected_size
            ):
                raise PublicationError("Uploaded transcript remote size/metadata does not match.")
            remote_content = self._run("cat", [destination], folder_id)
            if (
                len(remote_content) != expected_size
                or hashlib.sha256(remote_content).hexdigest() != expected_digest
            ):
                raise PublicationError("Uploaded transcript content checksum does not match.")
            try:
                actual_digest, actual_size = self._fingerprint(path)
            except OSError:
                raise PublicationError("Cannot recheck the local transcript artifact.") from None
            if (actual_digest, actual_size) != (expected_digest, expected_size):
                raise PublicationError("Local transcript changed during publication; retry.")

    def _run(self, action: str, arguments: list[str], folder_id: str) -> bytes:
        command = [
            self.executable,
            action,
            *arguments,
            "--drive-root-folder-id",
            folder_id,
            "--contimeout",
            "15s",
            "--timeout",
            "120s",
            "--retries",
            "1",
        ]
        try:
            result = self._runner(
                command,
                capture_output=True,
                shell=False,
                check=False,
                timeout=self.timeout,
            )
        except subprocess.TimeoutExpired:
            raise PublicationError(f"rclone {action} exceeded its command timeout.") from None
        except OSError:
            raise PublicationError(
                "Cannot execute rclone; verify its server-side executable and service PATH."
            ) from None
        if result.returncode != 0:
            # stderr can contain account details and tokens. Persist only this
            # safe summary; administrators can inspect rclone on the worker host.
            raise PublicationError(
                f"rclone {action} failed with exit status {result.returncode}; "
                "check the server's Drive authorization and network connection."
            )
        return result.stdout

    @staticmethod
    def _fingerprint(path: Path) -> tuple[str, int]:
        digest = hashlib.sha256()
        size = 0
        with path.open("rb") as source:
            while block := source.read(1024 * 1024):
                digest.update(block)
                size += len(block)
        return digest.hexdigest(), size
