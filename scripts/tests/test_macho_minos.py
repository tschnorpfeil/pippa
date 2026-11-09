import contextlib
import importlib.util
import io
import pathlib
import plistlib
import struct
import tempfile
import unittest

ROOT = pathlib.Path(__file__).resolve().parents[2]
spec = importlib.util.spec_from_file_location("macho_minos", ROOT / "scripts/macho-minos.py")
minos = importlib.util.module_from_spec(spec)
spec.loader.exec_module(minos)


def packed(major, minor):
    return (major << 16) | (minor << 8)


def thin(major, minor, old_command=False):
    """A minimal arm64 Mach-O with one version load command."""
    if old_command:
        command = struct.pack("<IIII", minos.LC_VERSION_MIN_MACOSX, 16, packed(major, minor), packed(major, minor))
    else:
        command = struct.pack("<IIIIII", minos.LC_BUILD_VERSION, 24, 1, packed(major, minor), packed(major, minor), 0)
    header = struct.pack("<IiiIIIII", minos.MH_MAGIC_64, 0x0100000C, 0, 6, 1, len(command), 0, 0)
    return header + command


def universal(*slices):
    """A universal (fat) file with each slice at a 4096-byte boundary."""
    data = bytearray(struct.pack(">II", minos.FAT_MAGIC, len(slices)))
    offset = 4096
    bodies = []
    for body in slices:
        data += struct.pack(">IiIII", 0x0100000C, 0, offset, len(body), 12)
        bodies.append((offset, body))
        offset += 4096
    for at, body in bodies:
        data += b"\0" * (at - len(data)) + body
    return bytes(data)


class MachOMinimumTests(unittest.TestCase):
    def setUp(self):
        self.folder = tempfile.TemporaryDirectory()
        self.root = pathlib.Path(self.folder.name)

    def tearDown(self):
        self.folder.cleanup()

    def write(self, name, data):
        path = self.root / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(data)
        return path

    def test_reads_build_version_and_old_version_command(self):
        self.assertEqual(minos.minimum_macos(self.write("new.dylib", thin(26, 2))), (26, 2, 0))
        self.assertEqual(minos.minimum_macos(self.write("old.so", thin(11, 0, old_command=True))), (11, 0, 0))

    def test_universal_file_reports_its_highest_slice(self):
        path = self.write("fat.dylib", universal(thin(14, 0), thin(26, 2)))
        self.assertEqual(minos.minimum_macos(path), (26, 2, 0))

    def test_ignores_files_that_are_not_mach_o(self):
        self.assertIsNone(minos.minimum_macos(self.write("notes.txt", b"plain text, long enough")))
        self.assertIsNone(minos.minimum_macos(self.write("A.class", b"\xca\xfe\xba\xbe\x00\x00\x00\x34rest")))

    def test_lists_only_binaries_newer_than_the_supported_macos(self):
        self.write("lib/libmlx.dylib", thin(26, 2))
        self.write("lib/core.so", thin(14, 0))
        self.write("README", b"text")
        self.assertEqual(minos.too_new(self.root, (26, 0)), [((26, 2, 0), "lib/libmlx.dylib")])
        self.assertEqual(minos.too_new(self.root, (26, 2)), [])

    def test_main_reads_the_supported_macos_from_the_plist(self):
        self.write("runtime/lib/libmlx.dylib", thin(26, 2))
        plist = self.root / "Info.plist"
        plist.write_bytes(plistlib.dumps({"LSMinimumSystemVersion": "26.2"}))
        args = ["macho-minos.py", str(self.root / "runtime"), str(plist)]
        with contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(minos.main(args), 0)
        self.assertEqual(output.getvalue(), "")
        plist.write_bytes(plistlib.dumps({"LSMinimumSystemVersion": "26.0"}))
        with contextlib.redirect_stdout(io.StringIO()) as output:
            self.assertEqual(minos.main(args), 1)
        self.assertEqual(output.getvalue(), "26.2.0 lib/libmlx.dylib\n")


if __name__ == "__main__":
    unittest.main()
