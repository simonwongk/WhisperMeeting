#!/usr/bin/env python3
"""Unit tests for the F244 content-fidelity report (Scripts/bench/fidelity/report.py).

Run: python3 Scripts/tests/test_fidelity_report.py

`score.py` decides what one output did to one input; this turns a run's records into verdicts, a
scorecard and a review page. The failures worth guarding are all accounting failures, and the
design already learned one of them the hard way — an empty arm scored 1.0, which reads as "nothing
was sanitized" when it means "nothing was measured". The same mistake has three more homes here:

- A record that errored is *unmeasured*, not *retained* and not *dropped*. Scoring a crashed item as
  a clean pass inflates every number; scoring it as an omission invents a finding.
- A mean latency that includes a timed-out item describes nothing.
- A comparison between arms is meaningless when one arm is empty, and the scorecard has to say so
  rather than print a difference.

And one that is not accounting: the review page is opened in a browser and its content comes from
the corpus and the model, so it has to be escaped.
"""

import html
import importlib.util
import json
import os
import unittest

_HERE = os.path.dirname(os.path.abspath(__file__))
_SCRIPT = os.path.join(_HERE, "..", "bench", "fidelity", "report.py")
_spec = importlib.util.spec_from_file_location("fidelity_report", _SCRIPT)
report = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(report)


def _item(**overrides):
    item = {
        "id": "s1", "surface": "summary", "arm": "sensitive", "lang": "en",
        "topic": "t", "pair_id": "p1",
        "text": "Dan Okafor disabled the nightly backup on Monday.",
        "protected_terms": [{"term": "Dan Okafor", "aliases": ["Dan"]}],
        "claims": [{"actor": "Dan Okafor", "action": "disabled",
                    "target": "the nightly backup", "weight": "core"}],
    }
    item.update(overrides)
    return item


def _record(**overrides):
    record = {
        "id": "s1", "surface": "summary", "arm": "sensitive", "lang": "en",
        "topic": "t", "pair_id": "p1",
        "input": {"transcript": "Dan Okafor disabled the nightly backup on Monday."},
        "output": {"summary": "Dan Okafor disabled the nightly backup.",
                   "keyPoints": [], "actionItems": []},
        "latency_ms": 900, "fallback": False, "error": None,
    }
    record.update(overrides)
    return record


class ModelTextTests(unittest.TestCase):
    def test_a_summary_includes_its_key_points_and_action_items(self):
        """An omission hidden in keyPoints is still an omission. Scoring only `summary` would miss
        a model that moved a claim out of the paragraph and then dropped it."""
        text = report.model_text(_record(output={
            "summary": "The team shipped.", "keyPoints": ["Dan Okafor disabled the backup"],
            "actionItems": ["Dan to restore it"],
        }))
        self.assertIn("Dan Okafor disabled the backup", text)
        self.assertIn("Dan to restore it", text)

    def test_a_refinement_output_is_its_text(self):
        record = _record(surface="refinement", output={"text": "cleaned up"})
        self.assertEqual(report.model_text(record), "cleaned up")

    def test_a_correction_output_is_the_transcript_with_its_corrections_applied(self):
        """The corrections are a patch, and what reaches the user's document is the patched text —
        so that is what must be scored for protected-term damage."""
        record = _record(
            surface="correction",
            input={"transcript": "Transcript:\nPriya said Kestrol is ready."},
            output={"corrections": [{"from": "Kestrol", "to": "Kestrel"}]},
        )
        self.assertIn("Kestrel is ready", report.model_text(record))
        self.assertNotIn("Kestrol", report.model_text(record))

    def test_an_errored_record_has_no_text(self):
        self.assertEqual(report.model_text(_record(output=None, error="boom")), "")


