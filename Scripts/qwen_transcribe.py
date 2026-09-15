#!/usr/bin/env python3
"""One-shot local Qwen3-ASR transcription with safe, bounded forced alignment."""

import argparse
import gc
import json
import os
import sys
from types import SimpleNamespace


SAMPLE_RATE = 16_000
# F213: 60 s chunks, four decoded at once. The decoder is memory-bandwidth bound, so a batch of
# four costs about the same weight traffic per step as one chunk (59 -> 142 tok/s measured), and
# four 60 s chunks peak at the same ~5.2 GB as one 240 s chunk did. On a 261 s ground-truth clip
# the ASR pass went 20.0 s -> 10.7 s with English WER 2.5 % -> 1.9 % and Mandarin CER 9.2 % -> 4.9 %
# (the shorter chunks also keep a language switch out of a single chunk).
ASR_CHUNK_SECONDS = 60.0
ASR_BATCH_SIZE = 4
ASR_MAX_TOKENS = 8192
# Qwen3 end-of-turn / end-of-text ids, as mlx-audio's own `stream_generate` stops on them.
ASR_EOS_TOKEN_IDS = (151645, 151643)
# F240: set to "0" to restore mlx-audio's stock materialized attention mask. The fast path is a
# monkey-patch on a pinned library, so a field regression should be a restart, not a rebuild.
FAST_ATTENTION_ENV = "WHISPERMEET_QWEN_FAST_ATTENTION"


def fast_attention_enabled(environ=None):
    """Whether the F240 fused-mask patch should be installed (default on)."""
    return (os.environ if environ is None else environ).get(FAST_ATTENTION_ENV, "1") != "0"


class _FusedAttentionMask:
    """Defers the mask decision to the call site's `.astype(dtype)` (F240).

    `TextAttention.__call__` does `create_additive_causal_mask(L, offset).astype(queries.dtype)` and
    hands the result to `mx.fast.scaled_dot_product_attention`. That kernel also accepts `None` and
    the string `"causal"`, which take a fused path instead of reading an explicit array — but the
    `.astype` call in between means a patched function cannot simply return a string. This stands in
    for the array and resolves at `.astype` time.

    Patching the mask builder rather than copying `TextAttention.__call__` keeps the change to the
    one thing that is actually wrong. It also fails loudly — with `AttributeError` — if a future
    mlx-audio changes the call site, instead of silently diverging from an upstream edit.
    """

    __slots__ = ("_resolve",)

    def __init__(self, resolve):
        self._resolve = resolve

    def astype(self, dtype):
        return self._resolve(dtype)


