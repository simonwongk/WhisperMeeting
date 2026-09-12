#!/usr/bin/env python3
"""Unit tests for the pure logic in Scripts/qwen_transcribe.py.

Run: python3 Scripts/tests/test_qwen_transcribe.py

These import only the helper's pure functions (no mlx / mlx_audio), which live at module scope; the
heavy model imports are deferred inside main(), so importing the module here is safe.
"""

import importlib.util
import json
import os
import sys
import tempfile
import unittest
from types import ModuleType, SimpleNamespace

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


class AlignmentLanguageTests(unittest.TestCase):
    """F155 — the per-chunk forced-aligner language must follow the MAJORITY script, not any single
    CJK char, so an English-dominant chunk that mentions one Chinese name/term aligns with the English
    model (better word timings) instead of being forced through Chinese alignment."""

    def test_english_dominant_single_cjk_is_english(self):
        self.assertEqual(qwen.alignment_language("Let's meet in 北京 next week", "auto"), "English")

    def test_mostly_chinese_is_chinese(self):
        self.assertEqual(qwen.alignment_language("我们讨论了太极拳的历史和哲学", "auto"), "Chinese")

    def test_pure_english_is_english(self):
        self.assertEqual(qwen.alignment_language("hello world", "auto"), "English")

    def test_empty_text_is_english(self):
        self.assertEqual(qwen.alignment_language("   ", "auto"), "English")

    def test_explicit_request_overrides_text(self):
        # An explicit language request is honored regardless of the chunk's script mix.
        self.assertEqual(qwen.alignment_language("hello world", "Chinese"), "Chinese")
        self.assertEqual(qwen.alignment_language("我们讨论了历史", "English"), "English")


class BuildChunksTests(unittest.TestCase):
    """F51 — segment extraction must degrade to [] + warning on schema drift, never raise."""

    def test_valid_segments_build_chunks(self):
        segments = [
            {"text": "hello", "start": 0.0, "end": 1.0},
            {"text": "  ", "start": 1.0, "end": 2.0},  # blank → dropped
        ]
        chunks, warning = qwen.build_chunks(segments)
        self.assertIsNone(warning)
        self.assertEqual(chunks, [{"text": "hello", "start": 0.0, "end": 1.0}])

    def test_schema_drift_degrades_to_warning(self):
        # A changed segment shape (missing the expected "text" key) raises KeyError; the helper must
        # swallow it so the full text is still written.
        segments = [{"content": "hello", "begin": 0.0}]
        chunks, warning = qwen.build_chunks(segments)
        self.assertEqual(chunks, [])
        self.assertIsNotNone(warning)
        self.assertIn("KeyError", warning)


class PlanBatchesTests(unittest.TestCase):
    """F213 — full chunks batch together; the (usually short) last chunk always decodes alone."""

    def test_full_chunks_batch_and_the_last_runs_alone(self):
        self.assertEqual(qwen.plan_batches(6, 4), [[0, 1, 2, 3], [4], [5]])
        self.assertEqual(qwen.plan_batches(5, 4), [[0, 1, 2, 3], [4]])
        self.assertEqual(qwen.plan_batches(2, 4), [[0], [1]])

    def test_single_or_no_chunk(self):
        self.assertEqual(qwen.plan_batches(1, 4), [[0]])
        self.assertEqual(qwen.plan_batches(0, 4), [])


class GreedyDecodeRowsTests(unittest.TestCase):
    """F213 — each row collects until its own EOS while the batch keeps stepping for the others."""

    def test_rows_finish_independently(self):
        script = [[5, 6], [7, 99], [8, 9], [99, 10], [11, 12]]  # per step: next token per row
        steps = iter(script)
        rows = qwen.greedy_decode_rows([1, 2], lambda tokens: next(steps), {99}, max_tokens=50)
        self.assertEqual(rows, [[1, 5, 7, 8], [2, 6]])

    def test_max_tokens_bounds_a_row_that_never_ends(self):
        rows = qwen.greedy_decode_rows([1], lambda tokens: [tokens[0] + 1], {99}, max_tokens=3)
        self.assertEqual(rows, [[1, 2, 3]])

    def test_eos_as_first_token_gives_an_empty_row(self):
        calls = []
        rows = qwen.greedy_decode_rows([99, 4], lambda t: (calls.append(t), [99, 99])[1], {99}, 10)
        self.assertEqual(rows, [[], [4]])
        self.assertEqual(calls, [[99, 4]])


