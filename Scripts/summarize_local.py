#!/usr/bin/env python3
"""Summarize a meeting transcript with a local mlx_lm model (F164).

One-shot helper mirroring Scripts/qwen_transcribe.py: inputs arrive via argv + a small JSON file,
the heavy `mlx_lm` import is deferred inside main() so the pure functions stay importable in tests,
and the structured result is written atomically to --output. The Swift `LocalSummarizer` builds the
system prompt (the single source of truth for wording) and passes it in verbatim; this helper only
runs the model and parses its text into {summary, keyPoints, actionItems}, degrading — never raising
— when the model's output is not the requested JSON.

    python3 summarize_local.py --model <dir> --input <in.json> --output <out.json> [--max-tokens N]

in.json:  {"systemPrompt": str, "transcript": str}
out.json: {"summary": str, "keyPoints": [str], "actionItems": [str],
           "warning": str|null, "finishReason": str|null, "generatedTokens": int}
"""

import argparse
import json
import os
import re
import sys

_THINK_RE = re.compile(r"<think>.*?</think>", re.DOTALL | re.IGNORECASE)


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True)
    parser.add_argument("--input", required=True)
    parser.add_argument("--output", required=True)
    parser.add_argument("--max-tokens", type=int, default=2048)
    return parser.parse_args()


def build_chat_messages(system_prompt: str, transcript: str) -> list:
    """Wrap the Swift-built system prompt and the transcript into a chat-template message list."""
    return [
        {"role": "system", "content": system_prompt},
        {"role": "user", "content": transcript},
    ]


def _strip_thinking(text: str) -> str:
    """Remove any Qwen3 <think>…</think> reasoning block before we look for the answer JSON."""
    return _THINK_RE.sub("", text)


def _json_object_candidates(text: str):
    """Yield every balanced top-level {...} substring, in order. Handles code fences and surrounding
    prose without a fragile regex: a fenced or narrated object is just the first balanced brace run."""
    start = text.find("{")
    while start != -1:
        depth = 0
        in_string = False
        escaped = False
        for index in range(start, len(text)):
            char = text[index]
            if in_string:
                if escaped:
                    escaped = False
                elif char == "\\":
                    escaped = True
                elif char == '"':
                    in_string = False
            elif char == '"':
                in_string = True
            elif char == "{":
                depth += 1
            elif char == "}":
                depth -= 1
                if depth == 0:
                    yield text[start:index + 1]
                    break
        start = text.find("{", start + 1)


def _coerce_str_list(value) -> list:
    """Coerce a model-provided array into a clean [str]: drop blanks, stringify non-strings."""
    if not isinstance(value, list):
        return []
    items = []
    for item in value:
        text = ("" if item is None else str(item)).strip()
        if text:
            items.append(text)
    return items


def parse_summary(text: str):
    """Turn the model's raw output into ({summary, keyPoints, actionItems}, warning|None).

    Degrades, never raises: unparseable output becomes a raw-text summary with a warning, and empty
    output becomes an empty payload with a warning — mirroring qwen_transcribe.py's build_chunks."""
    cleaned = _strip_thinking(text or "").strip()
    if not cleaned:
        return (
            {"summary": "", "keyPoints": [], "actionItems": []},
            "The local model returned an empty response.",
        )
    for candidate in _json_object_candidates(cleaned):
        try:
            parsed = json.loads(candidate)
        except (ValueError, TypeError):
            continue
        if isinstance(parsed, dict) and (
            "summary" in parsed or "keyPoints" in parsed or "actionItems" in parsed
        ):
            summary = parsed.get("summary")
            return (
                {
                    "summary": ("" if summary is None else str(summary)).strip(),
                    "keyPoints": _coerce_str_list(parsed.get("keyPoints")),
                    "actionItems": _coerce_str_list(parsed.get("actionItems")),
                },
                None,
            )
    # No usable JSON object: keep the model's text as the summary rather than failing outright.
    return (
        {"summary": cleaned, "keyPoints": [], "actionItems": []},
        "The local model did not return JSON; used its text as the summary.",
    )


def write_payload(output_path: str, payload: dict) -> None:
    """Atomically write the summary payload (temp file + fsync + rename), as qwen_transcribe does."""
    temporary_output = f"{output_path}.tmp"
    with open(temporary_output, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, ensure_ascii=False)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary_output, output_path)


def apply_chat_template(tokenizer, messages):
    """Apply the model's chat template with thinking disabled (summaries want the answer, not the
    reasoning trace). Fall back gracefully if a tokenizer predates the enable_thinking kwarg."""
    try:
        return tokenizer.apply_chat_template(
            messages, add_generation_prompt=True, enable_thinking=False
        )
    except TypeError:
        return tokenizer.apply_chat_template(messages, add_generation_prompt=True)


def main() -> int:
    args = parse_args()
    with open(args.input, encoding="utf-8") as handle:
        request = json.load(handle)
    system_prompt = request.get("systemPrompt") or ""
    transcript = request.get("transcript") or ""

    # An empty transcript never reaches the model: exit 0 with an empty payload (F53-style).
    if not transcript.strip():
        write_payload(args.output, {
            "summary": "", "keyPoints": [], "actionItems": [],
            "warning": "The transcript was empty.", "finishReason": "empty", "generatedTokens": 0,
        })
        return 0

    # Heavy import deferred so the pure functions above import cheaply in tests.
    from mlx_lm import load, stream_generate
    from mlx_lm.sample_utils import make_sampler

    model, tokenizer = load(args.model)
    prompt = apply_chat_template(tokenizer, build_chat_messages(system_prompt, transcript))
    sampler = make_sampler(temp=0.0)  # greedy: a summary should be reproducible, not sampled.

    pieces = []
    finish_reason = None
    generated = 0
    for response in stream_generate(
        model, tokenizer, prompt, max_tokens=args.max_tokens, sampler=sampler
    ):
        pieces.append(response.text)
        generated = getattr(response, "generation_tokens", None) or generated
        reason = getattr(response, "finish_reason", None)
        if reason is not None:
            finish_reason = reason
        if generated and generated % 32 == 0:
            # Progress goes to stderr; stdout/--output stays pure (F24).
            print(f"[summarize] generated {generated} tokens", file=sys.stderr, flush=True)

    summary, warning = parse_summary("".join(pieces))
    payload = dict(summary)
    payload["warning"] = warning
    payload["finishReason"] = finish_reason
    payload["generatedTokens"] = generated
    write_payload(args.output, payload)
    return 0


if __name__ == "__main__":
    sys.exit(main())
