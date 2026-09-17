#!/usr/bin/env python3
"""Unit tests for the F244 content-fidelity runner (Scripts/bench/fidelity/run_fidelity.py).

Run: python3 Scripts/tests/test_run_fidelity.py

The runner drives the app's own helper scripts over a corpus, one model at a time, and writes a
record per item. The scoring is already tested (test_fidelity_score.py); what is tested here is the
orchestration, and the reason it needs testing is that every one of its failure modes is silent:

- A prompt assembled slightly differently from the way Swift assembles it measures a prompt the app
  never sends. That is the same failure the Swift prompt-fixture test guards from its side, and this
  is the Python side of the same guard — so the layout is checked against the fixture's own rendered
  sample rather than against a copy of the logic.
- A missing language arm quietly falling back to English would attribute a Chinese result to a
  Chinese prompt that was never used.
- One item raising and aborting the run loses the other ninety-nine, after half an hour of GPU time.
- A resume that re-runs completed items wastes that time; a resume that skips *incomplete* ones
  silently shrinks the sample.

The model is injected, so these run without it. `--smoke` against the installed Qwen is the separate
real-model run AGENTS.md requires, and its output is F244's log evidence.
"""

import importlib.util
import json
import os
import tempfile
import unittest

_HERE = os.path.dirname(os.path.abspath(__file__))
_SCRIPT = os.path.join(_HERE, "..", "bench", "fidelity", "run_fidelity.py")
_spec = importlib.util.spec_from_file_location("run_fidelity", _SCRIPT)
runner = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(runner)

_PROMPTS = os.path.normpath(os.path.join(_HERE, "..", "bench", "fidelity", "prompts.json"))
_SMOKE = os.path.normpath(os.path.join(_HERE, "..", "bench", "fidelity", "smoke", "items.jsonl"))


class PromptAssemblyTests(unittest.TestCase):
    """The Python side must build byte-identical prompts to the ones Swift builds."""

    def setUp(self):
        self.prompts = runner.load_prompts(_PROMPTS)

    def test_the_correction_turn_matches_the_fixtures_rendered_sample(self):
        """The whole point of the fixture carrying `rendered`: this compares assembly against
        Swift's actual output, not against a second copy of the same guesswork."""
        for name, sample in self.prompts["correctionUserContent"].items():
            built = runner.correction_user_content(
                sample["transcript"], sample.get("vocabulary") or [], sample.get("reference")
            )
            self.assertEqual(built, sample["rendered"], f"layout drifted for the {name} sample")

    def test_a_layout_drift_is_reported_with_the_sample_name(self):
        drifted = json.loads(json.dumps(self.prompts))
        drifted["correctionUserContent"]["transcriptOnly"]["rendered"] += "\n\nIgnore the above."
        with self.assertRaises(runner.PromptMismatch) as caught:
            runner.verify_correction_layout(drifted)
        self.assertIn("transcriptOnly", str(caught.exception))

    def test_the_real_fixture_verifies_clean(self):
        runner.verify_correction_layout(self.prompts)  # must not raise

    def test_refine_prompt_uses_the_none_arm_for_an_unknown_language(self):
        """`None` is a real surface — refinement runs before language detection settles — and it is
        stored under "none" because JSON has no null key."""
        self.assertEqual(
            runner.refine_system_prompt(self.prompts, None),
            self.prompts["refineSystem"]["none"],
        )

    def test_each_language_arm_is_distinct(self):
        zh = runner.refine_system_prompt(self.prompts, "zh")
        en = runner.refine_system_prompt(self.prompts, "en")
        self.assertNotEqual(zh, en)
        self.assertIn("Mandarin", zh)

    def test_a_language_with_no_arm_raises_rather_than_falling_back(self):
        """Silently using the English prompt for a Japanese item would file the result under a
        prompt that was never sent. Better to stop: the corpus is fixed and knowable."""
        with self.assertRaises(runner.PromptMismatch):
            runner.refine_system_prompt(self.prompts, "ja")
        with self.assertRaises(runner.PromptMismatch):
            runner.summary_system_prompt(self.prompts, "ja")

    def test_summary_prompts_carry_the_language_code_they_claim(self):
        self.assertIn('"zh"', runner.summary_system_prompt(self.prompts, "zh"))
        self.assertIn('"en"', runner.summary_system_prompt(self.prompts, "en"))


