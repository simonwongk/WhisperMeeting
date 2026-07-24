# Scripts/whisper_dictate_server.py
"""Resident MLX-Whisper helper for WhisperMeet quick dictation.

Loads an Apple-Silicon MLX Whisper model once, then serves newline-delimited JSON
requests on stdin and writes newline-delimited JSON responses on stdout. Local-only;
no network at request time (model weights are cached under the app's support dir).
Exits cleanly when stdin closes (the app terminates it to evict the model).

Meetings still use openai/whisper via LocalWhisperClient; this MLX path is dictation-only.
"""
import argparse
import json
import os
import sys


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--mlx-repo", default="mlx-community/whisper-large-v3-turbo")
    parser.add_argument("--model-dir", required=True)
    # Legacy openai-whisper arg: accepted but ignored so older callers don't crash.
    parser.add_argument("--model", default=None)
    args = parser.parse_args()

    # Cache MLX/HF model weights under the app's local support dir (stays 100% local).
    # Must be set BEFORE importing mlx_whisper / huggingface_hub.
    hf_home = os.path.join(args.model_dir, "hf")
    os.makedirs(hf_home, exist_ok=True)
    os.environ["HF_HOME"] = hf_home

    # Once the model is cached locally, forbid ALL network access — huggingface_hub otherwise
    # issues a metadata/HEAD request to huggingface.co on every start even when fully cached.
    # The meeting path never phones home once its model exists; match that. On the very first
    # run the model isn't cached yet, so we allow that one-time download, after which every
    # subsequent start is fully offline (and works air-gapped).
    repo_cache = os.path.join(hf_home, "hub", "models--" + args.mlx_repo.replace("/", "--"))
    if os.path.isdir(repo_cache):
        os.environ["HF_HUB_OFFLINE"] = "1"

    import mlx.core as mx
    import mlx_whisper  # imported after arg parse so --help is instant

    # Pre-warm: run one throwaway transcribe on a short silent buffer. This is the exact
    # request code path, so it loads the model into mlx_whisper's ModelHolder cache (fp16
    # by default, matching real requests) and compiles the MLX kernels. Only after this
    # returns is {"ready": true} genuinely resident.
    try:
        mlx_whisper.transcribe(
            mx.zeros(1600, dtype=mx.float32),  # 0.1s of silence at 16 kHz
            path_or_hf_repo=args.mlx_repo,
            task="transcribe",
        )
    except Exception as error:  # pragma: no cover - warm failure is fatal to the helper
        sys.stdout.write(json.dumps({"error": "warm-up failed: " + str(error)}) + "\n")
        sys.stdout.flush()
        return 1

    # Signal readiness only after the model is resident.
    sys.stdout.write(json.dumps({"ready": True}) + "\n")
    sys.stdout.flush()

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            request = json.loads(line)
            result = mlx_whisper.transcribe(
                request["wavPath"],
                path_or_hf_repo=args.mlx_repo,
                task="transcribe",  # never translate
                language=request.get("language"),
                initial_prompt=request.get("initialPrompt"),
            )
            # Report the lowest per-segment no_speech_prob (the most speech-like segment). The app
            # uses it to tell a real dictation from a silence-driven prompt echo; taking the min
            # biases toward keeping — a clip is only "silence" if EVERY segment looks like silence.
            segments = result.get("segments") or []
            probs = [s.get("no_speech_prob") for s in segments if s.get("no_speech_prob") is not None]
            response = {
                "text": result.get("text", "").strip(),
                "language": result.get("language"),
                "noSpeechProb": min(probs) if probs else None,
            }
        except Exception as error:  # never crash the daemon on one bad request
            response = {"error": str(error)}
        sys.stdout.write(json.dumps(response) + "\n")
        sys.stdout.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main())
