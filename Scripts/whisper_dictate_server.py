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


# F210: the temperature-fallback ladder `mlx_whisper.transcribe` applies, replicated so the
# single-window path below behaves identically. Read from the installed 0.4.3
# (`transcribe.py:67-70`, `:207-245`) rather than assumed; pinned by
# `test_whisper_dictate_server.py` so a runtime upgrade that changes them fails a test.
FALLBACK_TEMPERATURES = (0.0, 0.2, 0.4, 0.6, 0.8, 1.0)
COMPRESSION_RATIO_THRESHOLD = 2.4
LOGPROB_THRESHOLD = -1.0
NO_SPEECH_THRESHOLD = 0.6


def needs_temperature_fallback(compression_ratio, avg_logprob, no_speech_prob) -> bool:
    """Whether to retry at a higher temperature — `transcribe.py:226-241`, in order.

    The `no_speech` clause comes LAST and sets the flag back to False, so a silent window is
    accepted rather than retried six times. Order is load-bearing and the reason this is a
    function: written as a single boolean expression it reads as an `and`, which it is not.
    """
    needs = False
    if compression_ratio > COMPRESSION_RATIO_THRESHOLD:
        needs = True                     # too repetitive
    if avg_logprob < LOGPROB_THRESHOLD:
        needs = True                     # average log probability too low
    if no_speech_prob > NO_SPEECH_THRESHOLD:
        needs = False                    # silence
    return needs


def skips_window_as_silence(no_speech_prob, avg_logprob) -> bool:
    """Whether `transcribe` drops this window's text as no speech — `transcribe.py:301-315` (F449).

    Runs AFTER the ladder, on the result the ladder settled on. A window is skipped when
    `no_speech_prob > NO_SPEECH_THRESHOLD`, unless `avg_logprob > LOGPROB_THRESHOLD` says the decode
    was confident anyway; both comparisons are strict, as upstream's are. A clip whose only window
    is skipped comes back from `transcribe` as empty text, which the app shows as "Didn't catch
    that" instead of pasting anything. F210's single-window path replicated the ladder and not
    this check, so for any window the rule skips it returned the decoder's guess instead of "".

    What this restores is parity, not a silence detector. Measured against the installed
    large-v3-turbo on seventeen synthetic silence and noise clips (the F449 log entry), that model
    reported a no_speech_prob of 0.000000 on every one, so the rule — upstream's as much as this
    copy — skipped none of them and both paths returned "Thank you." for digital silence.
    """
    should_skip = no_speech_prob > NO_SPEECH_THRESHOLD
    if avg_logprob > LOGPROB_THRESHOLD:
        should_skip = False
    return should_skip