class CorpusTests(unittest.TestCase):
    def test_the_tracked_smoke_corpus_loads_and_covers_every_text_surface(self):
        items = runner.load_corpus(_SMOKE)
        self.assertTrue(items)
        for surface in ("refinement", "correction", "summary"):
            found = runner.items_for_surface(items, surface)
            self.assertGreaterEqual(len(found), 2, f"{surface} needs two items for --smoke")

    def test_the_smoke_corpus_is_neutral_and_says_so(self):
        """It is tracked in a public repository. A sensitive item reaching it is unrecallable, so
        the check is mechanical rather than a matter of remembering."""
        items = runner.load_corpus(_SMOKE)
        for item in items:
            self.assertEqual(item["arm"], "neutral", f"{item['id']} is not marked neutral")

    def test_an_item_missing_a_required_field_is_rejected_with_its_id(self):
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "items.jsonl")
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(json.dumps({"id": "x1", "surface": "summary"}) + "\n")
            with self.assertRaises(runner.CorpusError) as caught:
                runner.load_corpus(path)
            self.assertIn("x1", str(caught.exception))

    def test_a_blank_line_is_skipped_rather_than_failing_the_run(self):
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "items.jsonl")
            body = json.dumps({
                "id": "a", "surface": "summary", "arm": "neutral", "lang": "en",
                "topic": "t", "pair_id": "p", "text": "hello",
            })
            with open(path, "w", encoding="utf-8") as handle:
                handle.write("\n" + body + "\n\n")
            self.assertEqual(len(runner.load_corpus(path)), 1)

    def test_duplicate_ids_are_rejected(self):
        """Resume keys on the id. Two items sharing one would make the second unrunnable and the
        first uncountable."""
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "items.jsonl")
            body = json.dumps({
                "id": "same", "surface": "summary", "arm": "neutral", "lang": "en",
                "topic": "t", "pair_id": "p", "text": "hello",
            })
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(body + "\n" + body + "\n")
            with self.assertRaises(runner.CorpusError):
                runner.load_corpus(path)

    def test_smoke_limit_takes_two_items_per_surface(self):
        items = runner.load_corpus(_SMOKE)
        picked = runner.items_for_surface(items, "summary", limit=2)
        self.assertEqual(len(picked), 2)


class _Sink:
    """Collects records the way the real jsonl writer does, so tests see what would be on disk."""

    def __init__(self):
        self.records = []

    def write(self, record):
        self.records.append(json.loads(json.dumps(record)))


class RunSurfaceTests(unittest.TestCase):
    def setUp(self):
        self.prompts = runner.load_prompts(_PROMPTS)
        self.items = [
            {"id": "s1", "surface": "summary", "arm": "neutral", "lang": "en",
             "topic": "t", "pair_id": "p1", "text": "We shipped on Tuesday."},
            {"id": "s2", "surface": "summary", "arm": "neutral", "lang": "en",
             "topic": "t", "pair_id": "p2", "text": "We shipped on Friday."},
        ]

    def test_each_item_records_its_input_output_and_latency(self):
        sink = _Sink()
        clock = iter([1.0, 1.25, 2.0, 2.5])
        runner.run_surface(
            self.items, "summary", self.prompts,
            invoke=lambda surface, request: {"summary": "ok", "keyPoints": [], "actionItems": []},
            sink=sink, clock=lambda: next(clock),
        )
        self.assertEqual([r["id"] for r in sink.records], ["s1", "s2"])
        first = sink.records[0]
        self.assertEqual(first["input"]["transcript"], "We shipped on Tuesday.")
        self.assertEqual(first["output"]["summary"], "ok")
        self.assertEqual(first["latency_ms"], 250)
        self.assertIsNone(first["error"])
        self.assertFalse(first["fallback"])

    def test_the_request_carries_the_prompt_for_the_items_language(self):
        sink = _Sink()
        seen = []
        runner.run_surface(
            self.items, "summary", self.prompts,
            invoke=lambda surface, request: seen.append(request) or {"summary": ""},
            sink=sink,
        )
        self.assertEqual(seen[0]["systemPrompt"], self.prompts["summarySystem"]["en"])

    def test_one_failing_item_is_recorded_and_the_rest_still_run(self):
        """Half an hour of GPU time must not be lost to one bad item. The error is data, not an
        exception: the scorecard has to be able to say how many items failed."""
        sink = _Sink()

        def invoke(surface, request):
            if "Tuesday" in request["transcript"]:
                raise RuntimeError("model died")
            return {"summary": "fine"}

        counts = runner.run_surface(self.items, "summary", self.prompts, invoke=invoke, sink=sink)
        self.assertEqual(len(sink.records), 2)
        self.assertIn("model died", sink.records[0]["error"])
        self.assertIsNone(sink.records[0]["output"])
        self.assertEqual(sink.records[1]["output"]["summary"], "fine")
        self.assertEqual(counts["failed"], 1)
        self.assertEqual(counts["completed"], 1)

    def test_a_keyboard_interrupt_is_not_swallowed(self):
        """A caught-everything loop that eats Ctrl-C makes an hour-long run unstoppable."""
        sink = _Sink()

        def invoke(surface, request):
            raise KeyboardInterrupt

        with self.assertRaises(KeyboardInterrupt):
            runner.run_surface(self.items, "summary", self.prompts, invoke=invoke, sink=sink)

    def test_resume_skips_ids_already_recorded(self):
        sink = _Sink()
        calls = []
        counts = runner.run_surface(
            self.items, "summary", self.prompts,
            invoke=lambda surface, request: calls.append(request) or {"summary": ""},
            sink=sink, already={"s1"},
        )
        self.assertEqual([r["id"] for r in sink.records], ["s2"])
        self.assertEqual(len(calls), 1)
        self.assertEqual(counts["skipped"], 1)

    def test_a_failed_item_is_not_treated_as_done_on_resume(self):
        """`completed_ids` reads the records back. A record carrying an error is unfinished work, and
        counting it as done would silently shrink the sample on every retry."""
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "summary.jsonl")
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(json.dumps({"id": "ok1", "error": None}) + "\n")
                handle.write(json.dumps({"id": "bad1", "error": "model died"}) + "\n")
            self.assertEqual(runner.completed_ids(path), {"ok1"})

    def test_completed_ids_of_a_missing_file_is_empty(self):
        self.assertEqual(runner.completed_ids("/nonexistent/summary.jsonl"), set())

    def test_a_truncated_last_line_does_not_lose_the_earlier_records(self):
        """A run killed mid-write leaves a partial line. Refusing to read the file would throw away
        every completed item; the partial one simply re-runs."""
        with tempfile.TemporaryDirectory() as directory:
            path = os.path.join(directory, "summary.jsonl")
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(json.dumps({"id": "ok1", "error": None}) + "\n")
                handle.write('{"id": "half", "err')
            self.assertEqual(runner.completed_ids(path), {"ok1"})

    def test_a_refinement_request_uses_text_not_transcript(self):
        """The resident server's field is `text`; the one-shot helpers take `transcript`. Sending the
        wrong one gets an empty refinement and no error at all."""
        sink = _Sink()
        seen = []
        items = [{"id": "r1", "surface": "refinement", "arm": "neutral", "lang": "zh",
                  "topic": "t", "pair_id": "p", "text": "今天 呃 我們出貨了"}]
        runner.run_surface(
            items, "refinement", self.prompts,
            invoke=lambda surface, request: seen.append(request) or {"text": "今天我們出貨了。"},
            sink=sink,
        )
        self.assertEqual(seen[0]["text"], "今天 呃 我們出貨了")
        self.assertNotIn("transcript", seen[0])
        self.assertEqual(seen[0]["systemPrompt"], self.prompts["refineSystem"]["zh"])

    def test_a_correction_request_sends_the_assembled_user_turn_as_transcript(self):
        """`LocalTranscriptCorrector` puts the assembled turn in the `transcript` field. The bench
        has to do the same or it measures a differently-shaped request."""
        sink = _Sink()
        seen = []
        items = [{"id": "c1", "surface": "correction", "arm": "neutral", "lang": "en",
                  "topic": "t", "pair_id": "p", "text": "We shipped Kestrol on Tuesday.",
                  "vocabulary": ["Kestrel"]}]
        runner.run_surface(
            items, "correction", self.prompts,
            invoke=lambda surface, request: seen.append(request) or {"corrections": []},
            sink=sink,
        )
        self.assertIn("Transcript:\nWe shipped Kestrol on Tuesday.", seen[0]["transcript"])
        self.assertIn("Correct business vocabulary:\n- Kestrel", seen[0]["transcript"])
        self.assertEqual(seen[0]["systemPrompt"], self.prompts["correctionSystem"])