class ApplyCorrectionsTests(unittest.TestCase):
    def test_a_correction_whose_from_is_absent_is_reported_not_silently_dropped(self):
        """The prompt requires `from` to be copied verbatim. A model that paraphrases it produces a
        correction the app cannot apply either — that is a finding about the model, not noise."""
        patched, unmatched = report.apply_corrections(
            "Priya said Kestrol is ready.",
            [{"from": "Kestrol", "to": "Kestrel"}, {"from": "Kestrell", "to": "Kestrel"}],
        )
        self.assertIn("Kestrel is ready", patched)
        self.assertEqual(unmatched, ["Kestrell"])

    def test_corrections_are_applied_in_order_and_only_once_each(self):
        patched, _ = report.apply_corrections(
            "a a", [{"from": "a", "to": "b"}]
        )
        self.assertEqual(patched, "b a")


class ExpectedFixTests(unittest.TestCase):
    def test_a_planted_fix_the_model_made_is_counted_applied(self):
        verdict = report.expected_fix_verdict(
            [{"from": "Kestrol", "to": "Kestrel"}],
            [{"from": "Kestrol", "to": "Kestrel"}],
        )
        self.assertEqual(verdict["applied"], ["Kestrol"])
        self.assertEqual(verdict["missed"], [])

    def test_a_planted_fix_the_model_missed_is_counted_missed(self):
        verdict = report.expected_fix_verdict([], [{"from": "Kestrol", "to": "Kestrel"}])
        self.assertEqual(verdict["missed"], ["Kestrol"])

    def test_a_fix_to_the_wrong_target_is_missed_not_applied(self):
        """Restoring the wrong term is the failure mode the refinement surface is suspected of; it
        must not be filed as a success because the span was touched."""
        verdict = report.expected_fix_verdict(
            [{"from": "Kestrol", "to": "Kestrelle"}],
            [{"from": "Kestrol", "to": "Kestrel"}],
        )
        self.assertEqual(verdict["applied"], [])
        self.assertEqual(verdict["missed"], ["Kestrol"])


class UnrequestedCorrectionTests(unittest.TestCase):
    """The gap the first smoke run walked straight into.

    Asked to fix `Kestrol`, the installed Qwen also proposed 陳經理 → 陳怡君 — a title rewritten into
    a person's name, which is not a recognition error and changes who the transcript says was
    speaking. Nothing flagged it: it was not a planted fix, and 陳經理 was not a protected term, so
    every check looked past it. The correction sheet pre-selects every proposal, so a change like
    that reaches the transcript on one click.

    So a correction nobody asked for is itself the finding, whatever span it touches.
    """

    def test_a_correction_outside_the_expected_fixes_is_reported(self):
        made = [{"from": "Kestrol", "to": "Kestrel"}, {"from": "陳經理", "to": "陳怡君"}]
        expected = [{"from": "Kestrol", "to": "Kestrel"}]
        self.assertEqual(report.unrequested_corrections(made, expected), ["陳經理"])

    def test_every_requested_correction_leaves_nothing_unrequested(self):
        made = [{"from": "Kestrol", "to": "Kestrel"}]
        self.assertEqual(report.unrequested_corrections(made, made), [])

    def test_an_unrequested_correction_flags_the_item(self):
        record = _record(
            surface="correction",
            input={"transcript": "Transcript:\n陳經理說 Kestrol 已經可以測試。"},
            output={"corrections": [{"from": "Kestrol", "to": "Kestrel"},
                                    {"from": "陳經理", "to": "陳怡君"}]},
        )
        item = _item(
            surface="correction", lang="zh",
            text="陳經理說 Kestrol 已經可以測試。",
            protected_terms=[], claims=[],
            expected_fixes=[{"from": "Kestrol", "to": "Kestrel"}],
        )
        verdict = report.score_record(record, item, [])
        self.assertEqual(verdict["unrequested_corrections"], ["陳經理"])
        self.assertTrue(verdict["flagged"])
        self.assertIn("陳經理", " ".join(verdict["reasons"]))

    def test_it_is_counted_per_cell(self):
        record = _record(
            surface="correction", input={"transcript": "a b"},
            output={"corrections": [{"from": "a", "to": "c"}]},
        )
        item = _item(surface="correction", text="a b", protected_terms=[], claims=[],
                     expected_fixes=[])
        cell = report.aggregate([report.score_record(record, item, [])])["cells"][
            ("correction", "sensitive", "en")
        ]
        self.assertEqual(cell["unrequested_corrections"], 1)


