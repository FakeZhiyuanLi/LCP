"""Command-line entry point; importing it does not load ML/GPU dependencies."""

import argparse
import hashlib
import json
import logging
import math
from pathlib import Path
from typing import Sequence

from .filesystem import read_json
from .models import TranscriptionSettings
from .worker import Worker


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(description="Process finalized LCP audio")
    result.add_argument("mode", choices=("once", "watch", "reprocess", "quality-audit", "grok-audit"), nargs="?", default="once")
    result.add_argument("--root", type=Path, default=Path("/data/lectures"))
    result.add_argument("--transcriber", choices=("local", "elevenlabs"), default="elevenlabs",
                        help="Transcription backend (ElevenLabs Scribe by default; use local for the explicit offline Whisper fallback)")
    result.add_argument("--model", default="medium.en")
    result.add_argument("--device", choices=("cuda", "cpu"), default="cuda")
    result.add_argument("--compute-type", default="int8_float32")
    result.add_argument("--elevenlabs-model", default="scribe_v2")
    result.add_argument("--elevenlabs-language-code", default="en")
    result.add_argument("--elevenlabs-api-key-env", default="ELEVENLABS_API_KEY")
    result.add_argument("--elevenlabs-diarize", action=argparse.BooleanOptionalAction, default=True,
                        help="Request ElevenLabs speaker diarization (default: enabled)")
    result.add_argument(
        "--elevenlabs-local-fallback",
        action=argparse.BooleanOptionalAction,
        default=False,
        help=(
            "After a successful ElevenLabs response with citation-unsafe timestamps, "
            "try local Whisper (default: disabled)"
        ),
    )
    result.add_argument(
        "--automatic-repair",
        action=argparse.BooleanOptionalAction,
        default=False,
        help=(
            "On watch reconciliation, re-transcribe citation-unsafe cached jobs "
            "from their verified archive at most once (default: disabled)"
        ),
    )
    result.add_argument(
        "--max-automatic-repairs",
        type=int,
        default=1,
        help="Maximum bounded timestamp repairs per accepted recording (default: 1)",
    )
    result.add_argument(
        "--professor-speakers",
        type=Path,
        help=(
            "JSON object mapping a recording filename or stem to its explicitly calibrated "
            "anonymous professor speaker ID"
        ),
    )
    result.add_argument("--allow-quality-publish", action="store_true",
                        help="Override transcript quality and relevance gates for Drive publication")
    result.add_argument("--publish", action="store_true", help="Explicitly enable transcript-only Drive uploads")
    destinations = result.add_mutually_exclusive_group()
    destinations.add_argument("--drive-folders", type=Path, help="JSON object mapping exact course codes to Drive folder IDs")
    destinations.add_argument("--drive-root-folder-id", help="Drive parent folder ID; transcripts go into exact course subdirectories")
    result.add_argument("--remote", default="gdrive")
    result.add_argument("--rclone", default="rclone", help="rclone executable, preferably an absolute path in services")
    result.add_argument("--reconcile-seconds", type=float, default=30)
    selection = result.add_mutually_exclusive_group()
    selection.add_argument("--filename", help="Recording basename for reprocess, quality-audit, or grok-audit")
    selection.add_argument("--job-id", help="Durable job id for reprocess, quality-audit, or grok-audit")
    result.add_argument("--dry-run", action="store_true",
                        help="Validate a reprocess selection without changing state or calling adapters")
    result.add_argument("--backup-dir", type=Path,
                        help="Directory for automatic reprocess backups (default: state/reprocess-backups)")
    result.add_argument("--json", action="store_true",
                        help="Emit JSON output (quality-audit or grok-audit mode only)")
    result.add_argument("--verbose", action="store_true")
    return result


