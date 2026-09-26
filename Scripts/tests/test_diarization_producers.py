#!/usr/bin/env python3
"""The evidence chain's producers, run on synthetic input (F340).

`generate_corpus.py --verify` and `score_diarization.py --self-test` exist because a number nobody
can re-obtain is not evidence. The three tools that produced the AMI tables had no such check and no
coverage in this gate at all, so a change to any of them would have been silent.
"""

import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest

BENCH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "bench", "diarization")


def run(script, *args):
    return subprocess.run(
        [sys.executable, os.path.join(BENCH, script), *args],
        capture_output=True, text=True, check=False,
    )


def write_meeting(rttm_dir, hyp_dir, stem, turns):
    """One synthetic meeting: `turns` as (start, end, reference speaker, hypothesis label)."""
    os.makedirs(rttm_dir, exist_ok=True)
    os.makedirs(hyp_dir, exist_ok=True)
    with open(os.path.join(rttm_dir, stem + ".rttm"), "w", encoding="utf-8") as handle:
        for start, end, speaker, _ in turns:
            handle.write("SPEAKER %s 1 %.3f %.3f <NA> <NA> %s <NA> <NA>\n"
                         % (stem, start, end - start, speaker))
    with open(os.path.join(hyp_dir, stem + ".json"), "w", encoding="utf-8") as handle:
        json.dump([{"start": s, "end": e, "speaker": label} for s, e, _, label in turns], handle)


class ProducerSelfTests(unittest.TestCase):
    def test_ami_prepare(self):
        result = run("ami_prepare.py", "--self-test")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("passed", result.stdout)

    def test_bucket_table(self):
        result = run("bucket_table.py", "--self-test")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("passed", result.stdout)

    def test_row_lengths(self):
        result = run("row_lengths.py", "--self-test")
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("passed", result.stdout)

    def test_each_producer_refuses_to_run_with_no_input(self):
        # A producer that silently does nothing is how an empty table gets quoted.
        for script, message in [
            ("ami_prepare.py", "--manifest"),
            ("bucket_table.py", "--rttm"),
            ("row_lengths.py", "--library"),
        ]:
            result = run(script)
            self.assertEqual(result.returncode, 2, script)
            self.assertIn(message, result.stderr)


class ProducersRefuseWhatTheyCannotScore(unittest.TestCase):
    """F409: an all-zero table with exit 0 reads as data, and a traceback is not a refusal."""

    def setUp(self):
        self.root = tempfile.mkdtemp()
        self.rttm = os.path.join(self.root, "rttm")
        self.sweep = os.path.join(self.root, "sweep")
        write_meeting(self.rttm, os.path.join(self.sweep, "0.60"), "m1",
                      [(0.0, 10.0, "A", "y"), (20.0, 30.0, "B", "x")])

    def tearDown(self):
        shutil.rmtree(self.root)

    def test_bucket_table_refuses_a_directory_with_no_hypotheses(self):
        empty = os.path.join(self.root, "empty")
        os.makedirs(empty)
        # The sweep's parent holds threshold folders, not .json files — the easy wrong argument.
        for hypotheses in (empty, self.sweep):
            with self.subTest(hypotheses=os.path.basename(hypotheses)):
                result = run("bucket_table.py", "--rttm", self.rttm, "--hypotheses", hypotheses)
                self.assertNotEqual(result.returncode, 0, result.stdout)
                self.assertNotIn("Traceback", result.stderr)
                self.assertIn("no hypothesis .json files", result.stderr)
                self.assertNotIn("| rows |", result.stdout)

    def test_bucket_table_prints_a_dash_for_precision_over_nothing_named(self):
        # A 0.5 s row is never named at the default 1 s gate, so that bucket has a row and no
        # name. `displayed_label_metrics` does not call that 0 % precise, so neither may this.
        write_meeting(self.rttm, os.path.join(self.sweep, "short"), "m2",
                      [(0.0, 0.5, "A", "a"), (20.0, 30.0, "B", "b")])
        result = run("bucket_table.py", "--rttm", self.rttm,
                     "--hypotheses", os.path.join(self.sweep, "short"))
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("| nobody else talking, under 1 s | 1 | 0.0 % | — |", result.stdout)
        self.assertIn("| nobody else talking, 3 s or more | 1 | 100.0 % | 100.0 % |", result.stdout)

    def test_sweep_score_scores_a_real_threshold(self):
        result = run("sweep_score.py", self.rttm, self.sweep)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("\n0.60 | 1 | 0.0 |", result.stdout)

    def test_sweep_score_refuses_an_empty_threshold_directory(self):
        os.makedirs(os.path.join(self.sweep, "0.70"))
        result = run("sweep_score.py", self.rttm, self.sweep)
        self.assertNotEqual(result.returncode, 0, result.stdout)
        self.assertNotIn("Traceback", result.stderr)
        self.assertIn("0.70", result.stderr)
        self.assertIn("nothing was scored", result.stderr)


if __name__ == "__main__":
    unittest.main()
