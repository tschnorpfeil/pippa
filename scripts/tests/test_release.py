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


# The Sparkle key must not drift by accident: an app signed with a new key cannot update builds that trust the old one.
# A deliberate rotation is announced by creating this file (any content; say why and which build carries both keys).
# Delete it again after the release that ships the new key, so the check guards the next release.
KEY_ROTATION_MARKER = ROOT / "scripts/release-key-rotation"
APP_PLIST = "app/Packaging/Info.plist"


def newest_release_tag():
    """The nearest v* tag reachable from HEAD, or None (no tags fetched)."""
    result = subprocess.run(["git", "-C", str(ROOT), "describe", "--tags", "--match", "v*", "--abbrev=0"],
                            capture_output=True, text=True)
    if result.returncode != 0:
        return None
    return result.stdout.strip() or None


def release_key_problem(plist_path, tag, marker=KEY_ROTATION_MARKER):
    """Returns a message when plist_path's SUPublicEDKey differs from the one shipped in tag, else None."""
    if marker.exists():
        return None
    current = plistlib.loads(pathlib.Path(plist_path).read_bytes()).get("SUPublicEDKey")
    shipped_bytes = subprocess.run(["git", "-C", str(ROOT), "show", f"{tag}:{APP_PLIST}"],
                                   capture_output=True, check=True).stdout
    shipped = plistlib.loads(shipped_bytes).get("SUPublicEDKey")
    if shipped is None or current == shipped:
        return None
    return (f"SUPublicEDKey {current!r} differs from {shipped!r} shipped in {tag}; "
            f"restore it, or create {marker} for a deliberate rotation")


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

    def test_unsigned_release_is_informational_and_never_older(self):
        with tempfile.TemporaryDirectory() as folder:
            folder = pathlib.Path(folder)
            plist, archive, output = folder / "Info.plist", folder / "Pippa-0.3.7-650.dmg", folder / "appcast.xml"
            plist.write_bytes(plistlib.dumps(dict(
                CFBundleVersion="650", CFBundleShortVersionString="0.3.7", LSMinimumSystemVersion="15.0",
                SUFeedURL="https://github.com/tschnorpfeil/pippa/releases/latest/download/appcast.xml")))
            archive.write_bytes(b"fixture")
            appcast.write_appcast(plist, archive, "v0.3.7-650", "", output)
            items = ET.parse(output).findall("channel/item")
            ns = "{http://www.andymatuschak.org/xml-namespaces/sparkle}"
            self.assertEqual(len(items), 1)
            self.assertEqual(items[0].findtext(ns + "version"), "650")
            self.assertEqual(items[0].findtext(ns + "shortVersionString"), "0.3.7")
            # No enclosure: Sparkle treats the item as informational and opens the link instead of installing.
            self.assertIsNone(items[0].find("enclosure"))
            self.assertEqual(items[0].findtext("link"), appcast.WEBSITE)

    def test_release_fails_before_build_without_credentials(self):
        result = subprocess.run(["bash", str(ROOT / "scripts/release.sh")], env={"PATH": "/usr/bin:/bin"}, capture_output=True, text=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("PIPPA_SIGN_IDENTITY", result.stderr)
        self.assertNotIn("swift", result.stdout)

    def test_sparkle_key_matches_newest_release_tag(self):
        tag = newest_release_tag()
        if tag is None:
            self.skipTest("no v* tag reachable (shallow clone)")
        self.assertIsNone(release_key_problem(ROOT / APP_PLIST, tag))

    def test_sparkle_key_check_catches_a_changed_key(self):
        tag = newest_release_tag()
        if tag is None:
            self.skipTest("no v* tag reachable (shallow clone)")
        with tempfile.TemporaryDirectory() as folder:
            folder = pathlib.Path(folder)
            info = plistlib.loads((ROOT / APP_PLIST).read_bytes())
            info["SUPublicEDKey"] = base64.b64encode(bytes(32)).decode()
            changed = folder / "Info.plist"
            changed.write_bytes(plistlib.dumps(info))
            absent_marker = folder / "release-key-rotation"
            self.assertIn("differs", release_key_problem(changed, tag, marker=absent_marker) or "")
            absent_marker.write_text("rotating to a new key\n")
            self.assertIsNone(release_key_problem(changed, tag, marker=absent_marker))


if __name__ == "__main__":
    unittest.main()
