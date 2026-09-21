#!/usr/bin/env python3
"""Diarization scoring for WhisperMeet's speaker-turn benchmark (F217).

Computes DER and JER from two lists of ``(start, end, speaker)`` turns, following the NIST
``md-eval-22.pl`` accounting and the pyannote.metrics definitions. Stdlib only — the rest of
``Scripts/`` has no third-party Python dependency and this does not introduce one, so the Hungarian
assignment is implemented here rather than taken from scipy.

Two conventions are chosen explicitly, because both have a widely-used opposite:

* ``collar`` is a **full width** centred on each reference boundary (pyannote's convention), so the
  conventional NIST 250 ms half-collar is ``--collar 0.5``. md-eval's ``-c`` is a half-width. Getting
  this backwards moves DER by several points and is the usual reason a scorer "doesn't match the
  paper".
* The optimal mapping is computed **after** collars and overlap exclusion are applied (pyannote's
  convention, not md-eval's). Sub-0.5% deltas against a number scored the other way are expected.

The denominator is speaker-weighted reference time, ``sum(d * n_ref)`` — not wall-clock. Ten seconds
of two concurrent reference speakers contributes twenty seconds. DER is therefore **unbounded above**
and is never clamped.

Run ``--self-test`` to check the implementation against pyannote's published golden vectors before
trusting any number it produces.
"""
import argparse
import json
import sys
from collections import defaultdict

EPS = 1e-6


# --------------------------------------------------------------------------------------
# Interval arithmetic
# --------------------------------------------------------------------------------------

def _merge(intervals):
    """Union of intervals, returned sorted and non-overlapping."""
    ordered = sorted((s, e) for s, e in intervals if e - s > EPS)
    if not ordered:
        return []
    merged = [list(ordered[0])]
    for start, end in ordered[1:]:
        if start <= merged[-1][1] + EPS:
            merged[-1][1] = max(merged[-1][1], end)
        else:
            merged.append([start, end])
    return [(s, e) for s, e in merged]


def _subtract(base, holes):
    """base minus holes, both as interval lists."""
    holes = _merge(holes)
    result = []
    for start, end in _merge(base):
        cursor = start
        for hole_start, hole_end in holes:
            if hole_end <= cursor or hole_start >= end:
                continue
            if hole_start > cursor:
                result.append((cursor, min(hole_start, end)))
            cursor = max(cursor, hole_end)
            if cursor >= end:
                break
        if cursor < end:
            result.append((cursor, end))
    return [(s, e) for s, e in result if e - s > EPS]


def _duration(intervals):
    return sum(e - s for s, e in intervals)


def _crop(turns, region):
    """Intersect every turn with `region`, splitting where the region has holes."""
    cropped = []
    for start, end, label in turns:
        for region_start, region_end in region:
            lo, hi = max(start, region_start), min(end, region_end)
            if hi - lo > EPS:
                cropped.append((lo, hi, label))
    return cropped


def normalise(turns):
    """Drop empty turns and merge same-label turns that touch or overlap.

    Without this, one speaker represented as two adjacent turns would count as two active speakers
    in the segment where they touch, inflating both the denominator and the false-alarm term.
    """
    by_label = defaultdict(list)
    for start, end, label in turns:
        if end - start > EPS:
            by_label[label].append((start, end))
    result = []
    for label, intervals in by_label.items():
        for start, end in _merge(intervals):
            result.append((start, end, label))
    return sorted(result)


# --------------------------------------------------------------------------------------
# Hungarian assignment (Jonker-Volgenant shortest-augmenting-path, O(n^3))
# --------------------------------------------------------------------------------------

