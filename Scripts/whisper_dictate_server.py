# Scripts/whisper_dictate_server.py
"""Resident MLX-Whisper helper for WhisperMeet quick dictation.

Loads an Apple-Silicon MLX Whisper model once, then serves newline-delimited JSON
requests on stdin and writes newline-delimited JSON responses on stdout. Local-only;
no network at request time (model weights are cached under the app's support dir).
Exits cleanly when stdin closes (the app terminates it to evict the model).

Meetings still use openai/whisper via LocalWhisperClient; this MLX path is dictation-only.
"""
import argparse
import contextlib
import json
import os
import shutil
import sys
import wave


def model_fully_cached(hub_dir: str, mlx_repo: str) -> bool:
    """Whether the MLX model's required files are actually present in the local HF cache.

    huggingface_hub creates the `models--org--repo` directory tree at the START of a download
    (before any weights finish), so directory existence does NOT mean the model is usable. We
    check that the files mlx_whisper needs — config.json and weights.safetensors — resolve to
    real cached paths. `try_to_load_from_cache` returns a str path on a hit, and None or a
    sentinel object otherwise, so a plain isinstance(str) check is decisive.
    """
    from huggingface_hub import try_to_load_from_cache
    for filename in ("config.json", "weights.safetensors"):
        if not isinstance(try_to_load_from_cache(mlx_repo, filename, cache_dir=hub_dir), str):
            return False
    return True


# WhisperMeet's capture format, from DictationCaptureLimits.sampleRate / WAVWriter: 16-bit PCM,
# mono, 16 kHz. Kept as a named constant so the fast path below and the app stay tied together.
DICTATION_SAMPLE_RATE = 16_000


def conforming_pcm16_frames(path: str, sample_rate: int = DICTATION_SAMPLE_RATE):
    """Raw little-endian int16 frames when `path` is ALREADY mono/16-bit/`sample_rate` PCM, else None.

    `mlx_whisper.load_audio` forks an `ffmpeg` process per request to down-mix and resample
    (site-packages/mlx_whisper/audio.py:41-59) — 27.6 ms median for a 3.1 s clip on an M-series Mac.
    Quick Dictation's own recorder writes exactly the target format, so that work is pure overhead
    on every single dictation. Returning None (never raising) keeps this a strict fast path: any
    clip that is not already conforming — an imported file, a future format change, a truncated
    write — falls through to the real decoder, which also owns the error message for a bad clip.
    """
    try:
        with contextlib.closing(wave.open(path, "rb")) as handle:
            if (
                handle.getnchannels(),
                handle.getsampwidth(),
                handle.getframerate(),
            ) != (1, 2, sample_rate):
                return None
            return handle.readframes(handle.getnframes())
    except Exception:
        return None


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
    hub_dir = os.path.join(hf_home, "hub")
    repo_cache = os.path.join(hub_dir, "models--" + args.mlx_repo.replace("/", "--"))
    if os.path.isdir(repo_cache):
        if model_fully_cached(hub_dir, args.mlx_repo):
            os.environ["HF_HUB_OFFLINE"] = "1"
        else:
            # The cache dir exists but its snapshot is incomplete — a download that was
            # interrupted (watchdog kill, quit/disable mid-download, network drop, sleep,
            # disk-full). Forcing HF_HUB_OFFLINE here would wedge dictation permanently, since
            # offline mode blocks the very HTTP the partial cache needs to repair itself. Wipe
            # the partial cache so THIS run re-downloads cleanly with network allowed.
            shutil.rmtree(repo_cache, ignore_errors=True)

    import mlx.core as mx
    import mlx_whisper  # imported after arg parse so --help is instant
    # numpy is a hard dependency of mlx_whisper in the installed runtime, but importing it
    # unconditionally would make this helper unstartable wherever it is absent. It powers only an
    # optional fast path, so treat it as optional: without it every clip takes the normal decoder.
    try:
        import numpy as np
    except Exception:  # pragma: no cover - exercised by the no-numpy helper protocol test
        np = None

    # Pre-warm: run one throwaway transcribe on a short silent buffer. This is the exact
    # request code path, so it loads the model into mlx_whisper's ModelHolder cache (fp16
    # by default, matching real requests) and compiles the MLX kernels. Only after this
    # returns is {"ready": true} genuinely resident.
    #
    # verbose MUST be None, not False. Whisper documents False as "minimal details", and the
    # code guards its prints with `if verbose is not None` — so False still writes
    # "Detected language: X" to STDOUT, which is this protocol's wire. Only None is silent.
    try:
        mlx_whisper.transcribe(
            mx.zeros(1600, dtype=mx.float32),  # 0.1s of silence at 16 kHz
            path_or_hf_repo=args.mlx_repo,
            task="transcribe",
            verbose=None,
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
            # Hand the model samples directly when the clip is already in its target format,
            # skipping load_audio's per-request ffmpeg fork. The conversion mirrors load_audio's
            # own line exactly (int16 -> float32 / 32768.0), so samples stay byte-identical.
            wav_path = request["wavPath"]
            audio = wav_path
            frames = conforming_pcm16_frames(wav_path) if np is not None else None
            if frames:
                try:
                    audio = (
                        mx.array(np.frombuffer(frames, np.int16))
                        .flatten()
                        .astype(mx.float32) / 32768.0
                    )
                except Exception:
                    # A fast path that cannot be taken must never fail a dictation: fall back to
                    # the decoder, which is also the one that owns errors for an unreadable clip.
                    audio = wav_path
            result = mlx_whisper.transcribe(
                audio,
                path_or_hf_repo=args.mlx_repo,
                task="transcribe",  # never translate
                language=request.get("language"),
                initial_prompt=request.get("initialPrompt"),
                verbose=None,  # see the warm-up call: False is NOT silent, it prints to stdout
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
