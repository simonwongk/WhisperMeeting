#!/usr/bin/env python3
"""The evidence chain's producers, run on synthetic input (F340).

`generate_corpus.py --verify` and `score_diarization.py --self-test` exist because a number nobody
can re-obtain is not evidence. The three tools that produced the AMI tables had no such check and no
coverage in this gate at all, so a change to any of them would have been silent.
"""

import os
import subprocess
import sys
import unittest

BENCH = os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "bench", "diarization")


def run(script, *args):
    return subprocess.run(
        [sys.executable, os.path.join(BENCH, script), *args],
        capture_output=True, text=True, check=False,
    )


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


if __name__ == "__main__":
    unittest.main()