def _hungarian_min(cost):
    """Minimum-cost assignment for a rectangular matrix with rows <= cols.

    Returns a list giving, for each row, the column assigned to it.
    """
    n_rows, n_cols = len(cost), len(cost[0])
    assert n_rows <= n_cols
    inf = float("inf")
    u = [0.0] * (n_rows + 1)
    v = [0.0] * (n_cols + 1)
    parent = [0] * (n_cols + 1)
    way = [0] * (n_cols + 1)

    for row in range(1, n_rows + 1):
        parent[0] = row
        col0 = 0
        minv = [inf] * (n_cols + 1)
        used = [False] * (n_cols + 1)
        while True:
            used[col0] = True
            row0, delta, col1 = parent[col0], inf, -1
            for col in range(1, n_cols + 1):
                if used[col]:
                    continue
                current = cost[row0 - 1][col - 1] - u[row0] - v[col]
                if current < minv[col]:
                    minv[col], way[col] = current, col0
                if minv[col] < delta:
                    delta, col1 = minv[col], col
            for col in range(n_cols + 1):
                if used[col]:
                    u[parent[col]] += delta
                    v[col] -= delta
                else:
                    minv[col] -= delta
            col0 = col1
            if parent[col0] == 0:
                break
        while True:
            col1 = way[col0]
            parent[col0] = parent[col1]
            col0 = col1
            if col0 == 0:
                break

    assignment = [-1] * n_rows
    for col in range(1, n_cols + 1):
        if parent[col] != 0:
            assignment[parent[col] - 1] = col - 1
    return assignment


def cooccurrence(hyp_turns, ref_turns):
    """Matrix of total simultaneously-active duration for every (hypothesis, reference) pair."""
    hyp_labels = sorted({label for _, _, label in hyp_turns})
    ref_labels = sorted({label for _, _, label in ref_turns})
    index_h = {label: i for i, label in enumerate(hyp_labels)}
    index_r = {label: i for i, label in enumerate(ref_labels)}
    matrix = [[0.0] * len(ref_labels) for _ in hyp_labels]
    for h_start, h_end, h_label in hyp_turns:
        for r_start, r_end, r_label in ref_turns:
            overlap = min(h_end, r_end) - max(h_start, r_start)
            if overlap > 0:
                matrix[index_h[h_label]][index_r[r_label]] += overlap
    return hyp_labels, ref_labels, matrix


def read_rttm(path):
    """Reference turns from a NIST RTTM file, as (start, end, speaker) tuples.

    Lived in `sweep_score.py` until F348, where `bucket_table.py` called `sd.read_rttm` and
    discovered it did not exist — the producer had never been run against a real file, because its
    self-test fed `tally` hand-made turns and never reached the reading path. One copy, in the
    module both readers already import.
    """
    turns = []
    with open(path, encoding="utf-8") as handle:
        for line in handle:
            parts = line.split()
            if len(parts) >= 8 and parts[0] == "SPEAKER":
                start, duration = float(parts[3]), float(parts[4])
                turns.append((start, start + duration, parts[7]))
    return turns


def optimal_mapping(hyp_turns, ref_turns):
    """One global injective map hypothesis_label -> reference_label maximising matched time.

    Pairs that never co-occur are dropped: a padding artifact must not marry two speakers who never
    overlap, because that would convert honest false alarm into apparent confusion.
    """
    hyp_labels, ref_labels, matrix = cooccurrence(hyp_turns, ref_turns)
    if not hyp_labels or not ref_labels:
        return {}
    transposed = len(hyp_labels) > len(ref_labels)
    cost = [[-value for value in row] for row in matrix]
    if transposed:
        cost = [list(column) for column in zip(*cost)]
    assignment = _hungarian_min(cost)

    mapping = {}
    for row, col in enumerate(assignment):
        if col < 0:
            continue
        h_index, r_index = (col, row) if transposed else (row, col)
        if matrix[h_index][r_index] > 0:
            mapping[hyp_labels[h_index]] = ref_labels[r_index]
    return mapping


# --------------------------------------------------------------------------------------
# Scored region
# --------------------------------------------------------------------------------------

def collar_regions(ref_turns, collar):
    """No-score windows of total width `collar` centred on every reference boundary.

    Anchored on the reference only — a hypothesis boundary earns no forgiveness.
    """
    if collar <= 0:
        return []
    half = collar / 2.0
    regions = []
    for start, end, _ in ref_turns:
        regions.append((start - half, start + half))
        regions.append((end - half, end + half))
    return _merge(regions)


def overlap_regions(ref_turns):
    """Every region where two or more distinct reference speakers are active."""
    events = []
    for start, end, label in ref_turns:
        events.append((start, 1, label))
        events.append((end, -1, label))
    # End before begin at equal times, so a turn ending exactly where another begins does not
    # register as one instant of overlap.
    events.sort(key=lambda event: (event[0], event[1]))

    regions = []
    active = defaultdict(int)
    distinct = 0
    opened_at = None
    for time, delta, label in events:
        before = distinct
        active[label] += delta
        if active[label] == 1 and delta == 1:
            distinct += 1
        elif active[label] == 0 and delta == -1:
            distinct -= 1
        if before < 2 <= distinct:
            opened_at = time
        elif before >= 2 > distinct and opened_at is not None:
            regions.append((opened_at, time))
            opened_at = None
    return _merge(regions)