def transcribe_single_window(mlx_whisper, mlx, audio, mlx_repo, language, initial_prompt):
    """One encoder pass, shared by language ID and every decode attempt (F210).

    With `language=None` — the app's default, so this is every Automatic dictation —
    `mlx_whisper.transcribe` computes the mel once and then calls
    `model.detect_language(mel_segment)` (`transcribe.py:173`), whose encoder pass is thrown away
    before the decode loop encodes the same segment again. **Measured on this Mac against the
    installed 0.4.3:** 1303 ms for `transcribe(language=None)` against 678 ms for
    `transcribe(language="en")`, with `detect_language` alone accounting for 623 ms. Roughly half
    the warm request time for a typical 3-second clip.

    The saving comes from `DecodingTask._get_audio_features` (`decoding.py:537-548`), which skips
    the encoder when handed something already shaped `(n_audio_ctx, n_audio_state)`. So the encoder
    runs once here and `model.decode` reuses its output — for the language ID it performs
    internally (`decoding.py:630`), and for each temperature in the ladder.

    **Returns None rather than raising for anything it cannot handle**, so the caller falls back to
    `transcribe`. Same principle as the raw-frames audio fast path below it: a fast path that cannot
    be taken must never fail a dictation.

    Single-window only. Dictation clips are seconds long, but a longer clip needs `transcribe`'s
    seek loop, conditioning between windows and segment assembly, none of which is replicated here.
    """
    try:
        from mlx_whisper.audio import (
            N_FRAMES,
            N_SAMPLES,
            log_mel_spectrogram,
            pad_or_trim,
        )
        from mlx_whisper.decoding import DecodingOptions
        from mlx_whisper.transcribe import ModelHolder
    except Exception:
        return None

    try:
        model = ModelHolder.get_model(mlx_repo, mlx.float16)
        if language is None and not model.is_multilingual:
            # `transcribe.py:164-165` forces English for a non-multilingual model instead of
            # detecting. Nothing here would be wrong, but there is no pass to save either.
            language = "en"

        mel = log_mel_spectrogram(audio, n_mels=model.dims.n_mels, padding=N_SAMPLES)
        content_frames = mel.shape[-2] - N_FRAMES
        if content_frames <= 0 or content_frames > N_FRAMES:
            return None

        # EXACTLY `transcribe.py`'s slice (`:264-267`): the content frames, then zero-padded to a
        # full window. NOT `pad_or_trim(mel, N_FRAMES)`, which keeps the appended silence that
        # `padding=N_SAMPLES` added and decodes to different text — verified, and it is what made
        # the first version of this change produce "会议记要" where transcribe produces "会议纪要".
        # `transcribe`'s own language detection at `:172` uses that other segment, which is an
        # inconsistency upstream rather than here; detecting from the decode segment is what makes
        # one pass possible, and it agreed with transcribe on all ten bench clips.
        segment = mel[0:min(N_FRAMES, content_frames)]
        segment = pad_or_trim(segment, N_FRAMES, axis=-2).astype(mlx.float16)
        features = model.encoder(segment[None])

        result = None
        for temperature in FALLBACK_TEMPERATURES:
            decoded = model.decode(
                features,
                DecodingOptions(
                    task="transcribe",          # never translate
                    language=language,          # None means detect, for free, from `features`
                    temperature=temperature,
                    # A string, which `_get_initial_tokens` encodes as
                    # `tokenizer.encode(" " + prompt.strip())` (`decoding.py:494-498`) — byte for
                    # byte what `transcribe.py:258` does with `initial_prompt`.
                    prompt=initial_prompt,
                    fp16=True,
                ),
            )
            result = decoded[0] if isinstance(decoded, list) else decoded
            if not needs_temperature_fallback(
                result.compression_ratio, result.avg_logprob, result.no_speech_prob
            ):
                break
        if result is None:
            return None
        text = result.text.strip()
        if skips_window_as_silence(result.no_speech_prob, result.avg_logprob):
            # F449: what `transcribe` returns for a clip whose one window it skipped. The language
            # and the score are still reported — the score is the reason the text is empty.
            text = ""
        return {
            "text": text,
            "language": result.language,
            "noSpeechProb": result.no_speech_prob,
        }
    except Exception:
        return None


def prewarm(transcribe, audio, mlx_repo: str) -> None:
    """One throwaway decode so the model and its Metal kernels are resident before readiness.

    `temperature=0.0` is load-bearing. Whisper's default is a six-temperature fallback ladder that
    re-decodes the clip whenever the result trips its compression-ratio / logprob thresholds — which
    pure digital silence always does — so the default paid five extra full decodes for a transcript
    that is discarded. Measured on the installed runtime with the model already resident:
    2631 ms default vs 1276 ms greedy, i.e. ~1.35 s off every helper start.

    This is still the exact request code path (same task, same model), so it loads the model into
    mlx_whisper's ModelHolder cache and compiles the kernels a real request will use. Only the
    fallback ladder — which no request reaches unless its own decode is poor — is skipped.

    verbose MUST be None, not False. Whisper documents False as "minimal details", and the code
    guards its prints with `if verbose is not None` — so False still writes "Detected language: X"
    to STDOUT, which is this protocol's wire. Only None is silent.
    """
    transcribe(
        audio,
        path_or_hf_repo=mlx_repo,
        task="transcribe",
        temperature=0.0,
        verbose=None,
    )


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
        prewarm(
            mlx_whisper.transcribe,
            mx.zeros(1600, dtype=mx.float32),  # 0.1s of silence at 16 kHz
            args.mlx_repo,
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
            # F210: one encoder pass instead of two on the Automatic path, which is the default
            # and therefore every dictation. Returns None for anything it will not handle — a long
            # clip, a runtime whose internals moved — and the full `transcribe` below then runs
            # exactly as before.
            response = transcribe_single_window(
                mlx_whisper,
                mx,
                audio,
                args.mlx_repo,
                request.get("language"),
                request.get("initialPrompt"),
            )
            if response is None:
                result = mlx_whisper.transcribe(
                    audio,
                    path_or_hf_repo=args.mlx_repo,
                    task="transcribe",  # never translate
                    language=request.get("language"),
                    initial_prompt=request.get("initialPrompt"),
                    verbose=None,  # see the warm-up call: False is NOT silent, it prints to stdout
                )
                # Report the lowest per-segment no_speech_prob (the most speech-like segment). The
                # app uses it to tell a real dictation from a silence-driven prompt echo; taking the
                # min biases toward keeping — a clip is only "silence" if EVERY segment looks like
                # silence. The single-window path has exactly one window, so its own
                # `no_speech_prob` is already that minimum.
                segments = result.get("segments") or []
                probs = [
                    s.get("no_speech_prob")
                    for s in segments
                    if s.get("no_speech_prob") is not None
                ]
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
