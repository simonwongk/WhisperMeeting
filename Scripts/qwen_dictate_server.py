#!/usr/bin/env python3
"""Persistent JSON-lines helper for Qwen3-ASR Quick Dictation.

The Swift recorder supplies the same temporary WAV used by every dictation engine.
This process keeps Qwen resident between clips and returns the existing dictation
wire format. The local Qwen API has no vocabulary-prompt parameter, so
``initialPrompt`` is deliberately ignored.
"""

import argparse
import json
import os
import sys
import tempfile
import wave


def emit(payload: dict) -> None:
    print(json.dumps(payload, ensure_ascii=False), flush=True)


def transcribe_request(model, request: dict) -> dict:
    language = request.get("language") or "auto"
    result = model.generate(
        request["wavPath"],
        language=language,
        chunk_duration=30.0,
        min_chunk_duration=0.1,
    )
    text = result.text.strip()
    detected_language = None if language == "auto" else language
    return {
        "text": text,
        "language": detected_language,
        "error": None,
        "noSpeechProb": None,
    }


def prewarm(model) -> None:
    """Compile the inference path before Swift is told the model is ready."""
    descriptor, path = tempfile.mkstemp(prefix="whispermeet-qwen-warmup-", suffix=".wav")
    os.close(descriptor)
    try:
        with wave.open(path, "wb") as audio:
            audio.setnchannels(1)
            audio.setsampwidth(2)
            audio.setframerate(16_000)
            audio.writeframes(b"\0\0" * 16_000)
        model.generate(
            path,
            language="auto",
            chunk_duration=30.0,
            min_chunk_duration=0.1,
        )
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