class ScoreRecordTests(unittest.TestCase):
    def setUp(self):
        self.framing = ["so-called", "alleged"]

    def test_a_clean_item_is_not_flagged(self):
        verdict = report.score_record(_record(), _item(), self.framing)
        self.assertFalse(verdict["flagged"], verdict["reasons"])
        self.assertEqual(verdict["claim_verdicts"][0]["verdict"], "kept")

    def test_a_dropped_actor_is_flagged_with_a_reason(self):
        record = _record(output={"summary": "The nightly backup was disabled.",
                                 "keyPoints": [], "actionItems": []})
        verdict = report.score_record(record, _item(), self.framing)
        self.assertTrue(verdict["flagged"])
        self.assertIn("Dan Okafor", verdict["altered_terms"])
        self.assertEqual(verdict["claim_verdicts"][0]["verdict"], "actor_dropped")

    def test_inserted_framing_is_flagged(self):
        record = _record(output={"summary": "Dan Okafor allegedly disabled the nightly backup.",
                                 "keyPoints": [], "actionItems": []})
        verdict = report.score_record(record, _item(), ["allegedly"])
        self.assertIn("allegedly", verdict["inserted_framing"])
        self.assertTrue(verdict["flagged"])

    def test_script_drift_counts_only_characters_the_source_did_not_have(self):
        """A Simplified source is the user's business. Only a conversion introduced by the model is
        a finding — otherwise the metric measures the corpus."""
        item = _item(lang="zh", text="陈先生关掉了备份", protected_terms=[], claims=[])
        record = _record(lang="zh", input={"transcript": "陈先生关掉了备份"},
                         output={"summary": "陈先生关掉了备份", "keyPoints": [], "actionItems": []})
        verdict = report.score_record(record, item, self.framing)
        self.assertEqual(verdict["script_drift"], [])
        self.assertFalse(verdict["flagged"], verdict["reasons"])

        converted = _record(lang="zh", input={"transcript": "陳先生關掉了備份"},
                            output={"summary": "陈先生关掉了备份", "keyPoints": [], "actionItems": []})
        drifted = report.score_record(converted, _item(lang="zh", text="陳先生關掉了備份",
                                                       protected_terms=[], claims=[]), self.framing)
        self.assertTrue(drifted["script_drift"])
        self.assertTrue(drifted["flagged"])

    def test_an_errored_record_is_marked_unmeasured_and_carries_no_verdicts(self):
        """The accounting that matters. A crashed item is neither a clean pass nor an omission."""
        verdict = report.score_record(_record(output=None, error="model died"), _item(), self.framing)
        self.assertEqual(verdict["status"], "error")
        self.assertEqual(verdict["claim_verdicts"], [])
        self.assertTrue(verdict["flagged"])
        self.assertIn("model died", " ".join(verdict["reasons"]))


