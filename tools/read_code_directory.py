#!/usr/bin/env python3
"""Prints the CodeDirectory a code signature carries, and which hash type sits in slot 0.

codesign accepts an arm64 image only when the SHA-256 directory is the primary one; zsign writes the SHA-1
directory there unless it is asked for SHA256-only, and the resulting signature is rejected with a message
("code or signature have been modified") that says nothing about the real cause. tools/verify_signing.sh uses
this to pin the layout.

usage: read_code_directory.py <signed Mach-O>
"""
import struct
import sys


def main() -> int:
    if len(sys.argv) != 2:
        print(__doc__.strip(), file=sys.stderr)
        return 2
    with open(sys.argv[1], "rb") as handle:
        data = handle.read()

    ncmds = struct.unpack_from("<I", data, 4)[0]
    offset, signature = 32, None
    for _ in range(ncmds):
        command, size = struct.unpack_from("<II", data, offset)
        if command == 0x1D:  # LC_CODE_SIGNATURE
            signature, _ = struct.unpack_from("<II", data, offset + 8)
        offset += size
    if signature is None:
        print("no LC_CODE_SIGNATURE", file=sys.stderr)
        return 1

    _, _, count = struct.unpack_from(">III", data, signature)
    entry = signature + 12
    for _ in range(count):
        blob_type, blob_offset = struct.unpack_from(">II", data, entry)
        entry += 8
        at = signature + blob_offset
        if struct.unpack_from(">I", data, at)[0] != 0xFADE0C02:  # CSMAGIC_CODEDIRECTORY
            continue
        hash_type = data[at + 37]
        code_limit = struct.unpack_from(">I", data, at + 32)[0]
        slots = struct.unpack_from(">I", data, at + 28)[0]
        name = {1: "SHA-1", 2: "SHA-256", 3: "SHA-256-truncated", 4: "SHA-384"}.get(hash_type, str(hash_type))
        print(f"slot 0x{blob_type:06x} {name}, codeLimit={code_limit}, nCodeSlots={slots}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
