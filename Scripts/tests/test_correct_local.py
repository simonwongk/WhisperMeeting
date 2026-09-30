#!/usr/bin/env python3
"""Unit tests for the pure logic in Scripts/correct_local.py.

Run: python3 Scripts/tests/test_correct_local.py

Imports only the helper's pure functions (no mlx_lm); main() is exercised with a fake mlx_lm injected
into sys.modules, mirroring test_summarize_local.py.
"""

import importlib.util
import json
import os
import sys
import tempfile
import unittest
from types import ModuleType, SimpleNamespace

_SCRIPT = os.path.join(os.path.dirname(__file__), "..", "correct_local.py")
_spec = importlib.util.spec_from_file_location("correct_local", _SCRIPT)
correct = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(correct)


class ParseCorrectionsTests(unittest.TestCase):
    """F165 — the model's text must degrade to a corrections list, never raise."""

    def test_clean_json(self):
        items, warning = correct.parse_corrections(
            '{"corrections":[{"from":"Kew Bernetes","to":"Kubernetes"},{"from":"Post Grease","to":"Postgres"}]}'
        )
        self.assertIsNone(warning)
        self.assertEqual(items, [
            {"from": "Kew Bernetes", "to": "Kubernetes"},
            {"from": "Post Grease", "to": "Postgres"},
        ])

    def test_json_in_code_fence_with_thinking_and_prose(self):
        text = (
            "<think>find the mis-heard terms</think>\n"
            "Here are the corrections:\n"
            '```json\n{"corrections":[{"from":"我们讨论了太急","to":"我们讨论了太极"}]}\n```'
        )
        items, warning = correct.parse_corrections(text)
        self.assertIsNone(warning)
        self.assertEqual(items, [{"from": "我们讨论了太急", "to": "我们讨论了太极"}])

    def test_coercion_drops_invalid_entries(self):
        items, warning = correct.parse_corrections(json.dumps({"corrections": [
            {"from": "good", "to": "Good"},   # kept
            {"from": "same", "to": "same"},    # dropped: from == to
            {"from": "  ", "to": "x"},          # dropped: blank from
            {"from": "y", "to": ""},            # dropped: blank to
            {"to": "no-from"},                  # dropped: missing from
            "not-a-dict",                       # dropped
        ]}))
        self.assertIsNone(warning)
        self.assertEqual(items, [{"from": "good", "to": "Good"}])

    def test_valid_but_empty_corrections_is_not_an_error(self):
        items, warning = correct.parse_corrections('{"corrections":[]}')
        self.assertIsNone(warning)
        self.assertEqual(items, [])

    def test_no_json_degrades_to_empty_with_warning(self):
        items, warning = correct.parse_corrections("I could not find anything to fix.")
        self.assertIsNotNone(warning)
        self.assertIn("JSON", warning)
        self.assertEqual(items, [])

    def test_empty_text_is_empty_with_warning(self):
        items, warning = correct.parse_corrections("   ")
        self.assertIsNotNone(warning)
        self.assertEqual(items, [])


class ContextOverflowDetailTests(unittest.TestCase):
    """F475 Part 3 — mirrors test_summarize_local.py's twin; see there for the real-model
    measurement (mlx-community/Qwen3-8B-4bit, max_position_embeddings 40,960)."""

    def test_a_prompt_that_fits_is_not_flagged(self):
        self.assertEqual(correct.context_overflow_detail(10_000, context_limit=40_960, max_tokens=2_048), "")

    def test_one_token_over_budget_is_flagged(self):
        budget = 40_960 - 2_048 - correct.CONTEXT_SAFETY_MARGIN_TOKENS
        detail = correct.context_overflow_detail(budget + 1, context_limit=40_960, max_tokens=2_048)
        self.assertIn(str(budget + 1), detail)
        self.assertIn("shorter selection", detail)


def _install_fake_mlx_lm(deltas, finish_reason="stop", context_limit=1_000_000, counted_prompt_tokens=10):
    """F475 Part 3: `context_limit`/`counted_prompt_tokens` fake the pre-flight context-window
    check (`mlx_lm.utils.load_config`/`load_tokenizer`) the same way test_summarize_local.py's
    twin does. Defaults keep every existing test on the path it always took."""
    recorded = {}

    class FakeTokenizer:
        def apply_chat_template(self, messages, add_generation_prompt=False, **kwargs):
            recorded["messages"] = messages
            recorded["kwargs"] = kwargs
            return "PROMPT<" + messages[-1]["content"] + ">"

    class FakeCountingTokenizer:
        def apply_chat_template(self, messages, add_generation_prompt=False, **kwargs):
            recorded["counted_messages"] = messages
            return list(range(counted_prompt_tokens))

    def load(path, **kwargs):
        recorded["model_path"] = path
        return (SimpleNamespace(name="fake"), FakeTokenizer())

    def stream_generate(model, tokenizer, prompt, max_tokens=256, **kwargs):
        recorded["prompt"] = prompt
        recorded["max_tokens"] = max_tokens
        for i, delta in enumerate(deltas):
            yield SimpleNamespace(
                text=delta, token=i,
                finish_reason=(finish_reason if i == len(deltas) - 1 else None),
                generation_tokens=i + 1,
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
    deltas, transcript="Kew Bernetes runs the cluster.", max_tokens=None,
    context_limit=1_000_000, counted_prompt_tokens=10,
):
    recorded = _install_fake_mlx_lm(
        deltas, context_limit=context_limit, counted_prompt_tokens=counted_prompt_tokens
    )
    directory = tempfile.mkdtemp()
    input_path = os.path.join(directory, "in.json")
    output_path = os.path.join(directory, "out.json")
    with open(input_path, "w", encoding="utf-8") as handle:
        json.dump({"systemPrompt": "SYS", "transcript": transcript}, handle)
    argv = ["correct_local.py", "--model", os.path.join(directory, "model"),
            "--input", input_path, "--output", output_path]
    if max_tokens is not None:
        argv += ["--max-tokens", str(max_tokens)]
    sys.argv = argv
    code = correct.main()
    payload = None
    if os.path.exists(output_path):
        with open(output_path, encoding="utf-8") as handle:
            payload = json.load(handle)
    return code, payload, recorded


