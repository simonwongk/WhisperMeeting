#!/usr/bin/env python3
"""Unit tests for the pure logic in Scripts/summarize_local.py.

Run: python3 Scripts/tests/test_summarize_local.py

These import only the helper's pure functions (no mlx_lm), which live at module scope; the heavy
model import is deferred inside main(), so importing the module here is safe. main() is exercised
end-to-end by injecting a fake mlx_lm into sys.modules, mirroring test_qwen_transcribe.py.
"""

import contextlib
import importlib.util
import io
import json
import os
import sys
import tempfile
import threading
import time
import unittest
from types import ModuleType, SimpleNamespace

_SCRIPT = os.path.join(os.path.dirname(__file__), "..", "summarize_local.py")
_spec = importlib.util.spec_from_file_location("summarize_local", _SCRIPT)
summ = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(summ)


class ParseSummaryTests(unittest.TestCase):
    """F164 — the model's text must degrade to a structured summary, never raise."""

    def test_clean_json_object(self):
        payload, warning = summ.parse_summary(
            '{"summary":"We shipped v1.","keyPoints":["Ship v1","Hire QA"],"actionItems":["Email vendor"]}'
        )
        self.assertIsNone(warning)
        self.assertEqual(payload["summary"], "We shipped v1.")
        self.assertEqual(payload["keyPoints"], ["Ship v1", "Hire QA"])
        self.assertEqual(payload["actionItems"], ["Email vendor"])

    def test_json_in_code_fence(self):
        text = '```json\n{"summary":"S","keyPoints":["k"],"actionItems":[]}\n```'
        payload, warning = summ.parse_summary(text)
        self.assertIsNone(warning)
        self.assertEqual(payload["summary"], "S")
        self.assertEqual(payload["keyPoints"], ["k"])
        self.assertEqual(payload["actionItems"], [])

    def test_thinking_block_and_prose_are_stripped(self):
        text = (
            "<think>The user wants a summary. Let me produce JSON.</think>\n"
            "Here is the summary you asked for:\n"
            '{"summary":"讨论了太极拳","keyPoints":["历史"],"actionItems":[]}'
        )
        payload, warning = summ.parse_summary(text)
        self.assertIsNone(warning)
        self.assertEqual(payload["summary"], "讨论了太极拳")
        self.assertEqual(payload["keyPoints"], ["历史"])

    def test_missing_and_blank_keys_are_coerced(self):
        # missing actionItems -> []; blank/whitespace list items dropped; non-string coerced.
        payload, warning = summ.parse_summary(
            '{"summary":"S","keyPoints":["a","   ", 7]}'
        )
        self.assertIsNone(warning)
        self.assertEqual(payload["keyPoints"], ["a", "7"])
        self.assertEqual(payload["actionItems"], [])

    def test_no_json_degrades_to_raw_summary_with_warning(self):
        payload, warning = summ.parse_summary("I could not follow the format but here is a recap.")
        self.assertIsNotNone(warning)
        self.assertIn("JSON", warning)
        self.assertEqual(payload["summary"], "I could not follow the format but here is a recap.")
        self.assertEqual(payload["keyPoints"], [])
        self.assertEqual(payload["actionItems"], [])

    def test_empty_text_is_empty_payload_with_warning(self):
        payload, warning = summ.parse_summary("   ")
        self.assertIsNotNone(warning)
        self.assertEqual(payload["summary"], "")
        self.assertEqual(payload["keyPoints"], [])
        self.assertEqual(payload["actionItems"], [])


class GenerationHeartbeatTests(unittest.TestCase):
    """F512 — generation reports every 32 tokens, or sooner when tokens are slow, so the only silence
    longer than a few seconds is one token that takes that long."""

    def test_reports_on_the_token_count(self):
        self.assertTrue(summ.should_report_generation(32, 0.1))
        self.assertTrue(summ.should_report_generation(64, 0.1))
        self.assertFalse(summ.should_report_generation(33, 0.1))

    def test_reports_on_time_when_tokens_are_slow(self):
        # Measured on a swapping Mac: 32 tokens at a 32k-token context took 146 s.
        self.assertFalse(summ.should_report_generation(33, summ.GENERATION_REPORT_SECONDS - 0.01))
        self.assertTrue(summ.should_report_generation(33, summ.GENERATION_REPORT_SECONDS))

    def test_nothing_generated_is_not_reported(self):
        self.assertFalse(summ.should_report_generation(0, 999))


