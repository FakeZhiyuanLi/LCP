"""Durable, single-writer ingestion with independently retryable publication."""

import fcntl
import hashlib
import json
import logging
import os
import re
import shutil
import stat
from contextlib import contextmanager
from dataclasses import asdict, dataclass
from datetime import datetime, timedelta, timezone
from pathlib import Path
from typing import Any, Callable, Iterator, Mapping

from .filesystem import (UnsafePath, archive_verified, atomic_bytes, atomic_json, copy_verified,
                         ensure_directory, fingerprint, read_json)
from .manifest import SUFFIX, RecordingManifest, load_manifest, manifest_from_data
from .models import Publisher, Transcriber, TranscriptionSettings
from .quality import assess_transcript
from .rendering import render_artifacts, transcript_from_dict, transcript_to_dict

LOGGER = logging.getLogger(__name__)


class WorkerBusy(RuntimeError):
    pass


def check_worker_state_format(root: Path) -> None:
    """Older workers cannot honor the admission controls in newer state roots."""
    for marker in ("provider-control.json", "provider-repairs.json", "stt-retry-limits.json"):
        try:
            (root / "state" / marker).lstat()
        except FileNotFoundError:
            continue
        raise ValueError(
            "This root uses provider controls from a newer worker. Use that worker for this root "
            "or choose a fresh directory for this version."
        )


class PendingRecording(RuntimeError):
    """Marker arrived before its matching final audio version."""


@dataclass(frozen=True)
class RunReport:
    processed: int = 0
    skipped: int = 0
    pending: int = 0
    failures: tuple[str, ...] = ()
    quality_blocked: int = 0


@dataclass(frozen=True)
class ReprocessResult:
    """The durable result of an operator-requested archive reprocess."""

    status: str
    filename: str
    selected_job_id: str
    job_id: str
    archive: Path
    backup_path: Path | None = None


@dataclass(frozen=True)
class _ReprocessPlan:
    filename: str
    selected_job_id: str
    job_id: str
    archive: Path
    identity: dict[str, Any]
    manifest: RecordingManifest
    selected_state_path: Path
    selected_state: dict[str, Any]
    target_state_path: Path
    target_state: dict[str, Any] | None
    heads: dict[str, Any]


