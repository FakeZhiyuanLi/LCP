"""Exercise release updates against disposable signed Mac app bundles."""

import json
from pathlib import Path
import os
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest
from unittest import mock

sys.dont_write_bytecode = True
sys.path.insert(0, str(Path(__file__).resolve().parents[2] / "scripts"))
import local_updates as updates


@unittest.skipUnless(sys.platform == "darwin", "Uses macOS code signing and atomic directory exchange")
class LocalUpdateTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.base = Path(self.tmp.name)
        self.root = self.base / "state"
        (self.root / "queue").mkdir(parents=True)
        self.lease = self.base / "capture.lock"
        self.destination = self.base / "Applications" / updates.APP
        self.old = self.release(1)
        self.new = self.release(2)
        subprocess.run(["/usr/bin/ditto", "-x", "-k", self.old / updates.ARCHIVE,
                        self.destination.parent], check=True)
        updates.write_json(self.root / "config.json", {
            "enabled": True, "app": str(self.destination), "scripts": str(updates.SCRIPTS)
        })

    def release(self, build):
        folder = self.base / str(build)
        bundle = folder / updates.APP
        macos = bundle / "Contents/MacOS"
        macos.mkdir(parents=True)
        shutil.copy("/bin/sleep", macos / "LCPDesktop")
        info = {"CFBundleIdentifier": "org.lcp.Desktop", "CFBundleExecutable": "LCPDesktop",
                "CFBundlePackageType": "APPL", "CFBundleVersion": str(build),
                "CFBundleShortVersionString": "1." + str(build)}
        (bundle / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        subprocess.run(["/usr/bin/codesign", "--force", "--sign", "-", bundle], check=True,
                       stderr=subprocess.DEVNULL)
        archive = folder / updates.ARCHIVE
        subprocess.run(["/usr/bin/ditto", "-c", "-k", "--keepParent", bundle, archive], check=True)
        updates.write_json(folder / "ReleaseManifest.json", {
            "distribution": "personal local distribution", "architecture": "arm64",
            "build": str(build), "version": info["CFBundleShortVersionString"],
            "artifacts": {updates.ARCHIVE: updates.sha(archive)}})
        return folder

    def apply(self):
        return updates.apply(self.root, self.lease)

    def test_safe_update_retry_and_downgrade(self):
        self.assertIn("Queued", updates.publish(self.new, self.root))
        self.assertIn("already queued", updates.publish(self.new, self.root))
        with updates.lock(self.lease):
            self.assertIn("recording", self.apply())
        with subprocess.Popen([self.destination / "Contents/MacOS/LCPDesktop", "5"]) as session:
            try:
                self.assertIn("quit", self.apply())
                self.assertIsNone(session.poll())
            finally:
                session.terminate()
        self.assertEqual(updates.identity(self.destination)["build"], 1)
        self.assertIn("Installed", self.apply())
        self.assertEqual(updates.identity(self.destination)["build"], 2)
        self.assertFalse((self.root / updates.PENDING).exists())
        self.assertIn("already installed", updates.publish(self.new, self.root))
        self.assertIn("older", updates.publish(self.old, self.root))

    def test_corruption_and_post_swap_failure_preserve_install(self):
        updates.publish(self.new, self.root)
        pending = updates.read_json(self.root / updates.PENDING)
        payload = self.root / (pending["sha256"] + ".zip")
        original = payload.read_bytes()
        payload.write_bytes(b"tampered")
        with self.assertRaisesRegex(ValueError, "checksum"):
            self.apply()
        payload.write_bytes(original)
        check = updates.signature
        def signature(app):
            if app == self.destination and updates.identity(app)["build"] == 2:
                raise ValueError("synthetic post-install failure")
            return check(app)
        with mock.patch.object(updates, "signature", side_effect=signature):
            with self.assertRaisesRegex(ValueError, "post-install"):
                self.apply()
        self.assertEqual(updates.identity(self.destination)["build"], 1)
        self.assertIn("Installed", self.apply())

    def test_recovery_after_swap_before_receipt(self):
        updates.publish(self.new, self.root)
        with mock.patch.object(updates, "write_json", side_effect=OSError("simulated interruption")):
            with self.assertRaisesRegex(OSError, "interruption"):
                self.apply()
        self.assertEqual(updates.identity(self.destination)["build"], 2)
        self.assertTrue((self.root / updates.PENDING).exists())
        self.assertIn("Already installed", self.apply())
        self.assertFalse((self.root / updates.PENDING).exists())

    def test_development_identity_is_scoped_to_the_checkout_and_required_by_the_updater(self):
        config_path = self.root / "config.json"
        config = updates.read_json(config_path)
        self.assertEqual(updates.build_signer(self.root), "-")
        fingerprint = "A" * 40
        config["developmentIdentity"] = fingerprint
        updates.write_json(config_path, config)
        self.assertEqual(updates.build_signer(self.root), fingerprint)
        with self.assertRaisesRegex(ValueError, "Apple Development"):
            updates.publish(self.new, self.root)
        self.assertFalse((self.root / updates.PENDING).exists())

        updates.write_json(config_path, {**config, "scripts": "/another/checkout"})
        self.assertEqual(updates.build_signer(self.root), "-")
        updates.write_json(config_path, {k: v for k, v in config.items() if k != "developmentIdentity"})
        updates.publish(self.new, self.root)
        updates.write_json(config_path, config)
        with self.assertRaisesRegex(ValueError, "Apple Development"):
            self.apply()
        self.assertEqual(updates.identity(self.destination)["build"], 1)

    def test_development_identity_selection_is_unambiguous(self):
        first, second = "A" * 40, "B" * 40
        listing = f'  1) {first} "Apple Development: Fictional One"\n'
        with mock.patch.object(updates.subprocess, "check_output", return_value=listing):
            self.assertEqual(updates.development_identity("auto"), first)
        listing += f'  2) {second} "Apple Development: Fictional Two"\n'
        with mock.patch.object(updates.subprocess, "check_output", return_value=listing):
            with self.assertRaisesRegex(ValueError, "Select one"):
                updates.development_identity("auto")
            self.assertEqual(updates.development_identity(second.lower()), second)


if __name__ == "__main__":
    unittest.main()
