#!/usr/bin/env python3
"""In-place fix of a Mach-O's LC_BUILD_VERSION minos (and a bogus sdk), without changing any
size or offset. Used for MPVKit's frameworks, whose binaries declare the invalid minos 100.0.

usage: patch_minos.py BINARY TARGET_VERSION
Only lowers minos when it is above TARGET (a real lower minos is left alone).
Prints the final minos; exits 1 if the file isn't a 64-bit Mach-O (thin or fat).
"""
import struct
import sys

LC_BUILD_VERSION = 0x32
MH_MAGIC_64 = 0xFEEDFACF


def enc(v):
    p = [int(x) for x in v.split(".")] + [0, 0]
    return (p[0] << 16) | (p[1] << 8) | p[2]


def dec(n):
    s = f"{n >> 16}.{(n >> 8) & 0xFF}"
    return s + (f".{n & 0xFF}" if n & 0xFF else "")


def patch_slice(buf, off, target):
    if struct.unpack_from("<I", buf, off)[0] != MH_MAGIC_64:
        raise ValueError("not a 64-bit Mach-O slice")
    ncmds = struct.unpack_from("<I", buf, off + 16)[0]
    p = off + 32
    found = None
    for _ in range(ncmds):
        cmd, size = struct.unpack_from("<II", buf, p)
        if cmd == LC_BUILD_VERSION:
            minos, sdk = struct.unpack_from("<II", buf, p + 12)
            if minos > target:
                struct.pack_into("<I", buf, p + 12, target)
                minos = target
            if sdk >= enc("50"):  # the same placeholder is used for sdk
                struct.pack_into("<I", buf, p + 16, max(target, minos))
            found = minos
        p += size
    if found is None:
        raise ValueError("no LC_BUILD_VERSION")
    return found


def main():
    path, target = sys.argv[1], enc(sys.argv[2])
    buf = bytearray(open(path, "rb").read())
    magic_be = struct.unpack_from(">I", buf, 0)[0]
    results = []
    if magic_be in (0xCAFEBABE, 0xCAFEBABF):  # fat / fat64
        n = struct.unpack_from(">I", buf, 4)[0]
        for i in range(n):
            if magic_be == 0xCAFEBABE:
                off = struct.unpack_from(">I", buf, 8 + i * 20 + 8)[0]
            else:
                off = struct.unpack_from(">Q", buf, 8 + i * 32 + 8)[0]
            results.append(patch_slice(buf, off, target))
    else:
        results.append(patch_slice(buf, 0, target))
    open(path, "r+b").write(buf)
    print(dec(max(results)))


if __name__ == "__main__":
    try:
        main()
    except Exception as e:  # noqa: BLE001
        print(f"error: {e}", file=sys.stderr)
        sys.exit(1)
