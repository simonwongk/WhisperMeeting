# Scripts/refine_server.py
"""Resident mlx_lm helper for WhisperMeet dictation refinement (F200).

Loads the Summarizer-runtime Qwen model once, then serves newline-delimited JSON requests on
stdin and writes newline-delimited JSON responses on stdout. Sibling of whisper_dictate_server.py
(the framing) and correct_local.py (the model/venv). Local-only: the app launches it with
HF_HUB_OFFLINE=1 / TRANSFORMERS_OFFLINE=1 so the pinned snapshot can never be re-fetched at
inference time. Exits cleanly when stdin closes (the app terminates it to evict the model).

Wire: request  {"text": str, "systemPrompt": str, "maxTokens": int}
      response {"text": str} | {"error": str}
Every stdout line is a JSON object; anything else would desync the stream (see
WarmWhisperDictationEngine.isProtocolMessage).
"""
import argparse
import json
import re
import sys

_THINK_RE = re.compile(r"<think>.*?</think>", re.DOTALL | re.IGNORECASE)


def apply_chat_template(tokenizer, messages):
    """Apply the model's chat template with thinking disabled (we want the answer, not the trace)."""
    try:
        return tokenizer.apply_chat_template(
            messages, add_generation_prompt=True, enable_thinking=False
        )
    except TypeError:
        return tokenizer.apply_chat_template(messages, add_generation_prompt=True)


def generate(model, tokenizer, stream_generate, sampler, system_prompt, text, max_tokens):
    prompt = apply_chat_template(tokenizer, [
        {"role": "system", "content": system_prompt},
        {"role": "user", "content": text},
    ])
    pieces = []
    for response in stream_generate(
        model, tokenizer, prompt, max_tokens=max_tokens, sampler=sampler
    ):
        pieces.append(response.text)
    return _THINK_RE.sub("", "".join(pieces)).strip()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True)
    args = parser.parse_args()

    from mlx_lm import load, stream_generate
    from mlx_lm.sample_utils import make_sampler

    model, tokenizer = load(args.model)
    sampler = make_sampler(temp=0.0)  # greedy: a cleanup should be reproducible, not sampled.

    # Pre-warm with a real (tiny) generation so the first user request pays no kernel-compile
    # cost; only after this returns is {"ready": true} genuinely resident.
    try:
        generate(model, tokenizer, stream_generate, sampler,
                 "Reply with exactly the word: ready", "ready", 8)
    except Exception as error:  # pragma: no cover - warm failure is fatal to the helper
        sys.stdout.write(json.dumps({"error": "warm-up failed: " + str(error)}) + "\n")
        sys.stdout.flush()
        return 1

    sys.stdout.write(json.dumps({"ready": True}) + "\n")
    sys.stdout.flush()

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            request = json.loads(line)
            text = generate(
                model, tokenizer, stream_generate, sampler,
                request.get("systemPrompt") or "",
                request.get("text") or "",
                int(request.get("maxTokens") or 256),
            )
            response = {"text": text}
        except Exception as error:  # never crash the daemon on one bad request
            response = {"error": str(error)}
        sys.stdout.write(json.dumps(response) + "\n")
        sys.stdout.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main())