class BuildChatMessagesTests(unittest.TestCase):
    """The helper forwards the Swift-built system prompt verbatim (single source of truth)."""

    def test_messages_wrap_system_and_transcript(self):
        messages = summ.build_chat_messages("SYSTEM RULES", "the transcript body")
        self.assertEqual(messages, [
            {"role": "system", "content": "SYSTEM RULES"},
            {"role": "user", "content": "the transcript body"},
        ])


class ContextOverflowDetailTests(unittest.TestCase):
    """F475 Part 3 — measured against the real installed model: mlx_lm.utils.load_tokenizer's
    apply_chat_template on mlx-community/Qwen3-8B-4bit returns the exact token-id list
    stream_generate receives, and a synthetic 4-hour-meeting transcript (a realistic sentence
    repeated to approximate ~150 wpm) tokenizes to 66,001 tokens (English) / 60,000 (Mandarin) —
    both past the installed model's max_position_embeddings of 40,960."""

    def test_a_prompt_that_fits_is_not_flagged(self):
        self.assertEqual(summ.context_overflow_detail(10_000, context_limit=40_960, max_tokens=2_048), "")

    def test_a_prompt_that_exactly_fills_the_budget_is_not_flagged(self):
        budget = 40_960 - 2_048 - summ.CONTEXT_SAFETY_MARGIN_TOKENS
        self.assertEqual(summ.context_overflow_detail(budget, context_limit=40_960, max_tokens=2_048), "")

    def test_one_token_over_budget_is_flagged(self):
        budget = 40_960 - 2_048 - summ.CONTEXT_SAFETY_MARGIN_TOKENS
        detail = summ.context_overflow_detail(budget + 1, context_limit=40_960, max_tokens=2_048)
        self.assertIn(str(budget + 1), detail)
        self.assertIn(str(budget), detail)
        self.assertIn("40960", detail)
        self.assertIn("shorter selection", detail)

    def test_the_measured_four_hour_transcript_is_flagged_on_the_installed_model(self):
        # The real numbers measured against mlx-community/Qwen3-8B-4bit (see class doc).
        detail = summ.context_overflow_detail(66_001, context_limit=40_960, max_tokens=2_048)
        self.assertNotEqual(detail, "")


