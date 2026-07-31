#!/usr/bin/env python3
"""One-shot local Qwen3-ASR transcription with safe, bounded forced alignment."""

import argparse
import gc
import json
import os
import sys


SAMPLE_RATE = 16_000
ALIGNMENT_CHUNK_SECONDS = 240.0


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True)
    parser.add_argument("--aligner", required=True)
    parser.add_argument("--audio", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--language", default="auto")
    return parser.parse_args()


def alignment_language(text: str, requested: str) -> str:
    if requested in {"English", "Chinese"}:
        return requested
    return "Chinese" if any("\u3400" <= char <= "\u9fff" for char in text) else "English"


def detected_language_code(text: str) -> str:
    """Top-level en/zh label for the whole transcript.

    Unlike the per-chunk aligner heuristic (`alignment_language`, which flags any CJK), require CJK
    to be the MAJORITY of non-whitespace characters. Otherwise a mostly-English meeting that mentions
    one Chinese name or term (e.g. "meet in \u5317\u4eac") is mislabeled `zh`, disagreeing with Whisper on the
    same audio and biasing the summary language (F41).
    """
    cjk = 0
    total = 0
    for char in text:
        if char.isspace():
            continue
        total += 1
        if "\u3400" <= char <= "\u9fff":
            cjk += 1
    if total == 0:
        return "en"
    return "zh" if cjk * 2 > total else "en"


def build_chunks(segments):
    """Extract ASR segments defensively. On any schema drift (a changed mlx_audio segment shape),
    degrade to no chunks plus a warning so the complete `text` is still written, mirroring how
    `align_chunks` already preserves text. Without this, a `KeyError`/`AttributeError` here would
    exit the process non-zero and discard a transcript that was actually produced (F51).
    """
    try:
        return [
            {
                "text": segment["text"].strip(),
                "start": float(segment["start"]),
                "end": float(segment["end"]),
            }
            for segment in segments
            if segment["text"].strip()
        ], None
    except Exception as error:
        warning = f"{type(error).__name__}: {error}"
        print(
            f"Qwen segment parsing failed; preserving complete ASR text. {warning}",
            file=sys.stderr,
        )
        return [], warning


def align_chunks(load_aligner, aligner_path: str, audio, chunks: list[dict], requested: str):
    aligned_items = []
    try:
        aligner = load_aligner(aligner_path)
        for chunk in chunks:
            start_sample = max(0, int(chunk["start"] * SAMPLE_RATE))
            end_sample = min(len(audio), int(chunk["end"] * SAMPLE_RATE))
            if end_sample <= start_sample:
                continue
            language = alignment_language(chunk["text"], requested)
            alignment = aligner.generate(
                audio[start_sample:end_sample],
                text=chunk["text"],
                language=language,
            )
            aligned_items.extend(
                {
                    "text": item.text,
                    "start": round(chunk["start"] + item.start_time, 3),
                    "end": round(chunk["start"] + item.end_time, 3),
                }
                for item in alignment.items
            )
        return aligned_items, None
    except Exception as error:
        warning = f"{type(error).__name__}: {error}"
        print(
            f"Qwen timestamp alignment was unavailable; preserving complete ASR text. {warning}",
            file=sys.stderr,
        )
        return [], warning


def main() -> int:
    import mlx.core as mx
    import numpy as np
    from mlx_audio.stt.utils import load_audio, load_model

    args = parse_args()
    audio = np.asarray(load_audio(args.audio))

    asr = load_model(args.model)
    transcription = asr.generate(
        audio,
        language=args.language,
        chunk_duration=ALIGNMENT_CHUNK_SECONDS,
        min_chunk_duration=0.1,
    )
    text = transcription.text.strip()
    if not text:
        raise RuntimeError("Qwen3-ASR returned an empty transcript.")
    chunks, chunk_warning = build_chunks(transcription.segments)

    del transcription
    del asr
    gc.collect()
    mx.clear_cache()

    aligned_items, alignment_warning = align_chunks(
        load_model,
        args.aligner,
        audio,
        chunks,
        args.language,
    )

    language_code = None
    if args.language == "English":
        language_code = "en"
    elif args.language == "Chinese":
        language_code = "zh"
    elif args.language == "auto":
        language_code = detected_language_code(text)

    payload = {
        "text": text,
        "language": language_code,
        "alignedItems": aligned_items,
        "alignmentWarning": alignment_warning or chunk_warning,
    }
    temporary_output = f"{args.output}.tmp"
    with open(temporary_output, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, ensure_ascii=False)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary_output, args.output)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
