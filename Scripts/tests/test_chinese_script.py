#!/usr/bin/env python3
"""Keeps `Sources/WhisperCore/ChineseScript.swift` in step with the vendored OpenCC table (F245).

Run: python3 Scripts/tests/test_chinese_script.py

The generated Swift file is what lets the app tell Traditional from Simplified, and the same table
feeds F244's scorer — so if the two drift, the app and the bench disagree about what a script change
*is*, and the bench's verdict on the guard stops describing the guard.

The parse is tested as well as the staleness, because the parse is where this went wrong three
times. The file is `<simplified>\\t<alt> <alt> …`: tab first, then space-separated alternatives, and
a character is Simplified-only only when none of its alternatives is itself. Comparing the key
against the unsplit remainder made `了`, `出` and `才` look Simplified-only — which would have made
the guard fire on ordinary Traditional text and taken refinement away from every Traditional writer.
"""

import importlib.util
import os
import unittest

_HERE = os.path.dirname(os.path.abspath(__file__))
_SCRIPT = os.path.join(_HERE, "..", "generate-chinese-script.py")
_spec = importlib.util.spec_from_file_location("generate_chinese_script", _SCRIPT)
generator = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(generator)


class GeneratedFileTests(unittest.TestCase):
    def test_the_generated_swift_file_is_current(self):
        """A stale file is silent: the app keeps compiling with yesterday's character sets."""
        self.assertEqual(generator.main(["--check"]), 0)


class ParseTests(unittest.TestCase):
    def setUp(self):
        self.simplified, self.traditional = generator.sets_from_table()

    def test_the_count_matches_the_scorer_computed_independently(self):
        """3810 is not a magic number — `score.SIMPLIFIED_CHARACTERS` derives it from the same table
        by its own code path, so agreeing is a real cross-check rather than a restatement."""
        score_path = os.path.join(_HERE, "..", "bench", "fidelity", "score.py")
        spec = importlib.util.spec_from_file_location("fidelity_score", score_path)
        score = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(score)
        self.assertEqual(len(self.simplified), len(score.SIMPLIFIED_CHARACTERS))
        self.assertEqual(self.simplified, set(score.SIMPLIFIED_CHARACTERS))

    def test_a_character_mapping_to_itself_is_shared_not_simplified(self):
        """`了 → 了 瞭`, `出 → 出 齣`, `才 → 才 纔`, `后 → 後 后`. Every one of these is ordinary
        Traditional Chinese, and calling them Simplified is the bug that would have made the
        directional check fire on any Traditional sentence."""
        for character in "了出才后":
            self.assertNotIn(character, self.simplified, f"{character} is shared")

    def test_a_character_with_no_self_alternative_is_simplified_only(self):
        """`个 → 個 箇`, `们 → 們`, `货 → 貨`."""
        for character in "个们货伦办":
            self.assertIn(character, self.simplified, f"{character} is Simplified-only")

    def test_the_two_sets_do_not_overlap(self):
        """A character in both would be evidence for whichever side asked first."""
        self.assertEqual(self.simplified & self.traditional, set())

    def test_the_traditional_side_has_the_forms_the_observed_conversion_replaced(self):
        for character in "個們貨倫辦":
            self.assertIn(character, self.traditional, f"{character} is Traditional-only")


if __name__ == "__main__":
    unittest.main()
