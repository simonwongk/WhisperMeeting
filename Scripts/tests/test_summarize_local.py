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


def _install_fake_mlx_lm(deltas, finish_reason="stop"):
    """Inject a fake mlx_lm (+ mlx_lm.sample_utils) so main() runs without a real model.

    stream_generate yields one GenerationResponse per delta in `deltas`; concatenated they are the
    model's full output text. The fake tokenizer records the messages it was asked to template.
    """
    recorded = {}

    class FakeTokenizer:
        def apply_chat_template(self, messages, add_generation_prompt=False, **kwargs):
            recorded["messages"] = messages
            recorded["add_generation_prompt"] = add_generation_prompt
            recorded["kwargs"] = kwargs
            return "PROMPT<" + messages[-1]["content"] + ">"

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
    sys.modules["mlx_lm"] = mlx_lm
    sys.modules["mlx_lm.sample_utils"] = sample_utils
    return recorded


def _run_main(deltas, system_prompt="SYS", transcript="hello world", finish_reason="stop", max_tokens=None):
    recorded = _install_fake_mlx_lm(deltas, finish_reason=finish_reason)
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


if __name__ == "__main__":
    unittest.main(verbosity=2)


class LoadHeartbeatTests(unittest.TestCase):
    """F512 review: `load()` blocks with no output, and the Swift side stops a helper that is silent
    for its stall timeout — so a slow cold load under swap would have read as a wedge. A thread
    speaks for the load while it runs."""

    def test_a_slow_load_keeps_reporting_until_it_returns(self):
        def slow_load(path, **kwargs):
            time.sleep(0.08)
            return ("model", "tokenizer")

        captured = io.StringIO()
        with contextlib.redirect_stderr(captured):
            result = summ.load_with_heartbeat(slow_load, "/models/x", interval=0.01)
        self.assertEqual(result, ("model", "tokenizer"))
        beats = [line for line in captured.getvalue().splitlines() if "still loading model" in line]
        self.assertGreaterEqual(len(beats), 2, captured.getvalue())

    def test_the_heartbeat_stops_when_the_load_returns(self):
        captured = io.StringIO()
        with contextlib.redirect_stderr(captured):
            summ.load_with_heartbeat(lambda path, **kwargs: "m", "/models/x", interval=0.01)
            before = captured.getvalue()
            time.sleep(0.05)
        self.assertEqual(captured.getvalue(), before, "the heartbeat outlived the load")

    def test_a_failing_load_still_stops_the_heartbeat_and_raises(self):
        def broken_load(path, **kwargs):
            raise RuntimeError("no such model")

        captured = io.StringIO()
        with contextlib.redirect_stderr(captured), self.assertRaises(RuntimeError):
            summ.load_with_heartbeat(broken_load, "/models/x", interval=0.01)
        self.assertEqual(threading.active_count(), 1, "the heartbeat thread is still running")