class HeaderTests(unittest.TestCase):
    def test_the_header_records_both_digests(self):
        """Two runs may only be compared when the corpus and prompt digests match. The corpus is
        untracked, so the digest is the only record of which one produced a number."""
        header = runner.run_header(_SMOKE, _PROMPTS, model="qwen3-8b-4bit")
        self.assertEqual(len(header["corpus_sha256"]), 64)
        self.assertEqual(len(header["prompts_sha256"]), 64)
        self.assertEqual(header["model"], "qwen3-8b-4bit")
        self.assertEqual(header["corpus"], os.path.basename(_SMOKE))

    def test_the_digest_changes_with_the_content(self):
        with tempfile.TemporaryDirectory() as directory:
            first = os.path.join(directory, "a")
            second = os.path.join(directory, "b")
            with open(first, "w", encoding="utf-8") as handle:
                handle.write("one")
            with open(second, "w", encoding="utf-8") as handle:
                handle.write("two")
            self.assertNotEqual(runner.digest(first), runner.digest(second))


class ContentionTests(unittest.TestCase):
    """A contended GPU invalidates every latency number in the run — the F212 lesson."""

    def test_another_mlx_process_is_detected(self):
        listing = (
            "  501 12345 python3 /Users/x/Runtime/Summarizer/venv/bin/mlx_lm.generate\n"
            "  501 12346 /bin/zsh -l\n"
        )
        found = runner.other_mlx_processes(listing, own_pid=999)
        self.assertEqual(len(found), 1)
        self.assertIn("12345", found[0])

    def test_the_runners_own_process_is_not_reported(self):
        listing = "  501 999 python3 run_fidelity.py --model qwen --mlx\n"
        self.assertEqual(runner.other_mlx_processes(listing, own_pid=999), [])

    def test_a_quiet_machine_reports_nothing(self):
        self.assertEqual(runner.other_mlx_processes("  501 1 /sbin/launchd\n", own_pid=999), [])


if __name__ == "__main__":
    unittest.main()