def main(argv: Sequence[str] | None = None) -> int:
    argument_parser = parser()
    args = argument_parser.parse_args(argv)
    if args.publish and not (args.drive_folders or args.drive_root_folder_id):
        argument_parser.error("--publish requires --drive-folders or --drive-root-folder-id")
    if args.mode == "reprocess":
        if not (args.filename or args.job_id):
            argument_parser.error("reprocess requires exactly one of --filename or --job-id")
    elif args.mode in {"quality-audit", "grok-audit"}:
        if args.publish or args.allow_quality_publish:
            argument_parser.error(f"{args.mode} is read-only and cannot publish or override the quality gate")
        if args.dry_run or args.backup_dir:
            argument_parser.error("--dry-run and --backup-dir require reprocess mode")
    elif args.filename or args.job_id or args.dry_run or args.backup_dir:
        argument_parser.error("--filename, --job-id, --dry-run, and --backup-dir require reprocess mode, quality-audit, or grok-audit")
    if args.elevenlabs_local_fallback and args.transcriber != "elevenlabs":
        argument_parser.error("--elevenlabs-local-fallback requires --transcriber elevenlabs")
    if args.professor_speakers and args.mode in {"quality-audit", "grok-audit"}:
        argument_parser.error("--professor-speakers is only used by worker modes")
    if args.json and args.mode not in {"quality-audit", "grok-audit"}:
        argument_parser.error("--json requires quality-audit or grok-audit mode")
    if not math.isfinite(args.reconcile_seconds) or args.reconcile_seconds <= 0:
        argument_parser.error("--reconcile-seconds must be finite and positive")
    logging.basicConfig(level=logging.DEBUG if args.verbose else logging.INFO,
                        format="%(asctime)s %(levelname)s %(name)s: %(message)s")
    try:
        if args.mode == "quality-audit":
            from .quality_audit import audit_quality_jobs, format_human

            result = audit_quality_jobs(args.root, filename=args.filename, job_id=args.job_id)
            if args.json:
                print(json.dumps(result.to_dict(), indent=2, sort_keys=True))
            else:
                print(format_human(result))
            return 1 if result.errors else 0
        if args.mode == "grok-audit":
            from .grok_contract import audit_grok_contract, format_human

            result = audit_grok_contract(args.root, filename=args.filename, job_id=args.job_id)
            if args.json:
                print(json.dumps(result.to_dict(), indent=2, sort_keys=True))
            else:
                print(format_human(result))
            return 1 if result.errors or result.failed_count else 0

        from .adapters import RclonePublisher, WhisperTranscriber

        settings = TranscriptionSettings(
            transcriber=args.transcriber,
            model=args.model,
            device=args.device,
            compute_type=args.compute_type,
            elevenlabs_model=args.elevenlabs_model,
            elevenlabs_diarize=args.elevenlabs_diarize,
            elevenlabs_language_code=args.elevenlabs_language_code,
            elevenlabs_local_fallback=args.elevenlabs_local_fallback,
        )
        professor_speakers = {}
        if args.professor_speakers:
            professor_speakers = read_json(args.professor_speakers, limit=1024 * 1024)
            if not isinstance(professor_speakers, dict):
                raise ValueError("Professor speaker calibration must be a JSON object")
        publisher = None
        publication_key = None
        if args.publish:
            folders = None
            if args.drive_folders:
                folders = read_json(args.drive_folders, limit=1024 * 1024)
                if not isinstance(folders, dict):
                    raise ValueError("Drive folder config must be a JSON object")
                publisher = RclonePublisher(remote=args.remote, folder_ids=folders, executable=args.rclone)
            else:
                publisher = RclonePublisher(remote=args.remote, root_folder_id=args.drive_root_folder_id,
                                            executable=args.rclone)
            publication_key = hashlib.sha256(json.dumps(
                {"remote": args.remote.rstrip(":"), "folders": folders,
                 "root_folder_id": args.drive_root_folder_id,
                 "mode": "course-folders" if folders is not None else "root-subdirectories"},
                sort_keys=True).encode()).hexdigest()
        if args.transcriber == "elevenlabs":
            from .adapters import ElevenLabsTranscriber

            primary = ElevenLabsTranscriber(
                model=args.elevenlabs_model,
                api_key_env=args.elevenlabs_api_key_env,
                diarize=args.elevenlabs_diarize,
                language_code=args.elevenlabs_language_code,
            )
            if args.elevenlabs_local_fallback:
                from .adapters import CitationFallbackTranscriber

                transcriber = CitationFallbackTranscriber(
                    primary,
                    WhisperTranscriber(
                        model=args.model,
                        device=args.device,
                        compute_type=args.compute_type,
                        # Citation repair must preserve quiet lecture tails;
                        # the primary ElevenLabs result already performs its
                        # own speech segmentation.  The explicit local-only
                        # backend keeps its normal VAD setting below.
                        vad_filter=False,
                        recover_timestamps=True,
                    ),
                )
            else:
                transcriber = primary
        else:
            transcriber = WhisperTranscriber(model=args.model, device=args.device,
                                             compute_type=args.compute_type)
        worker = Worker(args.root, transcriber, publisher=publisher,
                        settings=settings, publication_key=publication_key,
                        professor_speakers=professor_speakers,
                        automatic_repair=args.automatic_repair,
                        max_automatic_repairs=args.max_automatic_repairs,
                        quality_override=args.allow_quality_publish,
                        # A foreground/manual ``once`` command should remain
                        # an explicit immediate retry.  The long-running
                        # watcher persists and honors exponential retry
                        # windows for hosted STT/Drive outages.
                        respect_retry_after=args.mode == "watch")
        if args.mode == "reprocess":
            result = worker.reprocess_archived(
                filename=args.filename,
                job_id=args.job_id,
                dry_run=args.dry_run,
                backup_dir=args.backup_dir,
            )
            logging.info(
                "Reprocess status=%s filename=%s job_id=%s archive=%s backup=%s",
                result.status,
                result.filename,
                result.job_id,
                result.archive,
                result.backup_path or "none",
            )
            return 0
        if args.mode == "watch":
            from .watching import watch

            watch(worker, args.reconcile_seconds)
            return 0
        report = worker.run_once()
        logging.info("Processed=%s skipped=%s pending=%s quality_blocked=%s failures=%s",
                     report.processed, report.skipped, report.pending,
                     report.quality_blocked, len(report.failures))
        return 1 if report.failures else 0
    except KeyboardInterrupt:
        return 130
    except Exception:
        logging.exception("LCP worker failed")
        return 1