def _install_fake_mlx_lm(deltas, finish_reason="stop", context_limit=1_000_000, counted_prompt_tokens=10):
    """Inject a fake mlx_lm (+ mlx_lm.sample_utils, mlx_lm.utils) so main() runs without a real model.

    stream_generate yields one GenerationResponse per delta in `deltas`; concatenated they are the
    model's full output text. The fake tokenizer records the messages it was asked to template.

    F475 Part 3: `context_limit`/`counted_prompt_tokens` fake the pre-flight context-window check —
    `mlx_lm.utils.load_config`/`load_tokenizer`. Defaults (a huge limit, a tiny counted prompt) keep
    every EXISTING test below on the same path it always took; `MainEndToEndTests` below overrides
    them to exercise the new "too_long" branch specifically.
    """
    recorded = {}

    class FakeTokenizer:
        def apply_chat_template(self, messages, add_generation_prompt=False, **kwargs):
            recorded["messages"] = messages
            recorded["add_generation_prompt"] = add_generation_prompt
            recorded["kwargs"] = kwargs
            return "PROMPT<" + messages[-1]["content"] + ">"

    class FakeCountingTokenizer:
        """Stands in for `load_tokenizer`'s result in the pre-flight measurement only — a
        SEPARATE, lighter-weight load in the real helper, never used for real generation."""
        def apply_chat_template(self, messages, add_generation_prompt=False, **kwargs):
            recorded["counted_messages"] = messages
            return list(range(counted_prompt_tokens))

    def load(path, **kwargs):
        recorded["model_path"] = path
        return (SimpleNamespace(name="fake-model"), FakeTokenizer())

    def stream_generate(model, tokenizer, prompt, max_tokens=256, **kwargs):
        recorded["prompt"] = prompt
        recorded["max_tokens"] = max_tokens
        recorded["sampler"] = kwargs.get("sampler")
        # mlx_lm 0.30.5's generate_step calls this before prefill, after every prefill_step_size
        # (2048) chunk, and once more after the first token (generate.py:425, :440, :459).
        callback = kwargs.get("prompt_progress_callback")
        recorded["prompt_progress_callback"] = callback
        if callback is not None:
            for processed in (0, 2048, 4096, 4096):
                callback(processed, 4096)
        total = 0
        for i, delta in enumerate(deltas):
            total += 1
            yield SimpleNamespace(
                text=delta,
                token=i,
                finish_reason=(finish_reason if i == len(deltas) - 1 else None),
                generation_tokens=total,
                prompt_tokens=3,
            )

    mlx_lm = ModuleType("mlx_lm")
    mlx_lm.load = load
    mlx_lm.stream_generate = stream_generate
    sample_utils = ModuleType("mlx_lm.sample_utils")
    sample_utils.make_sampler = lambda **kwargs: ("sampler", kwargs)
    mlx_lm.sample_utils = sample_utils
    utils = ModuleType("mlx_lm.utils")
    utils.load_config = lambda path: {"max_position_embeddings": context_limit}
    utils.load_tokenizer = lambda path: FakeCountingTokenizer()
    mlx_lm.utils = utils
    sys.modules["mlx_lm"] = mlx_lm
    sys.modules["mlx_lm.sample_utils"] = sample_utils
    sys.modules["mlx_lm.utils"] = utils
    return recorded


def _run_main(
    deltas, system_prompt="SYS", transcript="hello world", finish_reason="stop", max_tokens=None,
    context_limit=1_000_000, counted_prompt_tokens=10,
):
    recorded = _install_fake_mlx_lm(
        deltas, finish_reason=finish_reason, context_limit=context_limit,
        counted_prompt_tokens=counted_prompt_tokens
    )
    directory = tempfile.mkdtemp()
    input_path = os.path.join(directory, "in.json")
    output_path = os.path.join(directory, "out.json")
    with open(input_path, "w", encoding="utf-8") as handle:
        json.dump({"systemPrompt": system_prompt, "transcript": transcript}, handle)
    argv = [
        "summarize_local.py",
        "--model", os.path.join(directory, "model"),
        "--input", input_path,
        "--output", output_path,
    ]
    if max_tokens is not None:
        argv += ["--max-tokens", str(max_tokens)]
    sys.argv = argv
    # The helper's heartbeat goes to stderr (F512); kept here rather than in the test runner's output.
    captured = io.StringIO()
    with contextlib.redirect_stderr(captured):
        code = summ.main()
    recorded["stderr"] = captured.getvalue()
    payload = None
    if os.path.exists(output_path):
        with open(output_path, encoding="utf-8") as handle:
            payload = json.load(handle)
    return code, payload, recorded