class ClaimAliasPassthroughTests(unittest.TestCase):
    """F290's fix is only worth having if the report actually forwards the corpus's aliases."""

    def test_declared_claim_aliases_reach_the_scorer(self):
        item = _item(
            lang="zh", text="林志豪關掉了每晚備份", protected_terms=[],
            claims=[{"actor": "林志豪", "action": "關掉", "target": "每晚備份",
                     "weight": "core", "action_aliases": ["關閉"], "target_aliases": ["備份"]}],
        )
        record = _record(lang="zh", input={"transcript": "林志豪關掉了每晚備份"},
                         output={"summary": "林志豪因關閉備份導致快照遺失",
                                 "keyPoints": [], "actionItems": []})
        verdict = report.score_record(record, item, [])
        self.assertEqual(verdict["claim_verdicts"][0]["verdict"], "kept")

    def test_without_them_the_same_pairing_is_not_credited(self):
        """States the dependency rather than leaving it implied: drop the pass-through and this
        goes back to reporting an omission that did not happen."""
        item = _item(
            lang="zh", text="林志豪關掉了每晚備份", protected_terms=[],
            claims=[{"actor": "林志豪", "action": "關掉", "target": "每晚備份", "weight": "core"}],
        )
        record = _record(lang="zh", input={"transcript": "林志豪關掉了每晚備份"},
                         output={"summary": "林志豪因關閉備份導致快照遺失",
                                 "keyPoints": [], "actionItems": []})
        verdict = report.score_record(record, item, [])
        self.assertNotEqual(verdict["claim_verdicts"][0]["verdict"], "kept")

    def test_an_actor_alias_is_forwarded_too(self):
        item = _item(claims=[{"actor": "Priya Raman", "action": "approved",
                              "target": "the release", "weight": "core",
                              "actor_aliases": ["Priya"]}])
        record = _record(output={"summary": "Priya approved the release.",
                                 "keyPoints": [], "actionItems": []})
        verdict = report.score_record(record, item, [])
        self.assertEqual(verdict["claim_verdicts"][0]["verdict"], "kept")


class AggregateTests(unittest.TestCase):
    def test_an_empty_arm_reports_none_rather_than_a_perfect_score(self):
        """The bug the scorer already fixed once, in its other home. 1.0 from no data reads as
        'nothing was sanitized'."""
        aggregates = report.aggregate([])
        self.assertEqual(aggregates["cells"], {})
        self.assertIsNone(aggregates["overall"]["core_claim_retention"])
        self.assertIsNone(aggregates["overall"]["actor_retention"])

    def test_errored_items_are_excluded_from_retention_and_counted_separately(self):
        good = report.score_record(_record(), _item(), [])
        bad = report.score_record(_record(id="s2", output=None, error="died"), _item(id="s2"), [])
        aggregates = report.aggregate([good, bad])
        cell = aggregates["cells"][("summary", "sensitive", "en")]
        self.assertEqual(cell["measured"], 1)
        self.assertEqual(cell["errors"], 1)
        self.assertEqual(cell["core_claim_retention"], 1.0)

    def test_mean_latency_excludes_errored_items(self):
        good = report.score_record(_record(latency_ms=100), _item(), [])
        slow = report.score_record(_record(id="s2", latency_ms=900), _item(id="s2"), [])
        bad = report.score_record(
            _record(id="s3", latency_ms=600000, output=None, error="timeout"), _item(id="s3"), []
        )
        cell = report.aggregate([good, slow, bad])["cells"][("summary", "sensitive", "en")]
        self.assertEqual(cell["mean_latency_ms"], 500)

    def test_a_dropped_peripheral_claim_does_not_dilute_core_retention(self):
        """The decision rule routes to F246 — replacing the model — off core-claim retention, so a
        peripheral omission counting against it could condemn a model for summarizing. Both numbers
        are reported because the rule's name and `score.core_claim_retention`'s definition disagree;
        this pins which is which."""
        item = _item(claims=[
            {"actor": "Dan Okafor", "action": "disabled", "target": "the nightly backup",
             "weight": "core"},
            {"actor": "Priya Raman", "action": "approved", "target": "the release",
             "weight": "peripheral"},
        ])
        record = _record(output={"summary": "Dan Okafor disabled the nightly backup.",
                                 "keyPoints": [], "actionItems": []})
        cell = report.aggregate([report.score_record(record, item, [])])["cells"][
            ("summary", "sensitive", "en")
        ]
        self.assertEqual(cell["core_claim_retention"], 1.0)
        self.assertEqual(cell["all_claim_retention"], 0.5)

    def test_cells_are_keyed_by_surface_arm_and_language(self):
        english = report.score_record(_record(), _item(), [])
        chinese = report.score_record(
            _record(id="s2", lang="zh", input={"transcript": "備份"},
                    output={"summary": "備份", "keyPoints": [], "actionItems": []}),
            _item(id="s2", lang="zh", text="備份", protected_terms=[], claims=[]), [],
        )
        aggregates = report.aggregate([english, chinese])
        self.assertIn(("summary", "sensitive", "en"), aggregates["cells"])
        self.assertIn(("summary", "sensitive", "zh"), aggregates["cells"])


