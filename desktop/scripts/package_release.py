"""Package the native app into a local review ZIP or a drag-install disk image."""

import argparse
import ctypes
import datetime
import hashlib
import json
import os
from pathlib import Path
import plistlib
import re
import shutil
import subprocess
import sys
import tempfile


SCRIPTS = Path(__file__).resolve().parent
BUILD = SCRIPTS.parent / "build"
RECEIPT = Path("Contents/Resources/BuildReceipt.json")
DEVELOPER_ID = (
    "=anchor apple generic and certificate 1[field.1.2.840.113635.100.6.2.6] exists "
    "and certificate leaf[field.1.2.840.113635.100.6.1.13] exists"
)


def run(*args, **kwargs):
    return subprocess.run(args, check=True, **kwargs)


def zip_app(app, archive):
    run("/usr/bin/ditto", "-c", "-k", "--sequesterRsrc", "--keepParent", app, archive)


def verify_app(app):
    run(SCRIPTS / "verify-release.sh", "--app", app)


def verify_public_contents(app):
    """The public bundle contains only the outputs produced by the release build."""
    expected = {Path(name) for name in (
        "Contents/Info.plist", "Contents/PkgInfo", "Contents/_CodeSignature/CodeResources",
        "Contents/MacOS/LCPDesktop", "Contents/Helpers/LCPAgentBridge", "Contents/Resources/LCP.icns",
    )} | {RECEIPT}
    files = set()
    for path in app.rglob("*"):
        if path.is_symlink():
            raise ValueError("Unexpected symlink in the app selected for public distribution.")
        if not path.is_dir():
            files.add(path.relative_to(app))
    if files != expected:
        raise ValueError("The app has unexpected or missing files. Build a fresh Release app for distribution.")
    for relative in expected - {Path("Contents/Resources/LCP.icns")}:
        data = (app / relative).read_bytes()
        if any(prefix in data for prefix in (b"/Users/", b"/home/", b"/var/folders/",
                                             os.fsencode(SCRIPTS.parent.parent))):
            raise ValueError(f"{relative} contains a local build path. Rebuild using build-app.sh.")


def verify_identity(item):
    run("/usr/bin/codesign", "--verify", "--strict", "-R", DEVELOPER_ID, item)


def notarize(upload, staple_target, profile):
    result = run("/usr/bin/xcrun", "notarytool", "submit", upload, "--keychain-profile",
                 profile, "--wait", "--output-format", "json", stdout=subprocess.PIPE)
    response = json.loads(result.stdout)
    if response.get("status") != "Accepted" or not response.get("id"):
        raise ValueError(f"Apple notarization returned {response.get('status')} "
                         f"for submission {response.get('id')}.")
    run("/usr/bin/xcrun", "stapler", "staple", staple_target)
    run("/usr/bin/xcrun", "stapler", "validate", staple_target)
    return response["id"]


def sign_app(app, workspace, identity, profile):
    # The hardened runtime requires this entitlement for the app's AVAudioRecorder.
    # LCPAgentBridge is a stdio helper and has no microphone capability.
    entitlements = workspace / "desktop-entitlements.plist"
    entitlements.write_bytes(plistlib.dumps({"com.apple.security.device.audio-input": True}))
    sign = ("/usr/bin/codesign", "--force", "--sign", identity, "--options", "runtime", "--timestamp")
    helper = app / "Contents/Helpers/LCPAgentBridge"
    run(*sign, helper)
    run(*sign, "--entitlements", entitlements, app)
    verify_identity(helper)
    verify_identity(app)
    verify_app(app)
    upload = workspace / "notarization-input.zip"
    zip_app(app, upload)
    return notarize(upload, app, profile)


