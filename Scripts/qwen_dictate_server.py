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
import wave


# The chunk length this helper has always asked mlx-audio for: a longer clip is split at the
# quietest point within ±5 s of each 30 s mark (`split_audio_into_chunks`) and decoded chunk by
# chunk.
DICTATION_CHUNK_SECONDS = 30.0
# F431: tokens one chunk may decode before it is cut off. mlx-audio's own default is 8192, which a
# decoder stuck in a cycle longer than the F260 guard's window (`ASR_MAX_CYCLE_LEN` tokens) runs all
# the way to: ~139 s per chunk at F213's measured single-row 59 tok/s, past the 120 s that
# `WarmWhisperDictationEngine` waits for a reply. A dictation is at most 120 s
# (`BoundedAudioSampleBuffer.maximumDurationSeconds`); with every cut landing as early as 25 s that
# is five chunks, decoded one after another, so the cap is what bounds the worst reply.
#
# Both sides of 768, measured on the F431 bench (synthetic 120 s clips, this model): the densest
# chunk was 138 tokens for 32.7 s of speech, so 768 is over five times what speech needed; and that
# chunk decoded end to end at ~45 tok/s, at which five chunks each stuck at 768 tokens take ~85 s,
# inside the timeout. 1024 would have left ~113 s at that rate — too close to 120 to call a bound.
DICTATION_MAX_TOKENS = 768


def emit(payload: dict) -> None:
    print(json.dumps(payload, ensure_ascii=False), flush=True)


@functools.lru_cache(maxsize=None)
def meeting_helper():
    """`qwen_transcribe.py`, the meeting helper installed beside this one (F431).

    Loaded by path rather than imported by name, so it is the sibling file whichever way this
    helper was started — as a script from the runtime directory, or loaded by a test. Setup and the
    app's helper sync both place the two in `QwenASRRuntime.managedDirectory`.
    """
    path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "qwen_transcribe.py")
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


def guarded_chunk_tokens(stream, meeting, max_tokens=DICTATION_MAX_TOKENS):
    """One chunk's tokens from mlx-audio's own greedy stream, with the meeting path's guard (F431).

    `stream` yields `(token, logprobs)` and ends at EOS or at its own `max_tokens`
    (`qwen3_asr.py:867-968`). It is fed to `greedy_decode_rows` — the loop every meeting decodes
    through — as a one-row batch, so the F260 cycle guard stops a runaway, F421 trims what it
    already emitted back to one copy, and `max_tokens` bounds anything the guard cannot see. The
    tokens themselves are exactly the ones `generate` would have produced up to that point: the
    stream is the library's, only the decision to stop reading it is added.
    """
    tokens = (int(token) for token, _logprobs in stream)
    end = meeting.ASR_EOS_TOKEN_IDS[0]  # a finished stream reads as EOS, which it was
    first = next(tokens, end)
    rows = meeting.greedy_decode_rows(
        [first],
        lambda _previous: [next(tokens, end)],
        set(meeting.ASR_EOS_TOKEN_IDS),
        max_tokens,
    )
    return rows[0]


def transcribe_audio(model, audio, language):
    """Decode a clip chunk by chunk through the guarded loop, joined as a meeting's chunks are."""
    meeting = meeting_helper()
    texts = []
    for chunk_audio, _offset in split_clip(audio, model.sample_rate):
        stream = model.stream_generate(
            chunk_audio, max_tokens=DICTATION_MAX_TOKENS, language=language
        )
        try:
            tokens = guarded_chunk_tokens(stream, meeting)
        finally:
            # A guarded stop leaves the library's generator suspended mid-decode; close it now
            # rather than whenever it happens to be collected.
            stream.close()
        texts.append(model._tokenizer.decode(tokens, skip_special_tokens=True))
        release_chunk_memory()
    return meeting.joined_text(texts)


def transcribe_request(model, request: dict) -> dict:
    language = request.get("language") or "auto"
    text = transcribe_audio(model, load_clip(request["wavPath"]), language).strip()
    detected_language = None if language == "auto" else language
    return {
        "text": text,
        "language": detected_language,
        "error": None,
        "noSpeechProb": None,
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
