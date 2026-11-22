"""Read-only checks for the transcript contract consumed by Drive agents.

The LCP worker deliberately stops at Google Drive publication.  This module
checks every accepted recording and the local publication set that a Drive-connected agent would receive;
it does not call Google, Grok, Hermes, OpenClaw, or mutate worker state.  A
passing report therefore proves that the local Markdown/TXT/SRT bundle is
internally consistent and tied to the published current accepted job, but it cannot prove that an
external bot has polled or indexed the files.
"""

from __future__ import annotations

import hashlib
import json
import math
import re
from dataclasses import asdict, dataclass, replace
from pathlib import Path
from typing import Any

from .filesystem import read_json
from .manifest import manifest_from_data
from .quality import assess_transcript
from .rendering import render_artifacts, transcript_from_dict


_SHA256 = re.compile(r"[0-9a-fA-F]{64}\Z")
_TXT_TIMESTAMP = re.compile(r"\A\[(?P<minutes>\d+):(?P<seconds>[0-5]\d)\]\s*(?P<text>.*)\Z")
_MARKDOWN_TIMESTAMP = re.compile(
    r"\A\*\*\[(?P<minutes>\d+):(?P<seconds>[0-5]\d)\]\*\*\s+(?P<text>.*)\Z"
)
_MARKDOWN_SPEAKER = re.compile(r"\A\*\*(?P<speaker>[^*\r\n]+):\*\*\s+(?P<text>.*)\Z")
_SRT_TIMESTAMP = re.compile(
    r"\A(?P<hours>\d+):(?P<minutes>[0-5]\d):(?P<seconds>[0-5]\d),(?P<millis>\d{3})"
    r"\s+-->\s+"
    r"(?P<end_hours>\d+):(?P<end_minutes>[0-5]\d):(?P<end_seconds>[0-5]\d),(?P<end_millis>\d{3})\Z"
)
_SOURCE = re.compile(r"\A.+\.m4a\Z")
_RELEVANCE = {"likely_lecture", "needs_review", "likely_accidental"}
_ANONYMOUS_SPEAKER = re.compile(r"\Aspeaker_[A-Za-z0-9_.-]+\Z")


@dataclass(frozen=True)
class GrokContractRecord:
    """Result for one local course/stem publication bundle."""

    course: str
    stem: str
    source_filename: str | None
    status: str
    errors: tuple[str, ...]
    artifact_hashes: dict[str, str]
    job_ids: tuple[str, ...]
    published: bool | None
    grok_ingested: bool | None
    state_artifacts_match: bool | None
    professor_speaker: str | None = None
    background_noise: str | None = None
    relevance: str | None = None
    cached_transcript_matches: bool | None = None
    current_quality: dict[str, Any] | None = None

    @property
    def passed(self) -> bool:
        return self.status == "pass"

    def to_dict(self) -> dict[str, Any]:
        return {
            "course": self.course,
            "stem": self.stem,
            "source_filename": self.source_filename,
            "status": self.status,
            "passed": self.passed,
            "errors": list(self.errors),
            "artifact_hashes": dict(self.artifact_hashes),
            "job_ids": list(self.job_ids),
            "published": self.published,
            "grok_ingested": self.grok_ingested,
            "state_artifacts_match": self.state_artifacts_match,
            "professor_speaker": self.professor_speaker,
            "background_noise": self.background_noise,
            "relevance": self.relevance,
            "cached_transcript_matches": self.cached_transcript_matches,
            "current_quality": dict(self.current_quality) if self.current_quality is not None else None,
        }


@dataclass(frozen=True)
class _CurrentStateCheck:
    """Metadata-only evidence for the exact accepted cached transcript."""

    job_ids: tuple[str, ...] = ()
    published: bool | None = None
    grok_ingested: bool | None = None
    artifacts_match: bool | None = None
    errors: tuple[str, ...] = ()
    cached_transcript_matches: bool | None = None
    current_quality: dict[str, Any] | None = None


@dataclass(frozen=True)
class GrokContractError:
    """A selected publication set that could not be audited."""

    target: str
    message: str

    def to_dict(self) -> dict[str, str]:
        return {"target": self.target, "error": self.message}