class MainEndToEndTests(unittest.TestCase):
    """main() streams the fake model, parses, and writes an atomic --output payload."""

    def test_every_slow_phase_reports_on_stderr(self):
        # F512: the Swift side stops a helper that prints nothing for its stall timeout. Loading the
        # model and prefilling a long transcript used to print nothing at all, so a slow but healthy
        # summary could not be told from a wedged one.
        code, payload, recorded = _run_main(['{"summary":"x","keyPoints":[],"actionItems":[]}'])
        self.assertEqual(code, 0)
        self.assertIsNotNone(recorded.get("prompt_progress_callback"), "prefill progress is not requested")
        lines = recorded["stderr"].splitlines()
        self.assertIn("[summarize] loading model", lines)
        self.assertIn("[summarize] model loaded", lines)
        self.assertIn("[summarize] prompt 2048/4096 tokens", lines)
        self.assertIn("[summarize] prompt 4096/4096 tokens", lines)

    def test_streamed_json_is_parsed_into_payload(self):
        deltas = ['{"summary":"S1",', '"keyPoints":["k1","k2"],', '"actionItems":["a1"]}']
        code, payload, recorded = _run_main(deltas)
        self.assertEqual(code, 0)
        self.assertIsNotNone(payload)
        self.assertEqual(payload["summary"], "S1")
        self.assertEqual(payload["keyPoints"], ["k1", "k2"])
        self.assertEqual(payload["actionItems"], ["a1"])
        self.assertIsNone(payload["warning"])
        # The Swift-built system prompt is forwarded verbatim as the system message.
        self.assertEqual(recorded["messages"][0], {"role": "system", "content": "SYS"})
        self.assertEqual(recorded["messages"][1], {"role": "user", "content": "hello world"})
        # Thinking is disabled for a summarization task.
        self.assertFalse(recorded["kwargs"].get("enable_thinking", True))

    def test_max_tokens_flows_to_stream_generate(self):
        code, payload, recorded = _run_main(['{"summary":"x","keyPoints":[],"actionItems":[]}'], max_tokens=1234)
        self.assertEqual(code, 0)
        self.assertEqual(recorded["max_tokens"], 1234)

    def test_truncated_generation_records_finish_reason(self):
        # A length-capped generation that still parsed keeps finishReason for the Swift side to map.
        code, payload, _ = _run_main(
            ['{"summary":"partial","keyPoints":[],"actionItems":[]}'], finish_reason="length"
        )
        self.assertEqual(code, 0)
        self.assertEqual(payload["finishReason"], "length")

    def test_empty_transcript_exits_zero_with_empty_payload(self):
        code, payload, recorded = _run_main(['ignored'], transcript="   ")
        self.assertEqual(code, 0)
        self.assertIsNotNone(payload)
        self.assertEqual(payload["summary"], "")
        self.assertEqual(payload["keyPoints"], [])
        # The model must not be invoked for an empty transcript.
        self.assertNotIn("prompt", recorded)

    def test_a_too_long_prompt_is_refused_without_loading_the_full_model(self):
        # F475 Part 3: the (comparatively expensive) full weights load must never run for a
        # request the pre-flight check has already decided to refuse.
        code, payload, recorded = _run_main(
            ['ignored'], context_limit=40_960, counted_prompt_tokens=66_001, max_tokens=2_048
        )
        self.assertEqual(code, 0)
        self.assertIsNotNone(payload)
        self.assertEqual(payload["summary"], "")
        self.assertEqual(payload["keyPoints"], [])
        self.assertEqual(payload["actionItems"], [])
        self.assertEqual(payload["finishReason"], "too_long")
        self.assertEqual(payload["generatedTokens"], 0)
        self.assertIn("66001", payload["warning"])
        self.assertIn("40960", payload["warning"])
        # Neither the full model load NOR stream_generate ran.
        self.assertNotIn("model_path", recorded)
        self.assertNotIn("prompt", recorded)
        # The counting tokenizer WAS asked to template the real system prompt + transcript.
        self.assertEqual(recorded["counted_messages"][0], {"role": "system", "content": "SYS"})

    def test_a_prompt_that_fits_still_reaches_the_real_model(self):
        # The regression this guards against: refusing everything, including the ordinary case.
        code, payload, recorded = _run_main(
            ['{"summary":"x","keyPoints":[],"actionItems":[]}'], context_limit=40_960, counted_prompt_tokens=10
        )
        self.assertEqual(code, 0)
        self.assertEqual(payload["summary"], "x")
        self.assertIn("model_path", recorded)
        self.assertIn("prompt", recorded)

