#!/usr/bin/env python3
"""Embed text with a local sentence-embedding model, for Ask Meetings' search by meaning (F316).

in.json:   {"kind": "query" | "passage", "texts": [str, ...]}
out.f32:   count x dimension little-endian float32, L2-normalised, in input order
out.json:  {"count": int, "dimension": int}       written last, so its presence means out.f32 is whole

The model is `intfloat/multilingual-e5-small` (a 12-layer BERT encoder, 384 dimensions). It is run
with plain `mlx` and the `tokenizers` the summarizer runtime already has: `mlx-embeddings` would
work, but installing it upgrades `mlx` and `transformers` under the pinned summarizer and pulls in
two dozen unrelated packages (measured with `pip install --dry-run`, 2026-09-18). A BERT encoder is
eighty lines; owning them is cheaper than that.

Offline by construction: it opens local files only and never imports `huggingface_hub`.
"""
import argparse
import json
import math
import os
import sys


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--model", required=True, help="directory holding config.json, tokenizer.json, model.safetensors")
    parser.add_argument("--input", required=True)
    parser.add_argument("--output", required=True, help="path of the .f32 file; the .json goes beside it")
    parser.add_argument("--max-length", type=int, default=256)
    return parser.parse_args()


def e5_inputs(kind: str, texts: list) -> list:
    """e5 models are trained with these prefixes; without them retrieval quality drops sharply."""
    prefix = "query: " if kind == "query" else "passage: "
    return [prefix + text for text in texts]


def batches(texts: list, size: int) -> list:
    """Index batches ordered by length, so a batch pads to its own longest text, not the corpus's."""
    order = sorted(range(len(texts)), key=lambda i: len(texts[i]))
    return [order[start:start + size] for start in range(0, len(order), size)]


def load_model(model_dir: str):
    import mlx.core as mx
    from tokenizers import Tokenizer

    with open(os.path.join(model_dir, "config.json"), encoding="utf-8") as handle:
        config = json.load(handle)
    weights = mx.load(os.path.join(model_dir, "model.safetensors"))
    weights = {key.removeprefix("bert."): value for key, value in weights.items()}
    tokenizer = Tokenizer.from_file(os.path.join(model_dir, "tokenizer.json"))
    tokenizer.enable_padding()
    return config, weights, tokenizer


def encode(model, texts: list, max_length: int):
    """One forward pass: mean-pooled, L2-normalised sentence vectors as an mx.array."""
    import mlx.core as mx

    config, weights, tokenizer = model
    heads = config["num_attention_heads"]
    eps = config.get("layer_norm_eps", 1e-12)
    tokenizer.enable_truncation(max_length=max_length)
    batch = tokenizer.encode_batch(texts)
    ids = mx.array([item.ids for item in batch])
    mask = mx.array([item.attention_mask for item in batch]).astype(mx.float32)

    def linear(x, prefix):
        return x @ weights[prefix + ".weight"].T + weights[prefix + ".bias"]

    def layer_norm(x, prefix):
        return mx.fast.layer_norm(x, weights[prefix + ".weight"], weights[prefix + ".bias"], eps)

    count, length = ids.shape
    x = (weights["embeddings.word_embeddings.weight"][ids]
         + weights["embeddings.position_embeddings.weight"][mx.arange(length)][None]
         + weights["embeddings.token_type_embeddings.weight"][mx.zeros_like(ids)])
    x = layer_norm(x, "embeddings.LayerNorm")
    bias = ((1.0 - mask) * -1e9)[:, None, None, :]
    for index in range(config["num_hidden_layers"]):
        p = f"encoder.layer.{index}"

        def split(t):
            return t.reshape(count, length, heads, -1).transpose(0, 2, 1, 3)

        q = split(linear(x, p + ".attention.self.query"))
        k = split(linear(x, p + ".attention.self.key"))
        v = split(linear(x, p + ".attention.self.value"))
        scores = (q @ k.transpose(0, 1, 3, 2)) / math.sqrt(q.shape[-1]) + bias
        attended = (mx.softmax(scores, axis=-1) @ v).transpose(0, 2, 1, 3).reshape(count, length, -1)
        x = layer_norm(x + linear(attended, p + ".attention.output.dense"), p + ".attention.output.LayerNorm")
        hidden = linear(x, p + ".intermediate.dense")
        hidden = hidden * 0.5 * (1.0 + mx.erf(hidden / math.sqrt(2.0)))
        x = layer_norm(x + linear(hidden, p + ".output.dense"), p + ".output.LayerNorm")
    pooled = (x * mask[:, :, None]).sum(axis=1) / mx.maximum(mask.sum(axis=1, keepdims=True), 1.0)
    pooled = pooled / mx.maximum(mx.sqrt((pooled * pooled).sum(axis=1, keepdims=True)), 1e-12)
    mx.eval(pooled)
    return pooled


def main() -> int:
    args = parse_args()
    with open(args.input, encoding="utf-8") as handle:
        request = json.load(handle)
    texts = [str(text) for text in request.get("texts") or []]
    kind = request.get("kind") or "passage"
    dimension = 0
    rows = [None] * len(texts)
    if texts:
        import numpy as np
        model = load_model(args.model)
        dimension = model[0]["hidden_size"]
        prepared = e5_inputs(kind, texts)
        done = 0
        for indices in batches(prepared, 32):
            vectors = np.array(encode(model, [prepared[i] for i in indices], args.max_length), dtype="<f4")
            for row, index in enumerate(indices):
                rows[index] = vectors[row]
            done += len(indices)
            print(f"embedded {done}/{len(texts)}", file=sys.stderr, flush=True)
        payload = np.stack(rows).astype("<f4").tobytes()
    else:
        payload = b""
    temporary = args.output + ".tmp"
    with open(temporary, "wb") as handle:
        handle.write(payload)
    os.replace(temporary, args.output)
    with open(args.output + ".json.tmp", "w", encoding="utf-8") as handle:
        json.dump({"count": len(texts), "dimension": dimension}, handle)
    os.replace(args.output + ".json.tmp", args.output + ".json")
    return 0


if __name__ == "__main__":
    sys.exit(main())