def install_fused_attention_mask(module):
    """Replace the materialized additive causal mask with the fused kernel's own (F240).

    Two cases are provably equivalent to the array the stock builder returns, and they are the only
    two this app reaches:

    - `N == 1` (every decode step): `linds` is `[offset]` and `rinds` is `arange(offset + 1)`, so
      `offset < j` is False for every `j <= offset` — the row is all zeros, i.e. no mask at all.
    - `offset == 0` (every prefill, and the forced aligner, which runs with `cache=None`): `linds`
      and `rinds` are both `arange(N)`, which is exactly a causal mask.

    Any other shape keeps the stock array, so this narrows behaviour nowhere. Returns True when the
    patch was installed, False when it was already present or disabled.
    """
    if not fast_attention_enabled() or getattr(module, "_whispermeet_fused_mask", False):
        return False
    original = module.create_additive_causal_mask

    def fused_causal_mask(N: int, offset: int = 0):
        if N == 1:
            return _FusedAttentionMask(lambda _dtype: None)
        if offset == 0:
            return _FusedAttentionMask(lambda _dtype: "causal")
        stock = original(N, offset=offset)
        return _FusedAttentionMask(stock.astype)

    module.create_additive_causal_mask = fused_causal_mask
    module._whispermeet_fused_mask = True
    return True


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True)
    parser.add_argument("--aligner", required=True)
    parser.add_argument("--audio", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--language", default="auto")
    return parser.parse_args()


def _cjk_is_majority(text: str) -> bool:
    """True when CJK ideographs are the strict majority of the non-whitespace characters.

    Shared by the whole-transcript label (`detected_language_code`) and the per-chunk forced-aligner
    language (`alignment_language`) so both decide by majority script instead of flagging on any single
    CJK scalar (F41, F155). Ties and empty text are not Chinese.
    """
    cjk = 0
    total = 0
    for char in text:
        if char.isspace():
            continue
        total += 1
        if "\u3400" <= char <= "\u9fff":
            cjk += 1
    return total > 0 and cjk * 2 > total


def alignment_language(text: str, requested: str) -> str:
    """Language handed to the forced aligner for a single chunk's text.

    Honor an explicit request; otherwise choose by the MAJORITY script (F155). The prior rule flagged
    any CJK scalar as Chinese, so an English-dominant chunk that mentions one Chinese name or term was
    aligned with the Chinese model and got worse word timings.
    """
    if requested in {"English", "Chinese"}:
        return requested
    return "Chinese" if _cjk_is_majority(text) else "English"


def detected_language_code(text: str) -> str:
    """Top-level en/zh label for the whole transcript.

    Require CJK to be the MAJORITY of non-whitespace characters. Otherwise a mostly-English meeting
    that mentions one Chinese name or term (e.g. "meet in \u5317\u4eac") is mislabeled `zh`, disagreeing with
    Whisper on the same audio and biasing the summary language (F41). The per-chunk aligner
    (`alignment_language`) now shares this same majority rule (F155).
    """
    return "zh" if _cjk_is_majority(text) else "en"


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


def plan_batches(chunk_count: int, batch_size: int) -> list[list[int]]:
    """Which chunks decode together (F213).

    The splitter cuts every chunk but the last at a low-energy point within ±5 s of the target, so
    those are all full length and batch `batch_size` at a time, padded to the longest in their
    batch. The last chunk is usually short and always decodes alone and unpadded: padding a short
    tail with tens of seconds of silence measurably changed its transcript, while ≤10 s on full
    chunks did not.
    """
    if chunk_count <= 0:
        return []
    full = list(range(chunk_count - 1))
    batches = [full[i:i + batch_size] for i in range(0, len(full), max(batch_size, 1))]
    batches.append([chunk_count - 1])
    return batches


def greedy_decode_rows(first, step, eos_ids, max_tokens):
    """Batched greedy decoding bookkeeping (F213; row eviction added by F240).

    `first` is the argmax after the prefill for each row; `step(tokens)` feeds one token per row
    and returns the next argmax per row.

    If `step` exposes a `filter(keep)` callable, a row that reaches its EOS is EVICTED from the
    batch: `filter` receives the positions — indices into the current, possibly already-narrowed
    batch — that survive, so the caller can narrow its KV cache to match, and decoding continues at
    the smaller width. Measured over 12 real 60 s chunks at the shipped batch of 4, 2556 row-steps
    produced 1937 useful tokens (24.2% discarded), and the batch holding two near-silent chunks
    discarded 52.1% — rows of 7 and 21 tokens dragged through all 236 steps of their loudest
    neighbour. Eviction never changes what a row emits, only how long the batch stays wide.

    Without that attribute the pre-F240 behaviour is kept exactly: a finished row keeps being fed
    until every row is done and its later tokens are ignored. `step` is a bare lambda in the unit
    tests, so `filter` must stay optional rather than become a required contract.
    """
    outputs = [[] for _ in first]
    done = [False] * len(first)
    active = list(range(len(first)))  # original row index for each live batch position
    tokens = list(first)
    evict = getattr(step, "filter", None)
    for _ in range(max_tokens):
        keep = []
        for position, token in enumerate(tokens):
            row = active[position]
            if done[row]:
                continue
            if token in eos_ids:
                done[row] = True
            else:
                outputs[row].append(token)
                keep.append(position)
        if all(done):
            break
        if evict is not None and len(keep) != len(tokens):
            evict(keep)
            active = [active[position] for position in keep]
            tokens = [tokens[position] for position in keep]
        tokens = step(tokens)
    return outputs


def segments_for(chunks, texts, sample_rate=SAMPLE_RATE):
    """The library's segment shape (`text`, `start`, `end`) from `(audio, offset_sec)` chunks and
    their transcripts, using each chunk's real length — never the padded one."""
    return [
        {"text": text, "start": offset, "end": offset + len(chunk_audio) / sample_rate}
        for (chunk_audio, offset), text in zip(chunks, texts)
    ]


def _decode_batch(asr, np, mx, KVCache, batch_audio, language):
    """One batched greedy pass through the Qwen3-ASR model for equal-length audio arrays."""
    features, masks, audio_tokens = [], [], None
    for chunk_audio in batch_audio:
        chunk_features, chunk_mask, count = asr._preprocess_audio(chunk_audio)
        features.append(chunk_features)
        masks.append(chunk_mask)
        if audio_tokens is not None and count != audio_tokens:
            raise ValueError(f"audio token count mismatch in batch: {count} vs {audio_tokens}")
        audio_tokens = count
    # F240: encode each chunk on its own rather than as one batch. `AudioEncoder` flattens a batch
    # into a single long sequence guarded by a dense block mask, and MLX's attention kernel has no
    # all-masked-block skip, so a batch of four computes ~9.73M score entries to use ~314k. Attention
    # blocks never span a chunk boundary, so this is the same computation with the waste removed —
    # and the waste grows quadratically with batch width.
    audio_features = mx.concatenate(
        [asr.get_audio_features(f, m) for f, m in zip(features, masks)]
    )
    mx.eval(audio_features)

    prompt = asr._build_prompt(audio_tokens, language)
    input_ids = mx.concatenate([prompt] * len(batch_audio))
    embeds = asr.model.embed_tokens(input_ids)
    batch, _, hidden = embeds.shape
    positions = np.where(np.array(input_ids[0] == asr.config.audio_token_id))[0]
    if len(positions) != audio_tokens or positions[-1] - positions[0] + 1 != audio_tokens:
        raise ValueError("audio placeholder tokens are not one contiguous run")
    audio_features = audio_features.reshape(batch, audio_tokens, hidden).astype(embeds.dtype)
    embeds = mx.concatenate(
        [embeds[:, :positions[0], :], audio_features, embeds[:, positions[-1] + 1:, :]], axis=1
    )
    mx.eval(embeds)

    cache = [KVCache() for _ in range(len(asr.layers))]
    logits = asr(input_ids, input_embeddings=embeds, cache=cache)
    first = mx.argmax(logits[:, -1, :], axis=-1)
    mx.eval(first)

    def step(tokens):
        next_logits = asr(mx.array(tokens, mx.uint32)[:, None], cache=cache)
        next_tokens = mx.argmax(next_logits[:, -1, :], axis=-1)
        mx.async_eval(next_tokens)
        return next_tokens.tolist()

    def evict(keep):
        """Narrow every layer's KV cache to the rows still decoding (F240).

        `keep` holds positions into the current batch, so a plain gather on axis 0 — which is the
        batch axis of KVCache's (B, n_kv_heads, capacity, head_dim) buffers — is all that is needed.
        `offset` is a step counter shared by every row and does not change. The next
        `update_and_fetch` then sees an incoming batch and a cache that agree on B.
        """
        rows = mx.array(keep, mx.uint32)
        for layer_cache in cache:
            if layer_cache.keys is None:
                continue
            layer_cache.keys = layer_cache.keys[rows]
            layer_cache.values = layer_cache.values[rows]

    step.filter = evict

    rows = greedy_decode_rows(first.tolist(), step, set(ASR_EOS_TOKEN_IDS), ASR_MAX_TOKENS)
    return [asr._tokenizer.decode(row, skip_special_tokens=True) for row in rows]


def transcribe_batched(asr, audio, language, chunk_duration, batch_size):
    """Batched transcription (F213); returns None when the audio is a single chunk so the caller
    keeps the library's own path for short recordings."""
    import mlx.core as mx
    import numpy as np
    from mlx_audio.stt.models.qwen3_asr.qwen3_asr import split_audio_into_chunks
    from mlx_lm.models.cache import KVCache
    from tqdm import tqdm

    chunks = split_audio_into_chunks(
        audio, sr=SAMPLE_RATE, chunk_duration=chunk_duration, min_chunk_duration=0.1
    )
    if len(chunks) <= 1:
        return None
    texts = [None] * len(chunks)
    # The same tqdm "Processing chunks" bar mlx-audio prints, which QwenProgressParser reads (F101).
    with tqdm(total=len(chunks), desc="Processing chunks") as progress:
        for batch in plan_batches(len(chunks), batch_size):
            longest = max(len(chunks[index][0]) for index in batch)
            batch_audio = [
                np.pad(chunks[index][0], (0, longest - len(chunks[index][0]))) for index in batch
            ]
            for index, text in zip(batch, _decode_batch(asr, np, mx, KVCache, batch_audio, language)):
                texts[index] = text
            mx.clear_cache()
            progress.update(len(batch))
    return SimpleNamespace(text=" ".join(texts), segments=segments_for(chunks, texts))


def transcribe(asr, audio, language, chunk_duration=ASR_CHUNK_SECONDS, batch_size=ASR_BATCH_SIZE):
    """Batched when the recording spans several chunks; the library's sequential `generate`
    otherwise, and on any failure of the batched path (a library-internal drift shows up as an
    exception here, and the sequential transcript is always available)."""
    try:
        result = transcribe_batched(asr, audio, language, chunk_duration, batch_size)
        if result is not None:
            return result
    except Exception as error:  # noqa: BLE001 - the sequential path is the safety net
        print(
            "Qwen batched decoding unavailable; using sequential decoding. "
            f"{type(error).__name__}: {error}",
            file=sys.stderr,
        )
    return asr.generate(
        audio,
        language=language,
        chunk_duration=chunk_duration,
        min_chunk_duration=0.1,
        # verbose=True streams mlx-audio's "Processing chunks" tqdm bar to stderr so the app can show a
        # determinate progress bar for long meetings (F101). It only affects the progress display, not
        # the transcription output; the bar is suppressed for single-chunk (short) runs.
        verbose=True,
    )


def write_payload(output_path: str, payload: dict) -> None:
    """Atomically write the transcript payload (temp file + fsync + rename)."""
    temporary_output = f"{output_path}.tmp"
    with open(temporary_output, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, ensure_ascii=False)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary_output, output_path)


def main() -> int:
    import mlx.core as mx
    import numpy as np
    from mlx_audio.stt.models.qwen3_asr import qwen3_asr
    from mlx_audio.stt.utils import load_audio, load_model

    # F240. Installed before any model is built so both the ASR decoder and the forced aligner get
    # it — the aligner imports the same `TextModel` from this module (qwen3_forced_aligner.py:12).
    install_fused_attention_mask(qwen3_asr)

    args = parse_args()
    audio = np.asarray(load_audio(args.audio))

    asr = load_model(args.model)
    transcription = transcribe(asr, audio, args.language)
    text = transcription.text.strip()
    if not text:
        # Write an empty-text payload and exit 0 so the client surfaces its designed "No speech was
        # detected" message. Exiting non-zero here made the client hit its terminationStatus guard
        # first and show a raw Python traceback instead (F53).
        write_payload(
            args.output,
            {"text": "", "language": None, "alignedItems": [], "alignmentWarning": None},
        )
        return 0
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
    write_payload(args.output, payload)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
