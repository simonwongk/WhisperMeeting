#!/usr/bin/env python3
"""How long a library's transcript rows actually are (F340).

The scorecard quotes "20.7 % of this user's real transcript rows are under a second (8,831 rows
across 21 meetings)". That is the number that says how many rows F317's sub-second rule touches, and
it had no committed counter — so nobody could re-obtain it, and nobody could re-obtain it for a
*different* library either.

    python3 row_lengths.py --library ~/Library/Application\\ Support/WhisperMeet
    python3 row_lengths.py --self-test

Reads only `start` and `end` from the meetings index. It never reads, prints or copies transcript
text: the question is about durations, and a tool that answers it should not be able to leak a
meeting. A row with no usable timing is counted separately rather than silently dropped — those rows
cannot be gated by a duration rule at all, so folding them in either direction would misstate the
reach of the rule.
"""

import argparse
import json
import os
import sys


BOUNDARIES = [0.5, 1.0, 3.0, 10.0]


def row_durations(meetings):
    """(durations, untimed) from an index's meetings. `end` falls back to the next row's start."""
    durations = []
    untimed = 0
    for meeting in meetings:
        segments = meeting.get("segments") or []
        starts = [seg.get("start") for seg in segments]
        for index, segment in enumerate(segments):
            start = segment.get("start")
            end = segment.get("end")
            if end is None:
                end = next((s for s in starts[index + 1:] if s is not None), None)
            if start is None or end is None or end <= start:
                untimed += 1
                continue
            durations.append(end - start)
    return durations, untimed


def histogram(durations, boundaries=BOUNDARIES):
    counts = [0] * (len(boundaries) + 1)
    for duration in durations:
        placed = False
        for index, boundary in enumerate(boundaries):
            if duration < boundary:
                counts[index] += 1
                placed = True
                break
        if not placed:
            counts[-1] += 1
    return counts


def render(meetings):
    durations, untimed = row_durations(meetings)
    counts = histogram(durations)
    total = len(durations)
    labels = ["under 0.5 s", "0.5-1 s", "1-3 s", "3-10 s", "10 s or more"]
    lines = ["%d meetings, %d timed rows, %d rows with no usable timing"
             % (len(meetings), total, untimed)]
    for label, count in zip(labels, counts):
        lines.append("  %-13s %7d  %5.1f %%" % (label, count, 100.0 * count / max(1, total)))
    under_a_second = counts[0] + counts[1]
    lines.append("under one second: %d rows, %.1f %% — the rows F317's rule touches"
                 % (under_a_second, 100.0 * under_a_second / max(1, total)))
    return "\n".join(lines)


def load(library):
    path = library if library.endswith(".json") else os.path.join(library, "meetings.json")
    with open(path, encoding="utf-8") as handle:
        index = json.load(handle)
    return index.get("meetings", index) if isinstance(index, dict) else index


def self_test():
    meetings = [{"segments": [
        {"start": 0.0, "end": 0.4},          # under 0.5
        {"start": 1.0, "end": 1.9},          # 0.5-1
        {"start": 2.0, "end": 4.0},          # 1-3
        {"start": 5.0, "end": 12.0},         # 3-10
        {"start": 20.0, "end": 40.0},        # 10+
        {"start": 50.0},                     # no end, no following start: untimed
    ]}]
    durations, untimed = row_durations(meetings)
    assert untimed == 1, untimed
    assert histogram(durations) == [1, 1, 1, 1, 1], histogram(durations)

    # An absent `end` falls back to the next row's start, the same three-level rule the app uses.
    derived, untimed = row_durations([{"segments": [{"start": 0.0}, {"start": 0.2, "end": 1.0}]}])
    assert untimed == 0 and abs(derived[0] - 0.2) < 1e-9, (derived, untimed)

    text = render(meetings)
    assert "under one second: 2 rows, 40.0 %" in text, text
    assert "hello" not in text
    print("row_lengths self-test passed")


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--library", help="a WhisperMeet library root, or a meetings.json")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args(argv)
    if args.self_test:
        self_test()
        return 0
    if not args.library:
        parser.error("--library is required unless --self-test")
    print(render(load(args.library)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
