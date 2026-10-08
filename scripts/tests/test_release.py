import base64
import importlib.util
import pathlib
import plistlib
import subprocess
import tempfile
import unittest
import xml.etree.ElementTree as ET

ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("appcast", ROOT / "scripts/write-appcast.py")
appcast = importlib.util.module_from_spec(spec)
spec.loader.exec_module(appcast)


class ReleaseChecks(unittest.TestCase):
    def test_appcast_uses_immutable_asset_and_bundle_metadata(self):
        with tempfile.TemporaryDirectory() as folder:
            folder = pathlib.Path(folder)
            plist, archive, output = folder / "Info.plist", folder / "Pippa 0.1.0-123.dmg", folder / "appcast.xml"
            info = dict(CFBundleVersion="123", CFBundleShortVersionString="0.1.0", LSMinimumSystemVersion="15.0",
                        SUFeedURL="https://github.com/tschnorpfeil/pippa/releases/latest/download/appcast.xml")
            plist.write_bytes(plistlib.dumps(info))
            archive.write_bytes(b"fixture")
            signature = base64.b64encode(bytes(range(64))).decode()
            appcast.write_appcast(plist, archive, "v0.1.0-123", signature, output)
            item = ET.parse(output).find("channel/item")
            ns = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
            self.assertEqual(item.findtext(ns + "version"), "123")
            self.assertEqual(item.findtext(ns + "minimumSystemVersion"), "15.0")
            self.assertEqual(item.findtext(ns + "hardwareRequirements"), "arm64")
            enclosure = item.find("enclosure")
            self.assertEqual(enclosure.get("url"), "https://github.com/tschnorpfeil/pippa/releases/download/v0.1.0-123/Pippa%200.1.0-123.dmg")
            self.assertEqual(enclosure.get("length"), "7")
            self.assertEqual(enclosure.get(ns + "edSignature"), signature)
            with self.assertRaises(ValueError):
                appcast.write_appcast(plist, archive, "../escape", signature, output)
            with self.assertRaises(ValueError):
                appcast.write_appcast(plist, archive, "v1", "bad", output)
            info["SUFeedURL"] = "http://github.com/tschnorpfeil/pippa/releases/latest/download/appcast.xml"
            plist.write_bytes(plistlib.dumps(info))
            with self.assertRaises(ValueError):
                appcast.write_appcast(plist, archive, "v1", signature, output)

    def test_release_fails_before_build_without_credentials(self):
        result = subprocess.run(["bash", str(ROOT / "scripts/release.sh")], env={"PATH": "/usr/bin:/bin"}, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("PIPPA_SIGN_IDENTITY", result.stderr)
        self.assertNotIn("swift", result.stdout)


if __name__ == "__main__":
    unittest.main()