@dataclass(frozen=True)
class GrokContractResult:
    """Read-only audit output suitable for operators and CI."""

    root: Path
    reports: tuple[GrokContractRecord, ...]
    errors: tuple[GrokContractError, ...]
    filename: str | None = None
    job_id: str | None = None

    @property
    def failed_count(self) -> int:
        return sum(not report.passed for report in self.reports)

    @property
    def external_ingestion_verified(self) -> bool:
        """Always false: no external bot acknowledgement is accepted here."""

        return False

    def to_dict(self) -> dict[str, Any]:
        return {
            "root": str(self.root),
            "selection": {"filename": self.filename, "job_id": self.job_id},
            "count": len(self.reports),
            "failed_count": self.failed_count,
            "external_ingestion_verified": self.external_ingestion_verified,
            "reports": [report.to_dict() for report in self.reports],
            "errors": [error.to_dict() for error in self.errors],
        }


def _normalise_text(value: str) -> str:
    return re.sub(r"\s+", " ", value.strip())


def _split_blocks(value: str) -> list[list[str]]:
    return [block.splitlines() for block in re.split(r"\n\s*\n", value.strip()) if block.strip()]


def _parse_audio_events(value: str, artifact: str) -> list[dict[str, Any]]:
    """Read explicit event metadata without interpreting or exposing labels."""
    message = f"{artifact} audio-event metadata is malformed"

    def unique_object(pairs: list[tuple[str, Any]]) -> dict[str, Any]:
        result: dict[str, Any] = {}
        for key, item in pairs:
            if key in result:
                raise ValueError(message)
            result[key] = item
        return result

    try:
        events = json.loads(value, object_pairs_hook=unique_object)
        if not isinstance(events, list):
            raise ValueError(message)
        for event in events:
            if (not isinstance(event, dict)
                    or set(event) != {"start", "end", "text", "type"}
                    or event["type"] != "audio_event"
                    or not isinstance(event["text"], str) or not event["text"].strip()):
                raise ValueError(message)
            start, end = event["start"], event["end"]
            if (type(start) not in {int, float} or type(end) not in {int, float}
                    or not math.isfinite(start) or not math.isfinite(end)
                    or start < 0 or end <= start):
                raise ValueError(message)
    except (TypeError, ValueError, OverflowError):
        # JSON errors can quote private event labels or invalid values.
        raise ValueError(message) from None
    return events


def _markdown_audio_events(value: str) -> list[dict[str, Any]] | None:
    header = value.partition("\n## Transcript\n")[0]
    prefix = "- **Audio events JSON:**"
    lines = [line for line in header.splitlines() if line.startswith(prefix)]
    if not lines:
        return None
    if len(lines) != 1 or not lines[0].startswith(prefix + " "):
        raise ValueError("Markdown audio-event metadata is malformed")
    return _parse_audio_events(lines[0][len(prefix) + 1:], "Markdown")


def _parse_txt_header(value: str) -> tuple[dict[str, str], str]:
    header, separator, body = value.partition("\n\n")
    if not separator:
        raise ValueError("TXT artifact has no metadata/body separator")
    metadata: dict[str, str] = {}
    for line in header.splitlines():
        key, delimiter, item = line.partition(": ")
        if not delimiter or not key or key in metadata:
            raise ValueError("TXT metadata header is malformed")
        metadata[key] = item
    return metadata, body


def _parse_txt(value: str) -> tuple[dict[str, str], list[tuple[int, str]]]:
    metadata, body = _parse_txt_header(value)
    cues: list[tuple[int, str]] = []
    for block in _split_blocks(body):
        if not block:
            continue
        match = _TXT_TIMESTAMP.fullmatch(block[0])
        if match is None or not match.group("text").strip():
            raise ValueError("TXT transcript cue is malformed")
        start = int(match.group("minutes")) * 60 + int(match.group("seconds"))
        text = "\n".join([match.group("text"), *block[1:]]).strip()
        if not text:
            raise ValueError("TXT transcript cue has no text")
        cues.append((start, _normalise_text(text)))
    if not cues:
        raise ValueError("TXT artifact contains no timestamped cues")
    return metadata, cues