def scored_region(ref_turns, hyp_turns, uem, collar, skip_overlap):
    if uem is None:
        starts = [t[0] for t in ref_turns + hyp_turns]
        ends = [t[1] for t in ref_turns + hyp_turns]
        if not starts:
            return []
        uem = [(min(starts), max(ends))]
    holes = collar_regions(ref_turns, collar)
    if skip_overlap:
        holes = holes + overlap_regions(ref_turns)
    return _subtract(uem, holes)


# --------------------------------------------------------------------------------------
# DER / JER
# --------------------------------------------------------------------------------------

def _elementary_segments(ref_turns, hyp_turns, region):
    boundaries = set()
    for start, end, _ in ref_turns + hyp_turns:
        boundaries.add(start)
        boundaries.add(end)
    for start, end in region:
        boundaries.add(start)
        boundaries.add(end)
    ordered = sorted(boundaries)
    segments = []
    for lo, hi in zip(ordered, ordered[1:]):
        if hi - lo <= EPS:
            continue
        mid = (lo + hi) / 2.0
        if any(rs <= mid <= re for rs, re in region):
            segments.append((lo, hi))
    return segments


def _active(turns, lo, hi):
    mid = (lo + hi) / 2.0
    return {label for start, end, label in turns if start <= mid <= end}


def score(ref_turns, hyp_turns, uem=None, collar=0.0, skip_overlap=False):
    """DER components for one file. Returns a dict of raw durations plus the ratio.

    The components are returned, not just the ratio, because a ratio cannot be re-aggregated across
    files and cannot be debugged.
    """
    reference = normalise(ref_turns)
    hypothesis = normalise(hyp_turns)
    region = scored_region(reference, hypothesis, uem, collar, skip_overlap)
    reference = normalise(_crop(reference, region))
    hypothesis = normalise(_crop(hypothesis, region))

    mapping = optimal_mapping(hypothesis, reference)
    assert len(set(mapping.values())) == len(mapping), "mapping must be injective"

    total = correct = miss = false_alarm = confusion = 0.0
    for lo, hi in _elementary_segments(reference, hypothesis, region):
        duration = hi - lo
        ref_set = _active(reference, lo, hi)
        hyp_set = _active(hypothesis, lo, hi)
        # The image of the hypothesis set in reference label space. n_hyp stays |hyp_set|:
        # an unmapped hypothesis speaker still occupies a slot and still generates false alarm.
        mapped = {mapping[label] for label in hyp_set if label in mapping}
        n_ref, n_hyp = len(ref_set), len(hyp_set)
        n_correct = len(ref_set & mapped)
        assert min(n_ref, n_hyp) - n_correct >= 0, "negative confusion: mapping is wrong"

        total += duration * n_ref
        correct += duration * n_correct
        miss += duration * max(n_ref - n_hyp, 0)
        false_alarm += duration * max(n_hyp - n_ref, 0)
        confusion += duration * (min(n_ref, n_hyp) - n_correct)

    errors = miss + false_alarm + confusion
    if total > 0:
        der = errors / total
    else:
        der = 0.0 if errors == 0 else 1.0
    return {
        "total": total,
        "correct": correct,
        "miss": miss,
        "false_alarm": false_alarm,
        "confusion": confusion,
        "der": der,
        "speakers_reference": len({label for _, _, label in reference}),
        "speakers_hypothesis": len({label for _, _, label in hypothesis}),
    }


