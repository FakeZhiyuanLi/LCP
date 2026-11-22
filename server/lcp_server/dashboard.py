"""Read-only LCP transcript dashboard.

The worker state files contain the complete transcript, so this module keeps a
strict metadata boundary: the HTTP API returns status and quality signals only.
It is intentionally dependency-free and binds to loopback by default. Put it
behind an authenticated proxy when enabling remote access.
"""

from __future__ import annotations

import argparse
import json
import mimetypes
import re
from datetime import datetime, timezone
from http import HTTPStatus
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any
from urllib.parse import urlparse

from .filesystem import read_json
from .quality import assess_transcript
from .rendering import transcript_from_dict


_FILENAME_RE = re.compile(
    r"^(?P<course>.+?)_(?P<date>\d{4}-\d{2}-\d{2})_(?P<time>\d{4})\.m4a$",
    re.IGNORECASE,
)
_STATIC_ROOT = Path(__file__).with_name("dashboard_static")


def _course_for(state: dict[str, Any], filename: str) -> str:
    identity = state.get("identity")
    if isinstance(identity, dict):
        for key in ("course", "course_code"):
            value = identity.get(key)
            if isinstance(value, str) and value.strip():
                return value.strip()
    for key in ("course", "course_code"):
        value = state.get(key)
        if isinstance(value, str) and value.strip():
            return value.strip()
    match = _FILENAME_RE.match(filename)
    return match.group("course").strip() if match else "Unassigned course"


def _recorded_at(filename: str) -> str | None:
    match = _FILENAME_RE.match(filename)
    if not match:
        return None
    try:
        value = datetime.strptime(
            f"{match.group('date')} {match.group('time')}", "%Y-%m-%d %H%M"
        )
    except ValueError:
        return None
    # The recorder writes local Mac time. Preserve that fact without claiming a
    # timezone we do not have in the durable manifest.
    return value.isoformat(timespec="minutes")


def _quality(state: dict[str, Any]) -> dict[str, Any]:
    cached = state.get("quality")
    if isinstance(cached, dict):
        return cached
    transcript_data = state.get("transcript")
    if isinstance(transcript_data, dict):
        try:
            return assess_transcript(transcript_from_dict(transcript_data)).to_dict()
        except (TypeError, ValueError):
            pass
    return {
        "status": "unknown",
        "publishable": False,
        "blocking": False,
        "cue_count": 0,
        "speaker_count": 0,
        "duration_seconds": 0,
        "speech_seconds": 0,
        "speech_density": 0,
        "trailing_silence_seconds": 0,
        "tail_word_count": 0,
        "tail_words_per_minute": 0,
        "diarization_coverage": 0,
        "noise_marker_count": 0,
        "noise_markers": [],
        "relevance": "unknown",
        "relevance_status": "unknown",
        "relevance_reasons": [],
        "publication_allowed": False,
        "warnings": [],
    }


def _artifact_presence(state: dict[str, Any]) -> dict[str, bool]:
    artifacts = state.get("artifacts")
    if not isinstance(artifacts, dict):
        return {"md": False, "txt": False, "srt": False}
    return {
        suffix: any(
            isinstance(name, str) and name.lower().endswith(f".{suffix}")
            for name in artifacts
        )
        for suffix in ("md", "txt", "srt")
    }


def _status_for(state: dict[str, Any]) -> str:
    stage = state.get("stage")
    if state.get("publication_blocked") is True or stage == "quality_blocked":
        return "blocked"
    if state.get("last_error"):
        return "error"
    if state.get("published") is True or stage == "published":
        return "published"
    if stage == "local_ready":
        return "ready"
    return "processing"


def _warning_data(quality: dict[str, Any]) -> list[dict[str, Any]]:
    warnings = quality.get("warnings")
    if not isinstance(warnings, list):
        return []
    result = []
    for warning in warnings:
        if not isinstance(warning, dict):
            continue
        code = warning.get("code")
        message = warning.get("message")
        if isinstance(code, str) and isinstance(message, str):
            result.append({
                "code": code,
                "message": message,
                "severity": warning.get("severity", "warning"),
                "blocking": bool(warning.get("blocking", False)),
            })
    return result


