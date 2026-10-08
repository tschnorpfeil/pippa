#!/usr/bin/env python3
"""Do two files share their first block on disk (APFS clone)? F_LOG2PHYS returns the physical address.

  python3 scripts/tests/same-blocks.py <a> <b>     -> "clone" or "copy", exit 0/1

Used by runtime/pippa-guard/guard.test.mjs to check that undo copies are clones. Read-only.
"""
import fcntl
import os
import struct
import sys

F_LOG2PHYS = 49  # <sys/fcntl.h>


def physical(path: str) -> int:
    fd = os.open(path, os.O_RDONLY)
    try:
        # struct log2phys { unsigned int l2p_flags; off_t l2p_contigbytes; off_t l2p_devoffset; }
        out = fcntl.fcntl(fd, F_LOG2PHYS, struct.pack("=Iqq", 0, 0, 0))
        return struct.unpack("=Iqq", out)[2]
    finally:
        os.close(fd)


a, b = sys.argv[1], sys.argv[2]
same = physical(a) == physical(b)
print("clone" if same else "copy")
sys.exit(0 if same else 1)
