#!/usr/bin/env python3
"""Summarize a meeting transcript with a local mlx_lm model (F164).

One-shot helper mirroring Scripts/qwen_transcribe.py: inputs arrive via argv + a small JSON file,
the heavy `mlx_lm` import is deferred inside main() so the pure functions stay importable in tests,
and the structured result is written atomically to --output. The Swift `LocalSummarizer` builds the
system prompt (the single source of truth for wording) and passes it in verbatim; this helper only
runs the model and parses its text into {summary, keyPoints, actionItems}, degrading — never raising
— when the model's output is not the requested JSON.

Before loading the model, the assembled prompt is measured against the installed model's own
context window (F475 Part 3): `finishReason: "too_long"` means the transcript needs more tokens
than fit alongside --max-tokens of response, and the model was never even loaded.
`finishReason: "model_unreadable"` means the model's own files could not be read (F598): a missing or
corrupt config.json, tokenizer, or weights file, reported with a sentence instead of a traceback.

    python3 summarize_local.py --model <dir> --input <in.json> --output <out.json> [--max-tokens N]

in.json:  {"systemPrompt": str, "transcript": str}
out.json: {"summary": str, "keyPoints": [str], "actionItems": [str],
           "warning": str|null, "finishReason": str|null, "generatedTokens": int}
"""

import argparse
import json
import os
import re
import resource
import sys
import threading
import time
from pathlib import Path

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


def report_progress(message: str) -> None:
    """One heartbeat line on stderr; stdout and --output stay pure (F24).

    The Swift side stops a helper that prints nothing for LocalSummarizer.defaultStallTimeout (F512),
    so every phase that can take a while says so: the model load while it is moving
    (load_with_heartbeat, F606), each prompt chunk, and generation (see should_report_generation).
    Silence then means stuck, not slow."""
    print(f"[summarize] {message}", file=sys.stderr, flush=True)


LOAD_REPORT_SECONDS = 15.0
LOAD_PROGRESS_CPU_FRACTION = 0.01


def load_progress_sample():
    """(major page faults, block reads, CPU seconds used by every thread except the caller) for this
    process: what a model load moves while it is working (F606).

    The heartbeat thread takes this sample, so its own CPU is subtracted: getrusage(RUSAGE_SELF)
    alone counts every thread, and would read the heartbeat's own wakeups as the load moving.
    process_time() is read before thread_time(), so the subtraction can only undercount."""
    usage = resource.getrusage(resource.RUSAGE_SELF)
    return (usage.ru_majflt, usage.ru_inblock, time.process_time() - time.thread_time())


def load_made_progress(before, after, interval) -> bool:
    """Whether the load moved between two load_progress_sample()s taken `interval` seconds apart:
    any major fault or block read (a page-in), or other threads' CPU of at least 1% of the interval.

    Measured 2026-09-30 with the installed Qwen3-8B-4bit and mlx_lm 0.30.5 on an 18 GB Mac, sampling
    every 0.5 s: a warm 3.9 s load moved the other threads' CPU by 0.22-0.57 s per sample and took
    up to 171 major faults per sample; the same process with its main thread then blocked for 20 s
    moved it by 0.0022 s in all, with no major faults and no block reads. 1% of a 15 s interval is
    0.15 s: about 70 times that blocked total, and below any 0.5 s sample of the load. A cold load,
    or one under heavy swap, has not been measured.

    What this cannot see: a load that spins the CPU while making no progress reads as moving, so a
    wedge of that shape is still stopped only by Cancel, as every wedge was before F606."""
    return (
        after[0] > before[0]
        or after[1] > before[1]
        or after[2] - before[2] >= interval * LOAD_PROGRESS_CPU_FRACTION
    )


def load_with_heartbeat(load, model_path, interval=LOAD_REPORT_SECONDS):
    """Run mlx_lm's load() while a thread reports every `interval` seconds that it is still going,
    as long as it is (F606).

    load() blocks with no output for as long as a cold 4.5 GB model takes to page in, and on a
    swapping Mac nobody has measured that (F512 review); rather than trust it to finish inside the
    stall timeout, the load speaks for itself. It speaks only when load_made_progress says it
    moved since the last check: F512's first version reported every interval unconditionally, so a
    load wedged in a call that releases the GIL was never silent, the stall timeout could never
    stop it, and it held the summary slot until Cancel. The thread is joined on every exit, so no
    line can arrive after the load has returned or raised."""
    finished = threading.Event()
    started = time.monotonic()

    def beat():
        last = load_progress_sample()
        while not finished.wait(interval):
            current = load_progress_sample()
            if load_made_progress(last, current, interval):
                report_progress(f"still loading model ({int(time.monotonic() - started)} s)")
            last = current

    thread = threading.Thread(target=beat, name="load-heartbeat", daemon=True)
    thread.start()
    try:
        return load(model_path)
    finally:
        finished.set()
        thread.join()


