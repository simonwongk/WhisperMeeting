#!/usr/bin/env python3
"""Propose transcript spelling corrections with a local mlx_lm model (F165).

Sibling to summarize_local.py, run from the same Runtime/Summarizer venv + model. The Swift
`LocalTranscriptCorrector` builds the system prompt and assembles the user content (the transcript
plus the business vocabulary and an optional reference document) and passes them in; this helper runs
the model and parses its output into a list of {from, to} corrections — degrading (never raising)
when the model's output is not the requested JSON. The proposals are reviewed by the user before any
apply; nothing here mutates a transcript.

    python3 correct_local.py --model <dir> --input <in.json> --output <out.json> [--max-tokens N]

in.json:  {"systemPrompt": str, "transcript": str}
out.json: {"corrections": [{"from": str, "to": str}], "warning": str|null,
           "finishReason": str|null, "generatedTokens": int}
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
    """Wrap the Swift-built system prompt and assembled user content into a chat-template message list."""
    return [
        {"role": "system", "content": system_prompt},
        {"role": "user", "content": transcript},
    ]


def _strip_thinking(text: str) -> str:
    return _THINK_RE.sub("", text)


def _json_object_candidates(text: str):
    """Yield every balanced top-level {...} substring, in order (handles fences + surrounding prose)."""
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


def _coerce_corrections(value) -> list:
    """Coerce the model's array into clean [{from, to}]: both non-blank strings and from != to."""
    if not isinstance(value, list):
        return []
    items = []
    for entry in value:
        if not isinstance(entry, dict):
            continue
        source = ("" if entry.get("from") is None else str(entry.get("from"))).strip()
        target = ("" if entry.get("to") is None else str(entry.get("to"))).strip()
        if source and target and source != target:
            items.append({"from": source, "to": target})
    return items


def parse_corrections(text: str):
    """Turn the model's raw output into ([{from, to}], warning|None).

    Degrades, never raises: an empty/valid-but-no-corrections result is ([], None) or ([], warning);
    unparseable output is ([], warning). A correction pass legitimately finds nothing, so an empty
    list is not an error on its own."""
    cleaned = _strip_thinking(text or "").strip()
    if not cleaned:
        return ([], "The local model returned an empty response.")
    for candidate in _json_object_candidates(cleaned):
        try:
            parsed = json.loads(candidate)
        except (ValueError, TypeError):
            continue
        if isinstance(parsed, dict) and "corrections" in parsed:
            return (_coerce_corrections(parsed.get("corrections")), None)
    return ([], "The local model did not return the requested JSON; proposing no corrections.")


def write_payload(output_path: str, payload: dict) -> None:
    """Atomically write the corrections payload (temp file + fsync + rename)."""
    temporary_output = f"{output_path}.tmp"
    with open(temporary_output, "w", encoding="utf-8") as handle:
        json.dump(payload, handle, ensure_ascii=False)
        handle.flush()
        os.fsync(handle.fileno())
    os.replace(temporary_output, output_path)


def apply_chat_template(tokenizer, messages):
    """Apply the model's chat template with thinking disabled (we want the answer, not the trace)."""
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

    if not transcript.strip():
        write_payload(args.output, {
            "corrections": [], "warning": "The transcript was empty.",
            "finishReason": "empty", "generatedTokens": 0,
        })
        return 0

    from mlx_lm import load, stream_generate
    from mlx_lm.sample_utils import make_sampler

    model, tokenizer = load(args.model)
    prompt = apply_chat_template(tokenizer, build_chat_messages(system_prompt, transcript))
    sampler = make_sampler(temp=0.0)  # greedy: corrections should be reproducible.

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
            print(f"[correct] generated {generated} tokens", file=sys.stderr, flush=True)

    corrections, warning = parse_corrections("".join(pieces))
    write_payload(args.output, {
        "corrections": corrections, "warning": warning,
        "finishReason": finish_reason, "generatedTokens": generated,
    })
    return 0


if __name__ == "__main__":
    sys.exit(main())
