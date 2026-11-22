"""Apply verified releases from one opted-in local checkout after LCP Desktop quits."""

import argparse
from contextlib import contextmanager
import ctypes
import fcntl
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile


SCRIPTS = Path(__file__).resolve().parent
ROOT = Path.home() / "Library/Application Support/LCP Desktop Updates"
LEASE = Path.home() / "Library/Application Support/LCP Capture/capture.lock"
LABEL = "org.lcp.desktop.local-updates"
PLIST = Path.home() / "Library/LaunchAgents" / (LABEL + ".plist")
DOMAIN = "gui/" + str(os.getuid())
APP = "LCP Desktop.app"
ARCHIVE = "LCPDesktop-arm64.zip"
PENDING = Path("queue/pending.json")


def require(condition, message):
    if not condition:
        raise ValueError(message)


def atomic_bytes(path, data):
    with tempfile.NamedTemporaryFile(dir=path.parent, delete=False) as tmp:
        try:
            tmp.write(data)
            tmp.flush()
            os.fsync(tmp.fileno())
        except BaseException:
            os.unlink(tmp.name)
            raise
    os.replace(tmp.name, path)


def write_json(path, value):
    atomic_bytes(path, (json.dumps(value, indent=2) + "\n").encode())


def read_json(path):
    return json.loads(path.read_bytes())


@contextmanager
def lock(path, nonblocking=False):
    fd = os.open(path, os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    try:
        require(stat.S_ISREG(os.fstat(fd).st_mode), f"Expected a regular lock file at {path}")
        flags = fcntl.LOCK_EX | (fcntl.LOCK_NB if nonblocking else 0)
        fcntl.flock(fd, flags)
        require(os.path.samestat(os.fstat(fd), path.lstat()), "Lock file changed during acquisition")
        yield
    finally:
        os.close(fd)


def sha(path):
    digest = hashlib.sha256()
    with path.open("rb") as source:
        for block in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(block)
    return digest.hexdigest()


def identity(app):
    require(app.is_dir() and not app.is_symlink(), f"Expected an installed app at {app}")
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    require(info.get("CFBundleIdentifier") == "org.lcp.Desktop" and
            info.get("CFBundleExecutable") == "LCPDesktop", "Expected an LCP Desktop bundle")
    build = info["CFBundleVersion"]
    require(isinstance(build, str) and re.fullmatch(r"[1-9][0-9]*", build), "Invalid desktop build number")
    return {"build": int(build), "version": info["CFBundleShortVersionString"]}


def signature(app):
    subprocess.run(["/usr/bin/codesign", "--verify", "--deep", "--strict", app], check=True)
    details = subprocess.run(["/usr/bin/codesign", "-dvvv", app], check=True, stderr=subprocess.PIPE).stderr
    match = re.search(rb"^CandidateCDHashFull sha256=([a-f0-9]{64})$", details, re.MULTILINE)
    require(match, "Expected a signed desktop code directory")
    return match[1].decode()


def running(app):
    # Use the executable path; a copy in another Applications folder is independent.
    wanted = app / "Contents/MacOS/LCPDesktop"
    listing = subprocess.check_output(["/bin/ps", "-axww", "-o", "comm="], text=True)
    for entry in listing.splitlines():
        candidate = Path(entry.strip())
        if candidate.name == wanted.name and (candidate == wanted or
                                               (candidate.is_file() and candidate.samefile(wanted))):
            return True
    return False


def exchange(left, right):
    rename = ctypes.CDLL(None, use_errno=True).renamex_np
    rename.argtypes = (ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint)
    if rename(os.fsencode(left), os.fsencode(right), 2):  # RENAME_SWAP
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), str(right))


