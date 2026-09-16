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
    # F240: main() patches the qwen3_asr module's mask builder before loading any model, so the fake
    # tree has to carry one for the patch to land on.
    qwen3_asr = ModuleType("mlx_audio.stt.models.qwen3_asr.qwen3_asr")
    qwen3_asr.create_additive_causal_mask = lambda N, offset=0: _StockMaskArray(N, offset)
    qwen3_asr_pkg = ModuleType("mlx_audio.stt.models.qwen3_asr")
    qwen3_asr_pkg.qwen3_asr = qwen3_asr
    models = ModuleType("mlx_audio.stt.models")
    models.qwen3_asr = qwen3_asr_pkg
    stt.models = models
    for name, module in {
        "mlx": mlx, "mlx.core": core, "numpy": numpy,
        "mlx_audio": mlx_audio, "mlx_audio.stt": stt, "mlx_audio.stt.utils": utils,
        "mlx_audio.stt.models": models,
        "mlx_audio.stt.models.qwen3_asr": qwen3_asr_pkg,
        "mlx_audio.stt.models.qwen3_asr.qwen3_asr": qwen3_asr,
    }.items():
        sys.modules[name] = module
    return qwen3_asr


def _run_main(transcription, language="auto", aligner_items=None):
    fake_qwen3_asr = _install_fake_mlx(transcription, aligner_items=aligner_items)
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
    return code, payload, fake_qwen3_asr


class EmptyTranscriptTests(unittest.TestCase):
    """F53 — an empty/silent clip must exit 0 with an empty payload, not raise a traceback."""

    def test_empty_text_writes_empty_payload_and_exits_zero(self):
        transcription = SimpleNamespace(text="   ", segments=[])
        code, payload, _module = _run_main(transcription)
        self.assertEqual(code, 0)
        self.assertIsNotNone(payload)
        self.assertEqual(payload["text"], "")
        self.assertEqual(payload["alignedItems"], [])

    def test_main_installs_the_fused_mask_before_loading_models(self):
        """F240 — the patch has to be in place for both the ASR decoder and the forced aligner."""
        _code, _payload, module = _run_main(SimpleNamespace(text="   ", segments=[]))
        self.assertTrue(getattr(module, "_whispermeet_fused_mask", False))
        self.assertIsNone(module.create_additive_causal_mask(1, offset=5).astype("float16"))


class _ScriptedStep:
    """A fake batched decoder step for F240.

    Each ORIGINAL row emits its own scripted token sequence, independent of which rows are still
    alive, so a test can assert that eviction changes only the WIDTH the step is called with and
    never the tokens a row produces. `widths` records the batch width of every call.

    `evictable=False` deliberately leaves the instance with no `filter` attribute, which is how a
    plain callable (the three pre-F240 tests, and the sequential fallback) must still behave.
    """

    def __init__(self, scripts, evictable):
        self.scripts = scripts
        self.rows = list(range(len(scripts)))  # original row index per live position
        self.pos = [0] * len(scripts)
        self.widths = []
        if evictable:
            self.filter = self._filter

    def _filter(self, keep):
        self.rows = [self.rows[i] for i in keep]

    def __call__(self, tokens):
        self.widths.append(len(tokens))
        out = []
        for row in self.rows:
            index = self.pos[row]
            self.pos[row] = index + 1
            out.append(self.scripts[row][index] if index < len(self.scripts[row]) else 99)
        return out


class GreedyDecodeRowsEvictionTests(unittest.TestCase):
    """F240 — a row that hit EOS must stop being decoded, without changing any row's output.

    Measured motivation: over 12 real 60 s chunks at the shipped batch of 4, 2556 row-steps produced
    1937 useful tokens (24.2% discarded), and the batch holding two near-silent chunks discarded
    52.1% — rows of 7 and 21 tokens dragged through all 236 steps of their loudest neighbour.
    """

    SCRIPTS = [[5, 7, 8, 99], [6, 99]]
    FIRST = [1, 2]
    EXPECTED = [[1, 5, 7, 8], [2, 6]]

    def test_evicts_a_finished_row_and_keeps_every_output(self):
        step = _ScriptedStep(self.SCRIPTS, evictable=True)
        rows = qwen.greedy_decode_rows(self.FIRST, step, {99}, max_tokens=50)
        self.assertEqual(rows, self.EXPECTED)
        # Row 1 finishes on the third iteration, so the batch must narrow 2 -> 1 from then on.
        self.assertEqual(step.widths, [2, 2, 1, 1])

    def test_eviction_does_not_change_the_result(self):
        without = qwen.greedy_decode_rows(
            self.FIRST, _ScriptedStep(self.SCRIPTS, evictable=False), {99}, max_tokens=50
        )
        with_eviction = qwen.greedy_decode_rows(
            self.FIRST, _ScriptedStep(self.SCRIPTS, evictable=True), {99}, max_tokens=50
        )
        self.assertEqual(without, with_eviction)

    def test_a_plain_callable_without_filter_is_never_narrowed(self):
        """The pre-F240 contract: `step` may be a bare callable, and then every row is fed to the end."""
        step = _ScriptedStep(self.SCRIPTS, evictable=False)
        rows = qwen.greedy_decode_rows(self.FIRST, step, {99}, max_tokens=50)
        self.assertEqual(rows, self.EXPECTED)
        self.assertEqual(step.widths, [2, 2, 2, 2])

    def test_all_rows_finishing_together_never_calls_filter(self):
        """Nothing to evict when the whole batch ends on the same step — filter must not be called."""
        step = _ScriptedStep([[99], [99]], evictable=True)
        called = []
        step.filter = lambda keep: called.append(keep)
        rows = qwen.greedy_decode_rows([1, 2], step, {99}, max_tokens=50)
        self.assertEqual(rows, [[1], [2]])
        self.assertEqual(called, [])


