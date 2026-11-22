"""Generate a local class catalog from the configured Google Drive root.

The macOS client must remain network-free.  A rack-side job runs this module,
writes the resulting JSON atomically, and exposes that file through a separate
server-to-Mac Syncthing folder.  The catalog is deliberately independent from
the transcript worker so a temporary Drive outage cannot replace a good local
snapshot with an empty one.
"""

from __future__ import annotations

import json
import math
import re
import subprocess
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path
from typing import Any, Callable

from .filesystem import atomic_json, ensure_directory
from .manifest import is_safe_course_component


class CatalogError(RuntimeError):
    """The Drive class catalog could not be read or validated."""


@dataclass(frozen=True)
class DriveClass:
    """One immediate child folder of the configured Drive root."""

    name: str
    folder_id: str


class DriveClassCatalog:
    """Read and atomically publish the immediate Drive class folders."""

    # This folder is a separate publication destination for synthetic and
    # manual transport tests. It must never become a selectable production
    # class merely because it is a child of the School Lectures root.
    RESERVED_TEST_FOLDER_NAME = "LCP Test"

    def __init__(
        self,
        remote: str,
        root_folder_id: str,
        executable: str = "rclone",
        *,
        timeout: float = 120.0,
        runner: Callable[..., subprocess.CompletedProcess[bytes]] | None = None,
        include_test_folder: bool = False,
    ) -> None:
        if not re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*:?", remote):
            raise ValueError("remote must name a configured rclone remote without a path")
        if not isinstance(root_folder_id, str) or not re.fullmatch(
            r"[A-Za-z0-9_-]+", root_folder_id
        ):
            raise ValueError("The root Drive folder ID must be a nonempty Google Drive folder ID")
        if not executable or not math.isfinite(timeout) or timeout <= 0:
            raise ValueError("rclone requires an executable and a finite positive timeout")
        if not isinstance(include_test_folder, bool):
            raise ValueError("include_test_folder must be a boolean")
        self.remote = remote.rstrip(":")
        self.root_folder_id = root_folder_id
        self.executable = executable
        self.timeout = timeout
        self._runner = runner or subprocess.run
        self.include_test_folder = include_test_folder

    def list_classes(self) -> tuple[DriveClass, ...]:
        """Return validated immediate child folders in stable display order."""
        payload = self._run(
            [f"{self.remote}:", "--dirs-only", "--max-depth", "1"]
        )
        try:
            decoded = json.loads(payload)
        except (TypeError, UnicodeError, ValueError) as error:
            raise CatalogError("rclone returned invalid Drive folder JSON") from error
        if not isinstance(decoded, list):
            raise CatalogError("rclone Drive folder listing must be a JSON array")

        folders: list[DriveClass] = []
        seen_names: set[str] = set()
        seen_ids: set[str] = set()
        for item in decoded:
            if not isinstance(item, dict) or item.get("IsDir") is not True:
                continue
            name = item.get("Name")
            if (
                not self.include_test_folder
                and isinstance(name, str)
                and name.casefold() == self.RESERVED_TEST_FOLDER_NAME.casefold()
            ):
                continue
            folder_id = item.get("ID")
            if not isinstance(name, str) or not is_safe_course_component(name):
                raise CatalogError("Drive contains a class folder with an unsafe name")
            if not isinstance(folder_id, str) or not re.fullmatch(
                r"[A-Za-z0-9_-]+", folder_id
            ):
                raise CatalogError("Drive returned a class folder without a valid ID")
            name_key = name.casefold()
            if name_key in seen_names:
                raise CatalogError("Drive contains duplicate class names")
            if folder_id in seen_ids:
                raise CatalogError("Drive returned duplicate class folder IDs")
            seen_names.add(name_key)
            seen_ids.add(folder_id)
            folders.append(DriveClass(name=name, folder_id=folder_id))
        folders.sort(key=lambda folder: (folder.name.casefold(), folder.name))
        return tuple(folders)

    def write(self, output: Path) -> dict[str, Any]:
        """Write a versioned catalog atomically and return its JSON object.

        Drive is queried and validated completely before the destination is
        replaced.  A failed refresh therefore leaves the previously synced
        catalog intact for the client to use or mark stale.
        """
        classes = self.list_classes()
        manifest: dict[str, Any] = {
            "version": 1,
            "source": "google_drive",
            "generated_at": datetime.now(timezone.utc).isoformat().replace("+00:00", "Z"),
            "root_folder_id": self.root_folder_id,
            "classes": [
                {
                    "name": folder.name,
                    "course_code": folder.name,
                    "drive_folder_id": folder.folder_id,
                }
                for folder in classes
            ],
        }
        destination = Path(output)
        destination.parent.mkdir(parents=True, exist_ok=True)
        ensure_directory(destination.parent)
        atomic_json(destination, manifest)
        return manifest

    def _run(self, arguments: list[str]) -> bytes:
        command = [
            self.executable,
            "lsjson",
            *arguments,
            "--drive-root-folder-id",
            self.root_folder_id,
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
            raise CatalogError("rclone Drive folder listing exceeded its command timeout") from None
        except OSError:
            raise CatalogError(
                "Cannot execute rclone; verify its server-side executable and Drive authorization"
            ) from None
        if result.returncode != 0:
            raise CatalogError(
                f"rclone Drive folder listing failed with exit status {result.returncode}"
            )
        return result.stdout
