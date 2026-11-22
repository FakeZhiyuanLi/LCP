"""Verified local file operations; synced inputs are always read-only."""

import hashlib
import json
import os
import stat
import tempfile
from pathlib import Path
from typing import Any, BinaryIO


class UnsafePath(ValueError):
    pass


def ensure_directory(path: Path) -> None:
    """Create a managed directory without accepting a symlink in its place."""
    try:
        path.mkdir()
    except FileExistsError:
        pass
    if not stat.S_ISDIR(path.lstat().st_mode):
        raise UnsafePath(f"Not a real directory: {path}")


def open_regular(path: Path) -> BinaryIO:
    descriptor = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
    try:
        if not stat.S_ISREG(os.fstat(descriptor).st_mode):
            raise UnsafePath(f"Not a regular file: {path}")
        return os.fdopen(descriptor, "rb")
    except BaseException:
        os.close(descriptor)
        raise


def fingerprint(path: Path) -> tuple[int, str]:
    digest = hashlib.sha256()
    size = 0
    with open_regular(path) as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            size += len(chunk)
            digest.update(chunk)
    return size, digest.hexdigest()


def sync_directory(directory: Path) -> None:
    descriptor = os.open(directory, os.O_RDONLY | os.O_DIRECTORY)
    try:
        os.fsync(descriptor)
    finally:
        os.close(descriptor)


def atomic_bytes(path: Path, content: bytes) -> None:
    descriptor, temporary = tempfile.mkstemp(prefix=".lcp-", dir=path.parent)
    try:
        with os.fdopen(descriptor, "wb") as target:
            target.write(content)
            target.flush()
            os.fsync(target.fileno())
        os.replace(temporary, path)
        sync_directory(path.parent)
    finally:
        Path(temporary).unlink(missing_ok=True)


def atomic_json(path: Path, content: dict[str, Any]) -> None:
    atomic_bytes(path, (json.dumps(content, sort_keys=True, indent=2, allow_nan=False) + "\n").encode())


def read_json(path: Path, limit: int = 16 * 1024 * 1024) -> Any:
    with open_regular(path) as source:
        content = source.read(limit + 1)
    if len(content) > limit:
        raise ValueError(f"JSON document too large: {path}")
    return json.loads(content)


def copy_verified(source: Path, destination: Path, expected: tuple[int, str]) -> None:
    """Copy to independent storage and compare the actual copied bytes."""
    descriptor, temporary = tempfile.mkstemp(prefix=".lcp-copy-", dir=destination.parent)
    digest = hashlib.sha256()
    size = 0
    try:
        with os.fdopen(descriptor, "wb") as target, open_regular(source) as audio:
            for chunk in iter(lambda: audio.read(1024 * 1024), b""):
                target.write(chunk)
                size += len(chunk)
                digest.update(chunk)
            target.flush()
            os.fsync(target.fileno())
        if (size, digest.hexdigest()) != expected:
            raise ValueError("Recording does not match its completion manifest")
        os.replace(temporary, destination)
        sync_directory(destination.parent)
    finally:
        Path(temporary).unlink(missing_ok=True)


def archive_verified(source: Path, destination: Path, expected: tuple[int, str]) -> None:
    """Publish an archive without ever replacing an existing, different file."""
    if destination.exists() or destination.is_symlink():
        if fingerprint(destination) != expected:
            raise ValueError(f"Archive collision or corruption: {destination}")
        return
    descriptor, temporary = tempfile.mkstemp(prefix=".lcp-archive-", dir=destination.parent)
    os.close(descriptor)
    temporary_path = Path(temporary)
    try:
        copy_verified(source, temporary_path, expected)
        try:
            os.link(temporary_path, destination)
            sync_directory(destination.parent)
        except FileExistsError:
            pass
        if fingerprint(destination) != expected:
            raise ValueError(f"Archive collision or corruption: {destination}")
    finally:
        temporary_path.unlink(missing_ok=True)