class SegmentsForTests(unittest.TestCase):
    def test_segment_bounds_use_the_real_chunk_length(self):
        chunks = [([0.0] * 32000, 0.0), ([0.0] * 16000, 2.0)]
        self.assertEqual(
            qwen.segments_for(chunks, ["a", "b"]),
            [{"text": "a", "start": 0.0, "end": 2.0}, {"text": "b", "start": 2.0, "end": 3.0}],
        )


class TranscribeFallbackTests(unittest.TestCase):
    """F213 — the sequential library path is the safety net for the batched decoder."""

    def test_batched_failure_falls_back_to_sequential_generate(self):
        calls = []

        def generate(audio, **kwargs):
            calls.append(kwargs)
            return SimpleNamespace(text="fallback", segments=[])

        asr = SimpleNamespace(generate=generate)  # no batched-path internals at all
        result = qwen.transcribe(asr, [0.0] * 32000, "auto", chunk_duration=60.0, batch_size=4)
        self.assertEqual(result.text, "fallback")
        self.assertEqual(calls[0]["chunk_duration"], 60.0)
        self.assertEqual(calls[0]["language"], "auto")
        self.assertTrue(calls[0]["verbose"])


def _install_fake_mlx(transcription, aligner_items=None):
    """Inject fake mlx / numpy / mlx_audio modules so main() runs without the real models. Both the
    ASR model and the aligner load through the same fake load_model (keyed on 'aligner' in the path)."""
    core = ModuleType("mlx.core")
    core.clear_cache = lambda: None
    mlx = ModuleType("mlx")
    mlx.core = core
    numpy = ModuleType("numpy")
    numpy.asarray = lambda x: x
    utils = ModuleType("mlx_audio.stt.utils")
    utils.load_audio = lambda path: [0.0] * 32000

    def load_model(path):
        if "aligner" in path:
            return SimpleNamespace(generate=lambda *a, **k: SimpleNamespace(items=aligner_items or []))
        return SimpleNamespace(generate=lambda *a, **k: transcription)

    utils.load_model = load_model
    stt = ModuleType("mlx_audio.stt")
    stt.utils = utils
    mlx_audio = ModuleType("mlx_audio")
    mlx_audio.stt = stt
    for name, module in {
        "mlx": mlx, "mlx.core": core, "numpy": numpy,
        "mlx_audio": mlx_audio, "mlx_audio.stt": stt, "mlx_audio.stt.utils": utils,
    }.items():
        sys.modules[name] = module


def _run_main(transcription, language="auto", aligner_items=None):
    _install_fake_mlx(transcription, aligner_items=aligner_items)
    directory = tempfile.mkdtemp()
    output = os.path.join(directory, "out.json")
    audio = os.path.join(directory, "audio.wav")
    open(audio, "w").close()
    sys.argv = [
        "qwen_transcribe.py",
        "--model", os.path.join(directory, "model"),
        "--aligner", os.path.join(directory, "aligner"),
        "--audio", audio,
        "--output", output,
        "--language", language,
    ]
    code = qwen.main()
    payload = None
    if os.path.exists(output):
        with open(output, encoding="utf-8") as handle:
            payload = json.load(handle)
    return code, payload


class EmptyTranscriptTests(unittest.TestCase):
    """F53 — an empty/silent clip must exit 0 with an empty payload, not raise a traceback."""

    def test_empty_text_writes_empty_payload_and_exits_zero(self):
        transcription = SimpleNamespace(text="   ", segments=[])
        code, payload = _run_main(transcription)
        self.assertEqual(code, 0)
        self.assertIsNotNone(payload)
        self.assertEqual(payload["text"], "")
        self.assertEqual(payload["alignedItems"], [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
