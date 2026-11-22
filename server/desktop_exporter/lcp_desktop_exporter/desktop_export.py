"""Bounded, read-only accepted-transcript export; Python standard library only.

Source access is limited to heads.json, inbox completion metadata and ONLY the
jobs selected by valid accepted heads. Never reads audio, vault, worker locks,
provider controls or historical jobs. All mutations are below an independent
output root. Errors never echo private JSON, transcript text or source paths.
"""

from __future__ import annotations

import argparse
import contextlib
import fcntl
import hashlib
import json
import math
import os
from pathlib import Path
import re
import stat
import sys
import unicodedata
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone

from ._models import AudioEvent, Segment, Transcript
from ._quality import assess_transcript


class ExportError(Exception):
    """A deliberately non-sensitive error code."""


@dataclass(frozen=True)
class Bounds:
    heads_bytes: int = 4 * 1024 * 1024
    job_bytes: int = 16 * 1024 * 1024
    marker_bytes: int = 64 * 1024
    payload_bytes: int = 16 * 1024 * 1024
    index_bytes: int = 4 * 1024 * 1024
    total_read_bytes: int = 128 * 1024 * 1024
    generation_bytes: int = 128 * 1024 * 1024
    retained_bytes: int = 512 * 1024 * 1024
    retained_files: int = 10000
    recordings: int = 2000
    directory_entries: int = 10000
    cues: int = 20000
    events: int = 20000
    text_bytes: int = 16384
    audio_size: int = 2 * 1024 * 1024 * 1024
    duration_seconds: int = 24 * 60 * 60


HEX = re.compile(r"[a-f0-9]{64}")
JOB = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,127}")
NAME = re.compile(r"(.+)_([0-9]{4}-[0-9]{2}-[0-9]{2})_([0-9]{4})\.m4a")
STATUS_KEYS = {"server_received", "processing", "quality", "drive_publication", "external_ingestion"}
RECORD_KEYS = {"filename", "size_bytes", "sha256", "accepted_job_id", "status", "transcript"}
PAYLOAD_KEYS = {"schema_version", "filename", "size_bytes", "sha256", "accepted_job_id", "cues", "audio_events", "generated_at"}
INDEX_KEYS = {"schema_version", "generation_id", "exported_at", "producer", "complete", "recordings", "retirements"}


def require(condition, code="invalid_metadata"):
    if not condition:
        raise ExportError(code)


def encoded(value):
    return (json.dumps(value, ensure_ascii=False, sort_keys=True, separators=(",", ":"), allow_nan=False) + "\n").encode("utf-8")


def digest(data):
    return hashlib.sha256(data).hexdigest()


def _pairs(items):
    result = {}
    for key, value in items:
        require(key not in result, "duplicate_json_key")
        result[key] = value
    return result


def decoded(data):
    try:
        def reject(_):
            raise ExportError("nonfinite_json")
        return json.loads(data.decode("utf-8"), object_pairs_hook=_pairs, parse_constant=reject)
    except (UnicodeError, ValueError, RecursionError):
        raise ExportError("invalid_json") from None


def utc_now():
    return datetime.now(timezone.utc).isoformat(timespec="microseconds").replace("+00:00", "Z")


def utc_stamp(value):
    require(isinstance(value, str) and value.endswith("Z"))
    try:
        require(datetime.fromisoformat(value.replace("Z", "+00:00")).utcoffset().total_seconds() == 0)
    except (ValueError, AttributeError):
        raise ExportError("invalid_timestamp") from None


def source_identity(value, bounds, manifest=False):
    require(isinstance(value, dict))
    if manifest:
        require(type(value.get("version")) is int and value["version"] == 1)
    name, size, sha = (value.get(k) for k in ("filename", "size_bytes", "sha256"))
    require(isinstance(name, str) and len(name.encode("utf-8")) <= 240)
    match = NAME.fullmatch(name)
    require(match is not None, "unsafe_filename")
    course = match[1]
    require(course == course.strip() and all(c in " _-" or unicodedata.category(c)[0] in "LMN" for c in course), "unsafe_filename")
    try:
        datetime.strptime(match[2] + "_" + match[3], "%Y-%m-%d_%H%M")
    except ValueError:
        raise ExportError("invalid_capture_time") from None
    require(type(size) is int and 0 < size <= bounds.audio_size)
    require(isinstance(sha, str) and HEX.fullmatch(sha) is not None)
    return {"filename": name, "size_bytes": size, "sha256": sha}