def _parse_srt(value: str) -> list[tuple[int, str]]:
    cues: list[tuple[int, str]] = []
    previous_end = -1
    for block in _split_blocks(value):
        if len(block) < 3 or not block[0].strip().isdigit():
            raise ValueError("SRT cue number is malformed")
        match = _SRT_TIMESTAMP.fullmatch(block[1].strip())
        if match is None:
            raise ValueError("SRT cue timing is malformed")

        def millis(prefix: str = "") -> int:
            return (
                int(match.group(prefix + "hours")) * 3_600_000
                + int(match.group(prefix + "minutes")) * 60_000
                + int(match.group(prefix + "seconds")) * 1_000
                + int(match.group(prefix + "millis"))
            )

        start, end = millis(), millis("end_")
        if end <= start or start < previous_end:
            raise ValueError("SRT cue timing overlaps or is not strictly ordered")
        text = "\n".join(block[2:]).strip()
        if not text:
            raise ValueError("SRT cue has no text")
        cues.append((start // 1_000, _normalise_text(text)))
        previous_end = end
    if not cues:
        raise ValueError("SRT artifact contains no cues")
    return cues


def _parse_markdown(value: str, stem: str, course: str) -> list[tuple[int, str]]:
    """Parse the agent-facing Markdown transcript cues.

    Markdown is the primary artifact an agent reads, so checking only that it
    contains *some* timestamp is insufficient: a stale or partially-written
    Markdown file could otherwise disagree with the TXT/SRT artifacts while
    the local contract still passes.  The renderer emits one cue block per
    segment, with optional anonymous speaker labels rendered in bold.  Keep
    this parser deliberately narrow and canonicalize those labels to the TXT
    representation (``[speaker_0]``) before comparing cue text.
    """
    lines = value.splitlines()
    if not lines or lines[0] != f"# Lecture Notes: {stem}":
        raise ValueError("Markdown heading does not match the transcript stem")
    if f"- **Course:** {course}" not in lines:
        raise ValueError("Markdown course metadata does not match the Drive folder")
    # Keep the agent-facing artifact explicit even when a consumer never
    # opens the TXT metadata.  Professor identity remains unknown until a
    # user supplies a calibration mapping; noise and relevance are separate
    # controls so marked noise is not mistaken for lecture content.
    required_metadata = (
        "- **Professor speaker:**",
        "- **Background noise:**",
        "- **Relevance:**",
        "- **Grok ingestion:**",
    )
    for prefix in required_metadata:
        if not any(line.startswith(prefix) for line in lines):
            label = prefix.removeprefix("- **").removesuffix("**:")
            raise ValueError(f"Markdown metadata is missing: {label}")
    try:
        transcript_index = lines.index("## Transcript")
    except ValueError as error:
        raise ValueError("Markdown transcript section is missing") from error

    cues: list[tuple[int, str]] = []
    current_start: int | None = None
    current_text: list[str] = []

    def flush() -> None:
        if current_start is None:
            return
        text = _normalise_text(" ".join(current_text))
        if not text:
            raise ValueError("Markdown transcript cue has no text")
        cues.append((current_start, text))

    for line in lines[transcript_index + 1:]:
        match = _MARKDOWN_TIMESTAMP.fullmatch(line.strip())
        if match is not None:
            flush()
            current_start = int(match.group("minutes")) * 60 + int(match.group("seconds"))
            cue_text = match.group("text").strip()
            speaker = _MARKDOWN_SPEAKER.fullmatch(cue_text)
            if speaker is not None:
                cue_text = f"[{speaker.group('speaker').strip()}] {speaker.group('text').strip()}"
            current_text = [cue_text]
        elif current_start is not None and line.strip():
            # Segment text is normally one line, but preserving wrapped text
            # keeps the audit correct if a provider returns embedded newlines.
            current_text.append(line.strip())
    flush()
    if not cues:
        raise ValueError("Markdown artifact contains no timestamped cues")
    for previous, current in zip(cues, cues[1:]):
        if current[0] < previous[0]:
            raise ValueError("Markdown cue timestamps are not ordered")
    return cues


def _parse_source(filename: str) -> Any:
    if Path(filename).name != filename or not _SOURCE.fullmatch(filename):
        raise ValueError("TXT Source metadata must be a recording basename ending in .m4a")
    return manifest_from_data({
        "version": 1,
        "filename": filename,
        "size_bytes": 1,
        "sha256": "0" * 64,
    })


def _state_matches(
    root: Path,
    filename: str,
    source_sha256: str | None,
    names: dict[str, str],
    heads: dict[str, Any],
    audio_event_metadata: dict[str, list[dict[str, Any]] | None],
) -> _CurrentStateCheck:
    """Bind a bundle to the current accepted head, never a historical job.

    The vault's canonical filenames can still contain an older good bundle
    while a replacement recording is processing. Scanning jobs for *any*
    matching source or artifact hash would let that old publication satisfy a
    new accepted head. Only the exact head/state identity is authoritative.
    """
    errors: list[str] = []
    head = heads.get(filename)
    if not isinstance(head, dict):
        return _CurrentStateCheck(errors=("current accepted recording head was not found or is invalid",))
    job_id = head.get("job_id")
    if not isinstance(job_id, str) or re.fullmatch(r"[0-9a-f]{64}", job_id) is None:
        return _CurrentStateCheck(errors=("current accepted recording head has an invalid job id",))
    job_ids = (job_id,)
    identity = head.get("identity")
    try:
        manifest = manifest_from_data(head.get("manifest"))
        if (not isinstance(identity, dict) or manifest.filename != filename
                or identity.get("filename") != filename
                or identity.get("sha256") != manifest.sha256
                or identity.get("size_bytes") != manifest.size_bytes
                or not isinstance(identity.get("settings"), dict)):
            raise ValueError("identity does not match the accepted manifest")
    except (TypeError, ValueError):
        return _CurrentStateCheck(job_ids=job_ids, errors=("current accepted recording head has an invalid identity or manifest",))
    if source_sha256 is None or source_sha256.lower() != manifest.sha256:
        errors.append("TXT Source-SHA256 does not match the current accepted recording")

    jobs = root / "state" / "jobs"
    path = jobs / f"{job_id}.json"
    if jobs.is_symlink() or path.is_symlink() or not path.is_file():
        return _CurrentStateCheck(job_ids=job_ids, errors=(*errors, "current accepted durable job state was not found"))
    try:
        state = read_json(path)
        if not isinstance(state, dict) or state.get("identity") != identity:
            raise ValueError("identity mismatch")
    except (OSError, ValueError, json.JSONDecodeError):
        return _CurrentStateCheck(job_ids=job_ids, errors=(*errors, "current accepted durable job state is invalid or does not match its head"))

    published = state.get("published") is True
    grok_ingested = state.get("grok_ingested") is True
    artifacts = state.get("artifacts")
    artifact_match = (
        len(names) == 3 and isinstance(artifacts, dict)
        and all(artifacts.get(name) == digest for name, digest in names.items())
    )
    if not artifact_match:
        errors.append("current durable job artifact hashes do not match local publication files")
    if not published:
        errors.append("durable job has not been published to Drive")
    if state.get("stage") != "published":
        errors.append("current accepted durable job has not completed publication")
    if state.get("publication_blocked") is True:
        errors.append("current accepted durable job publication is blocked")
    if state.get("last_error") is not None:
        errors.append("current accepted durable job has an unresolved processing error")

    # Stored quality/published flags may predate a strengthened gate. Reassess
    # the actual accepted transcript rather than trusting those historical
    # summaries, and bind it to the exact artifact bytes rendered today.
    cached_transcript_matches: bool | None = None
    current_quality: dict[str, Any] | None = None
    try:
        transcript_data = state.get("transcript")
        if not isinstance(transcript_data, dict):
            raise ValueError("missing transcript")
        transcript = transcript_from_dict(transcript_data)
        expected_events = [asdict(event) for event in transcript.audio_events]
        declared_events = [events for events in audio_event_metadata.values() if events is not None]
        if expected_events and any(events is None for events in audio_event_metadata.values()):
            errors.append("audio-event metadata is missing from publication artifacts")
        if any(event["end"] > transcript.duration for events in declared_events for event in events):
            errors.append("published audio-event timing exceeds current cached transcript duration")
        if any(events != expected_events for events in declared_events):
            errors.append("published audio-event metadata does not match current cached transcript")
        quality = assess_transcript(transcript)
        current_quality = {
            "status": quality.status,
            "publication_allowed": quality.publication_allowed,
            "relevance": quality.relevance_status,
            "warning_codes": [warning.code for warning in quality.warnings],
        }
        if not quality.publication_allowed:
            codes = sorted({warning.code for warning in quality.warnings if warning.blocking})
            errors.append(
                "current cached transcript fails current quality/relevance gates "
                f"(codes: {','.join(codes) or 'none'}; relevance: {quality.relevance_status})"
            )
    except (KeyError, TypeError, ValueError, AttributeError, OverflowError):
        # Provider/state errors can contain private words. Never include their
        # exception text or any cached transcript content in an audit report.
        errors.append("current accepted cached transcript is missing or invalid")
    else:
        try:
            calibration = state.get("speaker_calibration", {})
            if not isinstance(calibration, dict):
                raise ValueError("invalid calibration")
            expected_artifacts = render_artifacts(
                manifest, transcript, quality,
                professor_speaker=calibration.get("professor"),
            )
            expected_hashes = {
                name: hashlib.sha256(content).hexdigest()
                for name, content in expected_artifacts.items()
            }
            cached_transcript_matches = names == expected_hashes
            if not cached_transcript_matches:
                errors.append("current cached transcript does not match rendered publication artifacts")
        except (KeyError, TypeError, ValueError, AttributeError, OverflowError):
            cached_transcript_matches = False
            errors.append("current accepted cached transcript cannot render with its stored calibration")
    return _CurrentStateCheck(
        job_ids=job_ids, published=published, grok_ingested=grok_ingested,
        artifacts_match=artifact_match, errors=tuple(errors),
        cached_transcript_matches=cached_transcript_matches,
        current_quality=current_quality,
    )


def _audit_bundle(
    root: Path, course: str, stem: str, paths: dict[str, Path], heads: dict[str, Any]
) -> GrokContractRecord:
    errors: list[str] = []
    hashes: dict[str, str] = {}
    source_filename: str | None = None
    source_sha256: str | None = None
    markdown_cues: list[tuple[int, str]] = []
    txt_cues: list[tuple[int, str]] = []
    txt_duration_seconds: float | None = None
    srt_cues: list[tuple[int, str]] = []
    txt_metadata: dict[str, str] = {}
    audio_event_metadata: dict[str, list[dict[str, Any]] | None] = {".md": None, ".txt": None}
    for suffix, path in paths.items():
        if (path.parent.parent.is_symlink() or path.parent.is_symlink()
                or path.is_symlink() or not path.is_file()):
            errors.append(f"missing or non-regular {suffix} artifact")
            continue
        try:
            content = path.read_bytes()
        except OSError as error:
            errors.append(f"cannot read {suffix} artifact: {error}")
            continue
        if not content:
            errors.append(f"empty {suffix} artifact")
            continue
        hashes[path.name] = hashlib.sha256(content).hexdigest()
        try:
            decoded = content.decode("utf-8")
        except UnicodeDecodeError:
            errors.append(f"{suffix} artifact is not UTF-8")
            continue
        try:
            if suffix == ".txt":
                metadata, _ = _parse_txt_header(decoded)
                txt_metadata = metadata
                if "Audio-Events-JSON" in metadata:
                    audio_event_metadata[".txt"] = _parse_audio_events(metadata["Audio-Events-JSON"], "TXT")
                # A valid event-only header remains present even when the
                # separate speech contract fails for having no spoken cues.
                metadata, txt_cues = _parse_txt(decoded)
                required = {
                    "Course", "Date", "Time", "Lecture", "Source", "Duration",
                    "Language", "Source-SHA256", "Professor-Speaker",
                    "Speaker-Roles", "Background-Noise", "Relevance",
                    "Relevance-Reasons", "Grok-Use",
                }
                missing = sorted(required - metadata.keys())
                if missing:
                    errors.append("TXT metadata missing: " + ", ".join(missing))
                if metadata.get("Course") != course:
                    errors.append("TXT Course does not match the Drive course folder")
                source_filename = metadata.get("Source")
                source_manifest = None
                try:
                    source_manifest = _parse_source(source_filename or "")
                    if source_manifest.course != course or Path(source_manifest.filename).stem != stem:
                        errors.append("TXT Source does not match course/stem")
                except ValueError as error:
                    errors.append(str(error))
                if source_manifest is not None:
                    expected_date = source_manifest.captured_at.strftime("%Y-%m-%d")
                    expected_time = source_manifest.captured_at.strftime("%H:%M")
                    if metadata.get("Date") != expected_date:
                        errors.append("TXT Date does not match the recording filename")
                    if metadata.get("Time") != expected_time:
                        errors.append("TXT Time does not match the recording filename")
                digest = metadata.get("Source-SHA256", "")
                source_sha256 = digest
                if not _SHA256.fullmatch(digest):
                    errors.append("TXT Source-SHA256 is not a 64-character hexadecimal digest")
                for key in ("Date", "Time", "Duration", "Language"):
                    if not metadata.get(key, "").strip():
                        errors.append(f"TXT metadata field is empty: {key}")
                professor_speaker = metadata.get("Professor-Speaker", "").strip()
                if professor_speaker != "unknown" and not _ANONYMOUS_SPEAKER.fullmatch(professor_speaker):
                    errors.append(
                        "TXT Professor-Speaker must be unknown or an explicit anonymous speaker ID"
                    )
                if not metadata.get("Speaker-Roles", "").strip():
                    errors.append("TXT metadata field is empty: Speaker-Roles")
                relevance = metadata.get("Relevance", "").strip()
                if relevance not in _RELEVANCE:
                    errors.append(
                        "TXT Relevance must be one of: " + ", ".join(sorted(_RELEVANCE))
                    )
                elif relevance != "likely_lecture":
                    errors.append(
                        f"TXT Relevance is {relevance}; do not ingest this bundle into Grok"
                    )
                if not metadata.get("Relevance-Reasons", "").strip():
                    errors.append("TXT metadata field is empty: Relevance-Reasons")
                if not metadata.get("Background-Noise", "").strip():
                    errors.append("TXT metadata field is empty: Background-Noise")
                if not metadata.get("Grok-Use", "").strip():
                    errors.append("TXT metadata field is empty: Grok-Use")
                grok_use = metadata.get("Grok-Use", "").strip().lower()
                if relevance == "likely_lecture" and "include" not in grok_use:
                    errors.append("TXT Grok-Use does not permit a likely lecture bundle")
                elif relevance in {"needs_review", "likely_accidental"} and "do not ingest" not in grok_use:
                    errors.append("TXT Grok-Use must exclude a non-lecture relevance bundle")
                if professor_speaker and professor_speaker != "unknown" and txt_cues:
                    professor_marker = f"[{professor_speaker} (Professor)]"
                    if not any(text.startswith(professor_marker) for _, text in txt_cues):
                        errors.append(
                            "TXT Professor-Speaker calibration is not present in any transcript cue"
                        )
                duration_value = metadata.get("Duration", "").strip()
                duration_match = re.fullmatch(r"(?P<minutes>\d+(?:\.\d+)?)\s+minutes", duration_value)
                if duration_match is None:
                    errors.append("TXT Duration must be a positive number of minutes")
                else:
                    txt_duration_seconds = float(duration_match.group("minutes")) * 60.0
                    if not math.isfinite(txt_duration_seconds) or txt_duration_seconds <= 0:
                        errors.append("TXT Duration must be a positive number of minutes")
            elif suffix == ".srt":
                srt_cues = _parse_srt(decoded)
                if txt_cues and len(srt_cues) != len(txt_cues):
                    errors.append("SRT cue count does not match TXT cue count")
                elif txt_cues and [text for _, text in srt_cues] != [text for _, text in txt_cues]:
                    errors.append("SRT cue text does not match TXT cue text")
            else:
                audio_event_metadata[".md"] = _markdown_audio_events(decoded)
                markdown_cues = _parse_markdown(decoded, stem, course)
        except ValueError as error:
            errors.append(f"{suffix} contract error: {error}")

    # Markdown is the primary artifact for a human or agent.  Compare its
    # canonicalized cue text and timestamps with TXT so a stale/partial MD
    # upload cannot pass merely because TXT and SRT agree with one another.
    if markdown_cues and txt_cues:
        if len(markdown_cues) != len(txt_cues):
            errors.append("Markdown cue count does not match TXT cue count")
        elif markdown_cues != txt_cues:
            errors.append("Markdown cue text or timestamps do not match TXT cue text")
    if audio_event_metadata[".md"] != audio_event_metadata[".txt"]:
        errors.append("Markdown and TXT audio-event metadata do not match")
    if srt_cues and txt_duration_seconds is not None:
        last_srt_start = max(start for start, _ in srt_cues)
        # SRT parsing retains only whole-second starts; a small padding keeps
        # the check compatible with the renderer's millisecond cue ends while
        # catching a stale duration header that would mislead citations.
        if last_srt_start > txt_duration_seconds + 1.0:
            errors.append("SRT cue timestamps extend beyond TXT Duration")

    expected_filename = f"{stem}.m4a"
    current_state = _state_matches(
        root, expected_filename, source_sha256, hashes, heads, audio_event_metadata
    )
    errors.extend(current_state.errors)
    # A head with no TXT artifact still needs to identify the recording whose
    # context is missing. Orphan vault files retain a null Source as before.
    if source_filename is None and expected_filename in heads:
        source_filename = expected_filename

    return GrokContractRecord(
        course=course,
        stem=stem,
        source_filename=source_filename,
        status="pass" if not errors else "fail",
        errors=tuple(errors),
        artifact_hashes=hashes,
        job_ids=current_state.job_ids,
        published=current_state.published,
        grok_ingested=current_state.grok_ingested,
        state_artifacts_match=current_state.artifacts_match,
        professor_speaker=txt_metadata.get("Professor-Speaker"),
        background_noise=txt_metadata.get("Background-Noise"),
        relevance=txt_metadata.get("Relevance"),
        cached_transcript_matches=current_state.cached_transcript_matches,
        current_quality=current_state.current_quality,
    )


def audit_grok_contract(
    root: Path,
    *,
    filename: str | None = None,
    job_id: str | None = None,
) -> GrokContractResult:
    """Audit every current accepted recording without writing or networking.

    Accepted heads drive completeness, including jobs that have not produced
    artifacts yet. Vault-only candidates are also checked so orphaned or stale
    publication files cannot disappear from the report.
    """

    if filename is not None and job_id is not None:
        raise ValueError("Select at most one of filename or job id")
    if filename is not None and (not filename or Path(filename).name != filename):
        raise ValueError("Filename must be a nonempty recording basename")
    root = Path(root)
    vault = root / "vault"
    candidates: set[tuple[str, str]] = set()
    errors: list[GrokContractError] = []
    heads: dict[str, Any] = {}
    heads_path = root / "state" / "heads.json"
    if heads_path.is_symlink() or not heads_path.is_file():
        errors.append(GrokContractError(str(heads_path), "accepted recording index was not found or is not regular"))
    else:
        try:
            value = read_json(heads_path)
            if not isinstance(value, dict):
                raise ValueError("expected a JSON object")
            heads = value
        except (OSError, ValueError, json.JSONDecodeError):
            errors.append(GrokContractError(str(heads_path), "accepted recording index is invalid"))
    selected_filename = filename
    selected_job_id = job_id
    if job_id is not None:
        if not re.fullmatch(r"[0-9a-f]{64}", job_id):
            raise ValueError("Job id must be a 64-character lowercase SHA-256")
        state_path = root / "state" / "jobs" / f"{job_id}.json"
        if state_path.is_symlink() or not state_path.is_file():
            return GrokContractResult(root, (), (GrokContractError(job_id, "durable job state was not found"),), None, job_id)
        try:
            state = read_json(state_path)
            selected_filename = state["identity"]["filename"]
            if not isinstance(selected_filename, str):
                raise ValueError("recording filename is invalid")
        except (OSError, ValueError, KeyError, TypeError) as error:
            return GrokContractResult(root, (), (GrokContractError(job_id, f"invalid durable job state: {error}"),), None, job_id)
        head = heads.get(selected_filename)
        if not isinstance(head, dict) or head.get("job_id") != job_id:
            return GrokContractResult(
                root, (), (GrokContractError(job_id, "selected durable job is not the current accepted recording head"),),
                selected_filename, selected_job_id,
            )
    for accepted_filename in sorted(heads):
        if selected_filename is not None and accepted_filename != selected_filename:
            continue
        try:
            manifest = _parse_source(accepted_filename)
        except (TypeError, ValueError):
            errors.append(GrokContractError(accepted_filename, "accepted recording head has an invalid filename"))
            continue
        candidates.add((manifest.course, Path(accepted_filename).stem))
    if vault.is_dir() and not vault.is_symlink():
        for course_dir in sorted(vault.iterdir()):
            if course_dir.is_symlink() or not course_dir.is_dir():
                continue
            # Discover candidates from every suffix as well as accepted heads:
            # orphan files are failures even without a corresponding head.
            stems = {
                path.stem
                for suffix in (".md", ".txt", ".srt")
                for path in course_dir.glob(f"*{suffix}")
                if path.is_file() and not path.is_symlink()
            }
            for stem in sorted(stems):
                source = f"{stem}.m4a"
                if selected_filename is not None and source != selected_filename:
                    continue
                candidates.add((course_dir.name, stem))
    elif not candidates:
        errors.append(GrokContractError(str(vault), "vault directory was not found or is not regular"))
    if selected_filename is not None and not candidates:
        errors.append(GrokContractError(selected_filename, "no accepted recording head or local artifact matched selection"))
    reports = tuple(
        _audit_bundle(root, course, stem, {
            suffix: vault / course / f"{stem}{suffix}" for suffix in (".md", ".txt", ".srt")
        }, heads)
        for course, stem in sorted(candidates)
    )
    # Watch mode may accept a new revision while this read-only audit runs.
    # Never return a pass based on an index snapshot that ceased to be current
    # before the bundle checks finished. Retrying is safe and does not require
    # creating or taking the worker's mutable lock file.
    if not any(error.target == str(heads_path) for error in errors):
        try:
            unchanged = read_json(heads_path) == heads
        except (OSError, ValueError, json.JSONDecodeError):
            unchanged = False
        if not unchanged:
            message = "accepted recording index changed during audit; retry for current completeness"
            errors.append(GrokContractError(str(heads_path), message))
            reports = tuple(replace(report, status="fail", errors=(*report.errors, message)) for report in reports)
    return GrokContractResult(root, reports, tuple(errors), selected_filename, selected_job_id)


def format_human(result: GrokContractResult) -> str:
    selection = "all bundles"
    if result.filename:
        selection = f"filename={result.filename}"
    elif result.job_id:
        selection = f"job_id={result.job_id}"
    lines = [
        f"Grok contract audit ({selection}) root={result.root}",
        f"Bundles: {len(result.reports)}; failed: {result.failed_count}; errors: {len(result.errors)}",
        "External bot ingestion verified: no (this audit is local and read-only)",
    ]
    for report in result.reports:
        state = "published" if report.published else "not-published"
        if report.published is None:
            state = "no-durable-state"
        lines.append(
            f"{report.status.upper()} {report.course}/{report.stem} "
            f"artifacts={len(report.artifact_hashes)}/3 state={state} "
            f"grok_ingested={report.grok_ingested if report.grok_ingested is not None else 'unknown'} "
            f"relevance={report.relevance or 'unknown'} "
            f"professor={report.professor_speaker or 'unknown'}"
        )
        for error in report.errors:
            lines.append(f"  ERROR: {error}")
    for error in result.errors:
        lines.append(f"ERROR {error.target}: {error.message}")
    return "\n".join(lines)

