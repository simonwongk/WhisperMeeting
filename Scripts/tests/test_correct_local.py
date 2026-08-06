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


def _install_fake_mlx_lm(deltas, finish_reason="stop"):
    recorded = {}

    class FakeTokenizer:
        def apply_chat_template(self, messages, add_generation_prompt=False, **kwargs):
            recorded["messages"] = messages
            recorded["kwargs"] = kwargs
            return "PROMPT<" + messages[-1]["content"] + ">"

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
    sys.modules["mlx_lm"] = mlx_lm
    sys.modules["mlx_lm.sample_utils"] = sample_utils
    return recorded


def _run_main(deltas, transcript="Kew Bernetes runs the cluster.", max_tokens=None):
    recorded = _install_fake_mlx_lm(deltas)
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


if __name__ == "__main__":
    unittest.main(verbosity=2)