def _error_summary(value: Any) -> str | None:
    """Return an error class without echoing paths or provider details."""
    if not isinstance(value, str) or not value:
        return None
    summary = value.split(":", 1)[0].strip()
    return summary[:80] or "WorkerError"


def _repair_data(state: dict[str, Any]) -> dict[str, Any]:
    """Expose bounded repair metadata without transcript or path contents."""
    attempts = state.get("automatic_repair_attempts", 0)
    if type(attempts) is not int or attempts < 0:
        attempts = 0
    transcription = state.get("transcription")
    result: dict[str, Any] = {
        "attempts": attempts,
        "backend": None,
        "fallback_used": False,
        "fallback_attempted": False,
        "fallback_settings": None,
        "history": [],
    }
    if isinstance(transcription, dict):
        backend = transcription.get("backend")
        if isinstance(backend, str):
            result["backend"] = backend[:80]
        result["fallback_used"] = transcription.get("fallback_used") is True
        result["fallback_attempted"] = transcription.get("fallback_attempted") is True
        settings = transcription.get("fallback_settings")
        if isinstance(settings, dict):
            safe_settings: dict[str, Any] = {}
            for key in ("model", "device", "compute_type"):
                value = settings.get(key)
                if isinstance(value, str):
                    safe_settings[key] = value[:80]
            for key in ("vad_filter", "min_silence_duration_ms"):
                value = settings.get(key)
                if isinstance(value, bool) or (type(value) is int and value >= 0):
                    safe_settings[key] = value
            result["fallback_settings"] = safe_settings or None
    history = state.get("automatic_repair_history")
    if isinstance(history, list):
        safe_history = []
        for entry in history[-3:]:
            if not isinstance(entry, dict):
                continue
            attempt = entry.get("attempt")
            at = entry.get("at")
            previous = entry.get("previous_quality")
            warning_codes = []
            if isinstance(previous, dict) and isinstance(previous.get("warnings"), list):
                warning_codes = [
                    warning.get("code")[:80]
                    for warning in previous["warnings"]
                    if isinstance(warning, dict) and isinstance(warning.get("code"), str)
                ][:16]
            safe_history.append({
                "attempt": attempt if type(attempt) is int and attempt >= 1 else None,
                "at": at[:64] if isinstance(at, str) else None,
                "warning_codes": warning_codes,
            })
        result["history"] = safe_history
    return result


def _accepted_heads(root: Path) -> dict[str, str]:
    """Read the worker's accepted recording heads without exposing the index."""
    path = Path(root) / "state" / "heads.json"
    try:
        data = read_json(path, limit=4 * 1024 * 1024)
    except (OSError, ValueError, json.JSONDecodeError):
        return {}
    if not isinstance(data, dict):
        return {}
    result: dict[str, str] = {}
    for filename, entry in data.items():
        if not isinstance(filename, str) or not isinstance(entry, dict):
            continue
        job_id = entry.get("job_id")
        if isinstance(job_id, str) and re.fullmatch(r"[0-9a-f]{64}", job_id):
            result[filename] = job_id
    return result