def make_dmg(layout, dmg, identity, profile):
    (layout / "Applications").symlink_to("/Applications")
    run("/usr/bin/hdiutil", "create", "-quiet", "-volname", "LCP Desktop",
        "-srcfolder", layout, "-format", "UDZO", "-fs", "HFS+", dmg)
    submission = None
    if identity:
        run("/usr/bin/codesign", "--force", "--sign", identity, "--timestamp", dmg)
        verify_identity(dmg)
        submission = notarize(dmg, dmg, profile)
        run("/usr/sbin/spctl", "--assess", "--type", "open", "--context", "context:primary-signature", dmg)
    run("/usr/bin/hdiutil", "verify", "-quiet", dmg)
    mount = layout.parent / "mount"
    mount.mkdir()
    run("/usr/bin/hdiutil", "attach", "-quiet", "-readonly", "-nobrowse", "-noautoopen",
        "-mountpoint", mount, dmg)
    try:
        if os.readlink(mount / "Applications") != "/Applications":
            raise ValueError("The disk image has an unexpected Applications link.")
        mounted_app = mount / "LCP Desktop.app"
        verify_app(mounted_app)
        if identity:
            run("/usr/bin/xcrun", "stapler", "validate", mounted_app)
    finally:
        run("/usr/bin/hdiutil", "detach", "-quiet", mount)
    return submission


def promote_new_directory(staged, output):
    # macOS renamex_np with RENAME_EXCL commits the complete directory in one
    # step and refuses even an empty destination created by a concurrent run.
    rename = ctypes.CDLL(None, use_errno=True).renamex_np
    rename.argtypes = (ctypes.c_char_p, ctypes.c_char_p, ctypes.c_uint)
    if rename(os.fsencode(staged), os.fsencode(output), 0x00000004) != 0:
        error = ctypes.get_errno()
        raise OSError(error, os.strerror(error), str(output))


def package(options):
    source = options.app.expanduser().resolve(strict=True)
    output = options.output_directory.expanduser().absolute()
    if os.path.lexists(output):
        raise FileExistsError(f"Use a new release directory. Existing release preserved: {output}")
    output = output.resolve()
    if source in output.parents:
        raise ValueError("Choose a release directory outside the selected app.")
    if not (source / RECEIPT).is_file():
        raise ValueError("Build with build-app.sh before packaging so the archive has source evidence.")

    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(dir=output.parent, prefix=".lcp-package-") as tmp:
        workspace = Path(tmp)
        staged = workspace / "release"
        staged.mkdir()
        layout = workspace / "volume"
        layout.mkdir()
        app = layout / ("LCP Desktop.app" if options.dmg else source.name)
        public = bool(options.public_preview or options.sign_identity)
        if public:
            verify_public_contents(source)
            run("/usr/bin/ditto", "--norsrc", "--noextattr", "--noacl", source, app)
        else:
            run("/usr/bin/ditto", source, app)
        verify_app(app)
        receipt = json.loads((app / RECEIPT).read_bytes())
        info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
        version, build = info.get("CFBundleShortVersionString"), info.get("CFBundleVersion")
        if options.dmg:
            if receipt.get("configuration") != "Release":
                raise ValueError("A distribution DMG requires a Release build from build-app.sh.")
            if not all(isinstance(v, str) and re.fullmatch(r"[0-9A-Za-z][0-9A-Za-z.\-]*", v)
                       for v in (version, build)):
                raise ValueError("Expected a bundle version and build number suitable for the DMG filename.")

        shutil.copyfile(app / RECEIPT, staged / "BuildReceipt.json")
        signature = run("/usr/bin/codesign", "-dv", app, stderr=subprocess.PIPE).stderr.splitlines()
        signing = ("ad-hoc; not Developer ID signed or notarized" if b"Signature=adhoc" in signature
                   else "input signature preserved; notarization not assessed")
        distribution = "private local review"
        submissions = {}
        if options.sign_identity:
            submissions["app"] = sign_app(app, workspace, options.sign_identity, options.notary_profile)
            signing = "Developer ID Application; hardened runtime; app and DMG notarized and stapled"
            distribution = "Developer ID distribution"
        elif options.public_preview:
            distribution = "public preview"
        elif options.dmg:
            distribution = "personal local distribution"

        archive = staged / "LCPDesktop-arm64.zip"
        zip_app(app, archive)
        if options.dmg:
            extracted = workspace / "zip-contents"
            run("/usr/bin/ditto", "-x", "-k", archive, extracted)
            verify_app(extracted / app.name)
            if options.sign_identity:
                run("/usr/bin/xcrun", "stapler", "validate", extracted / app.name)
                run("/usr/sbin/spctl", "--assess", "--type", "execute", extracted / app.name)
            dmg = staged / f"LCPDesktop-{version}-{build}-arm64.dmg"
            dmg_id = make_dmg(layout, dmg, options.sign_identity, options.notary_profile)
            if dmg_id:
                submissions["dmg"] = dmg_id

        entries = {p.name: hashlib.sha256(p.read_bytes()).hexdigest() for p in sorted(staged.iterdir())}
        manifest = {"schema_version": 1, "artifacts": entries, "distribution": distribution,
                    "signing": signing, "contains_user_profile": False}
        if options.dmg:
            manifest.update(version=version, build=build, architecture="arm64",
                            minimum_macos=info.get("LSMinimumSystemVersion"),
                            build_receipt="Original build provenance before distribution packaging and signing.",
                            disk_image=dmg.name, disk_image_format="UDZO", disk_image_signed=bool(dmg_id),
                            notarization_submissions=submissions)
        manifest_path = staged / "ReleaseManifest.json"
        manifest_path.write_text(json.dumps(manifest, indent=2) + "\n")
        checksums = dict(entries)
        checksums[manifest_path.name] = hashlib.sha256(manifest_path.read_bytes()).hexdigest()
        sums = "".join(f"{digest}  {name}\n" for name, digest in sorted(checksums.items()))
        (staged / "SHA256SUMS").write_text(sums)
        promote_new_directory(staged, output)
        print(f"Release: {output}")
        print(sums, end="")
        if options.dmg and not public:
            # Only this checkout's explicitly enabled personal installation subscribes.
            sys.dont_write_bytecode = True
            import local_updates
            try:
                result = local_updates.publish(output, automatic=True, expected=entries[archive.name])
            except (OSError, ValueError, KeyError, subprocess.CalledProcessError) as error:
                raise ValueError(f"Release saved in {output}; local update queue failed: {error}. "
                                 "Retry with local_updates.py publish and the saved release directory.") from error
            if result:
                print(result)