class Worker:
    # Hosted transcription and Drive publication are both network-bound.  A
    # watch service must not retry a provider outage every reconciliation
    # interval: that can amplify rate limits and burn the user's quota while
    # the lecture remains safely cached locally.  Manual ``once`` runs keep
    # their historical immediate-retry behavior (``respect_retry_after`` is
    # enabled only by the watch CLI).
    RETRY_BASE_SECONDS = 60
    RETRY_MAX_SECONDS = 3600
    # Provider timestamp collapses are recoverable from the verified source
    # audio.  Other quality findings (for example a quiet tail or noise
    # markers) need human review and must never trigger an unattended rewrite.
    AUTO_REPAIR_WARNING_CODES = frozenset({"one_cue_collapse", "cue_over_30s"})

    def __init__(self, root: Path, transcriber: Transcriber, publisher: Publisher | None = None,
                 settings: TranscriptionSettings | None = None, publication_key: str | None = None,
                 quality_override: bool = False, *,
                 professor_speakers: Mapping[str, str] | None = None,
                 respect_retry_after: bool = False,
                 automatic_repair: bool = False,
                 max_automatic_repairs: int = 1,
                 clock: Callable[[], datetime] | None = None):
        self.root = Path(root).absolute()
        check_worker_state_format(self.root)
        self.root.mkdir(parents=True, exist_ok=True)
        ensure_directory(self.root)
        self.transcriber = transcriber
        self.publisher = publisher
        self.settings = settings or TranscriptionSettings()
        self.professor_speakers = self._validate_professor_speakers(professor_speakers or {})
        # A blocked transcript is still retained locally for review.  Operators
        # may deliberately override the gate for a known-good transcript after
        # checking its quality report; the default remains conservative.
        self.quality_override = bool(quality_override)
        self.respect_retry_after = bool(respect_retry_after)
        if type(max_automatic_repairs) is not int or not 0 <= max_automatic_repairs <= 3:
            raise ValueError("max_automatic_repairs must be an integer from 0 through 3")
        self.automatic_repair = bool(automatic_repair)
        self.max_automatic_repairs = max_automatic_repairs
        self._clock = clock or (lambda: datetime.now(timezone.utc))
        self.publication_key = publication_key or (
            f"{type(publisher).__module__}.{type(publisher).__qualname__}" if publisher else None)
        for name in ("inbox", "work", "archive", "state", "vault"):
            ensure_directory(self.root / name)
        self.inbox = self.root / "inbox"
        self.jobs = self.root / "state" / "jobs"
        ensure_directory(self.jobs)
        self.heads_path = self.root / "state" / "heads.json"

    @staticmethod
    def _validate_professor_speakers(mapping: Mapping[str, str]) -> dict[str, str]:
        """Validate explicit recording-to-speaker calibration without inference."""
        if not isinstance(mapping, Mapping):
            raise ValueError("Professor speaker calibration must be a JSON object")
        result: dict[str, str] = {}
        for key, speaker in mapping.items():
            if (not isinstance(key, str) or not key or Path(key).name != key
                    or (not key.endswith(".m4a") and Path(key).suffix)):
                raise ValueError(f"Invalid professor calibration recording key: {key!r}")
            if (not isinstance(speaker, str)
                    or re.fullmatch(r"speaker_[A-Za-z0-9_.-]+", speaker) is None):
                raise ValueError(f"Invalid professor calibration speaker ID for {key!r}")
            result[key] = speaker
        return result

    def _professor_speaker_for(self, manifest: RecordingManifest) -> str | None:
        """Return an explicit mapping for this recording, if configured."""
        return self.professor_speakers.get(manifest.filename) or self.professor_speakers.get(
            Path(manifest.filename).stem
        )

    def _heads(self) -> dict:
        return read_json(self.heads_path) if self.heads_path.exists() else {}

    def _head_job_id(self, filename: str) -> str | None:
        """Return a trusted head id, treating a damaged entry as unaccepted.

        The reconciliation pass reports malformed entries when they cannot be
        repaired from a matching marker.  During marker processing, however, a
        complete verified recording is sufficient to replace that one damaged
        entry safely, so callers must not dereference an arbitrary JSON value.
        """
        heads = self._heads()
        if not isinstance(heads, dict):
            return None
        head = heads.get(filename)
        if not isinstance(head, dict):
            return None
        job_id = head.get("job_id")
        return job_id if isinstance(job_id, str) else None

    @contextmanager
    def lock(self) -> Iterator[None]:
        descriptor = os.open(self.root / "state" / "worker.lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600)
        try:
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError as error:
                raise WorkerBusy("Another LCP worker owns this state directory") from error
            check_worker_state_format(self.root)
            yield
        finally:
            os.close(descriptor)

    def run_once(self) -> RunReport:
        with self.lock():
            return self._reconcile()

    def reprocess_archived(
        self,
        *,
        filename: str | None = None,
        job_id: str | None = None,
        dry_run: bool = False,
        backup_dir: Path | None = None,
    ) -> ReprocessResult:
        """Re-transcribe one verified archive under the current settings.

        The selected recording must be the current accepted head for its
        filename.  This prevents an operator from accidentally publishing a
        superseded correction over a newer recording.  The archive is checked
        by size and SHA-256 and is only read; it is never replaced.  A normal
        operation takes a complete state/artifact/archive backup before any
        durable state or transcript is changed.  ``dry_run`` performs every
        selection and integrity check while holding the worker lock, then
        returns without writing anything.
        """
        if (filename is None) == (job_id is None):
            raise ValueError("Select exactly one archived recording by filename or job id")
        with self.lock():
            plan = self._plan_reprocess(filename=filename, job_id=job_id)
            if dry_run:
                return ReprocessResult(
                    status="dry-run", filename=plan.filename,
                    selected_job_id=plan.selected_job_id, job_id=plan.job_id,
                    archive=plan.archive,
                )

            backup_path = self._backup_reprocess(plan, backup_dir)
            status = self._apply_reprocess(plan)
            return ReprocessResult(
                status=status, filename=plan.filename,
                selected_job_id=plan.selected_job_id, job_id=plan.job_id,
                archive=plan.archive, backup_path=backup_path,
            )

    def _plan_reprocess(self, *, filename: str | None, job_id: str | None) -> _ReprocessPlan:
        """Resolve and validate one current durable job without writing."""
        heads = self._heads()
        selected_state_path, selected_state = self._select_reprocess_state(
            filename=filename, job_id=job_id, heads=heads)
        selected_job_id = selected_state_path.stem
        identity = selected_state.get("identity")
        if not isinstance(identity, dict):
            raise ValueError(f"Invalid durable job identity: {selected_state_path}")
        if hashlib.sha256(json.dumps(identity, sort_keys=True).encode()).hexdigest() != selected_job_id:
            raise ValueError(f"Durable job id does not match its identity: {selected_state_path}")

        manifest_data = {
            "version": 1,
            "filename": identity.get("filename"),
            "size_bytes": identity.get("size_bytes"),
            "sha256": identity.get("sha256"),
        }
        manifest = manifest_from_data(
            manifest_data, marker_name=f"{identity.get('filename')}.ready.json")
        if filename is not None and manifest.filename != filename:
            raise ValueError("Selected filename does not match durable job identity")
        head = heads.get(manifest.filename)
        if not isinstance(head, dict) or head.get("job_id") != selected_job_id:
            raise ValueError(
                "Only the current accepted revision can be reprocessed; "
                "select its current job id or filename"
            )
        if head.get("identity") != identity:
            raise ValueError("Accepted head identity does not match durable job state")

        archive = self.root / "archive" / manifest.course / (
            f"{Path(manifest.filename).stem}--{manifest.sha256}.m4a")
        stored_archive = selected_state.get("archive")
        if stored_archive is not None:
            if not isinstance(stored_archive, str):
                raise ValueError("Durable archive path is invalid")
            try:
                stored_path = (self.root / stored_archive).resolve()
                expected_path = archive.resolve()
            except OSError as error:
                raise ValueError("Durable archive path cannot be resolved") from error
            if stored_path != expected_path:
                raise ValueError("Durable archive path does not match source identity")
        if archive.is_symlink() or not archive.is_file():
            raise ValueError(f"Verified archive is missing or not a regular file: {archive}")
        try:
            if fingerprint(archive) != manifest.expected:
                raise ValueError("Verified archive does not match durable source identity")
        except OSError as error:
            raise ValueError(f"Cannot read verified archive: {archive}") from error

        target_identity, target_job_id = self._identity(manifest)
        target_state_path = self.jobs / f"{target_job_id}.json"
        target_state = None
        if target_state_path.exists() or target_state_path.is_symlink():
            if target_state_path.is_symlink():
                raise UnsafePath(f"Not a regular durable job state: {target_state_path}")
            target_state = read_json(target_state_path)
            if not isinstance(target_state, dict) or target_state.get("identity") != target_identity:
                raise ValueError(f"Invalid durable target job identity: {target_state_path}")
        return _ReprocessPlan(
            filename=manifest.filename,
            selected_job_id=selected_job_id,
            job_id=target_job_id,
            archive=archive,
            identity=target_identity,
            manifest=manifest,
            selected_state_path=selected_state_path,
            selected_state=selected_state,
            target_state_path=target_state_path,
            target_state=target_state,
            heads=heads,
        )

    def _select_reprocess_state(
        self, *, filename: str | None, job_id: str | None, heads: dict[str, Any]
    ) -> tuple[Path, dict[str, Any]]:
        if job_id is not None:
            if not re.fullmatch(r"[0-9a-f]{64}", job_id):
                raise ValueError("Job id must be a 64-character lowercase SHA-256")
            path = self.jobs / f"{job_id}.json"
            if path.is_symlink() or not path.is_file():
                raise ValueError(f"Durable job state was not found: {path}")
            state = read_json(path)
            if not isinstance(state, dict):
                raise ValueError(f"Invalid durable job state: {path}")
            return path, state
        if not isinstance(filename, str) or Path(filename).name != filename or not filename:
            raise ValueError("Filename must be a nonempty recording basename")
        current = heads.get(filename)
        if isinstance(current, dict) and isinstance(current.get("job_id"), str):
            current_id = current["job_id"]
            if re.fullmatch(r"[0-9a-f]{64}", current_id):
                path = self.jobs / f"{current_id}.json"
                if path.is_file() and not path.is_symlink():
                    state = read_json(path)
                    if isinstance(state, dict):
                        return path, state
        matches = []
        for path in sorted(self.jobs.glob("*.json")):
            if path.is_symlink() or not path.is_file():
                continue
            try:
                state = read_json(path)
            except (OSError, ValueError, json.JSONDecodeError):
                continue
            if isinstance(state, dict) and isinstance(state.get("identity"), dict):
                if state["identity"].get("filename") == filename:
                    matches.append((path, state))
        if not matches:
            raise ValueError(f"No durable job state found for filename: {filename}")
        if len(matches) > 1:
            raise ValueError(
                "Filename matches multiple durable jobs; select the current job with --job-id"
            )
        return matches[0]

    def _backup_reprocess(self, plan: _ReprocessPlan, backup_dir: Path | None) -> Path:
        parent = Path(backup_dir) if backup_dir is not None else self.jobs.parent / "reprocess-backups"
        # The default backup directory may not exist on a fresh worker. Create
        # missing parents, then reject a symlink at the requested destination.
        parent.mkdir(parents=True, exist_ok=True)
        ensure_directory(parent)
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
        backup = parent / f"{stamp}-{plan.selected_job_id}"
        suffix = 0
        while True:
            try:
                backup.mkdir()
                break
            except FileExistsError:
                suffix += 1
                backup = parent / f"{stamp}-{plan.selected_job_id}-{suffix}"
        try:
            backup_state_jobs = backup / "state" / "jobs"
            backup_archive_course = backup / "archive" / plan.manifest.course
            backup_vault_course = backup / "vault" / plan.manifest.course
            for directory in (backup_state_jobs, backup_archive_course, backup_vault_course):
                directory.mkdir(parents=True, exist_ok=True)
                ensure_directory(directory)
            copy_verified(
                plan.selected_state_path, backup_state_jobs / plan.selected_state_path.name,
                fingerprint(plan.selected_state_path),
            )
            if plan.target_state_path != plan.selected_state_path and plan.target_state_path.exists():
                copy_verified(
                    plan.target_state_path, backup_state_jobs / plan.target_state_path.name,
                    fingerprint(plan.target_state_path),
                )
            if self.heads_path.exists():
                copy_verified(self.heads_path, backup / "state" / "heads.json", fingerprint(self.heads_path))
            copy_verified(
                plan.archive, backup_archive_course / plan.archive.name,
                plan.manifest.expected,
            )
            artifact_names = {f"{Path(plan.filename).stem}{suffix}" for suffix in (".md", ".txt", ".srt")}
            vault_course = self.root / "vault" / plan.manifest.course
            for name in artifact_names:
                path = vault_course / name
                if path.is_symlink():
                    raise UnsafePath(f"Not a regular transcript artifact: {path}")
                if path.is_file():
                    copy_verified(path, backup_vault_course / name, fingerprint(path))
            atomic_json(backup / "metadata.json", {
                "version": 1,
                "created_at": datetime.now(timezone.utc).isoformat(),
                "selected_job_id": plan.selected_job_id,
                "target_job_id": plan.job_id,
                "filename": plan.filename,
                "archive": str(plan.archive.relative_to(self.root)),
                "archive_size_bytes": plan.manifest.size_bytes,
                "archive_sha256": plan.manifest.sha256,
            })
            return backup
        except BaseException:
            shutil.rmtree(backup, ignore_errors=True)
            raise

    def _apply_reprocess(self, plan: _ReprocessPlan) -> str:
        # Always seed scratch from the verified archive.  A stale interrupted
        # scratch copy must never become the input for an operator rerun.
        scratch = self.root / "work" / plan.job_id
        ensure_directory(scratch)
        copy_verified(scratch.parent.parent / "archive" / plan.manifest.course / plan.archive.name,
                      scratch / plan.filename, plan.manifest.expected)

        if plan.job_id != plan.selected_job_id:
            heads = dict(plan.heads)
            heads[plan.filename] = {
                "job_id": plan.job_id,
                "identity": plan.identity,
                "manifest": {
                    "version": 1,
                    "filename": plan.manifest.filename,
                    "size_bytes": plan.manifest.size_bytes,
                    "sha256": plan.manifest.sha256,
                },
            }
            atomic_json(self.heads_path, heads)
            state = {
                "version": 1, "identity": plan.identity, "attempts": 0,
                "published": False, "grok_ingested": False, "transcript": None,
                "last_error": None,
            }
        else:
            state = dict(plan.selected_state)
            state.update({
                "identity": plan.identity, "attempts": 0, "published": False,
                "grok_ingested": False, "transcript": None, "last_error": None,
            })
        state.pop("publication_key", None)
        state.pop("artifacts", None)
        # An operator-requested reprocess is an explicit retry and must not be
        # held behind the previous watch-mode backoff window.
        state.pop("retry_after", None)
        state.pop("retry_count", None)
        state["archive"] = str(plan.archive.relative_to(self.root))
        state["archive_stat"] = self._archive_stat(plan.archive)
        state["stage"] = "accepted"
        atomic_json(plan.target_state_path, state)
        return self._resume(plan.manifest, plan.identity, plan.job_id)

    def _reconcile(self) -> RunReport:
        counts = {"processed": 0, "skipped": 0, "pending": 0, "quality_blocked": 0}
        failures = []
        # Read the accepted-record index before processing inbox markers.  A
        # malformed root document is an operator-repair condition; returning a
        # report keeps watch mode alive and, more importantly, avoids accepting
        # new work while the index cannot safely establish revision heads.
        try:
            heads = self._heads()
        except (OSError, TypeError, ValueError) as error:
            message = f"state/heads.json: invalid accepted recording index ({error})"
            LOGGER.exception("Cannot read accepted recording index")
            return RunReport(failures=(message,))
        if not isinstance(heads, dict):
            message = "state/heads.json: invalid accepted recording index (expected an object)"
            LOGGER.error(message)
            return RunReport(failures=(message,))
        markers = sorted(self.inbox.glob(f"*{SUFFIX}"))
        for marker in markers:
            try:
                result = self._process(marker)
                counts[result] += 1
            except PendingRecording as error:
                counts["pending"] += 1
                LOGGER.info("Waiting for %s: %s", marker.name, error)
            except Exception as error:
                failures.append(f"{marker.name}: {error}")
                LOGGER.exception("Processing failed for %s", marker.name)
        # Only accepted heads may resume. Superseded jobs remain historical and
        # cannot overwrite a newer revision's canonical files or Drive objects.
        seen_markers = {marker.name for marker in markers}
        for filename, head in heads.items():
            # A heads entry is written atomically, but an operator may restore
            # an incomplete backup or a disk fault may leave one entry
            # malformed.  Validate it before touching nested fields so one
            # damaged recording cannot terminate watch mode or hide healthy
            # accepted jobs.  Keep the entry in place for operator recovery and
            # report an actionable failure on every reconciliation.
            if not isinstance(filename, str) or not filename:
                failures.append("<unknown>: invalid accepted recording head (filename)")
                LOGGER.error("Invalid accepted recording head key: %r", filename)
                continue
            if f"{filename}.ready.json" in seen_markers:
                continue
            if not isinstance(head, dict):
                failures.append(f"{filename}: invalid accepted recording head (object)")
                LOGGER.error("Invalid accepted recording head for %s: expected an object", filename)
                continue
            identity = head.get("identity")
            if not isinstance(identity, dict):
                failures.append(f"{filename}: invalid accepted recording head (identity)")
                LOGGER.error("Invalid accepted recording head for %s: missing identity", filename)
                continue
            settings = identity.get("settings")
            if not isinstance(settings, dict):
                failures.append(f"{filename}: invalid accepted recording head (settings)")
                LOGGER.error("Invalid accepted recording head for %s: missing settings", filename)
                continue
            # Jobs accepted with another backend/settings belong to a separate
            # durable identity and are intentionally left alone.
            if not self._settings_compatible_for_recovery(settings):
                continue
            try:
                manifest = manifest_from_data(head["manifest"])
                if manifest.filename != filename:
                    raise ValueError("Invalid accepted recording identity")
                expected_identity, expected_job_id = self._identity(manifest)
                identity, job_id = self._migrate_legacy_head(
                    manifest, expected_identity, expected_job_id
                )
                counts[self._resume(manifest, identity, job_id)] += 1
            except PendingRecording as error:
                counts["pending"] += 1
                LOGGER.info("Waiting to resume %s: %s", filename, error)
            except Exception as error:
                failures.append(f"{filename}: {error}")
                LOGGER.exception("Durable retry failed for %s", filename)
        return RunReport(**counts, failures=tuple(failures))

    def _identity(self, manifest: RecordingManifest) -> tuple[dict, str]:
        settings = self._identity_settings()
        identity = {"filename": manifest.filename, "sha256": manifest.sha256,
                    "size_bytes": manifest.size_bytes, "settings": settings}
        job_id = hashlib.sha256(json.dumps(identity, sort_keys=True).encode()).hexdigest()
        return identity, job_id

    def _identity_settings(self) -> dict[str, Any]:
        """Return normalized settings for durable identity matching.

        The fallback is opt-in.  Omitting its false default keeps existing
        provider-only job identities resumable after this field is introduced;
        an explicit true value remains part of the job identity.
        """
        settings = asdict(self.settings)
        if settings.get("elevenlabs_local_fallback") is False:
            settings.pop("elevenlabs_local_fallback", None)
        return settings

    def _settings_compatible_for_recovery(self, settings: Any) -> bool:
        """Accept a legacy provider-only identity for fallback recovery."""
        current = self._identity_settings()
        if settings == current:
            return True
        if (current.get("transcriber") != "elevenlabs"
                or current.get("elevenlabs_local_fallback") is not True):
            return False
        legacy = dict(current)
        legacy.pop("elevenlabs_local_fallback", None)
        return settings == legacy

    def _migrate_legacy_head(
        self, manifest: RecordingManifest, identity: dict[str, Any], job_id: str
    ) -> tuple[dict[str, Any], str]:
        """Migrate a legacy provider-only head to the current identity once.

        The old state remains on disk as historical evidence and is marked as
        superseded.  The accepted head points to one current job, so marker
        reconciliation and archive-only recovery cannot create duplicate
        active revisions for the same source bytes.
        """
        heads = self._heads()
        head = heads.get(manifest.filename) if isinstance(heads, dict) else None
        if not isinstance(head, dict):
            return identity, job_id
        candidate = head.get("identity")
        old_job_id = head.get("job_id")
        if (not isinstance(candidate, dict) or candidate.get("filename") != manifest.filename
                or candidate.get("sha256") != manifest.sha256
                or candidate.get("size_bytes") != manifest.size_bytes
                or not self._settings_compatible_for_recovery(candidate.get("settings"))):
            return identity, job_id
        if candidate == identity:
            if old_job_id != job_id:
                raise ValueError("Accepted recording head job id does not match its identity")
            return identity, job_id
        if not isinstance(old_job_id, str) or re.fullmatch(r"[0-9a-f]{64}", old_job_id) is None:
            raise ValueError("Invalid legacy accepted recording job id")
        state_path = self.jobs / f"{old_job_id}.json"
        if state_path.is_symlink() or not state_path.is_file():
            raise ValueError(f"Legacy durable job state was not found: {state_path}")
        try:
            state = read_json(state_path)
        except (OSError, ValueError, json.JSONDecodeError):
            raise ValueError(f"Invalid legacy durable job state: {state_path}")
        if not isinstance(state, dict) or state.get("identity") != candidate:
            raise ValueError(f"Legacy durable job identity does not match: {state_path}")
        target_path = self.jobs / f"{job_id}.json"
        if target_path.is_symlink():
            raise UnsafePath(f"Not a regular durable target job state: {target_path}")
        if target_path.exists():
            target = read_json(target_path)
            if not isinstance(target, dict) or target.get("identity") != identity:
                raise ValueError(f"Invalid durable target job identity: {target_path}")
        else:
            target = dict(state)
            target["identity"] = identity
            target["superseded_from"] = old_job_id
            # A migrated target is about to be resumed under the current
            # settings.  Do not carry a provider failure or its backoff window
            # into that first attempt; the historical state keeps the original
            # failure for audit, while a new failure is recorded on the target.
            target["stage"] = "accepted"
            target["last_error"] = None
            self._clear_failure_retry(target)
            atomic_json(target_path, target)
        state["superseded_by"] = job_id
        atomic_json(state_path, state)
        heads[manifest.filename] = {
            "job_id": job_id,
            "identity": identity,
            "manifest": {
                "version": 1,
                "filename": manifest.filename,
                "size_bytes": manifest.size_bytes,
                "sha256": manifest.sha256,
            },
        }
        atomic_json(self.heads_path, heads)
        LOGGER.info("Migrated legacy provider-only job %s to %s for %s", old_job_id, job_id, manifest.filename)
        return identity, job_id

    def _process(self, marker: Path) -> str:
        manifest = load_manifest(marker, self.inbox)
        identity, job_id = self._identity(manifest)
        identity, job_id = self._migrate_legacy_head(manifest, identity, job_id)
        source = self.inbox / manifest.filename
        if source.is_symlink():
            raise UnsafePath(f"Not a regular recording: {source}")
        self._assert_current_if_accepted(manifest, job_id)
        if self._completed(manifest, identity, job_id):
            return "skipped"
        scratch = self.root / "work" / job_id
        ensure_directory(scratch)
        audio = scratch / manifest.filename
        # A successful independent copy establishes acceptance. A received
        # marker alone never creates durable work or supersedes a trusted job.
        try:
            copy_verified(source, audio, manifest.expected)
        except FileNotFoundError as error:
            if self._head_job_id(manifest.filename) == job_id:
                return self._resume(manifest, identity, job_id)
            raise PendingRecording("Audio has not arrived") from error
        except ValueError as error:
            if self._head_job_id(manifest.filename) == job_id:
                return self._resume(manifest, identity, job_id)
            raise PendingRecording(str(error)) from error
        heads = self._heads()
        heads[manifest.filename] = {
            "job_id": job_id, "identity": identity,
            "manifest": {"version": 1, "filename": manifest.filename,
                         "size_bytes": manifest.size_bytes, "sha256": manifest.sha256},
        }
        # Full metadata in the head permits recovery if the next state write
        # is interrupted. The verified scratch exists before either write.
        atomic_json(self.heads_path, heads)
        return self._resume(manifest, identity, job_id)

    def _archive_path(self, manifest: RecordingManifest) -> Path:
        course = self.root / "archive" / manifest.course
        ensure_directory(course)
        return course / f"{Path(manifest.filename).stem}--{manifest.sha256}.m4a"

    def _assert_current(self, manifest: RecordingManifest, job_id: str) -> None:
        if self._head_job_id(manifest.filename) != job_id:
            raise PendingRecording("Recording has been superseded")
        marker = self.inbox / f"{manifest.filename}.ready.json"
        try:
            current = load_manifest(marker, self.inbox)
        except FileNotFoundError:
            return  # Accepted work no longer depends on retention in the inbox.
        if current != manifest:
            raise PendingRecording("Completion marker changed during processing")

    def _assert_current_if_accepted(self, manifest: RecordingManifest, job_id: str) -> None:
        if self._head_job_id(manifest.filename) == job_id:
            self._assert_current(manifest, job_id)

    @staticmethod
    def _archive_stat(path: Path) -> list[int]:
        info = path.lstat()
        if not stat.S_ISREG(info.st_mode):
            raise UnsafePath(f"Not a regular archive: {path}")
        return [info.st_dev, info.st_ino, info.st_size, info.st_mtime_ns, info.st_ctime_ns]

    def _completed(self, manifest: RecordingManifest, identity: dict, job_id: str) -> bool:
        """Avoid rereading/writing lecture audio on every filesystem event.

        Archive bytes were SHA-256 verified when published. Stat changes force
        verification again; unchanged files are not a periodic bit-rot audit.
        """
        if self._head_job_id(manifest.filename) != job_id:
            return False
        state_path = self.jobs / f"{job_id}.json"
        if not state_path.exists():
            return False
        state = read_json(state_path)
        if (state.get("identity") != identity or state.get("transcript") is None
                or state.get("last_error") is not None or not state.get("archive_stat")
                or state.get("stage") not in {"local_ready", "published", "quality_blocked"}):
            return False
        # A citation-unsafe provider transcript can be repaired from the
        # verified archive on the next watch reconciliation.  Keep this
        # bounded and opt-in so ordinary quality review remains terminal.
        if self._automatic_repair_due(state):
            return False
        archive = self._archive_path(manifest)
        try:
            if self._archive_stat(archive) != state["archive_stat"]:
                return False
        except FileNotFoundError:
            return False
        course = self.root / "vault" / manifest.course
        ensure_directory(course)
        transcript = transcript_from_dict(state["transcript"])
        current_quality = assess_transcript(transcript)
        if (self.publisher is not None and not self.quality_override
                and not current_quality.publication_allowed
                and not (state.get("stage") == "quality_blocked"
                         and state.get("publication_blocked") is True)):
            # A newer quality rule can make an already-published cached
            # transcript unsafe without changing rendered bytes. Reconcile
            # its eligibility once, keeping the remote publication fact.
            return False
        for filename, content in render_artifacts(
                manifest, transcript,
                professor_speaker=self._professor_speaker_for(manifest),
        ).items():
            path = course / filename
            try:
                if fingerprint(path) != (len(content), hashlib.sha256(content).hexdigest()):
                    return False
            except FileNotFoundError:
                return False
        # A quality-blocked publication is a deliberate terminal state for
        # the unattended worker.  Re-running the same cached quality check
        # every reconciliation interval only floods logs and needlessly
        # touches durable state. Artifact comparison above still permits a
        # newly supplied explicit speaker calibration to update local files.
        quality_blocked_terminal = (
            state.get("stage") == "quality_blocked"
            and state.get("publication_blocked") is True
            and self.publisher is not None
            and not self.quality_override
        )
        if self.publisher is not None and not quality_blocked_terminal and (
                not state.get("published") or state.get("publication_key") != self.publication_key):
            return False
        return True

    def _automatic_repair_due(self, state: Mapping[str, Any]) -> bool:
        """Return whether one bounded timestamp repair should be attempted."""
        if not self.automatic_repair or self.max_automatic_repairs <= 0:
            return False
        if state.get("stage") not in {"quality_blocked", "accepted"} or state.get("publication_blocked") is not True:
            return False
        attempts = state.get("automatic_repair_attempts", 0)
        if type(attempts) is not int or attempts >= self.max_automatic_repairs:
            return False
        quality = state.get("quality")
        if not isinstance(quality, Mapping):
            return False
        if (quality.get("relevance_status", quality.get("relevance")) != "likely_lecture"
                or quality.get("relevance_reasons")):
            return False
        warnings = quality.get("warnings")
        if not isinstance(warnings, list) or any(not isinstance(warning, Mapping) for warning in warnings):
            return False
        blocking = [warning for warning in warnings if warning.get("blocking") is True]
        return bool(blocking) and all(warning.get("code") in self.AUTO_REPAIR_WARNING_CODES for warning in blocking)

    def _prepare_automatic_repair(self, state: dict[str, Any]) -> bool:
        """Clear a blocked cached transcript before a bounded re-transcription.

        The old quality report is retained as a compact history entry.  The
        verified archive remains the only source for the replacement, and the
        current source identity/head is never changed.
        """
        if not self._automatic_repair_due(state):
            return False
        attempts = state.get("automatic_repair_attempts", 0)
        quality = state.get("quality")
        history = state.get("automatic_repair_history")
        if not isinstance(history, list):
            history = []
        entry = {
            "attempt": attempts + 1,
            "previous_quality": quality,
            "at": self._clock().isoformat(),
        }
        history.append(entry)
        state["automatic_repair_attempts"] = attempts + 1
        state["automatic_repair_history"] = history[-self.max_automatic_repairs:]
        state["transcript"] = None
        state.pop("transcription", None)
        state.pop("quality", None)
        state.pop("artifacts", None)
        state["published"] = False
        state["publication_blocked"] = False
        state["last_error"] = None
        state["stage"] = "accepted"
        self._clear_failure_retry(state)
        return True

    def _retry_is_deferred(self, state: dict[str, Any]) -> bool:
        """Return whether watch mode should wait before retrying this job.

        Retry metadata is deliberately advisory for manual ``once`` runs.  A
        malformed or legacy timestamp is ignored so a damaged state file never
        strands a lecture indefinitely; the next failure simply writes a fresh
        valid timestamp.
        """
        if not self.respect_retry_after:
            return False
        raw = state.get("retry_after")
        if not isinstance(raw, str) or not raw:
            return False
        try:
            retry_at = datetime.fromisoformat(raw)
        except (TypeError, ValueError):
            LOGGER.warning("Ignoring malformed retry_after timestamp in durable job state")
            return False
        if retry_at.tzinfo is None:
            retry_at = retry_at.replace(tzinfo=timezone.utc)
        now = self._clock()
        if now.tzinfo is None:
            now = now.replace(tzinfo=timezone.utc)
        return retry_at > now

    def _record_failure_retry(self, state: dict[str, Any]) -> None:
        """Persist an exponential retry window after a failed provider call."""
        previous = state.get("retry_count", 0)
        count = previous + 1 if type(previous) is int and previous >= 0 else 1
        # Seven failures already reach the one-hour cap.  Keeping the stored
        # counter bounded also prevents a corrupted state value from creating
        # an enormous exponent before the cap is applied.
        count = min(count, 7)
        # Cap the exponent before constructing the integer. Durable state can
        # survive arbitrary operator edits, and a huge retry_count must never
        # trigger an unbounded ``2 ** n`` allocation.
        exponent = min(count - 1, 6)
        delay = min(self.RETRY_MAX_SECONDS, self.RETRY_BASE_SECONDS * (2 ** exponent))
        now = self._clock()
        if now.tzinfo is None:
            now = now.replace(tzinfo=timezone.utc)
        state["retry_count"] = count
        state["retry_after"] = (now + timedelta(seconds=delay)).isoformat()

    @staticmethod
    def _clear_failure_retry(state: dict[str, Any]) -> None:
        state.pop("retry_count", None)
        state.pop("retry_after", None)

    def _resume(self, manifest: RecordingManifest, identity: dict, job_id: str) -> str:
        self._assert_current(manifest, job_id)
        if self._completed(manifest, identity, job_id):
            return "skipped"
        state_path = self.jobs / f"{job_id}.json"
        if state_path.exists():
            state = read_json(state_path)
            if state.get("identity") != identity:
                raise ValueError(f"Invalid durable job identity: {state_path}")
        else:
            state = {"version": 1, "identity": identity, "attempts": 0, "published": False,
                     "grok_ingested": False, "transcript": None, "last_error": None}
        if self._retry_is_deferred(state):
            LOGGER.debug("Deferring retry for %s until %s", manifest.filename, state.get("retry_after"))
            return "skipped"
        repaired = self._prepare_automatic_repair(state)
        if repaired:
            LOGGER.warning(
                "Automatically repairing citation-unsafe transcript for %s (attempt %s/%s)",
                manifest.filename,
                state.get("automatic_repair_attempts"),
                self.max_automatic_repairs,
            )
            atomic_json(state_path, state)
        scratch = self.root / "work" / job_id
        ensure_directory(scratch)
        audio = scratch / manifest.filename
        if not audio.exists():
            archive = self._archive_path(manifest)
            copy_verified(archive, audio, manifest.expected)
        if fingerprint(audio) != manifest.expected:
            raise ValueError("Accepted scratch no longer matches its completion manifest")
        state["attempts"] += 1
        atomic_json(state_path, state)
        try:
            had_transcript = state["transcript"] is not None
            if not had_transcript:
                transcript = self.transcriber.transcribe(audio)
                state["transcript"] = transcript_to_dict(transcript)
                metadata = getattr(self.transcriber, "last_transcription_metadata", None)
                if isinstance(metadata, dict):
                    # Adapter metadata records whether the explicitly enabled
                    # local fallback supplied this transcript and that it has
                    # no speaker diarization. Keep it separate from the
                    # transcript schema so legacy cached jobs remain readable.
                    state["transcription"] = dict(metadata)
                state["stage"] = "transcribed"
                atomic_json(state_path, state)
            transcript = transcript_from_dict(state["transcript"])
            quality = assess_transcript(transcript)
            state["quality"] = quality.to_dict()
            if quality.warnings:
                LOGGER.warning(
                    "Transcript quality for %s: status=%s warnings=%s",
                    manifest.filename,
                    quality.status,
                    ", ".join(warning.code for warning in quality.warnings),
                )
            # A correction may have synced during lengthy GPU inference.
            self._assert_current(manifest, job_id)
            archive = self._archive_path(manifest)
            archive_verified(audio, archive, manifest.expected)
            state["archive"] = str(archive.relative_to(self.root))
            state["archive_stat"] = self._archive_stat(archive)
            state["stage"] = "archived"
            atomic_json(state_path, state)
            course = self.root / "vault" / manifest.course
            ensure_directory(course)
            artifacts = []
            changed = False
            fingerprints = {}
            for filename, content in render_artifacts(
                    manifest, transcript, quality,
                    professor_speaker=self._professor_speaker_for(manifest),
            ).items():
                path = course / filename
                expected = len(content), hashlib.sha256(content).hexdigest()
                if not path.exists() or fingerprint(path) != expected:
                    atomic_bytes(path, content)
                    changed = True
                fingerprints[filename] = expected[1]
                artifacts.append(path)
            if changed:
                state["published"] = False
            needs_publication = self.publisher is not None and (
                not state["published"] or state.get("publication_key") != self.publication_key)
            state["artifacts"] = fingerprints
            calibrated = self._professor_speaker_for(manifest)
            state["speaker_calibration"] = (
                {"professor": calibrated} if calibrated else {"professor": None}
            )
            state["stage"] = "local_ready"
            state["publication_blocked"] = False
            atomic_json(state_path, state)
            if self.publisher is not None:
                if not quality.publication_allowed and not self.quality_override:
                    state["publication_blocked"] = True
                    state["stage"] = "quality_blocked"
                    state["last_error"] = None
                    atomic_json(state_path, state)
                    blocked_reasons = [warning.code for warning in quality.warnings if warning.blocking]
                    blocked_reasons.extend(quality.relevance_reasons)
                    LOGGER.warning(
                        "Quality gate blocked publication for %s: %s",
                        manifest.filename,
                        ", ".join(dict.fromkeys(blocked_reasons)) or "relevance_review",
                    )
                    audio.unlink()
                    scratch.rmdir()
                    return "quality_blocked"
            if needs_publication:
                self._assert_current(manifest, job_id)
                self.publisher.publish(manifest.course, artifacts)
                state["published"] = True
                state["publication_key"] = self.publication_key
            state["stage"] = "published" if state["published"] else "local_ready"
            state["publication_blocked"] = False
            state["last_error"] = None
            self._clear_failure_retry(state)
            atomic_json(state_path, state)
            # Verified archival and durable state precede deletion of scratch.
            audio.unlink()
            scratch.rmdir()
            return "processed" if repaired or not had_transcript or changed or needs_publication else "skipped"
        except Exception as error:
            state["last_error"] = f"{type(error).__name__}: {error}"
            self._record_failure_retry(state)
            atomic_json(state_path, state)
            raise
