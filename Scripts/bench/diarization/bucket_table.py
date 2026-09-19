#!/usr/bin/env python3
"""The F317 table: what a displayed label is worth, by reference-turn length and overlap (F340).

`sweep_score.py` emits one aggregate row per threshold. The six-way split by row length x whether
anyone else is talking — the table the product change actually rests on, and the one F338 recomputes
against — had no committed producer. This is it.

    python3 bucket_table.py --rttm <dir> --hypotheses <sweep out>/0.60 [--gate 1.0]
    python3 bucket_table.py --self-test

A row is one reference turn. It is "named" when `score_diarization.overlay_label` would show a
cluster for it, and "named correctly" when that cluster is the one the optimal mapping assigns to
the turn's own speaker. `--gate` is the sub-second floor under test: pass 0 to see the table the
rule was chosen from, and 1.0 to see what it does.

Also prints the two aggregate lines the scorecard quotes — displayed precision and coverage, with
and without the gate — so the headline and the buckets come from one run of one script.
"""

import argparse
import json
import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
import score_diarization as sd          # noqa: E402


BUCKETS = [
    ("nobody else talking, under 1 s", False, 0.0, 1.0),
    ("nobody else talking, 1-3 s", False, 1.0, 3.0),
    ("nobody else talking, 3 s or more", False, 3.0, float("inf")),
    ("someone else also talking, under 1 s", True, 0.0, 1.0),
    ("someone else also talking, 1-3 s", True, 1.0, 3.0),
    ("someone else also talking, 3 s or more", True, 3.0, float("inf")),
]


def is_overlapped(turn, reference):
    """Whether anyone else is talking during any part of this reference turn."""
    start, end, speaker = turn
    for other_start, other_end, other_speaker in reference:
        if other_speaker == speaker:
            continue
        if min(end, other_end) - max(start, other_start) > 0:
            return True
    return False


def bucket_of(turn, reference):
    duration = turn[1] - turn[0]
    overlapped = is_overlapped(turn, reference)
    for name, wants_overlap, low, high in BUCKETS:
        if wants_overlap == overlapped and low <= duration < high:
            return name
    return None


def tally(reference, hypothesis, mapping, gate):
    """Counts per bucket: rows, named, named correctly."""
    counts = {name: [0, 0, 0] for name, _, _, _ in BUCKETS}
    for turn in reference:
        name = bucket_of(turn, reference)
        if name is None:
            continue
        counts[name][0] += 1
        # The gate is a parameter of the shared rule, never a second copy of it: the mirror in
        # `score_diarization` is what the scorecard's numbers come from, and a divergence here
        # would be invisible.
        shown = sd.overlay_label((turn[0], turn[1]), hypothesis, minimum_labelled_duration=gate)
        if shown is None or shown == "OVERLAP":
            continue
        counts[name][1] += 1
        if mapping.get(shown) == turn[2]:
            counts[name][2] += 1
    return counts


def run(rttm_dir, hypothesis_dir, gate):
    totals = {name: [0, 0, 0] for name, _, _, _ in BUCKETS}
    for entry in sorted(os.listdir(hypothesis_dir)):
        if not entry.endswith(".json"):
            continue
        stem = entry[:-5]
        reference = sd.read_rttm(os.path.join(rttm_dir, stem + ".rttm"))
        with open(os.path.join(hypothesis_dir, entry), encoding="utf-8") as handle:
            hypothesis = [(t["start"], t["end"], t["speaker"]) for t in json.load(handle)]
        mapping = sd.optimal_mapping(reference, hypothesis)
        for name, counts in tally(reference, hypothesis, mapping, gate).items():
            for index in range(3):
                totals[name][index] += counts[index]
    return totals


def render(totals):
    lines = ["| reference turn | rows | named | named correctly |", "|---|---|---|---|"]
    rows = named = correct = 0
    for name, _, _, _ in BUCKETS:
        count, shown, right = totals[name]
        rows += count
        named += shown
        correct += right
        lines.append("| %s | %d | %.1f %% | %.1f %% |" % (
            name, count, 100.0 * shown / max(1, count), 100.0 * right / max(1, shown)
        ))
    lines.append("")
    lines.append("displayed precision %.1f %% over %d named rows; coverage %.1f %% of %d rows" % (
        100.0 * correct / max(1, named), named, 100.0 * named / max(1, rows), rows
    ))
    return "\n".join(lines)


def self_test():
    """Two meetings' worth of hand-checked arithmetic, so the table is not trusted on faith."""
    reference = [
        (0.0, 0.5, "A"),      # solo, under 1 s
        (2.0, 4.0, "A"),      # solo, 1-3 s
        (6.0, 12.0, "A"),     # solo, 3 s or more
        (20.0, 20.4, "B"),    # overlapped, under 1 s
        (20.0, 26.0, "A"),    # overlapped, 3 s or more
    ]
    assert bucket_of(reference[0], reference) == "nobody else talking, under 1 s"
    assert bucket_of(reference[1], reference) == "nobody else talking, 1-3 s"
    assert bucket_of(reference[2], reference) == "nobody else talking, 3 s or more"
    assert bucket_of(reference[3], reference) == "someone else also talking, under 1 s"
    assert bucket_of(reference[4], reference) == "someone else also talking, 3 s or more"

    # A hypothesis that names every row "a", which is A: so B's row is named and wrong.
    hypothesis = [(0.0, 30.0, "a")]
    mapping = {"a": "A"}

    ungated = tally(reference, hypothesis, mapping, gate=0.0)
    assert ungated["nobody else talking, under 1 s"] == [1, 1, 1], ungated
    assert ungated["someone else also talking, under 1 s"] == [1, 1, 0], ungated

    gated = tally(reference, hypothesis, mapping, gate=1.0)
    assert gated["nobody else talking, under 1 s"] == [1, 0, 0], gated
    assert gated["someone else also talking, under 1 s"] == [1, 0, 0], gated
    assert gated["nobody else talking, 3 s or more"] == [1, 1, 1], gated

    # The gate trades one correct name for one wrong one here, so precision rises and coverage falls.
    def totals(counts):
        named = sum(v[1] for v in counts.values())
        correct = sum(v[2] for v in counts.values())
        return named, correct
    assert totals(ungated) == (5, 4), totals(ungated)
    assert totals(gated) == (3, 3), totals(gated)
    print("bucket_table self-test passed")


def main(argv):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--rttm", help="directory of <name>.rttm reference files")
    parser.add_argument("--hypotheses", help="one threshold directory from `sweep`")
    parser.add_argument("--gate", type=float, default=1.0,
                        help="sub-second floor to apply, in seconds (default 1.0; 0 disables)")
    parser.add_argument("--self-test", action="store_true")
    args = parser.parse_args(argv)
    if args.self_test:
        self_test()
        return 0
    if not args.rttm or not args.hypotheses:
        parser.error("--rttm and --hypotheses are required unless --self-test")
    print(render(run(args.rttm, args.hypotheses, args.gate)))
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
