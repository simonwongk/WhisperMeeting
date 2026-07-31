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