class UnreadableModelTests(unittest.TestCase):
    """F598 - a partial or damaged model install is refused with a sentence, not a traceback.

    `load_config` here is a faithful copy of the installed mlx_lm 0.30.5's (utils.py:250-252: open
    `config.json`, `json.load` it, no guard), run over a real temporary model directory, so the
    exceptions are the ones the real call raises rather than ones a fake chose to raise."""

    def setUp(self):
        self.model_dir = tempfile.mkdtemp()

    def _run(self, load_tokenizer=None, load=None):
        recorded = _install_fake_mlx_lm(['{"summary":"x","keyPoints":[],"actionItems":[]}'])
        utils = sys.modules["mlx_lm.utils"]

        def faithful_load_config(model_path):
            with open(model_path / "config.json", "r") as f:
                return json.load(f)

        utils.load_config = faithful_load_config
        if load_tokenizer is not None:
            utils.load_tokenizer = load_tokenizer
        if load is not None:
            sys.modules["mlx_lm"].load = load
        directory = tempfile.mkdtemp()
        input_path = os.path.join(directory, "in.json")
        output_path = os.path.join(directory, "out.json")
        with open(input_path, "w", encoding="utf-8") as handle:
            json.dump({"systemPrompt": "SYS", "transcript": "hello world"}, handle)
        sys.argv = ["summarize_local.py", "--model", self.model_dir,
                    "--input", input_path, "--output", output_path]
        with contextlib.redirect_stderr(io.StringIO()):
            code = summ.main()
        with open(output_path, encoding="utf-8") as handle:
            payload = json.load(handle)
        return code, payload, recorded

    def _write_config(self, text):
        with open(os.path.join(self.model_dir, "config.json"), "w", encoding="utf-8") as handle:
            handle.write(text)

    def _assert_refused(self, code, payload, recorded):
        self.assertEqual(code, 0)
        self.assertEqual(payload["finishReason"], "model_unreadable")
        self.assertEqual(payload["summary"], "")
        self.assertEqual(payload["keyPoints"], [])
        self.assertEqual(payload["actionItems"], [])
        self.assertEqual(payload["generatedTokens"], 0)
        self.assertIn(self.model_dir, payload["warning"])
        self.assertIn("Repair or Update", payload["warning"])
        self.assertNotIn("prompt", recorded, "the model generated anyway")

    def test_a_missing_config_is_refused_before_the_model_loads(self):
        code, payload, recorded = self._run()
        self._assert_refused(code, payload, recorded)
        self.assertNotIn("model_path", recorded, "the full model load ran")
        self.assertIn("FileNotFoundError", payload["warning"])

    def test_a_corrupt_config_is_refused_before_the_model_loads(self):
        self._write_config("{")
        code, payload, recorded = self._run()
        self._assert_refused(code, payload, recorded)
        self.assertNotIn("model_path", recorded, "the full model load ran")
        self.assertIn("JSONDecodeError", payload["warning"])

    def test_a_config_that_is_not_an_object_is_refused(self):
        self._write_config("[]")
        code, payload, recorded = self._run()
        self._assert_refused(code, payload, recorded)
        self.assertNotIn("model_path", recorded, "the full model load ran")

    def test_a_corrupt_tokenizer_is_refused_before_the_model_loads(self):
        # What transformers raises for a truncated tokenizer.json, measured against the installed
        # runtime: JSONDecodeError("Failed to parse tokenizer.json: ...").
        self._write_config('{"max_position_embeddings": 40960}')

        def broken_tokenizer(path):
            raise json.JSONDecodeError("Failed to parse tokenizer.json", "{", 0)

        code, payload, recorded = self._run(load_tokenizer=broken_tokenizer)
        self._assert_refused(code, payload, recorded)
        self.assertNotIn("model_path", recorded, "the full model load ran")

    def test_corrupt_weights_are_refused(self):
        # mlx's own message for a corrupt model.safetensors (100 KB of random bytes), measured
        # against the installed runtime.
        self._write_config('{"max_position_embeddings": 40960}')

        def broken_load(path, **kwargs):
            raise RuntimeError("[load_safetensors] Invalid json header length file " + path)

        code, payload, recorded = self._run(load=broken_load)
        self._assert_refused(code, payload, recorded)

    def test_a_runtime_error_that_is_not_a_damaged_file_still_raises(self):
        # A Metal allocation failure is not a broken install; "repair" would send the user to a
        # multi-gigabyte download that cannot help, so it keeps its own message.
        self._write_config('{"max_position_embeddings": 40960}')

        def out_of_memory(path, **kwargs):
            raise RuntimeError("[metal::malloc] Attempting to allocate 9000000000 bytes")

        with self.assertRaises(RuntimeError):
            self._run(load=out_of_memory)