def jaccard_error_rate(ref_turns, hyp_turns, uem=None, collar=0.0, skip_overlap=False):
    """JER: the mean per-reference-speaker Jaccard distance.

    Iterates over *reference* speakers, so an unmapped hypothesis speaker is invisible to it — the
    deliberate design that bounds JER to [0, 1] while DER is unbounded. It complements DER precisely
    because DER is dominated by whoever spoke most: a quiet participant who is entirely mis-clustered
    barely moves DER but moves JER a full 1/N.
    """
    reference = normalise(ref_turns)
    hypothesis = normalise(hyp_turns)
    region = scored_region(reference, hypothesis, uem, collar, skip_overlap)
    reference = normalise(_crop(reference, region))
    hypothesis = normalise(_crop(hypothesis, region))

    ref_labels = sorted({label for _, _, label in reference})
    if not ref_labels:
        return {"jer": 1.0, "speaker_count": 0, "speaker_errors": 0.0}

    mapping = optimal_mapping(hypothesis, reference)
    inverse = {ref: hyp for hyp, ref in mapping.items()}

    errors = 0.0
    for ref_label in ref_labels:
        ref_intervals = _merge([(s, e) for s, e, l in reference if l == ref_label])
        hyp_label = inverse.get(ref_label)
        if hyp_label is None:
            errors += 1.0
            continue
        hyp_intervals = _merge([(s, e) for s, e, l in hypothesis if l == hyp_label])
        union = _duration(_merge(ref_intervals + hyp_intervals))
        if union <= 0:
            errors += 1.0
            continue
        intersection = _duration(_subtract(ref_intervals, _subtract(ref_intervals, hyp_intervals)))
        errors += (union - intersection) / union
    return {
        "jer": errors / len(ref_labels),
        "speaker_count": len(ref_labels),
        "speaker_errors": errors,
    }


# The four cells of {collar} x {overlap} reported together: the same pass with a different scored
# region. The gap between cells is itself diagnostic — a large collar gap means boundary jitter
# dominates, a large overlap gap means missed overlapping speech dominates, and those want
# different fixes.
CONDITIONS = (
    ("no_collar_overlap_scored", 0.0, False),
    ("no_collar_overlap_skipped", 0.0, True),
    ("collar250_overlap_scored", 0.5, False),
    ("collar250_overlap_skipped", 0.5, True),
)


def score_all_conditions(ref_turns, hyp_turns, uem=None):
    report = {}
    for name, collar, skip_overlap in CONDITIONS:
        components = score(ref_turns, hyp_turns, uem, collar, skip_overlap)
        components.update(jaccard_error_rate(ref_turns, hyp_turns, uem, collar, skip_overlap))
        report[name] = components
    return report


def micro_average(per_file, condition):
    """Corpus DER is one division over summed components, never a mean of per-file ratios."""
    total = miss = false_alarm = confusion = 0.0
    speaker_errors = speaker_count = 0.0
    for report in per_file:
        cell = report[condition]
        total += cell["total"]
        miss += cell["miss"]
        false_alarm += cell["false_alarm"]
        confusion += cell["confusion"]
        speaker_errors += cell["speaker_errors"]
        speaker_count += cell["speaker_count"]
    errors = miss + false_alarm + confusion
    return {
        "total": total,
        "miss": miss,
        "false_alarm": false_alarm,
        "confusion": confusion,
        "der": (errors / total) if total > 0 else (0.0 if errors == 0 else 1.0),
        "jer": (speaker_errors / speaker_count) if speaker_count else 1.0,
    }


# --------------------------------------------------------------------------------------
# Displayed-label metrics: what a reader actually sees
# --------------------------------------------------------------------------------------

MINIMUM_COVERAGE = 0.80
MINIMUM_MARGIN = 0.20
# Rows shorter than this are never named (F317) — SpeakerOverlay.minimumLabelledDuration.
MINIMUM_LABELLED_DURATION = 1.0


