#!/usr/bin/env python3
"""Persistent JSON-lines helper for benchmarking MLX Qwen3-ASR.

The model is loaded exactly once. Requests and responses are one JSON object per
line so benchmark timings measure warm transcription rather than repeated model
startup. This helper only reads audio paths supplied by the benchmark.
"""

import json
import sys
import time

from mlx_audio.stt.utils import load_model


def emit(payload: dict) -> None:
    print(json.dumps(payload, ensure_ascii=False), flush=True)


def main() -> int:
    if len(sys.argv) != 2:
        print("usage: qwen_server.py MODEL_PATH", file=sys.stderr)
        return 2

    model = load_model(sys.argv[1])
    emit({"ready": True})

    for line in sys.stdin:
        try:
            request = json.loads(line)
            started = time.perf_counter()
            result = model.generate(
                request["audio"],
                language=request["language"],
                chunk_duration=30.0,
                min_chunk_duration=0.1,
            )
            emit(
                {
                    "text": result.text.strip(),
                    "segments": result.segments,
                    "seconds": time.perf_counter() - started,
                }
            )
        except Exception as error:  # noqa: BLE001
            emit({"error": f"{type(error).__name__}: {error}"})

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
