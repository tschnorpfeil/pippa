#!/usr/bin/env python3
"""Lists the Mach-O files in a folder that need a newer macOS than Pippa supports.

Usage: macho-minos.py <folder> <Info.plist>

Prints `<minimum macOS> <path>` for every binary whose minimum is above the plist's LSMinimumSystemVersion and exits
with 1 if there is one. scripts/build-mlx-runtime.sh runs it on the staged runtime: a binary built for a newer macOS
does not load on an older one, and MLX 0.32.4's wheels tagged macosx_26_0 need 26.2.
"""
import os
import plistlib
import struct
import sys

MH_MAGIC_64 = 0xFEEDFACF
FAT_MAGIC, FAT_MAGIC_64 = 0xCAFEBABE, 0xCAFEBABF
LC_VERSION_MIN_MACOSX, LC_BUILD_VERSION = 0x24, 0x32


def parse_version(text):
    """"26.2" → (26, 2, 0), comparable with unpack_version."""
    parts = [int(part) for part in text.split(".")]
    return tuple((parts + [0, 0, 0])[:3])


def unpack_version(packed):
    """Mach-O versions are xxxx.yy.zz in one 32-bit number."""
    return (packed >> 16, (packed >> 8) & 0xFF, packed & 0xFF)


def slice_offsets(handle):
    """Where each architecture's header starts: 0 for a thin file, the slices of a universal one, none otherwise."""
    head = handle.read(8)
    if len(head) < 8:
        return []
    if struct.unpack("<I", head[:4])[0] == MH_MAGIC_64:
        return [0]
    magic, count = struct.unpack(">II", head)
    if magic not in (FAT_MAGIC, FAT_MAGIC_64) or not 0 < count < 16:   # Java class files share 0xCAFEBABE
        return []
    entry = 20 if magic == FAT_MAGIC else 32
    table = handle.read(count * entry)
    offsets = []
    for index in range(count):
        at = index * entry + 8
        offsets.append(struct.unpack(">I", table[at:at + 4])[0] if magic == FAT_MAGIC
                       else struct.unpack(">Q", table[at:at + 8])[0])
    return offsets


def minimum_macos(path):
    """The highest minimum macOS among the file's slices, or None if it is not a 64-bit Mach-O."""
    found = None
    with open(path, "rb") as handle:
        for offset in slice_offsets(handle):
            handle.seek(offset)
            header = handle.read(32)
            if len(header) < 32 or struct.unpack("<I", header[:4])[0] != MH_MAGIC_64:
                continue
            ncmds, sizeofcmds = struct.unpack("<II", header[16:24])
            commands = handle.read(sizeofcmds)
            at = 0
            for _ in range(ncmds):
                if at + 8 > len(commands):
                    break
                cmd, size = struct.unpack("<II", commands[at:at + 8])
                if cmd == LC_BUILD_VERSION and at + 16 <= len(commands):
                    version = unpack_version(struct.unpack("<I", commands[at + 12:at + 16])[0])
                elif cmd == LC_VERSION_MIN_MACOSX and at + 12 <= len(commands):
                    version = unpack_version(struct.unpack("<I", commands[at + 8:at + 12])[0])
                else:
                    version = None
                if version and (found is None or version > found):
                    found = version
                if size < 8:
                    break
                at += size
    return found


def too_new(folder, supported):
    """(minimum, path relative to folder) for every binary that needs a newer macOS than `supported`."""
    supported = tuple((list(supported) + [0, 0, 0])[:3])
    result = []
    for root, _, files in os.walk(folder):
        for name in files:
            path = os.path.join(root, name)
            if os.path.islink(path) or not os.path.isfile(path):
                continue
            try:
                minimum = minimum_macos(path)
            except OSError:
                continue
            if minimum and minimum > supported:
                result.append((minimum, os.path.relpath(path, folder)))
    return sorted(result, key=lambda item: item[1])


def main(argv):
    if len(argv) != 3:
        print(__doc__.strip().splitlines()[2], file=sys.stderr)
        return 2
    with open(argv[2], "rb") as handle:
        supported = parse_version(plistlib.load(handle)["LSMinimumSystemVersion"])
    offenders = too_new(argv[1], supported)
    for minimum, path in offenders:
        print(".".join(str(part) for part in minimum), path)
    return 1 if offenders else 0


if __name__ == "__main__":
    sys.exit(main(sys.argv))