def overlay_label(segment, hyp_turns, uncertain_below=None, confidences=None,
                  minimum_labelled_duration=MINIMUM_LABELLED_DURATION):
    """Mirror of WhisperCore's SpeakerOverlay rule, for scoring what the UI would show.

    Kept deliberately in lockstep with Sources/WhisperCore/SpeakerOverlay.swift: a cluster is named
    only when the segment is at least a second long AND it covers >= 80% of it AND beats the
    runner-up by >= 20 points. Any drift between the two is a bug in one of them, so the scorecard's
    "displayed" numbers would stop describing the product.

    One rule the mirror does NOT have, and the claim used to imply it did (F343): the Swift side
    abstains when an `.overlap` turn intersects the row, and an RTTM reference carries no overlap
    *turns* — overlap is implied by two turns covering the same instant, which this scores as
    ordinary competing coverage. So `"OVERLAP"` below is reachable only from a caller that passes
    confidences, and the 75%-overlapped AMI numbers in the scorecard are produced by the coverage
    and margin rules alone. The sub-second gate is exercised by
    `Scripts/tests/test_score_diarization.py`; before F343 it was not, so this mirror could have
    drifted on the newest rule without a single test noticing.
    """
    seg_start, seg_end = segment
    duration = seg_end - seg_start
    if duration <= 0:
        return None
    coverage = {}
    overlap_seconds = 0.0
    for index, (start, end, label) in enumerate(hyp_turns):
        intersection = min(end, seg_end) - max(start, seg_start)
        if intersection <= 0:
            continue
        if confidences is not None and uncertain_below is not None:
            confidence = confidences[index]
            # -2.0 is the runtime's "unavailable" sentinel, not a low score; never threshold it.
            if confidence is not None and confidence != -2.0 and confidence < uncertain_below:
                overlap_seconds += 0.0   # an uncertain turn contributes to neither side
                continue
        coverage[label] = coverage.get(label, 0.0) + intersection
    if overlap_seconds > 0:
        return "OVERLAP"
    if not coverage:
        return None
    # A parameter, not the constant, so `bucket_table.py` can produce the before-and-after table the
    # rule was chosen from without a second copy of this function (F340). Every caller in the
    # scoring path leaves it at the shipped default.
    if duration < minimum_labelled_duration - 1e-9:
        return None
    ranked = sorted(coverage.items(), key=lambda kv: (-kv[1], kv[0]))
    best_share = ranked[0][1] / duration
    runner_up = ranked[1][1] / duration if len(ranked) > 1 else 0.0
    if best_share >= MINIMUM_COVERAGE and best_share - runner_up >= MINIMUM_MARGIN:
        return ranked[0][0]
    return None


def displayed_label_metrics(ref_turns, hyp_turns, mapping=None,
                            uncertain_below=None, confidences=None):
    """Precision, coverage and abstention of the labels the transcript would actually render.

    Each reference turn stands in for one ASR segment, which is the right granularity: a reader sees
    one label per transcript row, not per millisecond. DER counts time; this counts rows, and a
    feature whose posture is "abstain rather than guess" has to be judged on rows.
    """
    reference = normalise(ref_turns)
    hypothesis = normalise(hyp_turns)
    if mapping is None:
        mapping = optimal_mapping(hypothesis, reference)

    shown = correct = abstained = 0
    for start, end, ref_label in reference:
        label = overlay_label((start, end), hypothesis,
                              uncertain_below=uncertain_below, confidences=confidences)
        if label is None or label == "OVERLAP":
            abstained += 1
            continue
        shown += 1
        if mapping.get(label) == ref_label:
            correct += 1
    total = len(reference)
    return {
        "segments": total,
        "labelled": shown,
        "labelled_correct": correct,
        "abstained": abstained,
        # Of the labels we chose to show, how many were right. This is the number that decides
        # whether a reader can trust what they see.
        "displayed_precision": (correct / shown) if shown else 1.0,
        # How often we were willing to say anything at all.
        "coverage": (shown / total) if total else 0.0,
        "abstention_rate": (abstained / total) if total else 0.0,
    }


# --------------------------------------------------------------------------------------
# Self-test: golden vectors from pyannote.metrics' own suite
# --------------------------------------------------------------------------------------