GENERATION_REPORT_TOKENS = 32
GENERATION_REPORT_SECONDS = 5.0


def should_report_generation(generated: int, seconds_since_report: float) -> bool:
    """Every 32 tokens, or sooner when tokens are slow: on a swapping Mac, 32 tokens at a 32k-token
    context were measured taking 146 s (F512), so a count alone would leave long silences that are
    progress. With both, the only silence longer than 5 s is a single token taking that long."""
    if generated <= 0:
        return False
    return generated % GENERATION_REPORT_TOKENS == 0 or seconds_since_report >= GENERATION_REPORT_SECONDS


def report_prompt_progress(processed: int, total: int) -> None:
    """mlx_lm's prompt_progress_callback: called before prefill, after every prefill_step_size chunk,
    and once more after the first generated token (mlx_lm 0.30.5 generate.py:425, :440, :459)."""
    report_progress(f"prompt {processed}/{total} tokens")


def apply_chat_template(tokenizer, messages):
    """Apply the model's chat template with thinking disabled (summaries want the answer, not the
    reasoning trace). Fall back gracefully if a tokenizer predates the enable_thinking kwarg."""
    try:
        return tokenizer.apply_chat_template(
            messages, add_generation_prompt=True, enable_thinking=False
        )
    except TypeError:
        return tokenizer.apply_chat_template(messages, add_generation_prompt=True)


# F475 Part 3: neither this helper nor `LocalSummarizer` ever measured the prompt against the
# model's context window before this. Measured against the installed mlx-community/Qwen3-8B-4bit
# (2026-09-26, `mlx_lm.utils.load_tokenizer` + `apply_chat_template`, which returns the exact
# token-id list `stream_generate` receives): a 348,000-character synthetic English transcript (a
# realistic sentence repeated to approximate a 4-hour meeting at ~150 wpm) tokenizes to 66,001
# tokens, and the Mandarin equivalent (90,000 characters) to 60,000 — both well past this model's
# `max_position_embeddings` of 40,960. Nothing in mlx_lm 0.30.5's `stream_generate` raises when a
# prompt exceeds it; the model runs anyway with degraded quality past its trained window, and nothing
# said so.
#
# A small margin, not a large fudge factor: `apply_chat_template` already returns the exact final
# token-id list `stream_generate` receives (verified empirically above), so there is nothing left to
# guess about except the two token-count constants' own possible drift between mlx_lm versions.
CONTEXT_SAFETY_MARGIN_TOKENS = 32


def context_overflow_detail(prompt_tokens: int, context_limit: int, max_tokens: int) -> str:
    """A human-readable detail when `prompt_tokens` leaves no room for `max_tokens` of response
    inside `context_limit`, or "" when it fits. Pure so the budget arithmetic is testable without a
    5 GB model — the token counts it is handed come from the real tokenizer in `main()`."""
    budget = context_limit - max_tokens - CONTEXT_SAFETY_MARGIN_TOKENS
    if prompt_tokens <= budget:
        return ""
    return (
        f"This transcript needs about {prompt_tokens} tokens, more than the {budget} available "
        f"in this model's {context_limit}-token context window with {max_tokens} reserved for "
        "the response. Try a shorter selection, or use Claude for long meetings."
    )


# F598: what a partial or damaged model install raises, measured against the installed runtime
# (mlx_lm 0.30.5) on a temporary copy of the model folder: a missing config.json is
# FileNotFoundError, a truncated config.json or tokenizer.json is json.JSONDecodeError (a
# ValueError), and a corrupt model.safetensors is RuntimeError("[load_safetensors] Invalid json
# header length ..."). mlx_lm's own load() documents FileNotFoundError and ValueError. A Metal
# allocation failure is a RuntimeError too, measured the same day: "[metal::malloc] Attempting to
# allocate ... bytes which is greater than the maximum allowed buffer size ...".
MODEL_UNREADABLE = "model_unreadable"


