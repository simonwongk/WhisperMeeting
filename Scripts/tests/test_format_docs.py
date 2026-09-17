#!/usr/bin/env python3
"""Unit tests for Scripts/format-docs.py's content-safety check (F163).

Run: python3 Scripts/tests/test_format_docs.py

The formatter refuses to write a file whose non-code word stream changed, which is the property that
makes a bulk reflow safe to run unattended. That check counted blockquote `>` markers as content
words — and rewrapping a quote legitimately changes how many LINES it has, so it changes how many
markers there are. Nine of the twenty-two tracked documents were refused for this one reason,
including the Quick Dictation design guide F163 was filed about.

The fix must not weaken the guarantee, so these tests pin both halves: markers may move, and words
may not — including words moving in or out of a quote.
"""

import importlib.util
import os
import unittest

_SCRIPT = os.path.join(os.path.dirname(__file__), "..", "format-docs.py")
_spec = importlib.util.spec_from_file_location("format_docs", _SCRIPT)
formatter = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(formatter)


def reformat_is_safe(source):
    """Whether the formatter's own check accepts its own output for `source`."""
    formatted = formatter.format_text(source)
    return (
        formatter.words_outside_code(source.split("\n"))
        == formatter.words_outside_code(formatted.split("\n"))
    )


class BlockquoteRewrapTests(unittest.TestCase):
    def test_a_multi_line_quote_survives_its_own_reflow(self):
        """The reported bug. Two quoted lines become one when they fit, so the stream had two `>`
        tokens before and one after — a content drift, reported against the first word that moved."""
        source = (
            "> First quoted line here.\n"
            "> Second quoted line here, also reasonably long so it wraps somewhere.\n"
        )
        self.assertTrue(reformat_is_safe(source))

    def test_a_quote_long_enough_to_rewrap_into_more_lines_is_safe(self):
        source = "> " + " ".join(["word"] * 60) + "\n"
        self.assertTrue(reformat_is_safe(source))

    def test_a_single_line_quote_is_safe(self):
        self.assertTrue(reformat_is_safe("> One short quoted line.\n"))

    def test_a_tight_marker_with_no_space_is_safe(self):
        self.assertTrue(reformat_is_safe(">Tight marker, no space, long enough to be rewrapped.\n"))

    def test_an_empty_quoted_line_separating_two_quoted_paragraphs_is_safe(self):
        """The second cause, and a different one: a bare `>` is a paragraph break inside a quote.

        `flush` stripped the block's prefix by literal match, and `">"` does not start with `"> "`,
        so the marker survived into the body and was re-wrapped as a WORD — the stream gained a `>`
        instead of losing one. Four documents were refused for this after the marker fix.
        """
        source = (
            "> First quoted paragraph, long enough that the formatter will want to rewrap it here.\n"
            ">\n"
            "> **Second quoted paragraph.** Also long enough to be a candidate for reflowing.\n"
        )
        self.assertTrue(reformat_is_safe(source))

    def test_an_empty_quoted_line_still_separates_the_paragraphs(self):
        """Not merged, which is the whole reason it cannot simply be dropped. `> a`, `>`, `> b`
        renders as two paragraphs inside one quotation; joining them changes what the document
        says, and a formatter that silently rewrites structure is worse than one that refuses."""
        source = "> First paragraph.\n>\n> Second paragraph.\n"
        formatted = formatter.format_text(source)
        self.assertIn("\n>\n", formatted, "the quoted paragraph break was lost")

    def test_a_quoted_bullet_list_is_safe(self):
        source = (
            "> - first item, long enough that the formatter will consider rewrapping the line\n"
            "> - second item, likewise long enough to be a candidate for reflowing here\n"
        )
        self.assertTrue(reformat_is_safe(source))


class SafetyGuaranteeTests(unittest.TestCase):
    """What the check must still catch. Dropping the markers from the stream must not drop the
    property the stream exists to prove."""

    def test_a_lost_word_is_still_a_drift(self):
        before = formatter.words_outside_code(["> one two three"])
        after = formatter.words_outside_code(["> one three"])
        self.assertNotEqual(before, after)

    def test_a_word_moving_out_of_a_quote_is_a_drift(self):
        """The case the naive fix — strip every `>` and compare bare words — would miss. Turning a
        quotation into ordinary prose changes who is speaking, which is content."""
        before = formatter.words_outside_code(["> quoted words here"])
        after = formatter.words_outside_code(["quoted words here"])
        self.assertNotEqual(before, after)

    def test_a_word_moving_into_a_quote_is_a_drift(self):
        before = formatter.words_outside_code(["plain words here"])
        after = formatter.words_outside_code(["> plain words here"])
        self.assertNotEqual(before, after)

    def test_a_greater_than_sign_in_prose_is_still_content(self):
        """`QUOTE` anchors at the line start, so `a > b` mid-sentence is untouched — dropping it
        would make an inequality silently editable."""
        before = formatter.words_outside_code(["latency a > b matters"])
        after = formatter.words_outside_code(["latency a b matters"])
        self.assertNotEqual(before, after)

    def test_fenced_code_is_still_compared_line_by_line(self):
        before = formatter.words_outside_code(["```", "  indented  code", "```"])
        after = formatter.words_outside_code(["```", "indented code", "```"])
        self.assertNotEqual(before, after, "code whitespace must stay exact")


class EveryTrackedDocumentTests(unittest.TestCase):
    def test_the_formatter_accepts_its_own_output_for_every_target(self):
        """The real assertion, and the reason F163 matters: `format-docs.py` is a bulk pass, so one
        systematic false refusal makes the whole tool unusable. Nine of twenty-two were refused."""
        refused = []
        for path in formatter.targets():
            with open(path, encoding="utf-8") as handle:
                source = handle.read()
            if not reformat_is_safe(source):
                refused.append(os.path.basename(path))
        self.assertEqual(refused, [], "the formatter refuses its own output for these")


if __name__ == "__main__":
    unittest.main()