def _self_test():
    failures = []

    def check(name, actual, expected, tolerance=1e-9):
        if abs(actual - expected) > tolerance:
            failures.append("%s: expected %r, got %r" % (name, expected, actual))
        else:
            print("  ok  %-42s %r" % (name, actual))

    # pyannote test_detailed. The full component breakdown, not just the ratio, because a scorer can
    # land the right DER from two compensating errors.
    reference = [(0, 10, "A"), (12, 20, "B"), (24, 27, "A"), (30, 40, "C")]
    hypothesis = [(2, 13, "a"), (13, 14, "d"), (14, 20, "b"), (22, 38, "c"), (38, 40, "d")]
    got = score(reference, hypothesis, uem=[(0, 40)])
    check("golden total", got["total"], 31.0)
    check("golden correct", got["correct"], 22.0)
    check("golden miss", got["miss"], 2.0)
    check("golden false_alarm", got["false_alarm"], 7.0)
    check("golden confusion", got["confusion"], 7.0)
    check("golden der", got["der"], 16.0 / 31.0)

    # Overlap denominators: pyannote test_leep_overlap / test_skip_overlap.
    overlapping = [(0, 13, "A"), (12, 20, "B"), (24, 27, "A"), (30, 40, "C")]
    kept = score(overlapping, hypothesis, uem=[(0, 40)], skip_overlap=False)
    check("overlap kept total", kept["total"], 34.0)
    skipped = score(overlapping, hypothesis, uem=[(0, 40)], skip_overlap=True)
    check("overlap skipped total", skipped["total"], 32.0)

    # Collar width: pyannote test_bug_16. collar=1 removes 0.5 s at each of the two boundaries,
    # not 1.0 s each. Getting this backwards is the classic factor-of-two error.
    collared = score([(0, 10, "A")], [], uem=[(0, 10)], collar=1.0)
    check("collar width total", collared["total"], 9.0)

    # JER on an empty reference is 1.0, not a ZeroDivisionError.
    check("empty reference jer", jaccard_error_rate([], hypothesis)["jer"], 1.0)

    # A perfect hypothesis with permuted labels must score zero — the whole point of the mapping.
    permuted = [(0, 10, "z"), (12, 20, "y"), (24, 27, "z"), (30, 40, "x")]
    check("permutation invariance", score(reference, permuted, uem=[(0, 40)])["der"], 0.0)

    # DER is unbounded: five spurious speakers over a short reference exceeds 100%.
    spurious = [(0, 10, "s%d" % i) for i in range(5)]
    check("unbounded der", score([(0, 10, "A")], spurious, uem=[(0, 10)])["der"], 4.0)

    # A speaker split across two adjacent turns is one speaker, not two.
    split = score([(0, 10, "A")], [(0, 5, "a"), (5, 10, "a")], uem=[(0, 10)])
    check("adjacent same-label merge", split["der"], 0.0)

    if failures:
        print("\nFAILED:")
        for failure in failures:
            print("  " + failure)
        return 1
    print("\nAll golden vectors pass.")
    return 0


def main():
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--self-test", action="store_true",
                        help="check the implementation against pyannote's golden vectors and exit")
    parser.add_argument("input", nargs="?",
                        help='JSON: {"files":[{"id":..,"duration":..,"reference":[[s,e,spk]..],'
                             '"hypothesis":[[s,e,spk]..]}]}')
    parser.add_argument("--json", action="store_true", help="emit the full scorecard as JSON")
    args = parser.parse_args()

    if args.self_test:
        return _self_test()
    if not args.input:
        parser.error("an input file is required unless --self-test is given")

    with open(args.input, encoding="utf-8") as handle:
        payload = json.load(handle)

    per_file = []
    rows = []
    for entry in payload["files"]:
        reference = [tuple(turn) for turn in entry["reference"]]
        hypothesis = [tuple(turn) for turn in entry["hypothesis"]]
        uem = [(0.0, float(entry["duration"]))] if entry.get("duration") else None
        report = score_all_conditions(reference, hypothesis, uem)
        report["id"] = entry["id"]
        report["stratum"] = entry.get("stratum", "")
        per_file.append(report)
        primary = report["no_collar_overlap_scored"]
        rows.append((entry["id"], entry.get("stratum", ""), primary["der"],
                     report["collar250_overlap_skipped"]["der"], primary["jer"],
                     primary["speakers_reference"], primary["speakers_hypothesis"]))

    if args.json:
        print(json.dumps({
            "files": per_file,
            "micro": {name: micro_average(per_file, name) for name, _, _ in CONDITIONS},
        }, indent=2, sort_keys=True))
        return 0

    print("%-18s %-16s %>8s %>10s %>8s %>6s" % ("id", "stratum", "DER", "DER-NIST", "JER", "spk"))
    for row in rows:
        print("%-18s %-16s %8.2f%% %9.2f%% %7.2f%% %3d/%-3d" % (
            row[0], row[1], 100 * row[2], 100 * row[3], 100 * row[4], row[5], row[6]))
    for name, _, _ in CONDITIONS:
        micro = micro_average(per_file, name)
        print("micro %-28s DER %7.2f%%  JER %7.2f%%  (total %.1f s)" % (
            name, 100 * micro["der"], 100 * micro["jer"], micro["total"]))
    return 0


if __name__ == "__main__":
    sys.exit(main())
