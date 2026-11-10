import importlib.util
import plistlib
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("package_ipa", ROOT / "scripts" / "package_ipa.py")
packager = importlib.util.module_from_spec(spec)
spec.loader.exec_module(packager)


class PackageGuardTests(unittest.TestCase):
    def test_rejects_source_code_disguised_as_application(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app = root / "Example.app"
            app.mkdir()
            (app / "Info.plist").write_bytes(plistlib.dumps({"CFBundleExecutable": "Example"}))
            (app / "Example").write_text("print('not a compiled iOS app')")
            with self.assertRaisesRegex(ValueError, "Mach-O"):
                packager.package(app, root / "example.ipa")
            self.assertFalse((root / "example.ipa").exists())

    def test_rejects_simulator_application(self):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            app = root / "Example.app"
            app.mkdir()
            (app / "Info.plist").write_bytes(plistlib.dumps({
                "CFBundleExecutable": "Example", "DTPlatformName": "iphonesimulator",
                "CFBundleSupportedPlatforms": ["iPhoneSimulator"], "CFBundlePackageType": "APPL",
            }))
            (app / "Example").write_bytes(b"\xcf\xfa\xed\xfe" + b"\x00" * 24)
            with self.assertRaisesRegex(ValueError, "device build"):
                packager.package(app, root / "example.ipa")
            self.assertFalse((root / "example.ipa").exists())


if __name__ == "__main__":
    unittest.main()
