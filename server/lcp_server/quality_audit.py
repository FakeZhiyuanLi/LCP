"""Read-only quality audits of durable LCP transcript state.

The normal worker computes a quality report while processing a recording.  An
audit is useful when an operator wants to review already-cached transcripts
without retranscribing audio, touching the synced inbox, or publishing
anything.  This module intentionally reads only ``state/jobs/*.json``.
"""

from __future__ import annotations

import re
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .filesystem import read_json
from .quality import TranscriptQualityReport, assess_transcript
from .rendering import transcript_from_dict


_JOB_ID_RE = re.compile(r"[0-9a-f]{64}\Z")


@dataclass(frozen=True)
class QualityAuditRecord:
    """One durable job and its freshly recomputed quality report."""

    job_id: str
    filename: str
    stage: str | None
    published: bool
    publication_blocked: bool
    report: TranscriptQualityReport

    def to_dict(self) -> dict[str, Any]:
        return {
            "job_id": self.job_id,
            "filename": self.filename,
            "stage": self.stage,
            "published": self.published,
            "publication_blocked": self.publication_blocked,
            "quality": self.report.to_dict(),
        }


@dataclass(frozen=True)
class QualityAuditError:
    """A durable job that could not be audited without changing it."""

    job_id: str
    filename: str | None
    message: str

    def to_dict(self) -> dict[str, Any]:
        return {
            "job_id": self.job_id,
            "filename": self.filename,
            "error": self.message,
        }


@dataclass(frozen=True)
class QualityAuditResult:
    """Read-only audit output suitable for JSON or human rendering."""

    root: Path
    reports: tuple[QualityAuditRecord, ...]
    errors: tuple[QualityAuditError, ...]
    filename: str | None = None
    job_id: str | None = None

    @property
    def blocked_count(self) -> int:
        return sum(not record.report.publishable for record in self.reports)

    def to_dict(self) -> dict[str, Any]:
        return {
            "root": str(self.root),
            "selection": {"filename": self.filename, "job_id": self.job_id},
            "count": len(self.reports),
            "blocked_count": self.blocked_count,
            "reports": [record.to_dict() for record in self.reports],
            "errors": [error.to_dict() for error in self.errors],
        }


def _candidate_paths(jobs: Path, *, filename: str | None, job_id: str | None) -> list[Path]:
    if job_id is not None:
        if not _JOB_ID_RE.fullmatch(job_id):
            raise ValueError("Job id must be a 64-character lowercase SHA-256")
        return [jobs / f"{job_id}.json"]
    paths = sorted(jobs.glob("*.json"))
    if filename is None:
        return paths
    return paths


def audit_quality_jobs(
    root: Path,
    *,
    filename: str | None = None,
    job_id: str | None = None,
) -> QualityAuditResult:
    """Recompute quality for selected/all cached transcript jobs, read-only.

    ``filename`` matches all durable revisions for that basename, which lets
    an operator compare a corrected recording with its previous state.  A
    missing or malformed state becomes a structured error while other jobs
    continue to be audited.  No directories, lock files, state files, or
    transcript artifacts are created or modified.
    """

    if filename is not None and (not isinstance(filename, str) or not filename
                                 or Path(filename).name != filename):
        raise ValueError("Filename must be a nonempty recording basename")
    if filename is not None and job_id is not None:
        raise ValueError("Select at most one of filename or job id")
    root = Path(root)
    jobs = root / "state" / "jobs"
    if not jobs.is_dir() or jobs.is_symlink():
        return QualityAuditResult(
            root=root, reports=(),
            errors=(QualityAuditError("", None, f"Durable job directory not found: {jobs}"),),
            filename=filename, job_id=job_id,
        )

    paths = _candidate_paths(jobs, filename=filename, job_id=job_id)
    if job_id is not None and (paths[0].is_symlink() or not paths[0].is_file()):
        return QualityAuditResult(
            root=root, reports=(),
            errors=(QualityAuditError(job_id, None, f"Durable job state was not found: {paths[0]}"),),
            filename=filename, job_id=job_id,
        )

    reports: list[QualityAuditRecord] = []
    errors: list[QualityAuditError] = []
    for path in paths:
        if path.is_symlink() or not path.is_file():
            continue
        current_job_id = path.stem
        state: dict[str, Any] | None = None
        state_filename: str | None = None
        try:
            state = read_json(path)
            if not isinstance(state, dict):
                raise ValueError("durable state is not a JSON object")
            identity = state.get("identity")
            if not isinstance(identity, dict):
                raise ValueError("durable state has no identity")
            state_filename = identity.get("filename")
            if not isinstance(state_filename, str) or not state_filename:
                raise ValueError("durable state has no recording filename")
            if filename is not None and state_filename != filename:
                continue
            transcript_data = state.get("transcript")
            if not isinstance(transcript_data, dict):
                raise ValueError("durable state has no cached transcript")
            transcript = transcript_from_dict(transcript_data)
            report = assess_transcript(transcript)
            reports.append(QualityAuditRecord(
                job_id=current_job_id,
                filename=state_filename,
                stage=state.get("stage") if isinstance(state.get("stage"), str) else None,
                published=bool(state.get("published", False)),
                publication_blocked=bool(state.get("publication_blocked", False)),
                report=report,
            ))
        except Exception as error:
            errors.append(QualityAuditError(current_job_id, state_filename, str(error)))

    if filename is not None and not reports and not errors:
        errors.append(QualityAuditError("", filename, "No durable job matched the filename"))
    return QualityAuditResult(
        root=root,
        reports=tuple(reports),
        errors=tuple(errors),
        filename=filename,
        job_id=job_id,
    )


def format_human(result: QualityAuditResult) -> str:
    """Render a compact operator-facing summary without losing key signals."""

    selection = "all jobs"
    if result.filename is not None:
        selection = f"filename={result.filename}"
    elif result.job_id is not None:
        selection = f"job_id={result.job_id}"
    lines = [
        f"Quality audit ({selection}) root={result.root}",
        f"Reports: {len(result.reports)}; blocked: {result.blocked_count}; errors: {len(result.errors)}",
    ]
    for record in result.reports:
        warning_codes = ",".join(warning.code for warning in record.report.warnings) or "none"
        lines.append(
            f"{record.report.status.upper()} {record.filename} [{record.job_id}] "
            f"cues={record.report.cue_count} speakers={record.report.speaker_count} "
            f"density={record.report.speech_density:.3f} "
            f"tail_wpm={record.report.tail_words_per_minute:.1f} "
            f"trailing_silence={record.report.trailing_silence_seconds:.1f}s "
            f"relevance={record.report.relevance_status} "
            f"warnings={warning_codes}"
        )
    for error in result.errors:
        target = error.filename or error.job_id or "state"
        lines.append(f"ERROR {target}: {error.message}")
    return "\n".join(lines)