def _transcript_record(path: Path) -> dict[str, Any] | None:
    try:
        state = read_json(path, limit=64 * 1024 * 1024)
    except (OSError, ValueError, json.JSONDecodeError):
        return None
    if not isinstance(state, dict):
        return None
    identity = state.get("identity")
    if not isinstance(identity, dict):
        return None
    filename = identity.get("filename")
    if not isinstance(filename, str) or not filename:
        return None
    quality = _quality(state)
    warnings = _warning_data(quality)
    stage = state.get("stage") if isinstance(state.get("stage"), str) else "unknown"
    published = bool(state.get("published", False))
    grok_ingested = bool(state.get("grok_ingested", False))
    settings = identity.get("settings")
    provider = None
    if isinstance(settings, dict):
        if settings.get("transcriber") == "elevenlabs":
            provider = "ElevenLabs Scribe v2" if settings.get("elevenlabs_model") == "scribe_v2" else "ElevenLabs"
        elif settings.get("transcriber") == "local":
            provider = "Local Whisper"
    return {
        "id": path.stem,
        "filename": filename,
        "provider": provider,
        "course": _course_for(state, filename),
        "recorded_at": _recorded_at(filename),
        "stage": stage,
        "status": _status_for(state),
        "published": published,
        "publication_blocked": bool(state.get("publication_blocked", False)),
        "grok_ingested": grok_ingested,
        "delivery": "indexed" if grok_ingested else ("drive" if published else "local"),
        "attempts": state.get("attempts", 0) if isinstance(state.get("attempts", 0), int) else 0,
        "last_error": _error_summary(state.get("last_error")),
        "quality": {
            "status": quality.get("status", "unknown"),
            "relevance": quality.get("relevance_status", quality.get("relevance", "unknown")),
            "publishable": bool(quality.get("publishable", False)),
            "publication_allowed": bool(quality.get("publication_allowed", False)),
            "cue_count": quality.get("cue_count", 0),
            "speaker_count": quality.get("speaker_count", 0),
            "duration_seconds": quality.get("duration_seconds", 0),
            "speech_seconds": quality.get("speech_seconds", 0),
            "speech_density": quality.get("speech_density", 0),
            "trailing_silence_seconds": quality.get("trailing_silence_seconds", 0),
            "tail_words_per_minute": quality.get("tail_words_per_minute", 0),
            "diarization_coverage": quality.get("diarization_coverage", 0),
            "noise_marker_count": quality.get("noise_marker_count", 0),
            "noise_markers": list(quality.get("noise_markers", [])) if isinstance(quality.get("noise_markers", []), list) else [],
            "warnings": warnings,
            "relevance_reasons": list(quality.get("relevance_reasons", [])) if isinstance(quality.get("relevance_reasons", []), list) else [],
        },
        "artifacts": _artifact_presence(state),
        "repair": _repair_data(state),
        # Internal selection metadata.  It is removed before the payload is
        # returned so the API remains a status-only contract.
        "_superseded_by": state.get("superseded_by") if isinstance(state.get("superseded_by"), str) else None,
        "updated_at": datetime.fromtimestamp(path.stat().st_mtime, tz=timezone.utc).isoformat(),
    }


def build_dashboard_payload(root: Path) -> dict[str, Any]:
    """Build the safe dashboard payload from durable job metadata."""
    root = Path(root)
    jobs = root / "state" / "jobs"
    records = []
    if jobs.is_dir() and not jobs.is_symlink():
        for path in sorted(jobs.glob("*.json"), key=lambda item: item.stat().st_mtime, reverse=True):
            if path.is_symlink() or not path.is_file():
                continue
            record = _transcript_record(path)
            if record is not None:
                records.append(record)
    # A recording can have several durable revisions after a settings change
    # or fallback migration.  The worker's accepted-head index identifies the
    # one current row.  Keep historical JSON files for auditability, while the
    # operations view presents one status per recording and hides explicitly
    # superseded revisions when an index is unavailable.
    heads = _accepted_heads(root)
    grouped: dict[str, list[dict[str, Any]]] = {}
    for record in records:
        grouped.setdefault(record["filename"], []).append(record)
    selected_ids: set[str] = set()
    for filename, group in grouped.items():
        head_id = heads.get(filename)
        selected = next((record for record in group if record["id"] == head_id), None)
        if selected is None:
            selected = next(
                (record for record in group if not record.get("_superseded_by")),
                group[0],
            )
        selected_ids.add(selected["id"])
    records = [record for record in records if record["id"] in selected_ids]

    counts = {key: 0 for key in ("total", "published", "review", "blocked", "processing", "errors", "local")}
    durations = []
    for record in records:
        counts["total"] += 1
        status = record["status"]
        status_key = "errors" if status == "error" else status if status in counts else "processing"
        counts[status_key] += 1
        if record["status"] != "blocked" and (
            record["quality"]["status"] == "warn"
            or record["quality"]["relevance"] == "needs_review"
        ):
            counts["review"] += 1
        if record["delivery"] == "local":
            counts["local"] += 1
        duration = record["quality"].get("duration_seconds")
        if isinstance(duration, (int, float)) and duration > 0:
            durations.append(float(duration))
    latest = records[0]["updated_at"] if records else None
    providers = sorted({record["provider"] for record in records if record["provider"]})
    for record in records:
        record.pop("_superseded_by", None)
    return {
        "generated_at": datetime.now(timezone.utc).isoformat(),
        "service": {
            "name": "Lecture Capture Pipeline",
            "short_name": "LCP",
            "node": "self-hosted",
            "provider": " / ".join(providers) or None,
            "mode": "read-only operations view",
        },
        "summary": {
            **counts,
            "average_duration_seconds": round(sum(durations) / len(durations), 1) if durations else 0,
            "last_change": latest,
        },
        "transcripts": records,
    }


