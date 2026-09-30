#!/usr/bin/env python3
"""Print `StoreFingerprint.of` for the bytes on stdin: the 16 hex characters a retained generation's
file name carries (`g-<sequence>-<fingerprint>.json`).

`Scripts/rehearse-recovery.sh` names its synthetic generations with this, so WhisperMeet recognises
them (F550). It used the first 16 hex characters of a SHA-256 before, which is not the app's
fingerprint: Recover Library listed every generation as not matching its name and refused to
restore any of them.

This is a second implementation of an on-disk format, so it must produce the same output as
`Sources/WhisperCore/StoreFingerprint.swift`. `test_rehearse_recovery.py` checks it against that
file's published golden values, and `RecoveryRehearsalLibraryTests` checks that the app accepts the
names the rehearsal writes.
"""

import sys

MASK = (1 << 64) - 1


def _mix(h, w):
    x = ((h ^ w) * 0xFF51AFD7ED558CCD) & MASK
    return ((((x << 31) | (x >> 33)) & MASK) + 0x165667B19E3779F9) & MASK


def fingerprint(data):
    a = 0x9E3779B97F4A7C15 ^ len(data)
    b = 0xBF58476D1CE4E5B9
    c = 0x94D049BB133111EB
    e = 0x2545F4914F6CDD1D
    i = 0
    while i + 32 <= len(data):
        a = _mix(a, int.from_bytes(data[i:i + 8], "little"))
        b = _mix(b, int.from_bytes(data[i + 8:i + 16], "little"))
        c = _mix(c, int.from_bytes(data[i + 16:i + 24], "little"))
        e = _mix(e, int.from_bytes(data[i + 24:i + 32], "little"))
        i += 32
    while i < len(data):
        a = ((a ^ data[i]) * 0x100000001B3) & MASK
        i += 1
    h = a ^ ((b * 0xC2B2AE3D27D4EB4F) & MASK) ^ (((c << 17) | (c >> 47)) & MASK) \
        ^ ((e + 0x9E3779B97F4A7C15) & MASK)
    h ^= h >> 33
    h = (h * 0xFF51AFD7ED558CCD) & MASK
    h ^= h >> 29
    h = (h * 0xC4CEB9FE1A85EC53) & MASK
    h ^= h >> 32
    return "%016x" % h


if __name__ == "__main__":
    print(fingerprint(sys.stdin.buffer.read()))