def key_for(value):
    return tuple(value[k] for k in ("filename", "size_bytes", "sha256"))


def absolute(path):
    p = Path(path).absolute()
    require(".." not in p.parts, "unsafe_root")
    return p


def stamp(info):
    return (info.st_dev, info.st_ino, info.st_mode, info.st_size, info.st_mtime_ns, info.st_ctime_ns)


class Tree:
    """Directory-descriptor anchored reads/writes, rejecting every symlink hop."""

    def __init__(self, path, bounds, *, writable=False):
        self.path = absolute(path)
        self.bounds = bounds
        self.read_bytes = 0
        # Linux O_PATH traverses ancestors without granting directory-listing
        # access to their entire subtrees under Landlock. macOS keeps the
        # original directory-descriptor behavior. Writable directories need
        # ordinary descriptors for fsync; source descriptors never need fsync.
        self.directory_flags = os.O_RDONLY if writable else getattr(os, "O_PATH", os.O_RDONLY)
        self.fd = os.open("/", getattr(os, "O_PATH", os.O_RDONLY) | os.O_DIRECTORY)
        try:
            for component in self.path.parts[1:]:
                nxt = os.open(component, getattr(os, "O_PATH", os.O_RDONLY) | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=self.fd)
                os.close(self.fd)
                self.fd = nxt
            if writable:
                nxt = os.open(".", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=self.fd)
                os.close(self.fd)
                self.fd = nxt
        except BaseException:
            os.close(self.fd)
            raise

    def close(self):
        os.close(self.fd)

    @contextlib.contextmanager
    def parent(self, relative):
        parts = relative.split("/")
        require(all(p not in {"", ".", ".."} and "\\" not in p and "\x00" not in p for p in parts), "unsafe_path")
        fd = os.dup(self.fd)
        try:
            for part in parts[:-1]:
                nxt = os.open(part, self.directory_flags | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
                os.close(fd)
                fd = nxt
            yield fd, parts[-1]
        finally:
            os.close(fd)

    def read(self, relative, limit, missing=False, charged=True):
        try:
            with self.parent(relative) as (fd, name):
                file_fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=fd)
                with os.fdopen(file_fd, "rb") as file:
                    before = os.fstat(file.fileno())
                    require(stat.S_ISREG(before.st_mode) and before.st_nlink == 1, "unsafe_file")
                    require(before.st_size <= limit, "file_too_large")
                    data = file.read(limit + 1)
                    require(len(data) <= limit, "file_too_large")
                    require(stamp(os.fstat(file.fileno())) == stamp(before), "source_mutated")
                    require(stamp(os.stat(name, dir_fd=fd, follow_symlinks=False)) == stamp(before), "source_mutated")
            if charged:
                self.read_bytes += len(data)
                require(self.read_bytes <= self.bounds.total_read_bytes, "read_budget_exceeded")
            return data, stamp(before)
        except FileNotFoundError:
            if missing:
                return None
            raise ExportError("required_file_missing") from None

    def entries(self, relative):
        # Names only; audio and historical jobs are never opened or statted.
        with self.parent(relative + "/placeholder") as (fd, _):
            readable = os.open(".", os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            try:
                with os.scandir(readable) as it:
                    names = []
                    for entry in it:
                        names.append(entry.name)
                        require(len(names) <= self.bounds.directory_entries, "directory_too_large")
            finally:
                os.close(readable)
        return sorted(names)

    def ensure_dir(self, name):
        require("/" not in name and name not in {"", ".", ".."})
        try:
            os.mkdir(name, mode=0o700, dir_fd=self.fd)
            os.fsync(self.fd)
        except FileExistsError:
            pass
        with self.parent(name + "/placeholder"):
            pass

    def write(self, relative, data, immutable=False):
        with self.parent(relative) as (fd, name):
            temp = ".desktop-" + uuid.uuid4().hex + ".tmp"
            file_fd = os.open(temp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600, dir_fd=fd)
            try:
                with os.fdopen(file_fd, "wb") as file:
                    file.write(data)
                    file.flush()
                    os.fsync(file.fileno())
                if immutable:
                    try:
                        os.link(temp, name, src_dir_fd=fd, dst_dir_fd=fd, follow_symlinks=False)
                    except FileExistsError:
                        require(self.read(relative, len(data), charged=False)[0] == data, "immutable_payload_conflict")
                else:
                    # Refuse a non-regular destination even though replace would
                    # replace the symlink itself rather than follow it.
                    try:
                        require(stat.S_ISREG(os.stat(name, dir_fd=fd, follow_symlinks=False).st_mode), "unsafe_output")
                    except FileNotFoundError:
                        pass
                    os.replace(temp, name, src_dir_fd=fd, dst_dir_fd=fd)
                os.fsync(fd)
            finally:
                try:
                    os.unlink(temp, dir_fd=fd)
                    os.fsync(fd)
                except FileNotFoundError:
                    pass


class Snapshot:
    def __init__(self, tree):
        self.tree = tree
        self.files = {}
        self.directories = {}

    def read(self, relative, limit, missing=False):
        value = self.tree.read(relative, limit, missing)
        self.files[relative] = (value, limit)
        return decoded(value[0]) if value else None

    def entries(self, relative):
        value = self.tree.entries(relative)
        self.directories[relative] = value
        return value

    def verify(self):
        # Read exactly the same bounded metadata bytes again, including absence
        # and file identity, after every payload is durable and before index commit.
        for relative, (before, limit) in self.files.items():
            require(self.tree.read(relative, limit, missing=True) == before, "source_mutated")
        for relative, before in self.directories.items():
            require(self.tree.entries(relative) == before, "source_mutated")
        # Reject a renamed/replaced source root as well as child mutations.
        current = Tree(self.tree.path, self.tree.bounds)
        try:
            require(os.fstat(current.fd).st_ino == os.fstat(self.tree.fd).st_ino and os.fstat(current.fd).st_dev == os.fstat(self.tree.fd).st_dev, "source_mutated")
        finally:
            current.close()


def finite(value, bounds):
    require(type(value) in (float, int) and 0 <= value <= bounds.duration_seconds, "invalid_timing")
    require(math.isfinite(value), "invalid_timing")
    return value


def text_value(value, bounds, limit=None):
    require(isinstance(value, str) and bool(value.strip()), "invalid_text")
    require(len(value.encode("utf-8")) <= (limit or bounds.text_bytes), "text_too_large")
    require(not any(unicodedata.category(c) == "Cc" and c not in "\n\t\r" for c in value), "invalid_text")
    return value


def transcript(value, bounds):
    require(isinstance(value, dict), "invalid_transcript")
    duration = finite(value.get("duration"), bounds)
    require(duration > 0, "invalid_timing")
    cues, events = value.get("segments"), value.get("audio_events", [])
    require(isinstance(cues, list) and len(cues) <= bounds.cues, "invalid_cues")
    require(isinstance(events, list) and len(events) <= bounds.events, "invalid_events")
    segments, audio_events, end = [], [], 0
    for cue in cues:
        require(isinstance(cue, dict), "invalid_cue")
        start, stop = finite(cue.get("start"), bounds), finite(cue.get("end"), bounds)
        require(start >= end and stop > start and stop <= duration, "invalid_timing")
        speaker = cue.get("speaker")
        if speaker is not None:
            text_value(speaker, bounds, 128)
            require(re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]*", speaker) is not None, "invalid_speaker")
        segments.append(Segment(start, stop, text_value(cue.get("text"), bounds), speaker))
        end = stop
    for event in events:
        require(isinstance(event, dict) and set(event) == {"start", "end", "text", "type"} and event["type"] == "audio_event", "invalid_event")
        start, stop = finite(event.get("start"), bounds), finite(event.get("end"), bounds)
        require(stop > start and stop <= duration, "invalid_timing")
        audio_events.append(AudioEvent(start, stop, text_value(event.get("text"), bounds)))
    require(segments or audio_events, "empty_transcript")
    return Transcript(duration, tuple(segments), audio_events=tuple(audio_events))


def status(processing="unknown", quality="unknown", drive="unknown", received=True):
    return {"server_received": received, "processing": processing, "quality": quality, "drive_publication": drive, "external_ingestion": "unknown"}


def select(snapshot, bounds):
    heads = snapshot.read("state/heads.json", bounds.heads_bytes)
    require(isinstance(heads, dict) and len(heads) <= bounds.recordings, "invalid_heads")
    markers = {}
    for name in snapshot.entries("inbox"):
        if not name.endswith(".m4a.ready.json"):
            continue
        marker = snapshot.read("inbox/" + name, bounds.marker_bytes)
        identity = source_identity(marker, bounds, manifest=True)
        require(name == identity["filename"] + ".ready.json", "marker_name_mismatch")
        markers[identity["filename"]] = identity
    require(len(set(markers) | set(heads)) <= bounds.recordings, "too_many_recordings")
    records, contents = [], {}
    for name in sorted(set(markers) | set(heads)):
        head = heads.get(name)
        if head is None:
            identity = markers[name]
            records.append({**identity, "accepted_job_id": None, "status": status("unaccepted", received=False), "transcript": None})
            continue
        require(isinstance(head, dict), "invalid_head")
        identity = source_identity(head.get("manifest"), bounds, manifest=True)
        require(identity["filename"] == name, "head_name_mismatch")
        head_identity = head.get("identity")
        require(source_identity(head_identity, bounds) == identity, "head_identity_mismatch")
        job = head.get("job_id")
        # Job IDs remain opaque. No settings hashing or current-settings filter.
        require(isinstance(job, str) and JOB.fullmatch(job) is not None and ".." not in job, "unsafe_job_id")
        marker = markers.get(name)
        record = {**identity, "accepted_job_id": job, "status": status("inconsistent"), "transcript": None}
        if marker is not None and marker != identity:
            records.append({**marker, "accepted_job_id": None, "status": status("unaccepted", received=False), "transcript": None})
            continue
        records.append(record)
        # A missing finalization marker cannot authorize transcript disclosure.
        if marker is None:
            continue
        state = snapshot.read("state/jobs/" + job + ".json", bounds.job_bytes, missing=True)
        if not isinstance(state, dict) or state.get("identity") != head_identity or type(state.get("version")) is not int or state["version"] != 1 or state.get("superseded_by"):
            continue
        if source_identity(state["identity"], bounds) != identity:
            continue
        stage = state.get("stage")
        drive = "published" if state.get("published") is True else "not_published" if state.get("published") is False else "unknown"
        processing = stage if stage in {"published", "local_ready", "quality_blocked", "transcribed", "archived", "accepted", "processing"} else "unknown"
        if state.get("last_error"):
            processing = "error"
        record["status"] = status(processing, drive=drive)
        if state.get("transcript") is None:
            continue
        try:
            parsed = transcript(state["transcript"], bounds)
            quality = assess_transcript(parsed)
        except (ExportError, ValueError, TypeError, KeyError, OverflowError):
            record["status"]["quality"] = "invalid"
            continue
        cached = state.get("quality")
        blocked = (state.get("publication_blocked") is True or stage == "quality_blocked"
                   or not quality.publication_allowed
                   or (isinstance(cached, dict) and (cached.get("blocking") is True or cached.get("publishable") is False
                       or cached.get("publication_allowed") is False or cached.get("status") == "blocked"
                       or cached.get("relevance_status", cached.get("relevance")) in {"needs_review", "likely_accidental"})))
        record["status"]["quality"] = "blocked" if blocked else "unknown"
        if blocked or state.get("last_error") or stage not in {"published", "local_ready"}:
            continue
        record["status"]["quality"] = "eligible"
        contents[key_for(identity)] = {
            "schema_version": 1, **identity, "accepted_job_id": job,
            "cues": [{"start": s.start, "end": s.end, "text": s.text, "speaker": s.speaker} for s in parsed.segments],
            "audio_events": [{"start": e.start, "end": e.end, "text": e.text} for e in parsed.audio_events],
        }
    return records, contents


def previous_index(output, bounds):
    previous = output.read("index.json", bounds.index_bytes, missing=True, charged=False)
    if previous is None:
        return None, {}
    value = decoded(previous[0])
    require(isinstance(value, dict) and set(value) == INDEX_KEYS and value.get("complete") is True and type(value.get("schema_version")) is int and value["schema_version"] == 1, "invalid_previous_index")
    require(isinstance(value["generation_id"], str) and 0 < len(value["generation_id"]) <= 128)
    require(isinstance(value["producer"], dict) and set(value["producer"]) == {"id", "environment"})
    require(isinstance(value["recordings"], list) and len(value["recordings"]) <= bounds.recordings)
    require(isinstance(value["retirements"], list) and len(value["retirements"]) <= bounds.recordings)
    utc_stamp(value["exported_at"])
    seen, reusable = set(), {}
    for record in value["recordings"]:
        require(isinstance(record, dict) and set(record) == RECORD_KEYS)
        ident = source_identity(record, bounds)
        key = key_for(ident)
        require(key not in seen)
        seen.add(key)
        require(record["accepted_job_id"] is None or (isinstance(record["accepted_job_id"], str) and JOB.fullmatch(record["accepted_job_id"]) is not None))
        require(isinstance(record["status"], dict) and set(record["status"]) == STATUS_KEYS)
        ref = record["transcript"]
        if ref is None:
            continue
        require(isinstance(ref, dict) and set(ref) == {"path", "sha256", "size_bytes", "accepted_job_id"})
        sha, size = ref["sha256"], ref["size_bytes"]
        require(isinstance(sha, str) and HEX.fullmatch(sha) is not None and ref["path"] == "payloads/" + sha + ".json", "unsafe_payload_path")
        require(type(size) is int and 0 < size <= bounds.payload_bytes and ref["accepted_job_id"] == record["accepted_job_id"])
        data = output.read(ref["path"], bounds.payload_bytes, charged=True)[0]
        require(len(data) == size and digest(data) == sha, "previous_payload_corrupt")
        payload = decoded(data)
        require(isinstance(payload, dict) and set(payload) == PAYLOAD_KEYS and type(payload["schema_version"]) is int and payload["schema_version"] == 1)
        require(source_identity(payload, bounds) == ident and payload["accepted_job_id"] == record["accepted_job_id"])
        utc_stamp(payload["generated_at"])
        reusable[key] = (payload, data)
    for retirement in value["retirements"]:
        require(isinstance(retirement, dict) and set(retirement) == {"filename", "size_bytes", "sha256", "reason"})
        source_identity(retirement, bounds)
        require(retirement["reason"] in {"source_replaced", "no_longer_present"})
    return value, reusable


def storage_budget(output, new_payloads, bounds):
    names = output.entries("payloads")
    count, size = len(names), 0
    with output.parent("payloads/placeholder") as (fd, _):
        for name in names:
            # A crash orphan is safe but consumes the same finite storage budget.
            require(re.fullmatch(r"[a-f0-9]{64}\.json|\.desktop-[a-f0-9]{32}\.tmp", name) is not None, "unexpected_payload_file")
            info = os.stat(name, dir_fd=fd, follow_symlinks=False)
            require(stat.S_ISREG(info.st_mode) and info.st_nlink == 1, "unsafe_output")
            size += info.st_size
    for path, data in new_payloads:
        if path.removeprefix("payloads/") not in names:
            count += 1
            size += len(data)
    require(count <= bounds.retained_files and size <= bounds.retained_bytes, "retention_limit_reached")


def export_feed(source_root, output_root, producer_id="lcp-desktop-exporter", environment="self-hosted", *, bounds=None, checkpoint=None):
    """Export one complete generation; hook is solely for synthetic crash tests."""
    bounds = bounds or Bounds()
    source_path, output_path = absolute(source_root), absolute(output_root)
    require(source_path != output_path and source_path not in output_path.parents and output_path not in source_path.parents, "roots_overlap")
    for value in (producer_id, environment):
        require(isinstance(value, str) and re.fullmatch(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,127}", value) is not None, "invalid_producer")
    source, output = None, None
    lock_fd = None
    try:
        source = Tree(source_path, bounds)
        output = Tree(output_path, bounds, writable=True)
        require((os.fstat(source.fd).st_dev, os.fstat(source.fd).st_ino) != (os.fstat(output.fd).st_dev, os.fstat(output.fd).st_ino), "roots_overlap")
        require(os.fstat(output.fd).st_uid == os.getuid() and stat.S_IMODE(os.fstat(output.fd).st_mode) & 0o077 == 0, "output_not_private")
        lock_fd = os.open(".export.lock", os.O_WRONLY | os.O_CREAT | os.O_NOFOLLOW | os.O_NONBLOCK, 0o600, dir_fd=output.fd)
        require(stat.S_ISREG(os.fstat(lock_fd).st_mode) and os.fstat(lock_fd).st_nlink == 1, "unsafe_lock")
        try:
            fcntl.flock(lock_fd, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise ExportError("export_already_running") from None
        output.ensure_dir("payloads")
        previous, reusable = previous_index(output, bounds)
        snapshot = Snapshot(source)
        records, contents = select(snapshot, bounds)
        when = utc_now()
        payloads, total_size = [], 0
        for record in records:
            key = key_for(record)
            body = contents.get(key)
            if body is None:
                continue
            prior = reusable.get(key)
            if prior and {k: v for k, v in prior[0].items() if k != "generated_at"} == body:
                data = prior[1]
            else:
                data = encoded({**body, "generated_at": when})
            require(len(data) <= bounds.payload_bytes, "payload_too_large")
            total_size += len(data)
            require(total_size <= bounds.generation_bytes, "generation_too_large")
            sha = digest(data)
            path = "payloads/" + sha + ".json"
            record["transcript"] = {"path": path, "sha256": sha, "size_bytes": len(data), "accepted_job_id": record["accepted_job_id"]}
            payloads.append((path, data))
        keys = {key_for(r) for r in records}
        names = {r["filename"] for r in records}
        retirements = []
        for record in previous["recordings"] if previous else []:
            if key_for(record) not in keys:
                retirements.append({**source_identity(record, bounds), "reason": "source_replaced" if record["filename"] in names else "no_longer_present"})
        # Keep tombstones across successful generations so an intermittently
        # connected client cannot miss a one-cycle retirement. Never prune data.
        retired = {key_for(r): r for r in retirements}
        for r in previous["retirements"] if previous else []:
            if key_for(r) not in keys:
                retired.setdefault(key_for(r), r)
        require(len(retired) <= bounds.recordings, "too_many_retirements")
        index = {"schema_version": 1, "generation_id": uuid.uuid4().hex, "exported_at": when,
                 "producer": {"id": producer_id, "environment": environment}, "complete": True,
                 "recordings": records, "retirements": sorted(retired.values(), key=key_for)}
        index_data = encoded(index)
        require(len(index_data) <= bounds.index_bytes, "index_too_large")
        require(len(index_data) + total_size <= bounds.generation_bytes, "generation_too_large")
        storage_budget(output, payloads, bounds)
        if checkpoint:
            checkpoint("selected")
        for path, data in payloads:
            output.write(path, data, immutable=True)
            # Resolve and hash the committed immutable file before referencing it.
            require(output.read(path, bounds.payload_bytes, charged=False)[0] == data, "payload_verification_failed")
            if checkpoint:
                checkpoint("payload_durable")
        snapshot.verify()
        # Also reject replacement of the output anchor before publishing index.
        current = Tree(output.path, bounds)
        try:
            require((os.fstat(current.fd).st_dev, os.fstat(current.fd).st_ino) == (os.fstat(output.fd).st_dev, os.fstat(output.fd).st_ino), "output_mutated")
        finally:
            current.close()
        if checkpoint:
            checkpoint("before_index")
        output.write("index.json", index_data)
        return {"generation_id": index["generation_id"], "recordings": len(records), "transcripts": len(payloads), "retirements": len(retired), "index_sha256": digest(index_data)}
    except OSError:
        raise ExportError("filesystem_access_failed") from None
    finally:
        if lock_fd is not None:
            os.close(lock_fd)
        if source is not None:
            source.close()
        if output is not None:
            output.close()


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--source-root", required=True, type=Path)
    parser.add_argument("--output-root", required=True, type=Path)
    parser.add_argument("--producer-id", default="lcp-desktop-exporter")
    parser.add_argument("--environment", default="self-hosted")
    args = parser.parse_args(argv)
    try:
        print(json.dumps(export_feed(args.source_root, args.output_root, args.producer_id, args.environment), sort_keys=True))
        return 0
    except ExportError as error:
        print("desktop_export_failed:" + str(error), file=sys.stderr)
        return 1
    except (ValueError, TypeError, KeyError, RecursionError, OverflowError):
        print("desktop_export_failed:invalid_metadata", file=sys.stderr)
        return 1


if __name__ == "__main__":
    raise SystemExit(main())
