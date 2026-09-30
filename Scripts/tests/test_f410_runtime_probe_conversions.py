#!/usr/bin/env python3
"""F410 — the diarization bench's `probe` and `sweep` must not convert a `Double` with a bare `Int(…)`.

Run: python3 Scripts/tests/test_f410_runtime_probe_conversions.py

`Scripts/bench/diarization/runtime-probe` is a separate SwiftPM package that the app's gate never
builds, so nothing else looks at it between bench runs. F343 set out to make its conversions
saturate, and its log said "Both now saturate" — but `sweep`'s progress line kept
`prepareSeconds.isFinite ? Int(prepareSeconds.rounded(.down)) : -1` under a comment calling it
"Saturating rather than `Int(Double)`". `isFinite` does not make a conversion saturate: `1e30` is
finite and traps `Int(_:)` all the same (AGENTS.md: "`isFinite` does not help").

Whether an argument is a `Double` cannot be read off the source text, so this guard is fail-closed:
every construction of a standard integer type (`Int`, `Int64`, `UInt32`, …) in the package's sources
must be `Int(saturating:)` / `Int(exactly:)`, or appear in `KNOWN_NON_DOUBLE` with the reason it is
safe. A new bare conversion fails here until someone decides which it is. A typealias such as
`AVAudioFrameCount` is not recognised, so a conversion spelled that way is not checked. Comments are
stripped first, so a comment that quotes the old shape cannot trip it (F285's false positive in the
other direction).
"""

import glob
import os
import re
import unittest

_HERE = os.path.dirname(os.path.abspath(__file__))
_PACKAGE = os.path.normpath(os.path.join(_HERE, "..", "bench", "diarization", "runtime-probe"))

_INTEGER_TYPES = r"(?:Int|Int8|Int16|Int32|Int64|UInt|UInt8|UInt16|UInt32|UInt64)"
_CONSTRUCTION = re.compile(r"(?<![\w.])(" + _INTEGER_TYPES + r")\(")
_SAFE_LABELS = ("saturating:", "exactly:")

# (file relative to Sources/, argument text) -> why that conversion cannot trap on a Double.
KNOWN_NON_DOUBLE = {
    ("probe/main.swift", "id"): "a String parse returning Int?, not a Double conversion",
    ("probe/main.swift", "value"): "the saturating init's own in-range branch, after both bounds",
    ("sweep/main.swift", "buffer.frameLength"): "AVAudioFrameCount is UInt32, which always fits Int",
    ("sweep/main.swift", "value"): "the saturating init's own in-range branch, after both bounds",
}


def strip_comments(source):
    """Swift source with `//…` and `/*…*/` comments blanked. String literals are kept, because an
    interpolation can hold a conversion (sweep's progress line did); a `//` inside one is not a
    comment."""
    out = []
    i, n = 0, len(source)
    in_string = False
    while i < n:
        c = source[i]
        if in_string:
            out.append(c)
            if c == "\\" and i + 1 < n:
                out.append(source[i + 1])
                i += 2
                continue
            if c == '"':
                in_string = False
            i += 1
            continue
        if source.startswith("//", i):
            end = source.find("\n", i)
            i = n if end == -1 else end
            continue
        if source.startswith("/*", i):
            end = source.find("*/", i + 2)
            i = n if end == -1 else end + 2
            continue
        if c == '"':
            in_string = True
        out.append(c)
        i += 1
    return "".join(out)


def constructions(source):
    """(type, argument text) for every integer-type construction in comment-stripped `source`."""
    found = []
    for match in _CONSTRUCTION.finditer(source):
        depth, j = 1, match.end()
        while j < len(source) and depth:
            depth += {"(": 1, ")": -1}.get(source[j], 0)
            j += 1
        found.append((match.group(1), source[match.end():j - 1].strip()))
    return found


def unsafe_conversions(relative_path, source):
    return [
        f"{relative_path}: {kind}({argument})"
        for kind, argument in constructions(strip_comments(source))
        if not argument.startswith(_SAFE_LABELS) and (relative_path, argument) not in KNOWN_NON_DOUBLE
    ]


class RuntimeProbeConversionTests(unittest.TestCase):
    def sources(self):
        root = os.path.join(_PACKAGE, "Sources")
        paths = sorted(glob.glob(os.path.join(root, "*", "*.swift")))
        found = []
        for path in paths:
            with open(path, encoding="utf-8") as handle:
                found.append((os.path.relpath(path, root), handle.read()))
        return found

    def test_the_package_sources_are_where_this_guard_looks(self):
        # Precondition, not decoration: if the package moved, every other assertion here would pass
        # on an empty list.
        self.assertEqual([path for path, _ in self.sources()], ["probe/main.swift", "sweep/main.swift"])

    def test_no_bare_integer_conversion_in_probe_or_sweep(self):
        offenders = []
        for relative_path, source in self.sources():
            offenders.extend(unsafe_conversions(relative_path, source))
        self.assertEqual(offenders, [], "bare integer conversions — use Int(saturating:), or add the "
                         "argument to KNOWN_NON_DOUBLE with the reason it cannot be a Double:\n"
                         + "\n".join(offenders))

    def test_the_guard_sees_an_isfinite_guarded_conversion_inside_an_interpolation(self):
        source = 'let line = "\\(name) \\(t.isFinite ? Int(t.rounded(.down)) : -1)s"\n'
        self.assertEqual(unsafe_conversions("sweep/main.swift", source),
                         ["sweep/main.swift: Int(t.rounded(.down))"])

    def test_the_guard_ignores_a_comment_and_accepts_saturating(self):
        source = ('// was Int(seconds), which traps\n/* Int(x) */\n'
                  'let url = "https://example.com//path"\nlet n = Int(saturating: end * 10) + 1\n')
        self.assertEqual(unsafe_conversions("probe/main.swift", source), [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