class LoadHeartbeatTests(unittest.TestCase):
    """F512 review: `load()` blocks with no output, and the Swift side stops a helper that is silent
    for its stall timeout — so a slow cold load under swap would have read as a wedge. A thread
    speaks for the load while it runs.

    No clock. The first version slept 80 ms and expected two 10 ms beats; the CI runner produced
    one (2026-09-26, run 36217649615) where this Mac produced several. The fake load below returns
    when it has SEEN two beats, so the wait's subject is the assertion's subject, and a heartbeat
    that never comes fails on the wait, not on a count.

    F606: a beat is sent only when the load moved since the last check, so a wedged load goes
    silent and the stall timeout can stop it. The tests that need beats therefore stand in a probe
    that always moves; the tests that need silence wait on the number of probes taken, not on time."""

    def setUp(self):
        self.beats = []
        self._report = summ.report_progress
        summ.report_progress = lambda message: self.beats.append(message)
        self._sample = getattr(summ, "load_progress_sample", None)

    def tearDown(self):
        summ.report_progress = self._report
        if self._sample is None:
            if hasattr(summ, "load_progress_sample"):
                del summ.load_progress_sample
        else:
            summ.load_progress_sample = self._sample

    def _always_moving(self):
        counter = iter(range(1, 1_000_000))
        return lambda: (next(counter), 0, 0.0)

    def _heartbeat_thread_is_alive(self):
        return any(thread.name == "load-heartbeat" and thread.is_alive() for thread in threading.enumerate())

    def test_a_slow_load_keeps_reporting_until_it_returns(self):
        summ.load_progress_sample = self._always_moving()

        def load_until_two_beats(path, **kwargs):
            deadline = time.monotonic() + 30
            while len(self.beats) < 2:
                self.assertLess(time.monotonic(), deadline, f"no second heartbeat within 30 s: {self.beats}")
                time.sleep(0.001)
            return ("model", "tokenizer")

        result = summ.load_with_heartbeat(load_until_two_beats, "/models/x", interval=0.001)
        self.assertEqual(result, ("model", "tokenizer"))
        self.assertGreaterEqual(len(self.beats), 2)
        self.assertTrue(all(beat.startswith("still loading model (") for beat in self.beats), self.beats)

    def test_the_heartbeat_stops_when_the_load_returns(self):
        summ.load_with_heartbeat(lambda path, **kwargs: "m", "/models/x", interval=0.001)
        self.assertFalse(self._heartbeat_thread_is_alive(), "the heartbeat thread outlived the load")
        count = len(self.beats)
        time.sleep(0.02)  # a beat landing here could only make this fail, never pass falsely
        self.assertEqual(len(self.beats), count, "a heartbeat arrived after the load had returned")

    def test_a_failing_load_still_stops_the_heartbeat_and_raises(self):
        def broken_load(path, **kwargs):
            raise RuntimeError("no such model")

        with self.assertRaises(RuntimeError):
            summ.load_with_heartbeat(broken_load, "/models/x", interval=0.001)
        self.assertFalse(self._heartbeat_thread_is_alive(), "the heartbeat thread is still running")

    def _load_until(self, probes_taken, beats_seen, cap_seconds=30):
        """A load that returns once the heartbeat has taken 4 probes, as `probes_taken()` counts
        them -- or, so that a heartbeat which never probes fails on an assertion instead of hanging,
        once `beats_seen` beats have arrived. The cap is only a backstop: neither passing nor failing waits on it."""
        def load(path, **kwargs):
            deadline = time.monotonic() + cap_seconds
            while probes_taken() < 4 and len(self.beats) < beats_seen:
                self.assertLess(time.monotonic(), deadline, f"neither 4 probes nor {beats_seen} beats in {cap_seconds} s")
                time.sleep(0.001)
            return ("model", "tokenizer")
        return load

    def test_a_load_that_makes_no_progress_is_silent(self):
        # F606: before, a load wedged in a call that releases the GIL (a stalled page-in, Metal
        # init) was reported "still loading" every 15 s for as long as it hung, so the 600 s
        # stall timeout could never stop it and it held the summary slot until Cancel.
        calls = []

        def stuck():
            calls.append(1)
            return (7, 0, 1.25)

        summ.load_progress_sample = stuck
        load = self._load_until(lambda: len(calls), beats_seen=3)
        summ.load_with_heartbeat(load, "/models/x", interval=0.001)
        self.assertEqual(self.beats, [], "a load that did not move was still reported as loading")
        self.assertGreaterEqual(len(calls), 4, "the heartbeat never probed the load")

    def test_a_blocked_load_is_silent_with_the_real_probe(self):
        # The same claim against the real probe: the load below waits in a lock acquire, which
        # releases the GIL and burns no CPU -- the shape of a wedged Metal or page-in wait. The
        # interval is 50 ms rather than 1 ms because the CPU bar scales with it (see
        # load_made_progress), and a 10 microsecond bar would be timer noise.
        real = summ.load_progress_sample
        taken = threading.Event()
        calls = []

        def counting():
            sample = real()
            calls.append(sample)
            if len(calls) >= 4:
                taken.set()
            return sample

        summ.load_progress_sample = counting

        def blocked_load(path, **kwargs):
            # Returns on the 4th probe; on a heartbeat that never probes, the 30 s backstop ends it
            # and the assertion below fails on the beats that arrived meanwhile.
            taken.wait(30)
            return ("model", "tokenizer")

        summ.load_with_heartbeat(blocked_load, "/models/x", interval=0.05)
        self.assertGreaterEqual(len(calls), 4, "the heartbeat never probed the load")
        self.assertEqual(self.beats, [], f"a blocked load was reported as loading: {calls}")


