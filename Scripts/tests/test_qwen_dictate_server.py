#!/usr/bin/env python3
"""Unit tests for Scripts/qwen_dictate_server.py (F431, F607).

Run: python3 Scripts/tests/test_qwen_dictate_server.py

Imports the helper without mlx or mlx_audio, like test_qwen_transcribe.py: the model imports are
deferred into functions, and these tests replace the three that touch the runtime.
"""

import importlib.util
import os
import re
import sys
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
        # Pinned at `stream_generate`: the cap is handed to the library's own loop, so the model is
        # asked for exactly DICTATION_MAX_TOKENS tokens. The guarded reader's one extra `next` finds
        # the stream already exhausted and reads EOS without another decode step.
        self.assertEqual(model.pulled, server.DICTATION_MAX_TOKENS)

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


# The Swift side of the reply wait, read from the source rather than restated (F607): the first
# `readLine(timeout: …)` inside `WarmWhisperDictationEngine.transcribe`, which Qwen dictation shares
# through `WarmQwenDictationEngine`'s runner. If that argument stops being a literal, this raises
# instead of silently pinning a stale number.
_SWIFT_ENGINE = os.path.join(
    os.path.dirname(__file__), "..", "..", "Sources", "WhisperCore", "WarmWhisperDictationEngine.swift"
)


def swift_reply_timeout_seconds():
    with open(_SWIFT_ENGINE, encoding="utf-8") as handle:
        source = handle.read()
    start = source.index("public func transcribe(")
    # The FIRST `readLine(timeout:` after `transcribe` begins, whatever its argument: matching only
    # a literal would skip a renamed one and land on the 1,800 s ready wait further down.
    match = re.compile(r"readLine\(timeout:\s*([^,)]+)").search(source, start)
    if match is None:
        raise AssertionError("no readLine(timeout:) after WarmWhisperDictationEngine.transcribe")
    argument = match.group(1).strip()
    if not re.fullmatch(r"[0-9][0-9_]*(\.[0-9_]+)?", argument):
        raise AssertionError(f"transcribe's reply wait is {argument!r}, not a literal; update this reader")
    return float(argument.replace("_", ""))


class _Clock:
    """A monotonic clock that only moves when the fake decoder pulls a token."""

    def __init__(self):
        self.now = 1_000.0

    def __call__(self):
        return self.now


class _TimedQwen3ASR(_Qwen3ASR):
    """`_Qwen3ASR` whose every decoded token costs `1 / rate` seconds of `clock`, with a script per
    chunk (`chunk_scripts[i]` is `(script, repeat)` for the i-th `stream_generate` call)."""

    def __init__(self, chunk_scripts, vocabulary, clock, rate):
        super().__init__(chunk_scripts[0][0], vocabulary, repeat=chunk_scripts[0][1])
        self.chunk_scripts = chunk_scripts
        self.clock = clock
        self.rate = rate
        self.per_chunk_pulled = []

    def stream_generate(self, audio, *, max_tokens=LIBRARY_MAX_TOKENS, language="English", **_):
        index = len(self.stream_calls)
        self.stream_calls.append({"max_tokens": max_tokens, "language": language})
        script, repeat = self.chunk_scripts[index]
        self.per_chunk_pulled.append(0)
        emitted = 0
        while emitted < max_tokens:
            if not repeat and emitted >= len(script):
                return
            self.clock.now += 1.0 / self.rate
            self.pulled += 1
            self.per_chunk_pulled[index] += 1
            token = script[emitted % len(script)]
            emitted += 1
            yield token, None