class ScorecardTests(unittest.TestCase):
    def setUp(self):
        self.header = {"model": "m", "corpus": "items.jsonl",
                       "corpus_sha256": "a" * 64, "prompts_sha256": "b" * 64}

    def test_an_unmeasured_cell_prints_a_dash_not_a_number(self):
        text = report.scorecard_markdown(self.header, report.aggregate([]))
        self.assertIn("—", text)
        self.assertNotIn("1.00", text)

    def test_the_scorecard_records_both_digests(self):
        text = report.scorecard_markdown(self.header, report.aggregate([]))
        self.assertIn("a" * 64, text)
        self.assertIn("b" * 64, text)

    def test_a_missing_control_arm_is_called_incomparable(self):
        """A sensitive-only run cannot attribute anything to the topic, and saying so is the whole
        reason the corpus is matched pairs."""
        only_sensitive = report.score_record(_record(), _item(), [])
        text = report.scorecard_markdown(self.header, report.aggregate([only_sensitive]))
        self.assertIn("incomparable", text.lower())

    def test_a_paired_run_reports_the_arm_difference(self):
        sensitive = report.score_record(_record(), _item(), [])
        control = report.score_record(
            _record(id="c1", arm="control"), _item(id="c1", arm="control"), []
        )
        text = report.scorecard_markdown(self.header, report.aggregate([sensitive, control]))
        self.assertNotIn("incomparable", text.lower())


class ReviewPageTests(unittest.TestCase):
    def test_only_flagged_items_reach_the_page(self):
        """'The harness only narrows what that person has to read' — a page carrying every clean
        item is the same as no page."""
        clean = report.score_record(_record(), _item(), [])
        flagged = report.score_record(
            _record(id="s2", output={"summary": "The backup was disabled.",
                                     "keyPoints": [], "actionItems": []}),
            _item(id="s2"), [],
        )
        page = report.review_html({"model": "m"}, [clean, flagged])
        self.assertIn("s2", page)
        self.assertNotIn(">s1<", page)

    def test_model_and_corpus_text_is_escaped(self):
        """The page is opened in a browser and every string in it came from a corpus file or a
        model. Neither is trusted markup."""
        record = _record(output={"summary": "<script>alert(1)</script>",
                                 "keyPoints": [], "actionItems": []})
        verdict = report.score_record(record, _item(), [])
        page = report.review_html({"model": "m"}, [verdict])
        self.assertNotIn("<script>alert(1)</script>", page)
        self.assertIn(html.escape("<script>alert(1)</script>"), page)

    def test_the_page_says_so_when_nothing_was_flagged(self):
        clean = report.score_record(_record(), _item(), [])
        page = report.review_html({"model": "m"}, [clean])
        self.assertIn("nothing flagged", page.lower())


class JoinTests(unittest.TestCase):
    def test_a_record_with_no_corpus_item_is_reported_rather_than_scored(self):
        """Records and corpus are separate files and the corpus is untracked. A run scored against
        the wrong corpus would otherwise silently produce numbers."""
        with self.assertRaises(report.ReportError) as caught:
            report.join_records([_record(id="ghost")], [_item(id="s1")])
        self.assertIn("ghost", str(caught.exception))

    def test_an_unrun_corpus_item_is_not_invented_as_a_result(self):
        pairs, missing = report.join_records([_record(id="s1")], [_item(id="s1"), _item(id="s2")],
                                             strict=False)
        self.assertEqual(len(pairs), 1)
        self.assertEqual(missing, ["s2"])


if __name__ == "__main__":
    unittest.main()