class LoadProgressTests(unittest.TestCase):
    """F606: what counts as a load moving. Measured with the installed Qwen3-8B-4bit and mlx_lm
    0.30.5 (see load_made_progress): a warm load moved the other threads' CPU by 0.22-0.57 s per
    0.5 s and took up to 171 major faults per 0.5 s; the same process then blocked for 20 s moved
    it by 0.0022 s in all, with no major faults and no block reads."""

    def test_major_faults_or_block_reads_are_progress(self):
        self.assertTrue(summ.load_made_progress((10, 0, 1.0), (11, 0, 1.0), 15.0))
        self.assertTrue(summ.load_made_progress((10, 5, 1.0), (10, 6, 1.0), 15.0))

    def test_cpu_counts_only_above_one_percent_of_the_interval(self):
        # From 0.0 so the subtraction is exact: 1.15 - 1.0 is 0.1499999999999999 in binary.
        self.assertFalse(summ.load_made_progress((10, 5, 0.0), (10, 5, 0.0), 15.0))
        self.assertFalse(summ.load_made_progress((10, 5, 0.0), (10, 5, 0.149), 15.0))
        self.assertTrue(summ.load_made_progress((10, 5, 0.0), (10, 5, 0.15), 15.0))

    def _burn(self, seconds):
        start = time.thread_time()
        while time.thread_time() - start < seconds:
            pass

    def test_the_probing_threads_own_cpu_is_not_progress(self):
        # The heartbeat thread takes the probe, so its own wakeups must not read as the load
        # moving: getrusage(RUSAGE_SELF) alone counts every thread, and moved by up to 0.5 ms per
        # 0.5 s in the blocked measurement from the sampling thread's work alone.
        before = summ.load_progress_sample()
        self._burn(0.05)
        after = summ.load_progress_sample()
        self.assertLess(after[2] - before[2], 0.01, f"the caller's own CPU was counted: {before} -> {after}")

    def test_another_threads_cpu_is_progress(self):
        before = summ.load_progress_sample()
        worker = threading.Thread(target=self._burn, args=(0.05,))
        worker.start()
        worker.join()
        after = summ.load_progress_sample()
        self.assertGreaterEqual(after[2] - before[2], 0.045, f"another thread's CPU was missed: {before} -> {after}")


if __name__ == "__main__":
    unittest.main(verbosity=2)