def publish(release, root=ROOT, automatic=False, expected=None):
    config_path = root / "config.json"
    if automatic and not config_path.exists():
        return
    with lock(root / "update.lock"):
        config = read_json(config_path)
        if automatic and (not config["enabled"] or config["scripts"] != str(SCRIPTS)):
            return
        require(config["enabled"], "Enable local updates first.")
        manifest = read_json(release / "ReleaseManifest.json")
        require(manifest.get("distribution") == "personal local distribution" and
                manifest.get("architecture") == "arm64", "Choose a personal arm64 release packaged with --dmg.")
        meta = {"build": int(manifest["build"]), "version": manifest["version"]}
        checksum = manifest["artifacts"][ARCHIVE]
        require(re.fullmatch(r"[0-9a-f]{64}", checksum) and (expected is None or expected == checksum),
                "The packaged release digest changed.")
        installed = identity(Path(config["app"]))
        pending = read_json(root / PENDING) if (root / PENDING).exists() else None
        if meta["build"] < installed["build"] or (pending and meta["build"] < pending["build"]):
            return "Skipped older local release."
        if pending and pending["build"] == meta["build"]:
            require(pending["sha256"] == checksum, "A different update already uses this build number.")
            return f"Build {meta['build']} is already queued."
        with tempfile.TemporaryDirectory(dir=root) as tmp:
            stage = Path(tmp)
            archive = stage / ARCHIVE
            shutil.copyfile(release / ARCHIVE, archive)
            require(sha(archive) == checksum, "Release ZIP failed checksum verification.")
            candidate = unpack(archive, stage / "expanded", meta)
            code = signature(candidate)
            if installed["build"] == meta["build"]:
                require(installed == meta and signature(Path(config["app"])) == code,
                        "Installed release already has this build number with different contents.")
                return f"Build {meta['build']} is already installed."
            target_archive = root / (checksum + ".zip")
            os.replace(archive, target_archive)
            write_json(root / PENDING, {**meta, "sha256": checksum, "cdhash": code})
            if pending and pending["sha256"] != checksum:
                (root / (pending["sha256"] + ".zip")).unlink(missing_ok=True)
        return f"Queued LCP Desktop {meta['version']} for {config['app']}."


def unpack(archive, folder, meta):
    # Only our release format is accepted; it has a single, flat native bundle
    # and ditto's optional AppleDouble companions. It contains no symlinks.
    import zipfile
    with zipfile.ZipFile(archive) as package:
        for member in package.infolist():
            name = Path(member.filename)
            require(name.parts and name.parts[0] in (APP, "__MACOSX") and ".." not in name.parts and
                    not stat.S_ISLNK(member.external_attr >> 16), "Unexpected file in update archive.")
    subprocess.run(["/usr/bin/ditto", "-x", "-k", archive, folder], check=True)
    candidate = folder / APP
    require(identity(candidate) == meta, "Release and bundle versions differ.")
    return candidate


def apply(root=ROOT, capture=LEASE):
    with lock(root / "update.lock"):
        pending = root / PENDING
        if not pending.exists():
            return "No update queued."
        config = read_json(root / "config.json")
        require(config["enabled"], "Local updates are disabled.")
        dest = Path(config["app"])
        update = read_json(pending)
        meta = {k: update[k] for k in ("build", "version")}
        checksum = update["sha256"]
        require(re.fullmatch(r"[0-9a-f]{64}", checksum), "Invalid update archive digest.")
        archive = root / (checksum + ".zip")
        installed = identity(dest)
        if installed["build"] >= meta["build"]:
            if installed["build"] == meta["build"]:
                require(installed == meta and signature(dest) == update["cdhash"],
                        "Installed build number matches a different app signature.")
            result = "Already installed or superseded."
        elif running(dest):
            return "Waiting for LCP Desktop to quit."
        else:
            capture.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
            try:
                with lock(capture, nonblocking=True):
                    require(sha(archive) == checksum, "Queued ZIP failed checksum verification.")
                    predecessor = dest.stat()
                    signature(dest)
                    # Staging alongside the destination guarantees a same-volume exchange.
                    with tempfile.TemporaryDirectory(prefix=".lcp-desktop-update-", dir=dest.parent) as tmp:
                        staged = unpack(archive, Path(tmp), meta)
                        require(signature(staged) == update["cdhash"], "Staged app signature changed.")
                        require(os.path.samestat(predecessor, dest.lstat()), "Installed app changed during staging.")
                        if running(dest):
                            return "Waiting for LCP Desktop to quit."
                        exchange(staged, dest)
                        try:
                            require(signature(dest) == update["cdhash"], "Installed app verification failed.")
                        except BaseException:
                            exchange(staged, dest)
                            raise
            except BlockingIOError:
                return "Waiting for the lecture recording to finish."
            result = f"Installed LCP Desktop {meta['version']}."
        write_json(root / "last-update.json", {**meta, "app": str(dest), "result": result})
        pending.unlink()
        archive.unlink(missing_ok=True)
        return result