class DictationReplyDeadlineTests(unittest.TestCase):
    """F607 — F431's 768-token cap bounded the worst reply only at the development Mac's measured
    ~45 tok/s: five chunks each stuck in a cycle too long for the F260 guard decode 5 x 768 = 3,840
    tokens, which is 192 s at 20 tok/s and 384 s at 10 — past the Swift reply wait, so a looping
    dictation on a slower Mac still ended in the watchdog kill and a cold reload. The bound must not
    rest on a rate nobody has measured, so these tests run the same worst case at three rates."""

    _SEAMS = ("load_clip", "split_clip", "release_chunk_memory", "monotonic")
    CHUNKS = 5  # a 120 s dictation cut as early as every 25 s
    LONG_CYCLE = list(range(10, 22))  # twelve tokens: longer than the guard's eight-token window

    def setUp(self):
        self._saved = {name: getattr(server, name, None) for name in self._SEAMS}
        self.clock = _Clock()
        server.monotonic = self.clock
        server.load_clip = lambda path: ("audio from", path)
        server.split_clip = lambda audio, sample_rate: [
            ([0.1] * 16_000, 30.0 * index) for index in range(self.CHUNKS)
        ]
        server.release_chunk_memory = lambda: None

    def tearDown(self):
        for name, value in self._saved.items():
            setattr(server, name, value)

    def vocabulary(self):
        words = {token: f"w{token} " for token in self.LONG_CYCLE}
        words.update({token: f"s{token} " for token in range(100, 300)})
        return words

    def dictate(self, model):
        started = self.clock.now
        response = server.transcribe_request(
            model, {"wavPath": "/tmp/clip.wav", "language": None, "initialPrompt": None}
        )
        return response, self.clock.now - started

    def test_the_helper_mirrors_the_swift_reply_wait(self):
        timeout = swift_reply_timeout_seconds()
        self.assertEqual(getattr(server, "REPLY_TIMEOUT_SECONDS", None), timeout)
        budget = getattr(server, "DICTATION_DECODE_BUDGET_SECONDS", None)
        self.assertIsNotNone(budget)
        self.assertLess(budget, timeout)

    def test_five_stuck_chunks_reply_inside_the_swift_wait_at_any_rate(self):
        timeout = swift_reply_timeout_seconds()
        for rate in (10, 20, 45):
            with self.subTest(rate=rate):
                self.clock.now = 1_000.0
                model = _TimedQwen3ASR(
                    [(self.LONG_CYCLE, True)] * self.CHUNKS, self.vocabulary(), self.clock, rate
                )
                response, elapsed = self.dictate(model)
                self.assertLess(elapsed, timeout)
                self.assertEqual(len(model.stream_calls), self.CHUNKS)
                self.assertTrue(response["text"].startswith("w10 w11"))

    def test_one_stuck_chunk_does_not_starve_the_speech_after_it(self):
        """A fair share per chunk, not one deadline for the whole clip: a runaway first chunk is cut
        at its share, and the four ordinary chunks after it are decoded in full. At 5 tok/s the
        runaway alone would take 768 / 5 = 154 s, so one deadline for the whole clip would spend all
        of it on the first chunk and decode none of the speech after it."""
        speech = [list(range(100 + 40 * index, 140 + 40 * index)) for index in range(4)]
        model = _TimedQwen3ASR(
            [(self.LONG_CYCLE, True)] + [(chunk, False) for chunk in speech],
            self.vocabulary(), self.clock, rate=5,
        )
        response, elapsed = self.dictate(model)
        self.assertLess(elapsed, swift_reply_timeout_seconds())
        self.assertEqual(model.per_chunk_pulled[1:], [len(chunk) for chunk in speech])
        for chunk in speech:
            self.assertIn("".join(f"s{token} " for token in chunk).strip(), response["text"])

    def test_ordinary_five_chunk_speech_is_decoded_in_full_at_a_slow_rate(self):
        """~140 tokens a chunk — the F431 bench's densest chunk was 138 — at 20 tok/s is 35 s in all,
        well inside the budget, so the deadline must not cut a single token of it."""
        speech = [list(range(100 + 40 * index, 100 + 40 * index + 140)) for index in range(self.CHUNKS)]
        words = {token: f"s{token} " for token in range(100, 400)}
        model = _TimedQwen3ASR([(chunk, False) for chunk in speech], words, self.clock, rate=20)
        response, _elapsed = self.dictate(model)
        self.assertEqual(model.per_chunk_pulled, [140] * self.CHUNKS)
        decoded = ["".join(words[token] for token in chunk) for chunk in speech]
        self.assertEqual(response["text"], " ".join(decoded).strip())


