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

F212 — prompt-lookup speculative decoding. Decoding one token per forward pass, the 8B refiner
measured ~30 ms per dictated word, so every 40+ word dictation missed its 1.5 s budget. A cleanup
reply mostly copies the dictated text, so `CopyDrafter` drafts the next few tokens from that text
(or, failing that, from the reply's own history) and `lookup_generate` verifies the whole draft in
one forward pass — a pass over three tokens costs the same as one on this bandwidth-bound model,
and the draft length adapts to how the last one fared. Accepted tokens are exactly the argmax the
model produced, so the reply is what greedy decoding gives, up to floating-point near-ties between
batched and single-token matmuls (13 of 14 bench replies byte-identical; the odd one out gained a
capital letter). Measured on the installed Qwen3-8B-4bit: 40 words 1508 -> 804 ms, 60 words
2152 -> 998 ms, Mandarin 60 eff-words 2171 -> 1249 ms — all inside their budgets.
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
        # F212: the dictated tokens the cached-path generator may draft from; set per request by
        # the caller, consumed only by generate_fn(..., source_tokens=...).
        self.generate_source = None

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
            if self.generate_source is None:
                text = self.generate_fn(list(tokens[common:]), max_tokens, self.cache)
            else:
                text = self.generate_fn(
                    list(tokens[common:]), max_tokens, self.cache,
                    source_tokens=self.generate_source,
                )
        except Exception:
            self.cache = None
            self.cached_tokens = []
            raise
        self.cached_tokens = list(tokens)
        return text


def ngram_draft(sequence, max_draft, ngram_sizes=(3, 2)):
    """Prompt-lookup draft (F212): the tokens that followed the most recent earlier occurrence of
    the sequence's final n-gram, largest n first. Empty when nothing earlier matches.

    A refined dictation is mostly a verbatim copy of the dictated text sitting in the prompt, so the
    continuation after the last few emitted tokens is usually already spelled out earlier in the
    sequence. The draft is only ever a *guess*: `lookup_generate` verifies every drafted token
    against the model's own argmax before keeping it.
    """
    if max_draft <= 0:
        return []
    for n in ngram_sizes:
        if len(sequence) <= n:
            continue
        tail = sequence[-n:]
        for start in range(len(sequence) - n - 1, -1, -1):
            if sequence[start:start + n] == tail:
                return list(sequence[start + n:start + n + max_draft])
    return []


def source_pointer(source, generated, window=4):
    """Where in the dictated `source` tokens the reply `generated` so far has copied up to (F212).

    A greedy alignment: each generated token that reappears within the next `window` source
    positions advances the pointer past it. That covers the edits a cleanup makes — an inserted
    punctuation or capitalised token matches nothing and leaves the pointer alone, a substituted or
    removed filler token is skipped when the token after it matches — without ever needing to know
    which edit happened.
    """
    pos = 0
    for token in generated:
        if pos >= len(source):
            break
        for skip in range(window + 1):
            if pos + skip < len(source) and source[pos + skip] == token:
                pos += skip + 1
                break
    return pos


def source_draft(source, generated, max_draft, window=4):
    """The next `max_draft` dictated tokens after the point the reply has copied up to."""
    if max_draft <= 0 or not source:
        return []
    pos = source_pointer(source, generated, window)
    return list(source[pos:pos + max_draft])


def find_span(haystack, needle):
    """Index of `needle` as a contiguous token sub-list of `haystack`, or None."""
    if not needle or len(needle) > len(haystack):
        return None
    for start in range(len(haystack) - len(needle) + 1):
        if haystack[start:start + len(needle)] == needle:
            return start
    return None


class CopyDrafter:
    """Chooses each step's draft and its length (F212).

    The refined reply is expected to copy the dictated text, so the primary draft is the dictated
    tokens after the point the reply has reached (`source_draft`); when that is exhausted the
    reply's own history is searched instead (`ngram_draft`). The draft length adapts to how the
    last draft fared: a verifying forward pass over one token plus two drafted ones costs the same
    as a single token on the 8B refiner (35 vs 37 ms measured), four costs 47 ms and six 70 ms —
    so length pays only while drafts keep being accepted, and shrinks to the free size as soon as
    the model is editing rather than copying.
    """

    def __init__(self, source_tokens, initial=4, minimum=2, maximum=6, window=4):
        self.source = list(source_tokens or [])
        self.length = initial
        self.minimum = minimum
        self.maximum = maximum
        self.window = window

    def draft(self, context, generated, budget):
        length = min(self.length, budget)
        draft = source_draft(self.source, generated, length, self.window)
        return draft or ngram_draft(context, length, (3, 2, 1))

    def observe(self, drafted, accepted):
        if not drafted:
            return
        if accepted == drafted:
            self.length = min(self.length + 2, self.maximum)
        elif accepted == 0:
            self.length = max(self.length - 2, self.minimum)


def lookup_generate(step, trim, prompt_tokens, max_tokens, eos_ids, drafter=None, max_draft=8):
    """Greedy generation with prompt-lookup speculative verification (F212).

    Collaborators:
      step(tokens) -> list[int]   feeds `tokens` through the model on the persistent cache and
                                  returns the argmax prediction after EACH fed position.
      trim(n)                     drops the last n positions from that cache.
      drafter                     `draft(context, generated, budget)` / `observe(drafted, accepted)`;
                                  defaults to a fixed-length `ngram_draft` of `max_draft`.

    Every step feeds the one token the model has predicted but not yet seen plus a draft of what
    should follow it; the model's predictions verify the draft position by position. Accepted
    tokens are exactly what one-token-at-a-time greedy decoding would have produced, and the
    rejected tail is trimmed from the cache before the next step, so the cache never carries a
    position the transcript does not. Returns the generated token ids, without the EOS.
    """
    generated = []
    if max_tokens <= 0:
        return generated
    context = list(prompt_tokens)
    next_token = step(context)[-1]
    while next_token not in eos_ids:
        generated.append(next_token)
        context.append(next_token)
        if len(generated) >= max_tokens:
            break
        budget = max_tokens - len(generated)
        if drafter is None:
            draft = ngram_draft(context, min(max_draft, budget))
        else:
            draft = drafter.draft(context, generated, budget)
        predictions = step([next_token] + draft)
        accepted = 0
        while accepted < len(draft) and predictions[accepted] == draft[accepted]:
            accepted += 1
        if drafter is not None:
            drafter.observe(len(draft), accepted)
        trim(len(draft) - accepted)
        stop = False
        for index, token in enumerate(draft[:accepted]):
            if token in eos_ids:
                # The chat template's own <|im_end|> is a legitimate draft source, so an accepted
                # draft can end the reply. Nothing after it belongs in the cache either.
                trim(accepted - index)
                stop = True
                break
            generated.append(token)
            context.append(token)
        if stop or len(generated) >= max_tokens:
            break
        next_token = predictions[accepted]
    return generated


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

    import mlx.core as mx

    model, tokenizer = load(args.model)
    sampler = make_sampler(temp=0.0)  # greedy: a cleanup should be reproducible, not sampled.
    eos_ids = set(tokenizer.eos_token_ids)

    def generate_fn(tokens, max_tokens, prompt_cache, source_tokens=None):
        if prompt_cache is None:
            # No trimmable cache: plain one-token-at-a-time decoding.
            pieces = []
            for response in stream_generate(
                model, tokenizer, tokens, max_tokens=max_tokens, sampler=sampler
            ):
                pieces.append(response.text)
            return _THINK_RE.sub("", "".join(pieces)).strip()

        # F212: prompt-lookup speculative decoding on the persistent cache. The 8B refiner decodes
        # ~27 tok/s one token at a time, ~30 ms per dictated word, so 40+ word dictations missed
        # their budget on every attempt. One forward pass over a token plus an 8-token draft costs
        # about the same as a single token on this bandwidth-bound model, and the draft — copied
        # from the dictated text already in the prompt — is right most of the time.
        def step(fed):
            logits = model(mx.array(fed, mx.uint32)[None], cache=prompt_cache)
            return mx.argmax(logits[0], axis=-1).tolist()

        def trim(count):
            if count > 0:
                trim_prompt_cache(prompt_cache, count)

        drafter = CopyDrafter(source_tokens)
        generated = lookup_generate(step, trim, tokens, max_tokens, eos_ids, drafter)
        text = tokenizer.decode(generated) if generated else ""
        return _THINK_RE.sub("", text).strip()

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
        # The dictated text as the model sees it inside the template — the draft source. The
        # template tokenizes the user turn on its own line, so its tokens appear verbatim; if a
        # tokenizer ever merged across that boundary, the drafter simply falls back to n-grams.
        user_tokens = tokenizer.encode(text) if text else []
        span = find_span(tokens, user_tokens)
        source = user_tokens if span is not None else []
        session.generate_source = source
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