class _StockMaskArray:
    """Stands in for the mx.array the stock mask builder returns, recording the dtype asked for."""

    def __init__(self, n, offset):
        self.n, self.offset, self.asked = n, offset, []

    def astype(self, dtype):
        self.asked.append(dtype)
        return self


class FusedAttentionMaskTests(unittest.TestCase):
    """F240 — the fused kernel's own mask replaces the materialized one where they are equivalent."""

    def _module(self):
        built = []

        def stock(N, offset=0):
            array = _StockMaskArray(N, offset)
            built.append(array)
            return array

        return SimpleNamespace(create_additive_causal_mask=stock), built

    def test_decode_step_resolves_to_no_mask(self):
        """L == 1: the stock mask row is all zeros, so `None` is exact and takes the fused path."""
        module, built = self._module()
        self.assertTrue(qwen.install_fused_attention_mask(module))
        self.assertIsNone(module.create_additive_causal_mask(1, offset=873).astype("float16"))
        self.assertEqual(built, [])  # the stock array is never even allocated

    def test_prefill_resolves_to_the_causal_string(self):
        """offset == 0: linds and rinds are both arange(N), i.e. a plain causal mask."""
        module, built = self._module()
        qwen.install_fused_attention_mask(module)
        self.assertEqual(module.create_additive_causal_mask(736).astype("float16"), "causal")
        self.assertEqual(module.create_additive_causal_mask(736, offset=0).astype("float16"), "causal")
        self.assertEqual(built, [])

    def test_any_other_shape_keeps_the_stock_array(self):
        """Not a shape this app reaches, but the patch must narrow behaviour nowhere."""
        module, built = self._module()
        qwen.install_fused_attention_mask(module)
        resolved = module.create_additive_causal_mask(4, offset=9).astype("float16")
        self.assertEqual(len(built), 1)
        self.assertIs(resolved, built[0])
        self.assertEqual((built[0].n, built[0].offset), (4, 9))
        self.assertEqual(built[0].asked, ["float16"])

    def test_install_is_idempotent(self):
        module, _ = self._module()
        self.assertTrue(qwen.install_fused_attention_mask(module))
        patched = module.create_additive_causal_mask
        self.assertFalse(qwen.install_fused_attention_mask(module))
        self.assertIs(module.create_additive_causal_mask, patched)

    def test_kill_switch_leaves_the_stock_builder_in_place(self):
        module, _ = self._module()
        stock = module.create_additive_causal_mask
        os.environ[qwen.FAST_ATTENTION_ENV] = "0"
        try:
            self.assertFalse(qwen.install_fused_attention_mask(module))
            self.assertIs(module.create_additive_causal_mask, stock)
        finally:
            del os.environ[qwen.FAST_ATTENTION_ENV]

    def test_enabled_by_default_and_only_zero_disables(self):
        self.assertTrue(qwen.fast_attention_enabled({}))
        self.assertTrue(qwen.fast_attention_enabled({qwen.FAST_ATTENTION_ENV: "1"}))
        self.assertFalse(qwen.fast_attention_enabled({qwen.FAST_ATTENTION_ENV: "0"}))


class CompletelySilentChunkTests(unittest.TestCase):
    """F243 — a chunk with no signal at all is not worth an encoder pass.

    The user's decision was explicit and narrow: drop a chunk only when it is COMPLETELY silent. So
    the threshold is read literally rather than as a voice-activity judgement — one least-significant
    bit of a 16-bit sample (about -90 dBFS) is the smallest non-zero signal the source format can
    represent, and anything above it is not *completely* silent. A sparse chunk that holds a few
    quiet words is NOT silent and must still be transcribed; that case is what the tests below pin.
    """

    def test_digital_silence_is_silent(self):
        self.assertTrue(qwen.is_completely_silent(0.0))

    def test_one_16_bit_lsb_is_still_silent(self):
        # Exactly at the threshold: a single bit of dither is not audible content.
        self.assertTrue(qwen.is_completely_silent(1.0 / 32768))

    def test_anything_above_the_threshold_is_not_silent(self):
        self.assertFalse(qwen.is_completely_silent(1.0 / 32768 * 1.01))
        self.assertFalse(qwen.is_completely_silent(0.001))
        self.assertFalse(qwen.is_completely_silent(0.5))

    def test_a_single_quiet_sample_keeps_the_whole_chunk(self):
        """The safety property: peak, not average. One word in 60 s of room tone must survive."""
        chunks = [([0.0] * 9_999 + [0.02], 0.0)]
        self.assertEqual(qwen.silent_chunk_indices(chunks, _peak), set())

    def test_only_the_silent_chunks_are_selected(self):
        chunks = [
            ([0.0] * 10, 0.0),            # digital silence
            ([0.0, 0.3, -0.4], 60.0),     # speech
            ([1e-9] * 10, 120.0),         # far below one LSB
            ([0.0, 1.0 / 32768], 180.0),  # exactly at the threshold
            ([0.0, 0.01], 240.0),         # quiet but real
        ]
        self.assertEqual(qwen.silent_chunk_indices(chunks, _peak), {0, 2, 3})

    def test_an_empty_chunk_counts_as_silent_and_never_raises(self):
        self.assertEqual(qwen.silent_chunk_indices([([], 0.0)], _peak), {0})

    def test_no_chunks_selects_nothing(self):
        self.assertEqual(qwen.silent_chunk_indices([], _peak), set())


def _peak(chunk_audio):
    """The pure-Python stand-in for the numpy peak the helper is given in production."""
    return max((abs(sample) for sample in chunk_audio), default=0.0)


if __name__ == "__main__":
    unittest.main(verbosity=2)