class MainEndToEndTests(unittest.TestCase):
    def test_streamed_corrections_are_parsed(self):
        deltas = ['{"corrections":[', '{"from":"Kew Bernetes","to":"Kubernetes"}', ']}']
        code, payload, recorded = _run_main(deltas)
        self.assertEqual(code, 0)
        self.assertEqual(payload["corrections"], [{"from": "Kew Bernetes", "to": "Kubernetes"}])
        self.assertIsNone(payload["warning"])
        self.assertFalse(recorded["kwargs"].get("enable_thinking", True))

    def test_max_tokens_flows(self):
        code, _, recorded = _run_main(['{"corrections":[]}'], max_tokens=999)
        self.assertEqual(code, 0)
        self.assertEqual(recorded["max_tokens"], 999)

    def test_empty_transcript_exits_zero_without_invoking_model(self):
        code, payload, recorded = _run_main(['ignored'], transcript="   ")
        self.assertEqual(code, 0)
        self.assertEqual(payload["corrections"], [])
        self.assertNotIn("prompt", recorded)

    def test_a_too_long_prompt_is_refused_without_loading_the_full_model(self):
        code, payload, recorded = _run_main(
            ['ignored'], context_limit=40_960, counted_prompt_tokens=55_000, max_tokens=2_048
        )
        self.assertEqual(code, 0)
        self.assertEqual(payload["corrections"], [])
        self.assertEqual(payload["finishReason"], "too_long")
        self.assertEqual(payload["generatedTokens"], 0)
        self.assertIn("55000", payload["warning"])
        self.assertNotIn("model_path", recorded)
        self.assertNotIn("prompt", recorded)

    def test_a_prompt_that_fits_still_reaches_the_real_model(self):
        code, payload, recorded = _run_main(
            ['{"corrections":[]}'], context_limit=40_960, counted_prompt_tokens=10
        )
        self.assertEqual(code, 0)
        self.assertEqual(payload["corrections"], [])
        self.assertIn("model_path", recorded)
        self.assertIn("prompt", recorded)



class UnreadableModelTests(unittest.TestCase):
    """F598 - test_summarize_local.py's twin: a partial or damaged model install is refused with a
    sentence, not a traceback. `load_config` is a faithful copy of the installed mlx_lm 0.30.5's
    (utils.py:250-252), run over a real temporary model directory."""

    def setUp(self):
        self.model_dir = tempfile.mkdtemp()

    def _run(self, load_tokenizer=None, load=None):
        recorded = _install_fake_mlx_lm(['{"corrections":[]}'])
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
            json.dump({"systemPrompt": "SYS", "transcript": "Kew Bernetes runs."}, handle)
        sys.argv = ["correct_local.py", "--model", self.model_dir,
                    "--input", input_path, "--output", output_path]
        code = correct.main()
        with open(output_path, encoding="utf-8") as handle:
            payload = json.load(handle)
        return code, payload, recorded

    def _write_config(self, text):
        with open(os.path.join(self.model_dir, "config.json"), "w", encoding="utf-8") as handle:
            handle.write(text)

    def _assert_refused(self, code, payload, recorded):
        self.assertEqual(code, 0)
        self.assertEqual(payload["finishReason"], "model_unreadable")
        self.assertEqual(payload["corrections"], [])
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

    def test_a_corrupt_tokenizer_is_refused_before_the_model_loads(self):
        self._write_config('{"max_position_embeddings": 40960}')

        def broken_tokenizer(path):
            raise json.JSONDecodeError("Failed to parse tokenizer.json", "{", 0)

        code, payload, recorded = self._run(load_tokenizer=broken_tokenizer)
        self._assert_refused(code, payload, recorded)
        self.assertNotIn("model_path", recorded, "the full model load ran")

    def test_corrupt_weights_are_refused(self):
        self._write_config('{"max_position_embeddings": 40960}')

        def broken_load(path, **kwargs):
            raise RuntimeError("[load_safetensors] Invalid json header length file " + path)

        code, payload, recorded = self._run(load=broken_load)
        self._assert_refused(code, payload, recorded)

    def test_a_runtime_error_that_is_not_a_damaged_file_still_raises(self):
        self._write_config('{"max_position_embeddings": 40960}')

        def out_of_memory(path, **kwargs):
            raise RuntimeError("[metal::malloc] Attempting to allocate 9000000000 bytes")

        with self.assertRaises(RuntimeError):
            self._run(load=out_of_memory)

if __name__ == "__main__":
    unittest.main(verbosity=2)
