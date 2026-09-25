#!/usr/bin/env python3
"""Unit tests for Scripts/qwen_dictate_server.py (F431).

Run: python3 Scripts/tests/test_qwen_dictate_server.py

Imports the helper without mlx or mlx_audio, like test_qwen_transcribe.py: the model imports are
deferred into functions, and these tests replace the three that touch the runtime.
"""

import importlib.util
import os
import unittest
from types import SimpleNamespace

_SCRIPT = os.path.join(os.path.dirname(__file__), "..", "qwen_dictate_server.py")
_spec = importlib.util.spec_from_file_location("qwen_dictate_server", _SCRIPT)
server = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(server)

# mlx-audio 0.3.1's own defaults (`qwen3_asr.py:1008-1012` in the pinned wheel): what a request
# decodes to when nothing narrower is passed, and so what an unguarded runaway runs to.
LIBRARY_MAX_TOKENS = 8192


class _Tokenizer:
    def __init__(self, vocabulary):
        self.vocabulary = vocabulary

    def decode(self, tokens, skip_special_tokens=True):
        return "".join(self.vocabulary[token] for token in tokens)


class _Qwen3ASR:
    """Stands in for mlx-audio 0.3.1's `Qwen3ASR` at the two entry points a caller can use.

    `stream_generate` is the per-chunk greedy loop (`qwen3_asr.py:867-968`): it yields one
    `(token, logprobs)` per step and stops ONLY at an EOS id or at `max_tokens` — there is no
    repetition check. `generate` is the sequential loop over chunks (`:1008-1162`), each chunk
    decoded by `stream_generate` and the texts joined with a space.

    `script` is what the decoder emits for every chunk; `repeat=True` cycles it forever, which is
    the shape of F260's real exhibit (`"No, "` x4034 from six seconds of audio).
    """

    sample_rate = 16_000

    def __init__(self, script, vocabulary, repeat=False):
        self.script = script
        self.repeat = repeat
        self._tokenizer = _Tokenizer(vocabulary)
        self.pulled = 0
        self.stream_calls = []

    def stream_generate(self, audio, *, max_tokens=LIBRARY_MAX_TOKENS, language="English", **_):
        self.stream_calls.append({"max_tokens": max_tokens, "language": language})
        emitted = 0
        while emitted < max_tokens:
            if not self.repeat and emitted >= len(self.script):
                return  # EOS: the library breaks without yielding it
            token = self.script[emitted % len(self.script)]
            self.pulled += 1
            emitted += 1
            yield token, None

    def generate(self, audio, *, max_tokens=LIBRARY_MAX_TOKENS, language="English", **_):
        tokens = [int(t) for t, _ in self.stream_generate(audio, max_tokens=max_tokens, language=language)]
        return SimpleNamespace(text=self._tokenizer.decode(tokens), segments=[])


class DictationDecodeTests(unittest.TestCase):
    """F431 — Quick Dictation must get the same runaway guard as a meeting.

    Before this, `transcribe_request` called mlx-audio's own `generate`, which F260/F268 had taken
    every meeting off: it stops only at EOS or at 8,192 tokens per 30 s chunk. At F213's measured
    single-row ~59 tok/s that is ~139 s — past `WarmWhisperDictationEngine`'s 120 s read timeout,
    so a looping dictation ended as "Dictation helper stopped unexpectedly" and a cold reload, or,
    on a faster Mac, as thousands of repeated words pasted into the focused app.
    """

    _SEAMS = ("load_clip", "split_clip", "release_chunk_memory")

    def setUp(self):
        # Saved with a default, so a helper without these seams still runs every test to its
        # assertion — the red run below fails on what the decode did, not on a missing name.
        self._saved = {name: getattr(server, name, None) for name in self._SEAMS}
        self.chunks = [([0.1] * 16_000, 0.0)]
        server.load_clip = lambda path: ("audio from", path)
        server.split_clip = lambda audio, sample_rate: list(self.chunks)
        server.release_chunk_memory = lambda: None

    def tearDown(self):
        for name, value in self._saved.items():
            setattr(server, name, value)

    def request(self, model, language=None):
        return server.transcribe_request(
            model, {"wavPath": "/tmp/clip.wav", "language": language, "initialPrompt": None}
        )

    def test_a_looping_dictation_stops_at_the_guard_and_keeps_one_copy(self):
        """F260's shape: a two-token cycle forever. The meeting path stops it within
        `ASR_MAX_CYCLE_LEN * ASR_MAX_CYCLE_REPS` tokens and F421 trims it back to one copy."""
        model = _Qwen3ASR([1, 2], {1: "No", 2: ", "}, repeat=True)
        response = self.request(model)
        self.assertEqual(response["text"], "No,")
        self.assertLess(model.pulled, 64)

    def test_a_cycle_too_long_for_the_guard_stops_at_the_dictation_cap(self):
        """A repeated twelve-token phrase is longer than the guard's eight-token window, so only a
        token cap can stop it — and the library's own cap is the 8,192 that outlasts the timeout."""
        cycle = list(range(10, 22))
        model = _Qwen3ASR(cycle, {token: f"w{token} " for token in cycle}, repeat=True)
        self.request(model)
        self.assertLess(model.pulled, LIBRARY_MAX_TOKENS)
        # +1: the greedy loop asks for one token past its cap before it stops asking.
        self.assertLessEqual(model.pulled, server.DICTATION_MAX_TOKENS + 1)

    def test_ordinary_speech_is_decoded_in_full(self):
        """Natural repetition — "no, no, no" — is well under the guard and must survive intact."""
        script = [1, 2, 1, 2, 1, 3]
        model = _Qwen3ASR(script, {1: "no", 2: ", ", 3: "."})
        self.assertEqual(self.request(model)["text"], "no, no, no.")

    def test_every_chunk_is_decoded_and_joined_as_the_meeting_path_joins(self):
        self.chunks = [([0.1] * 16_000, 0.0), ([0.1] * 16_000, 30.0)]
        model = _Qwen3ASR([1], {1: "hello"})
        self.assertEqual(self.request(model)["text"], "hello hello")
        self.assertEqual(len(model.stream_calls), 2)

    def test_the_pinned_or_automatic_language_reaches_the_decoder(self):
        model = _Qwen3ASR([1], {1: "hi"})
        self.request(model, language="Chinese")
        self.request(model, language=None)
        self.assertEqual([call["language"] for call in model.stream_calls], ["Chinese", "auto"])

    def test_the_request_clip_is_the_one_decoded(self):
        seen = []
        server.split_clip = lambda audio, sample_rate: seen.append((audio, sample_rate)) or list(self.chunks)
        self.request(_Qwen3ASR([1], {1: "hi"}))
        self.assertEqual(seen, [(("audio from", "/tmp/clip.wav"), 16_000)])


if __name__ == "__main__":
    unittest.main()