class DictationChunkJoinTests(unittest.TestCase):
    """F607 part 2 — dictation joins its chunks with `qwen_transcribe.joined_text` (F431), so F562's
    CJK boundary rule changed multi-chunk Mandarin dictation too. Nothing on the dictation side
    pinned it: the only multi-chunk test joined Latin words, which `" ".join` would also pass."""

    _SEAMS = ("load_clip", "split_clip", "release_chunk_memory")

    def setUp(self):
        self._saved = {name: getattr(server, name, None) for name in self._SEAMS}
        server.load_clip = lambda path: ("audio from", path)
        server.split_clip = lambda audio, sample_rate: [([0.1] * 16_000, 0.0), ([0.1] * 16_000, 30.0)]
        server.release_chunk_memory = lambda: None

    def tearDown(self):
        for name, value in self._saved.items():
            setattr(server, name, value)

    def dictate(self, chunk_texts):
        vocabulary = {index + 1: text for index, text in enumerate(chunk_texts)}
        clock = _Clock()
        model = _TimedQwen3ASR([([index + 1], False) for index in range(len(chunk_texts))], vocabulary, clock, 45)
        return server.transcribe_request(
            model, {"wavPath": "/tmp/clip.wav", "language": "Chinese", "initialPrompt": None}
        )["text"]

    def test_a_mandarin_boundary_gets_no_space(self):
        self.assertEqual(self.dictate(["我们明天开会", "我们明天开会"]), "我们明天开会我们明天开会")

    def test_a_code_switched_boundary_keeps_its_space(self):
        self.assertEqual(self.dictate(["我们用", "Swift 写"]), "我们用 Swift 写")
        self.assertEqual(self.dictate(["deploy 到", "production"]), "deploy 到 production")


class MeetingHelperContractTests(unittest.TestCase):
    """F431 follow-up — this helper borrows `greedy_decode_rows`, `ASR_EOS_TOKEN_IDS` and
    `joined_text` from the `qwen_transcribe.py` beside it. A runtime directory holding an older
    sibling must be refused at startup, naming that file, rather than surfacing as an
    AttributeError inside the first dictation after seconds of model loading."""

    def setUp(self):
        self._meeting_helper = server.meeting_helper
        self._argv = sys.argv

    def tearDown(self):
        server.meeting_helper = self._meeting_helper
        sys.argv = self._argv

    def test_the_sibling_in_this_tree_passes_the_check(self):
        module = server.meeting_helper()
        self.assertIs(server.check_meeting_helper(module, server.meeting_helper_path()), module)
        self.assertEqual(
            server.MEETING_HELPER_NAMES, ("greedy_decode_rows", "ASR_EOS_TOKEN_IDS", "joined_text")
        )

    def test_startup_refuses_an_older_sibling_and_names_the_file(self):
        """Through `main`, so the refusal is shown to come before the model import: this test
        runs without mlx_audio, so reaching `load_model` would raise ModuleNotFoundError instead."""
        older = SimpleNamespace(ASR_EOS_TOKEN_IDS=(1,), joined_text=" ".join)  # pre-F431 sibling
        server.meeting_helper = lambda: older
        sys.argv = ["qwen_dictate_server.py", "--model", "/nonexistent/model"]
        with self.assertRaises(RuntimeError) as refused:
            server.main()
        message = str(refused.exception)
        self.assertIn(server.meeting_helper_path(), message)
        self.assertIn("greedy_decode_rows", message)


if __name__ == "__main__":
    unittest.main()
