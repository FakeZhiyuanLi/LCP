"""Explicit recorder-finalization contract shared with the macOS client."""

import re
import unicodedata
from dataclasses import dataclass
from datetime import datetime
from pathlib import Path

from .filesystem import read_json

SUFFIX = ".m4a.ready.json"
FILENAME = re.compile(r"(?P<course>.+)_(?P<date>[0-9]{4}-[0-9]{2}-[0-9]{2})_(?P<time>[0-9]{4})\.m4a")


def is_safe_course_component(course: str) -> bool:
    """Return whether *course* is safe in a filename and Drive path.

    Drive folder names are the source of truth for the class picker and may
    contain spaces (for example, ``"PHIL 102"``).  Keep the character policy
    deliberately narrow so a class name can never introduce a path component,
    another rclone remote, or a control character.  Unicode letters, marks,
    and numbers are preserved, as are spaces, ``_`` and ``-``.
    """
    if not isinstance(course, str) or not course or course != course.strip():
        return False
    if course in {".", ".."}:
        return False
    allowed_separators = {" ", "_", "-"}
    for character in course:
        if character in allowed_separators:
            continue
        category = unicodedata.category(character)
        if category.startswith(("L", "M", "N")):
            continue
        return False
    return True


@dataclass(frozen=True)
class RecordingManifest:
    filename: str
    size_bytes: int
    sha256: str
    course: str
    captured_at: datetime  # Local wall time from the client filename, not UTC.

    @property
    def expected(self) -> tuple[int, str]:
        return self.size_bytes, self.sha256


def load_manifest(path: Path, inbox: Path) -> RecordingManifest:
    if path.parent != inbox or not path.name.endswith(SUFFIX):
        raise ValueError("Completion marker must be directly inside the inbox")
    data = read_json(path, limit=64 * 1024)
    return manifest_from_data(data, marker_name=path.name)


def manifest_from_data(data: object, marker_name: str | None = None) -> RecordingManifest:
    """Validate both received and durably accepted completion metadata."""
    if not isinstance(data, dict) or type(data.get("version")) is not int or data["version"] != 1:
        raise ValueError("Unsupported completion manifest version")
    name = data.get("filename")
    if (not isinstance(name, str) or Path(name).name != name
            or (marker_name is not None and marker_name != f"{name}.ready.json")):
        raise ValueError("Manifest filename does not match its marker basename")
    match = FILENAME.fullmatch(name)
    if match is None:
        raise ValueError("Expected <COURSE>_yyyy-MM-dd_HHmm.m4a")
    if not is_safe_course_component(match["course"]):
        raise ValueError(
            "Course name requires letters, marks, numbers, spaces, underscores, or hyphens"
        )
    try:
        captured_at = datetime.strptime(f"{match['date']}_{match['time']}", "%Y-%m-%d_%H%M")
    except ValueError as error:
        raise ValueError("Invalid capture date/time") from error
    size = data.get("size_bytes")
    digest = data.get("sha256")
    if type(size) is not int or size <= 0:
        raise ValueError("Manifest size_bytes must be a positive integer")
    if not isinstance(digest, str) or not re.fullmatch(r"[a-fA-F0-9]{64}", digest):
        raise ValueError("Manifest sha256 must contain 64 hexadecimal characters")
    return RecordingManifest(name, size, digest.lower(), match["course"], captured_at)