def main():
    parser = argparse.ArgumentParser(prog="package-release.sh", allow_abbrev=False,
                                     description="Create a local archive and optional drag-install DMG.")
    parser.add_argument("--app", type=Path, default=BUILD / "Release/LCP Desktop.app")
    timestamp = datetime.datetime.now(datetime.timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    parser.add_argument("--output-directory", type=Path, default=BUILD / "releases" / f"LCPDesktop-{timestamp}",
                        metavar="NEW_RELEASE_DIRECTORY")
    parser.add_argument("--dmg", action="store_true", help="also create a read-only, versioned Release DMG")
    parser.add_argument("--public-preview", action="store_true",
                        help="create a public preview DMG with the local signature and skip the personal update queue")
    parser.add_argument("--sign-identity", help="Developer ID Application identity for signing the app and DMG")
    parser.add_argument("--notary-profile", help="Keychain profile for submitting the app and DMG to Apple")
    args = parser.parse_args()
    if args.public_preview:
        if args.sign_identity is not None or args.notary_profile is not None:
            parser.error("Use --public-preview for local signing or --dmg with the Developer ID options.")
        args.dmg = True
    if args.sign_identity is not None or args.notary_profile is not None:
        if not (args.dmg and args.sign_identity and args.sign_identity != "-" and args.notary_profile):
            parser.error("Developer ID distribution requires --dmg, --sign-identity and --notary-profile together.")
    try:
        package(args)
    except (OSError, ValueError, subprocess.CalledProcessError) as error:
        parser.exit(1, f"Packaging failed: {error}\n")


if __name__ == "__main__":
    main()
