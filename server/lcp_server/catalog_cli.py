"""Command-line entry point for the rack-side Drive class catalog refresh."""

from __future__ import annotations

import argparse
import logging
from pathlib import Path
from typing import Sequence

from .catalog import DriveClassCatalog


def parser() -> argparse.ArgumentParser:
    result = argparse.ArgumentParser(
        description="Publish Google Drive class folders as a local LCP catalog"
    )
    result.add_argument("--output", type=Path, required=True)
    result.add_argument("--remote", default="gdrive")
    result.add_argument("--drive-root-folder-id", required=True)
    result.add_argument("--rclone", default="rclone")
    result.add_argument(
        "--include-test-folder",
        action="store_true",
        help=(
            "Include the reserved 'LCP Test' Drive folder; use only when "
            "generating an explicitly isolated test catalog (excluded by default)"
        ),
    )
    result.add_argument("--verbose", action="store_true")
    return result


def main(argv: Sequence[str] | None = None) -> int:
    args = parser().parse_args(argv)
    logging.basicConfig(
        level=logging.DEBUG if args.verbose else logging.INFO,
        format="%(asctime)s %(levelname)s %(name)s: %(message)s",
    )
    try:
        manifest = DriveClassCatalog(
            remote=args.remote,
            root_folder_id=args.drive_root_folder_id,
            executable=args.rclone,
            include_test_folder=args.include_test_folder,
        ).write(args.output)
        logging.info("Published %d Drive class folders to %s", len(manifest["classes"]), args.output)
        return 0
    except KeyboardInterrupt:
        return 130
    except Exception:
        logging.exception("Drive class catalog refresh failed")
        return 1
