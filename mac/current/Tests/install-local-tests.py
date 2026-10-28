"""Exercise local installation with small signed application fixtures."""

import importlib.util
from pathlib import Path
import plistlib
import shutil
import subprocess
import tempfile
import unittest
from unittest.mock import patch

ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location("installer", ROOT / "scripts/install-local.py")
installer = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(installer)


class InstallTests(unittest.TestCase):
    def setUp(self):
        self.temporary = tempfile.TemporaryDirectory(prefix="margin-install-test-")
        self.addCleanup(self.temporary.cleanup)
        self.root = Path(self.temporary.name).resolve()
        self.source = self.bundle("build/Margin.app", "0.5.1")
        self.target = self.bundle("installed/Margin.app", "0.5.0")

    def bundle(self, path, version):
        app = self.root / path
        executable = app / "Contents/MacOS/LeafReader"
        executable.parent.mkdir(parents=True)
        shutil.copy("/usr/bin/true", executable)
        info = {"CFBundleIdentifier": "local.leaf.pdfreader", "CFBundleExecutable": "LeafReader",
                "CFBundlePackageType": "APPL", "CFBundleShortVersionString": version, "CFBundleVersion": "13"}
        (app / "Contents/Info.plist").write_bytes(plistlib.dumps(info))
        installer.run("/usr/bin/codesign", "--force", "--sign", "-", str(app))
        return app

    def test_install_and_replace(self):
        marker = self.target / "obsolete-file"
        marker.write_text("old bundle")
        installer.install(self.source, self.target)
        self.assertFalse(marker.exists())
        self.assertEqual(installer.bundle_info(self.target)["CFBundleShortVersionString"], "0.5.1")
        installer.verify(self.target)
        self.assertFalse(list(self.target.parent.glob(".margin-install-*")))
        installer.install(self.source, self.root / "fresh/Margin.app")
        installer.verify(self.root / "fresh/Margin.app")

    def test_rejects_invalid_signature_and_downgrade(self):
        original = (self.target / "Contents/Info.plist").read_bytes()
        (self.source / "Contents/MacOS/LeafReader").write_bytes(b"invalid executable")
        with self.assertRaises(subprocess.CalledProcessError):
            installer.install(self.source, self.target)
        self.assertEqual((self.target / "Contents/Info.plist").read_bytes(), original)
        older = self.bundle("older/Margin.app", "0.4.0")
        with self.assertRaisesRegex(ValueError, "newer installed version"):
            installer.install(older, self.target)
        installer.verify(self.target)

    def test_rolls_back_failed_final_verification(self):
        verify = installer.verify

        def fail_on_destination(app):
            if app == self.target:
                raise OSError("Synthetic final verification failure")
            verify(app)

        with patch.object(installer, "verify", side_effect=fail_on_destination):
            with self.assertRaises(OSError):
                installer.install(self.source, self.target)
        self.assertEqual(installer.bundle_info(self.target)["CFBundleShortVersionString"], "0.5.0")
        installer.verify(self.target)
        self.assertFalse(list(self.target.parent.glob(".margin-install-*")))


if __name__ == "__main__":
    unittest.main()