def enable(app):
    dest = app.expanduser().absolute()
    require(dest.name == APP and dest.parent in (Path("/Applications"), Path.home() / "Applications"),
            "Select the existing LCP Desktop.app in Applications.")
    identity(dest)
    signature(dest)
    require(os.access(dest.parent, os.W_OK | os.X_OK), f"Write access is needed to update {dest.parent}.")
    ROOT.mkdir(mode=0o700, parents=True, exist_ok=True)
    with lock(ROOT / "update.lock"):
        config = ROOT / "config.json"
        if config.exists() and (ROOT / PENDING).exists():
            require(read_json(config)["app"] == str(dest), "Finish the queued update before changing destinations.")
        (ROOT / "queue").mkdir(mode=0o700, exist_ok=True)
        worker = ROOT / "local_updates.py"
        atomic_bytes(worker, Path(__file__).read_bytes())
        spec = {"Label": LABEL, "ProgramArguments": ["/usr/bin/python3", "-I", str(worker), "apply"],
                "QueueDirectories": [str(ROOT / "queue")], "ThrottleInterval": 10,
                "StandardErrorPath": str(ROOT / "error.log")}
        PLIST.parent.mkdir(parents=True, exist_ok=True)
        atomic_bytes(PLIST, plistlib.dumps(spec))
        service = DOMAIN + "/" + LABEL
        if subprocess.run(["/bin/launchctl", "print", service], capture_output=True).returncode:
            subprocess.run(["/bin/launchctl", "enable", service], check=True)
            subprocess.run(["/bin/launchctl", "bootstrap", DOMAIN, PLIST], check=True)
        write_json(config, {"enabled": True, "app": str(dest), "scripts": str(SCRIPTS)})
    return f"Local automatic updates enabled for {dest}."


def disable():
    with lock(ROOT / "update.lock"):
        config = read_json(ROOT / "config.json")
        config["enabled"] = False
        write_json(ROOT / "config.json", config)
        pending = ROOT / PENDING
        if pending.exists():
            checksum = read_json(pending)["sha256"]
            pending.unlink()
            if re.fullmatch(r"[0-9a-f]{64}", checksum):
                (ROOT / (checksum + ".zip")).unlink(missing_ok=True)
    if not subprocess.run(["/bin/launchctl", "print", DOMAIN + "/" + LABEL], capture_output=True).returncode:
        subprocess.run(["/bin/launchctl", "bootout", DOMAIN + "/" + LABEL], check=True)
    PLIST.unlink(missing_ok=True)
    return "Local automatic updates disabled."


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("enable").add_argument("--app", type=Path, required=True)
    commands.add_parser("publish").add_argument("release", type=Path)
    for command in ("status", "apply", "disable"):
        commands.add_parser(command)
    options = parser.parse_args()
    try:
        if options.command == "enable":
            result = enable(options.app)
        elif not (ROOT / "config.json").exists():
            require(options.command in ("status", "disable"), "Enable local updates first.")
            result = "Local automatic updates are disabled."
        elif options.command == "publish":
            result = publish(options.release)
        elif options.command == "apply":
            result = apply()
        elif options.command == "disable":
            result = disable()
        else:
            with lock(ROOT / "update.lock"):
                config = read_json(ROOT / "config.json")
                result = json.dumps({"enabled": config["enabled"], "app": config["app"],
                                     "installed": identity(Path(config["app"])),
                                     "pending": read_json(ROOT / PENDING) if (ROOT / PENDING).exists() else None,
                                     "lastUpdate": read_json(ROOT / "last-update.json") if (ROOT / "last-update.json").exists() else None},
                                    indent=2)
        print(result)
    except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Local update: {error}\n")


if __name__ == "__main__":
    main()