class DashboardHandler(BaseHTTPRequestHandler):
    """Serve the static dashboard and a bounded metadata API."""

    root: Path = Path("/data/lectures")

    def log_message(self, format: str, *args: Any) -> None:  # noqa: A003
        # Keep access logs useful without echoing query strings or payloads.
        return

    def _send(self, status: HTTPStatus, content_type: str, body: bytes) -> None:
        self.send_response(status)
        self.send_header("Content-Type", content_type)
        self.send_header("Cache-Control", "no-store")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_GET(self) -> None:  # noqa: N802
        parsed = urlparse(self.path)
        if parsed.path == "/api/status":
            body = json.dumps(build_dashboard_payload(self.root), separators=(",", ":")).encode()
            self._send(HTTPStatus.OK, "application/json; charset=utf-8", body)
            return
        if parsed.path == "/healthz":
            self._send(HTTPStatus.OK, "application/json; charset=utf-8", b'{"ok":true}')
            return
        if parsed.path == "/" or parsed.path == "/index.html":
            self._send_file(_STATIC_ROOT / "index.html")
            return
        if parsed.path.startswith("/assets/"):
            relative = parsed.path.removeprefix("/assets/")
            target = (_STATIC_ROOT / relative).resolve()
            if _STATIC_ROOT.resolve() not in target.parents:
                self._send(HTTPStatus.NOT_FOUND, "text/plain; charset=utf-8", b"Not found")
                return
            self._send_file(target)
            return
        self._send(HTTPStatus.NOT_FOUND, "text/plain; charset=utf-8", b"Not found")

    def _send_file(self, path: Path) -> None:
        try:
            if path.is_symlink() or not path.is_file():
                raise FileNotFoundError
            body = path.read_bytes()
        except (OSError, FileNotFoundError):
            self._send(HTTPStatus.NOT_FOUND, "text/plain; charset=utf-8", b"Not found")
            return
        content_type = mimetypes.guess_type(path.name)[0] or "application/octet-stream"
        if content_type == "text/html":
            content_type += "; charset=utf-8"
        self._send(HTTPStatus.OK, content_type, body)


def serve(root: Path, host: str = "127.0.0.1", port: int = 8186) -> None:
    """Run the dashboard HTTP server until interrupted."""
    DashboardHandler.root = Path(root).absolute()
    server = ThreadingHTTPServer((host, port), DashboardHandler)
    print(f"LCP dashboard listening on http://{host}:{port}/", flush=True)
    try:
        server.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        server.server_close()


def main(argv: list[str] | None = None) -> int:
    parser = argparse.ArgumentParser(description="Serve the read-only LCP transcript dashboard")
    parser.add_argument("--root", type=Path, default=Path("/data/lectures"))
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=8186)
    args = parser.parse_args(argv)
    serve(args.root, args.host, args.port)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
