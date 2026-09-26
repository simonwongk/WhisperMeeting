#!/usr/bin/env python3
"""Regression tests for the diarization scorer (F217).

The scorer decides whether a diarization runtime is good enough to ship, so a silently wrong scorer
is worse than no scorer: it produces confident numbers nobody can check. These tests pin it against
pyannote.metrics' published golden vectors and against the specific ways a hand-written DER goes
wrong.

Run: python3 Scripts/tests/test_score_diarization.py
"""
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
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

    def test_sub_second_rows_are_never_named(self):
        # F317's gate, and F343: every case here used 10 s or 100 s segments, so the newest rule in
        # the mirror was untested and would not have failed if it had been left out entirely.
        short = S.displayed_label_metrics([(0, 0.6, "A")], [(0, 0.6, "a")])
        self.assertEqual(short["labelled"], 0)
        self.assertEqual(short["abstained"], 1)

    def test_the_one_second_boundary_is_inclusive(self):
        # Exactly one second is named; a hair under is not. The Swift side allows a 1e-9 tolerance
        # for floating-point subtraction and so does the mirror — if one of them stops, this fails.
        exact = S.displayed_label_metrics([(0, 1.0, "A")], [(0, 1.0, "a")])
        self.assertEqual(exact["labelled"], 1)
        just_under = S.displayed_label_metrics([(0, 0.999, "A")], [(0, 0.999, "a")])
        self.assertEqual(just_under["labelled"], 0)


class SelfTestEntryPoint(unittest.TestCase):
    def test_self_test_passes(self):
        # The scorer ships a --self-test; make sure the documented entry point actually works, since
        # the README tells people to run it before trusting any number.
        result = subprocess.run(
            [sys.executable, os.path.join(BENCH, "score_diarization.py"), "--self-test"],
            capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("All golden vectors pass", result.stdout)

    def test_the_default_table_prints(self):
        # F480: the header's `%>8s` is not a %-format conversion, so every run without --json
        # raised ValueError before printing a row; only --self-test and --json had ever been run.
        with tempfile.TemporaryDirectory() as root:
            path = os.path.join(root, "scores.json")
            with open(path, "w", encoding="utf-8") as handle:
                json.dump({"files": [{"id": "m1", "stratum": "clean", "duration": 20.0,
                                      "reference": [[0, 10, "A"], [10, 20, "B"]],
                                      "hypothesis": [[0, 10, "a"], [10, 20, "b"]]}]}, handle)
            result = subprocess.run([sys.executable, os.path.join(BENCH, "score_diarization.py"), path],
                                    capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        header, row = result.stdout.splitlines()[:2]
        self.assertEqual(header.split(), ["id", "stratum", "DER", "DER-NIST", "JER", "spk"])
        self.assertEqual(row.split()[:5], ["m1", "clean", "0.00%", "0.00%", "0.00%"])
        # Each percentage heading ends where its column's values end, not merely present.
        ends = lambda line: [m.end() for m in re.finditer(r"\S+", line)]
        self.assertEqual(ends(header)[2:5], ends(row)[2:5])


def write_fixture(corpus, hypotheses, fixture_id, turns, hypothesis_lines):
    """A synthetic truth file, plus the runtime's text output unless `hypothesis_lines` is None."""
    with open(os.path.join(corpus, fixture_id + ".truth.json"), "w", encoding="utf-8") as handle:
        json.dump({"stratum": "synthetic", "duration": 20.0,
                   "turns": [{"start": s, "end": e, "speaker": k} for s, e, k in turns]}, handle)
    if hypothesis_lines is not None:
        with open(os.path.join(hypotheses, fixture_id + ".txt"), "w", encoding="utf-8") as handle:
            handle.write("loading model\nStarted\n" + "".join(line + "\n" for line in hypothesis_lines))


class ScoreCorpusAccountsForEveryFixture(unittest.TestCase):
    """F480: a fixture with no hypothesis was dropped from every table without a word, so the
    fixtures the runtime crashed on quietly improved 'ALL speech fixtures'."""

    TURNS = [(0.0, 10.0, "A"), (10.0, 20.0, "B")]
    PERFECT = ["0.00 -- 10.00 speaker_0 confidence=0.90", "10.00 -- 20.00 speaker_3 confidence=0.90"]

    def setUp(self):
        self.root = tempfile.mkdtemp()
        self.corpus = os.path.join(self.root, "corpus")
        self.hypotheses = os.path.join(self.root, "hyp")
        os.makedirs(self.corpus)
        os.makedirs(self.hypotheses)

    def tearDown(self):
        shutil.rmtree(self.root)

    def score(self, *extra):
        return subprocess.run(
            [sys.executable, os.path.join(BENCH, "score_corpus.py"), self.hypotheses,
             "--corpus", self.corpus, *extra],
            capture_output=True, text=True)

    def test_a_missing_hypothesis_is_named(self):
        write_fixture(self.corpus, self.hypotheses, "en_2spk_alt", self.TURNS, self.PERFECT)
        write_fixture(self.corpus, self.hypotheses, "long_turns", self.TURNS, None)
        result = self.score()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("scored 1 of 2 corpus fixtures; no hypothesis for: long_turns", result.stdout)
        as_json = self.score("--json")
        self.assertEqual(as_json.returncode, 0, as_json.stderr)
        self.assertEqual(sorted(json.loads(as_json.stdout)), ["en_2spk_alt"])   # stdout stays JSON
        self.assertIn("no hypothesis for: long_turns", as_json.stderr)

    def test_nothing_scored_is_a_refusal_not_a_table(self):
        write_fixture(self.corpus, self.hypotheses, "en_2spk_alt", self.TURNS, None)
        for extra in ((), ("--json",)):
            with self.subTest(extra=extra):
                result = self.score(*extra)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertNotIn("Traceback", result.stderr)
                self.assertIn("nothing was scored", result.stderr)
                self.assertEqual(result.stdout, "")

    def test_an_empty_corpus_is_a_refusal(self):
        result = self.score()
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertNotIn("Traceback", result.stderr)
        self.assertIn("no *.truth.json", result.stderr)

    def test_precision_over_nothing_shown_is_a_dash(self):
        # A run that named nobody showed no label, so none was wrong: `displayed_label_metrics`
        # calls that 1.0, and 0.0% contradicted it (F343's one definition).
        write_fixture(self.corpus, self.hypotheses, "en_2spk_alt", self.TURNS, [])
        result = self.score()
        self.assertEqual(result.returncode, 0, result.stderr)
        lines = result.stdout.splitlines()
        fixture_row = next(l for l in lines if l.startswith("en_2spk_alt "))
        self.assertEqual(fixture_row.split()[-1], "—", fixture_row)
        for prefix in ("2-speaker clean ", "ALL speech fixtures "):
            with self.subTest(line=prefix):
                line = next(l for l in lines if l.startswith(prefix))
                self.assertEqual(line.split("(coverage")[0].split()[-1], "—", line)


if __name__ == "__main__":
    unittest.main(verbosity=2)
