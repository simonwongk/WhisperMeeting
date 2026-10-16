#!/usr/bin/env python3
"""Persistent JSON-lines helper for Qwen3-ASR Quick Dictation.

The Swift recorder supplies the same temporary WAV used by every dictation engine.
This process keeps Qwen resident between clips and returns the existing dictation
wire format. The local Qwen API has no vocabulary-prompt parameter, so
``initialPrompt`` is deliberately ignored.
"""

import argparse
import functools
import importlib.util
import json
import os
import sys
import tempfile
import time
import wave


# The chunk length this helper has always asked mlx-audio for: a longer clip is split at the
# quietest point within ±5 s of each 30 s mark (`split_audio_into_chunks`) and decoded chunk by
# chunk.
DICTATION_CHUNK_SECONDS = 30.0
# F431: tokens one chunk may decode before it is cut off. mlx-audio's own default is 8192, which a
# decoder stuck in a cycle longer than the F260 guard's window (`ASR_MAX_CYCLE_LEN` tokens) runs all
# the way to: ~139 s per chunk at F213's measured single-row 59 tok/s (measured on the development
# Mac, Apple M3 Pro, 18 GB), past the 120 s that `WarmWhisperDictationEngine` waits for a reply.
#
# Both sides of 768, measured on the F431 bench (synthetic 120 s clips, this model, development Mac
# — Apple M3 Pro, 18 GB): the densest chunk was 138 tokens for 32.7 s of speech, so 768 is over five
# times what speech needed; and that chunk decoded end to end at ~45 tok/s.
#
# F607: this cap is NOT what bounds the reply — it is a token count, and whether a token count fits
# a timeout depends on the decode rate. A dictation is at most 120 s
# (`DictationCaptureLimits.maximumDurationSeconds`); with every cut landing as early as 25 s that is
# five chunks decoded one after another, 5 x 768 = 3,840 tokens when every chunk is stuck: ~85 s at
# the ~45 tok/s above, but ~192 s at 20 tok/s — and Qwen dictation is offered on every Apple-silicon
# Mac, where no rate but the M3 Pro's has been measured. `DICTATION_DECODE_BUDGET_SECONDS` below is
# the bound, and it needs no rate; the cap stays as the per-chunk ceiling it was measured to be.
DICTATION_MAX_TOKENS = 768

# F607: the reply wait on the Swift side — `readLine(timeout: 120)` in
# `WarmWhisperDictationEngine.transcribe`, which `WarmQwenDictationEngine` shares through its
# runner. Mirrored, not imported, so `test_qwen_dictate_server.py` reads that literal from the
# Swift source and fails if the two drift apart.
REPLY_TIMEOUT_SECONDS = 120.0
# Wall-clock seconds a request may spend before its reply is sent with what was decoded so far. The
# deadline is set when the request line has been read, before the clip loads, so loading and
# splitting the clip are paid out of this budget, not out of the margin. The 20 s left of the reply
# wait covers what this clock cannot interrupt once the deadline passes: a chunk's audio encode and
# prefill that began just before its time ran out (they run on its first pull, before its first
# token), the one decode step in flight, and the join and emit. It also covers the moments between
# the Swift side starting its wait and this clock starting.
DICTATION_DECODE_BUDGET_SECONDS = REPLY_TIMEOUT_SECONDS - 20.0

# The clock the budget is measured on; a test replaces it with one that advances per decoded token.
monotonic = time.monotonic


def emit(payload: dict) -> None:
    print(json.dumps(payload, ensure_ascii=False), flush=True)


# The names this helper borrows from `qwen_transcribe.py` — `guarded_chunk_tokens` and
# `transcribe_audio` reach for all three. An older sibling left behind by a stale install is
# missing at least one of them, and the failure must name the file at startup rather than surface
# as an `AttributeError` inside the first dictation, after several seconds of model loading.
MEETING_HELPER_NAMES = ("greedy_decode_rows", "ASR_EOS_TOKEN_IDS", "joined_text")


def meeting_helper_path() -> str:
    """The path `meeting_helper()` loads — named separately so a startup check can cite it."""
    return os.path.join(os.path.dirname(os.path.abspath(__file__)), "qwen_transcribe.py")


