#!/usr/bin/env python3
"""Unit tests for the pure logic in Scripts/qwen_transcribe.py.

Run: python3 Scripts/tests/test_qwen_transcribe.py

These import only the helper's pure functions (no mlx / mlx_audio), which live at module scope; the
heavy model imports are deferred inside main(), so importing the module here is safe.
"""

import importlib.util
import os
import unittest

_SCRIPT = os.path.join(os.path.dirname(__file__), "..", "qwen_transcribe.py")
_spec = importlib.util.spec_from_file_location("qwen_transcribe", _SCRIPT)
qwen = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(qwen)


class DetectedLanguageCodeTests(unittest.TestCase):
    """F41 — the top-level language label must reflect the majority script, not any CJK char."""

    def test_mostly_english_with_one_cjk_name_is_en(self):
        self.assertEqual(qwen.detected_language_code("Let's meet in 北京 next week"), "en")

    def test_mostly_chinese_is_zh(self):
        self.assertEqual(qwen.detected_language_code("我们讨论了太极拳的历史和哲学"), "zh")

    def test_pure_english_is_en(self):
        self.assertEqual(qwen.detected_language_code("hello world"), "en")

    def test_empty_is_en(self):
        self.assertEqual(qwen.detected_language_code("   "), "en")


if __name__ == "__main__":
    unittest.main(verbosity=2)
