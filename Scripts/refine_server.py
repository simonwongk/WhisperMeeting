# Scripts/refine_server.py
"""Resident mlx_lm helper for WhisperMeet dictation refinement (F200, cached F203).

Loads the Summarizer-runtime Qwen model once, then serves newline-delimited JSON requests on
stdin and writes newline-delimited JSON responses on stdout. Sibling of whisper_dictate_server.py
(the framing) and correct_local.py (the model/venv). Local-only: the app launches it with
HF_HUB_OFFLINE=1 / TRANSFORMERS_OFFLINE=1 so the pinned snapshot can never be re-fetched at
inference time. Exits cleanly when stdin closes (the app terminates it to evict the model).

Wire: request  {"text": str, "systemPrompt": str, "maxTokens": int}
      response {"text": str} | {"error": str}
Every stdout line is a JSON object; anything else would desync the stream (see
WarmRefineEngine.isProtocolMessage).

F203 — persistent prompt cache. The templated system prompt (~120 tokens) dominated each
request's prefill, giving a measured ~1.0-1.3 s floor on Qwen3-8B-4bit. `RefineSession` keeps one
KV cache across requests and, per request, trims it back to the common token prefix with the
previous prompt and feeds only the suffix. Verified against the pinned mlx_lm==0.30.5 installed
source: `stream_generate(..., prompt_cache=...)` flows through generate_step
(mlx_lm/generate.py:311,367-390); `trim_prompt_cache`/`can_trim_prompt_cache`
(mlx_lm/models/cache.py:86-109); `KVCache.offset` is the exact materialized-token count and
`trim(n)` min-clamps and decrements it (mlx_lm/models/cache.py:180-207). The app primes the cache
at warm-up with a tiny request carrying the real base system prompt (WarmRefineEngine, F203), so
the first dictation's request already reuses the hot prefix.
"""
import argparse
import json
import re
import sys

_THINK_RE = re.compile(r"<think>.*?</think>", re.DOTALL | re.IGNORECASE)


def common_prefix_length(a, b):
    """Length of the common element-wise prefix of two token lists."""
    n = min(len(a), len(b))
    i = 0
    while i < n and a[i] == b[i]:
        i += 1
    return i


class RefineSession:
    """Owns the persistent prompt cache across requests.

    Collaborators are injected so the reuse logic is testable without mlx:
      make_cache()            -> new cache object
      can_trim(cache)         -> bool
      trim(cache, n)          -> tokens actually trimmed (mlx trim_prompt_cache contract)
      offset_of(cache)        -> exact materialized token count (KVCache.offset ground truth)
      generate_fn(tokens, max_tokens, cache_or_None) -> generated text

    Correctness rule: the cache's contents are only ever trusted up to the common token prefix
    with `cached_tokens`, measured against `offset_of` (never a hand-counted total, so generated
    tokens and EOS bookkeeping can't drift). Any generation error resets the cache outright —
    a partially-fed cache with stale `cached_tokens` could otherwise be reused past the true
    common prefix.
    """

    def __init__(self, make_cache, can_trim, trim, offset_of, generate_fn):
        self.make_cache = make_cache
        self.can_trim = can_trim
        self.trim = trim
        self.offset_of = offset_of
        self.generate_fn = generate_fn
        self.cache = None          # None = not yet created; False = caching unusable
        self.cached_tokens = []

    def run(self, tokens, max_tokens):
        if self.cache is None:
            candidate = self.make_cache()
            if self.can_trim(candidate):
                self.cache = candidate
                self.cached_tokens = []
            else:
                self.cache = False
        if self.cache is False:
            return self.generate_fn(list(tokens), max_tokens, None)

        common = common_prefix_length(tokens, self.cached_tokens)
        if common >= len(tokens):
            common = len(tokens) - 1  # identical prompt: always feed at least the final token
        excess = self.offset_of(self.cache) - common
        if excess > 0:
            trimmed = self.trim(self.cache, excess)
            if trimmed != excess:
                self.cache = self.make_cache()
                self.cached_tokens = []
                common = 0
        try:
            text = self.generate_fn(list(tokens[common:]), max_tokens, self.cache)
        except Exception:
            self.cache = None
            self.cached_tokens = []
            raise
        self.cached_tokens = list(tokens)
        return text


def apply_chat_template(tokenizer, messages):
    """Apply the model's chat template with thinking disabled (we want the answer, not the trace)."""
    try:
        return tokenizer.apply_chat_template(
            messages, add_generation_prompt=True, enable_thinking=False
        )
    except TypeError:
        return tokenizer.apply_chat_template(messages, add_generation_prompt=True)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True)
    args = parser.parse_args()

    from mlx_lm import load, stream_generate
    from mlx_lm.sample_utils import make_sampler
    from mlx_lm.models.cache import (
        can_trim_prompt_cache,
        make_prompt_cache,
        trim_prompt_cache,
    )

    model, tokenizer = load(args.model)
    sampler = make_sampler(temp=0.0)  # greedy: a cleanup should be reproducible, not sampled.

    def generate_fn(tokens, max_tokens, prompt_cache):
        kwargs = {"prompt_cache": prompt_cache} if prompt_cache is not None else {}
        pieces = []
        for response in stream_generate(
            model, tokenizer, tokens, max_tokens=max_tokens, sampler=sampler, **kwargs
        ):
            pieces.append(response.text)
        return _THINK_RE.sub("", "".join(pieces)).strip()

    session = RefineSession(
        make_cache=lambda: make_prompt_cache(model),
        can_trim=can_trim_prompt_cache,
        trim=trim_prompt_cache,
        offset_of=lambda cache: cache[0].offset,
        generate_fn=generate_fn,
    )

    def refine(system_prompt, text, max_tokens):
        tokens = apply_chat_template(tokenizer, [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": text},
        ])
        return session.run(tokens, max_tokens)

    # Pre-warm with a real (tiny) generation so the first user request pays no kernel-compile
    # cost; only after this returns is {"ready": true} genuinely resident. The app's warm-up then
    # primes the cache with the real system prompt over the wire (F203).
    try:
        refine("Reply with exactly the word: ready", "ready", 8)
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
            text = refine(
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