def check_meeting_helper(module, path: str):
    """Refuse a sibling `qwen_transcribe.py` that does not expose `MEETING_HELPER_NAMES` (F431).

    Returns `module` unchanged when every name is present, so a caller can chain this onto
    `meeting_helper()` without a separate variable.
    """
    missing = [name for name in MEETING_HELPER_NAMES if not hasattr(module, name)]
    if missing:
        raise RuntimeError(
            f"{path} does not expose {', '.join(missing)} — this helper needs the "
            f"qwen_transcribe.py that ships beside it; reinstall with Scripts/setup-qwen-asr.sh."
        )
    return module


@functools.lru_cache(maxsize=None)
def meeting_helper():
    """`qwen_transcribe.py`, the meeting helper installed beside this one (F431).

    Loaded by path rather than imported by name, so it is the sibling file whichever way this
    helper was started — as a script from the runtime directory, or loaded by a test. Setup and the
    app's helper sync both place the two in `QwenASRRuntime.managedDirectory`.
    """
    path = meeting_helper_path()
    spec = importlib.util.spec_from_file_location("qwen_transcribe", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def load_clip(path):
    """The request's WAV as mlx-audio's own `generate` loads it (`qwen3_asr.py:1069-1075`)."""
    import mlx.core as mx
    import numpy as np
    from mlx_audio.stt.utils import load_audio

    audio = load_audio(path)
    return np.array(audio) if isinstance(audio, mx.array) else audio


def split_clip(audio, sample_rate):
    """The chunks mlx-audio's own `generate` would decode, cut the same way (`:1078-1083`)."""
    from mlx_audio.stt.models.qwen3_asr.qwen3_asr import split_audio_into_chunks

    return split_audio_into_chunks(
        audio,
        sr=sample_rate,
        chunk_duration=DICTATION_CHUNK_SECONDS,
        min_chunk_duration=0.1,
    )


def release_chunk_memory():
    """What `generate` does between chunks (`:1137-1138`)."""
    import mlx.core as mx

    mx.clear_cache()


class ChunkEnd:
    """How one chunk's decode ended, as far as it decides whether its text is a fragment (F762).

    `pulled` counts the tokens read from the library's stream; `deadline_hit` is set when the clock
    ended the read before the stream did. The F260 guard stopping a runaway sets neither: what it
    keeps is one copy of the cycle, not a fragment of the speech.
    """

    def __init__(self):
        self.pulled = 0
        self.deadline_hit = False

    def truncated(self, max_tokens):
        """True when the chunk was cut by its share of the deadline (F607) or ran to `max_tokens`
        (F431). The library's stream ends at EOS without yielding it, or at its own `max_tokens`
        (`qwen3_asr.py:956-968` in the pinned mlx-audio 0.3.1), so a stream that yielded the whole
        cap never reached EOS."""
        return self.deadline_hit or self.pulled >= max_tokens


def tokens_until(stream, stop_at, end=None):
    """`stream`'s tokens as ints, read only while `monotonic()` is before `stop_at` (F607).

    The clock is checked before each pull, so a chunk whose time is already spent never starts its
    audio encode and prefill; `None` reads the whole stream. `end`, a `ChunkEnd`, is told what was
    read and whether the clock stopped it (F762).
    """
    iterator = iter(stream)
    while stop_at is None or monotonic() < stop_at:
        try:
            token, _logprobs = next(iterator)
        except StopIteration:
            return
        if end is not None:
            end.pulled += 1
        yield int(token)
    if end is not None:
        end.deadline_hit = True


def guarded_chunk_tokens(stream, meeting, max_tokens=DICTATION_MAX_TOKENS, stop_at=None, end=None):
    """One chunk's tokens from mlx-audio's own greedy stream, with the meeting path's guard (F431).

    `stream` yields `(token, logprobs)` and ends at EOS or at its own `max_tokens`
    (`qwen3_asr.py:867-968`). It is fed to `greedy_decode_rows` — the loop every meeting decodes
    through — as a one-row batch, so the F260 cycle guard stops a runaway, F421 trims what it
    already emitted back to one copy, `max_tokens` caps anything the guard cannot see, and `stop_at`
    (F607) ends the chunk when its share of the reply's time is spent, at whatever rate this Mac
    decodes. The tokens themselves are exactly the ones `generate` would have produced up to that
    point: the stream is the library's, only the decision to stop reading it is added. `end`, a
    `ChunkEnd`, records whether the chunk was cut (F762).
    """
    tokens = tokens_until(stream, stop_at, end)
    end = meeting.ASR_EOS_TOKEN_IDS[0]  # a finished or timed-out stream reads as EOS
    first = next(tokens, end)
    rows = meeting.greedy_decode_rows(
        [first],
        lambda _previous: [next(tokens, end)],
        set(meeting.ASR_EOS_TOKEN_IDS),
        max_tokens,
    )
    return rows[0]


def transcribe_audio(model, audio, language, deadline=None, cut=None):
    """Decode a clip chunk by chunk through the guarded loop, joined as a meeting's chunks are.

    With a `deadline` (a `monotonic()` time), each chunk may run until an equal share of the time
    left: (deadline - now) / chunks still to decode (F607). A runaway chunk is cut at its share, so
    it cannot starve the speech after it, and time an early-finishing chunk leaves unused passes to
    the rest. A chunk cut this way contributes what it decoded — the same partial-output choice
    F431 made for the token cap — so the reply arrives before the Swift wait kills the helper and
    the model stays loaded. `cut`, a list, gets one entry per chunk that was cut that way or by the
    token cap, so the reply can say its text is a fragment (F762).
    """
    meeting = meeting_helper()
    chunks = list(split_clip(audio, model.sample_rate))
    texts = []
    for index, (chunk_audio, _offset) in enumerate(chunks):
        stop_at = None
        if deadline is not None:
            now = monotonic()
            stop_at = now + max(0.0, deadline - now) / (len(chunks) - index)
        # The call shape is the pinned mlx-audio 0.3.1 `Qwen3ASR.stream_generate(audio, *,
        # max_tokens, language, ...)` (`mlx_audio/stt/models/qwen3_asr/qwen3_asr.py:867-968`); the
        # deadline is enforced by what this helper reads, not by an argument the library lacks.
        stream = model.stream_generate(
            chunk_audio, max_tokens=DICTATION_MAX_TOKENS, language=language
        )
        end = ChunkEnd()
        try:
            tokens = guarded_chunk_tokens(stream, meeting, stop_at=stop_at, end=end)
        finally:
            # A guarded stop leaves the library's generator suspended mid-decode; close it now
            # rather than whenever it happens to be collected.
            stream.close()
        texts.append(model._tokenizer.decode(tokens, skip_special_tokens=True))
        if cut is not None and end.truncated(DICTATION_MAX_TOKENS):
            cut.append(index)
        release_chunk_memory()
    return meeting.joined_text(texts)


def transcribe_request(model, request: dict) -> dict:
    # Measured from here, once the request line has been read. The Swift side starts its wait right
    # after writing that line, so the two clocks start within moments of each other; the budget's
    # 20 s margin absorbs the difference.
    deadline = monotonic() + DICTATION_DECODE_BUDGET_SECONDS
    language = request.get("language") or "auto"
    cut = []
    text = transcribe_audio(model, load_clip(request["wavPath"]), language, deadline, cut).strip()
    detected_language = None if language == "auto" else language
    return {
        "text": text,
        "language": detected_language,
        "error": None,
        "noSpeechProb": None,
        # F762: a chunk cut by its share of the deadline or by the token cap leaves a fragment
        # that otherwise reads as a complete reply. Absent from older helpers; Swift reads absent
        # as false.
        "truncated": bool(cut),
    }


def prewarm(model) -> None:
    """Compile the inference path before Swift is told the model is ready.

    Runs the request path itself on a one-second clip, so what it compiles is exactly what the
    first dictation uses.
    """
    descriptor, path = tempfile.mkstemp(prefix="whispermeet-qwen-warmup-", suffix=".wav")
    os.close(descriptor)
    try:
        with wave.open(path, "wb") as audio:
            audio.setnchannels(1)
            audio.setsampwidth(2)
            audio.setframerate(16_000)
            audio.writeframes(b"\0\0" * 16_000)
        transcribe_request(model, {"wavPath": path, "language": None})
    finally:
        try:
            os.unlink(path)
        except FileNotFoundError:
            pass


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True)
    arguments = parser.parse_args()

    check_meeting_helper(meeting_helper(), meeting_helper_path())

    from mlx_audio.stt.utils import load_model

    model = load_model(arguments.model)
    prewarm(model)
    emit({"ready": True})

    for line in sys.stdin:
        try:
            request = json.loads(line)
            emit(transcribe_request(model, request))
        except Exception as error:  # noqa: BLE001
            emit({"error": f"{type(error).__name__}: {error}"})
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
