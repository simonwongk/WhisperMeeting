#!/usr/bin/env python3
"""Unit tests for the ASR benchmark's Summary table (Scripts/bench/asr_summary.py).

Run: python3 Scripts/tests/test_asr_benchmark_summary.py

F438 part 3. `benchmark.py` records an errored clip with `sec=-1` and `val=nan`, and the Summary
averaged over the clips that survived, with no count. So an engine that timed out on the two hard
Chinese clips scored the easy one's CER as its 中文 number, and its average seconds left out the
slow clips — the Summary row is the table that gets quoted, and engine-default decisions are made
from it. These pin that an errored clip is counted against the engine and that the row says so.
"""

import importlib.util
import math
import os
import unittest

_HERE = os.path.dirname(os.path.abspath(__file__))
_SCRIPT = os.path.join(_HERE, "..", "bench", "asr_summary.py")
_spec = importlib.util.spec_from_file_location("asr_summary", _SCRIPT)
summary = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(summary)


def _ok(clip, lang, val, sec=1.0):
    return dict(clip=clip, lang=lang, sec=sec, det=lang, metric="CER", val=val, hyp="text")


def _error(clip, lang):
    """Exactly what `benchmark.py` records when an engine raises on a clip."""
    return dict(clip=clip, lang=lang, sec=-1.0, det="?", metric="?", val=float("nan"),
                hyp="ERROR: TimeoutError()")


def _row(results, engine):
    """The Summary row for `engine`, as its cells."""
    line = next(line for line in summary.summary_lines(results) if line.startswith(f"| {engine} |"))
    return [cell.strip() for cell in line.strip().strip("|").split("|")]


class ErroredClipTests(unittest.TestCase):
    def setUp(self):
        # zh1 scored perfectly; zh2 and zh3 timed out. The engine got one of three right.
        self.results = {"qwen": [_ok("zh1", "zh", 0.0, sec=0.5), _error("zh2", "zh"), _error("zh3", "zh")]}

    def test_an_errored_clip_counts_as_a_total_miss_not_as_absent(self):
        """1.0 is what an empty transcript scores — the rule `qwen_meeting_engine` already uses for a
        clip it could not transcribe. Leaving the clip out made two failures read as a perfect 0.000."""
        engine, sec, en, zh, cs = _row(self.results, "qwen")
        self.assertTrue(zh.startswith("0.667"), zh)

    def test_the_row_says_how_many_clips_errored(self):
        engine, sec, en, zh, cs = _row(self.results, "qwen")
        self.assertIn("2 of 3 errored", zh)

    def test_the_average_seconds_say_how_many_clips_they_cover(self):
        """An errored clip has no latency to average, and a mean over the fast survivors must not
        read as the engine's speed."""
        engine, sec, en, zh, cs = _row(self.results, "qwen")
        self.assertEqual(sec, "0.50 (1 of 3 ran)")

    def test_a_language_with_no_clips_prints_a_dash(self):
        engine, sec, en, zh, cs = _row(self.results, "qwen")
        self.assertEqual(en, "—")
        self.assertEqual(cs, "—")

    def test_a_clean_run_prints_plain_numbers(self):
        clean = {"mlx": [_ok("en1", "en", 0.1, sec=1.0), _ok("en2", "en", 0.3, sec=2.0)]}
        engine, sec, en, zh, cs = _row(clean, "mlx")
        self.assertEqual(sec, "1.50")
        self.assertEqual(en, "0.200")

    def test_errored_clips_are_listed_so_the_run_can_fail(self):
        """`benchmark.py` exits non-zero when this is not empty."""
        self.assertEqual(summary.errored_clips(self.results), [("qwen", "zh2"), ("qwen", "zh3")])
        self.assertEqual(summary.errored_clips({"mlx": [_ok("en1", "en", 0.1)]}), [])

    def test_a_row_reloaded_from_results_json_is_still_an_error(self):
        """`BENCH_APPEND=1` reloads earlier rows from results.json, where nan round-trips as NaN."""
        reloaded = {"qwen": [dict(_error("zh2", "zh"), val=float("nan"))]}
        self.assertTrue(math.isnan(reloaded["qwen"][0]["val"]))
        self.assertEqual(summary.errored_clips(reloaded), [("qwen", "zh2")])

    def test_the_table_explains_the_rule(self):
        text = "\n".join(summary.summary_lines(self.results))
        self.assertIn("total miss", text)


if __name__ == "__main__":
    unittest.main()