def is_unreadable_model_error(error: BaseException) -> bool:
    """Whether `error`, raised while reading the model's files, means the install itself is damaged.

    Only the RuntimeError that names the weights file counts: any other RuntimeError, such as a
    Metal allocation failure while the weights are evaluated, is not a broken install, and telling
    the user to repair it would send them to a multi-gigabyte download that cannot help."""
    if isinstance(error, (OSError, ValueError)):
        return True
    return isinstance(error, RuntimeError) and str(error).startswith("[load_safetensors]")


def model_unreadable_detail(model_dir: str, error: BaseException) -> str:
    """The sentence the Swift side shows verbatim (`SummarizerError.localModelUnreadable`)."""
    reason = f"{type(error).__name__}: {error}"
    if len(reason) > 300:
        reason = reason[:300] + "…"
    return (
        f"The on-device model in {model_dir} could not be read ({reason}). Its files may be "
        "incomplete or damaged. Use Repair or Update under Summaries in Settings, then try again."
    )


def load_counting_inputs(load_config, load_tokenizer, model_dir: str, messages: list):
    """(context_limit, prompt_tokens) for the pre-flight, reading only config.json and the
    tokenizer files. prompt_tokens is None when the config declares no context window."""
    config = load_config(Path(model_dir))
    if not isinstance(config, dict):
        raise ValueError(f"config.json holds a {type(config).__name__}, not an object")
    context_limit = config.get("max_position_embeddings")
    if not context_limit:
        return None, None
    counting_tokenizer = load_tokenizer(Path(model_dir))
    return context_limit, len(apply_chat_template(counting_tokenizer, messages))


def write_model_unreadable(output_path: str, model_dir: str, error: BaseException) -> None:
    write_payload(output_path, {
        "summary": "", "keyPoints": [], "actionItems": [],
        "warning": model_unreadable_detail(model_dir, error),
        "finishReason": MODEL_UNREADABLE, "generatedTokens": 0,
    })


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
    from mlx_lm.utils import load_config, load_tokenizer

    # F475 Part 3: measured against the REAL tokenizer and the model's own config.json, ahead of
    # the (comparatively expensive) full weights load below — `load_config`/`load_tokenizer` read
    # only the tokenizer files and a small JSON file, not the multi-gigabyte weights.
    messages = build_chat_messages(system_prompt, transcript)
    try:
        context_limit, prompt_tokens = load_counting_inputs(
            load_config, load_tokenizer, args.model, messages
        )
    except (OSError, ValueError, RuntimeError) as error:
        if not is_unreadable_model_error(error):
            raise
        write_model_unreadable(args.output, args.model, error)
        return 0
    if context_limit:
        detail = context_overflow_detail(prompt_tokens, context_limit, args.max_tokens)
        if detail:
            write_payload(args.output, {
                "summary": "", "keyPoints": [], "actionItems": [],
                "warning": detail, "finishReason": "too_long", "generatedTokens": 0,
            })
            return 0

    report_progress("loading model")
    try:
        model, tokenizer = load_with_heartbeat(load, args.model)
    except (OSError, ValueError, RuntimeError) as error:
        # F598: the weights are read only here, so a corrupt model.safetensors surfaces here.
        if not is_unreadable_model_error(error):
            raise
        write_model_unreadable(args.output, args.model, error)
        return 0
    report_progress("model loaded")
    prompt = apply_chat_template(tokenizer, messages)
    sampler = make_sampler(temp=0.0)  # greedy: a summary should be reproducible, not sampled.

    pieces = []
    finish_reason = None
    generated = 0
    last_report = time.monotonic()
    # stream_generate passes its kwargs, this callback included, to generate_step (mlx_lm 0.30.5
    # generate.py:692).
    for response in stream_generate(
        model, tokenizer, prompt, max_tokens=args.max_tokens, sampler=sampler,
        prompt_progress_callback=report_prompt_progress,
    ):
        pieces.append(response.text)
        generated = getattr(response, "generation_tokens", None) or generated
        reason = getattr(response, "finish_reason", None)
        if reason is not None:
            finish_reason = reason
        now = time.monotonic()
        if should_report_generation(generated, now - last_report):
            report_progress(f"generated {generated} tokens")
            last_report = now

    summary, warning = parse_summary("".join(pieces))
    payload = dict(summary)
    payload["warning"] = warning
    payload["finishReason"] = finish_reason
    payload["generatedTokens"] = generated
    write_payload(args.output, payload)
    return 0


if __name__ == "__main__":
    sys.exit(main())
