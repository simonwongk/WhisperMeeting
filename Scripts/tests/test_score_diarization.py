#!/usr/bin/env python3
"""Regression tests for the diarization scorer (F217).

The scorer decides whether a diarization runtime is good enough to ship, so a silently wrong scorer
is worse than no scorer: it produces confident numbers nobody can check. These tests pin it against
pyannote.metrics' published golden vectors and against the specific ways a hand-written DER goes
wrong.

Run: python3 Scripts/tests/test_score_diarization.py
"""
import os
import subprocess
import sys
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
BENCH = os.path.join(os.path.dirname(HERE), "bench", "diarization")
sys.path.insert(0, BENCH)

import score_diarization as S  # noqa: E402


class GoldenVectors(unittest.TestCase):
    """The published pyannote.metrics test case, asserted component by component.

    Asserting only the DER ratio would pass on two compensating errors, so every component is
    pinned separately.
    """

    REFERENCE = [(0, 10, "A"), (12, 20, "B"), (24, 27, "A"), (30, 40, "C")]
    HYPOTHESIS = [(2, 13, "a"), (13, 14, "d"), (14, 20, "b"), (22, 38, "c"), (38, 40, "d")]

    def test_components(self):
        got = S.score(self.REFERENCE, self.HYPOTHESIS, uem=[(0, 40)])
        self.assertAlmostEqual(got["total"], 31.0)
        self.assertAlmostEqual(got["correct"], 22.0)
        self.assertAlmostEqual(got["miss"], 2.0)
        self.assertAlmostEqual(got["false_alarm"], 7.0)
        self.assertAlmostEqual(got["confusion"], 7.0)
        self.assertAlmostEqual(got["der"], 16.0 / 31.0)

    def test_overlap_changes_the_denominator(self):
        # The denominator is speaker-weighted reference time, not wall clock: ten seconds of two
        # concurrent speakers contributes twenty. Getting this wrong is the most common DER bug.
        overlapping = [(0, 13, "A"), (12, 20, "B"), (24, 27, "A"), (30, 40, "C")]
        kept = S.score(overlapping, self.HYPOTHESIS, uem=[(0, 40)], skip_overlap=False)
        skipped = S.score(overlapping, self.HYPOTHESIS, uem=[(0, 40)], skip_overlap=True)
        self.assertAlmostEqual(kept["total"], 34.0)
        self.assertAlmostEqual(skipped["total"], 32.0)

    def test_collar_is_a_full_width(self):
        # pyannote's convention: `collar` is the TOTAL width centred on each reference boundary, so
        # collar=1 removes 0.5 s at each of the two boundaries of a 10 s turn, leaving 9 s.
        # md-eval's -c is a half-width. Getting this backwards shifts DER by several points and is
        # the classic "my scorer doesn't match the paper" cause.
        collared = S.score([(0, 10, "A")], [], uem=[(0, 10)], collar=1.0)
        self.assertAlmostEqual(collared["total"], 9.0)


class MappingAndBounds(unittest.TestCase):
    def test_permutation_invariance(self):
        # A perfect hypothesis with renamed speakers must score zero: the whole purpose of the
        # Hungarian mapping.
        reference = [(0, 10, "A"), (12, 20, "B"), (24, 27, "A"), (30, 40, "C")]
        permuted = [(0, 10, "z"), (12, 20, "y"), (24, 27, "z"), (30, 40, "x")]
        self.assertAlmostEqual(S.score(reference, permuted, uem=[(0, 40)])["der"], 0.0)

    def test_der_is_unbounded(self):
        # Five spurious speakers over a one-speaker reference is 400% DER. Never clamp it: a clamp
        # would hide exactly the catastrophic over-clustering this project had to detect.
        spurious = [(0, 10, "s%d" % i) for i in range(5)]
        self.assertAlmostEqual(S.score([(0, 10, "A")], spurious, uem=[(0, 10)])["der"], 4.0)

    def test_mapping_drops_zero_cooccurrence_pairs(self):
        # A rectangular assignment must not marry two speakers who never overlap; that would turn
        # honest false alarm into apparent confusion.
        mapping = S.optimal_mapping([(0, 5, "h1")], [(90, 95, "R1")])
        self.assertEqual(mapping, {})

    def test_adjacent_same_label_turns_merge(self):
        # One speaker split across two touching turns is one speaker, not two active at the seam.
        split = S.score([(0, 10, "A")], [(0, 5, "a"), (5, 10, "a")], uem=[(0, 10)])
        self.assertAlmostEqual(split["der"], 0.0)

    def test_empty_reference(self):
        self.assertAlmostEqual(S.jaccard_error_rate([], [(0, 1, "a")])["jer"], 1.0)


class DisplayedLabelMetrics(unittest.TestCase):
    """These mirror SpeakerOverlay's rule in Swift; if the two drift, the scorecard stops describing
    the product."""

    def test_unambiguous_segment_is_labelled(self):
        m = S.displayed_label_metrics([(0, 10, "A")], [(0, 10, "a")])
        self.assertEqual(m["labelled"], 1)
        self.assertEqual(m["labelled_correct"], 1)

    def test_split_segment_abstains(self):
        # 50/50 coverage fails both the 80% floor and the 20-point margin.
        m = S.displayed_label_metrics([(0, 10, "A")], [(0, 5, "a"), (5, 10, "b")])
        self.assertEqual(m["labelled"], 0)
        self.assertEqual(m["abstained"], 1)

    def test_coverage_floor(self):
        below = S.displayed_label_metrics([(0, 100, "A")], [(0, 79, "a")])
        above = S.displayed_label_metrics([(0, 100, "A")], [(0, 81, "a")])
        self.assertEqual(below["labelled"], 0)
        self.assertEqual(above["labelled"], 1)


class SelfTestEntryPoint(unittest.TestCase):
    def test_self_test_passes(self):
        # The scorer ships a --self-test; make sure the documented entry point actually works, since
        # the README tells people to run it before trusting any number.
        result = subprocess.run(
            [sys.executable, os.path.join(BENCH, "score_diarization.py"), "--self-test"],
            capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("All golden vectors pass", result.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
