#!/usr/bin/env python3
"""Unit tests for the pure cache-reuse logic in Scripts/refine_server.py (F203).

Run: python3 Scripts/tests/test_refine_server.py

Imports only the helper's pure pieces (no mlx_lm import at module scope), mirroring
test_correct_local.py. The fake cache mimics the pinned mlx_lm==0.30.5 KVCache contract this
logic relies on: `offset` is the exact materialized token count and `trim(n)` min-clamps
(mlx_lm/models/cache.py:180-207); `trim_prompt_cache` returns the number trimmed.
"""

import importlib.util
import os
import unittest

_SCRIPT = os.path.join(os.path.dirname(__file__), "..", "refine_server.py")
_spec = importlib.util.spec_from_file_location("refine_server", _SCRIPT)
refine = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(refine)


class FakeCache:
    """Token-level stand-in for a prompt cache: stores actual token ids so tests can assert the
    cache CONTENT matches what the reuse logic believes it holds — the property that matters."""

    def __init__(self):
        self.tokens = []

    @property
    def offset(self):
        return len(self.tokens)


class FakeRig:
    def __init__(self, trimmable=True, fail_generation=False):
        self.trimmable = trimmable
        self.fail_generation = fail_generation
        self.fed = []            # token lists fed to generate, in order
        self.generated = [7, 8]  # token ids appended per generation

    def make_cache(self):
        return FakeCache()

    def can_trim(self, cache):
        return self.trimmable

    def trim(self, cache, n):
        n = min(len(cache.tokens), n)
        if n:
            cache.tokens = cache.tokens[:-n]
        return n

    def offset_of(self, cache):
        return cache.offset

    def generate_fn(self, tokens, max_tokens, cache):
        self.fed.append(list(tokens))
        if self.fail_generation:
            raise RuntimeError("boom")
        if cache is not None:
            cache.tokens.extend(tokens)
            cache.tokens.extend(self.generated)
        return "out"

    def session(self):
        return refine.RefineSession(
            make_cache=self.make_cache,
            can_trim=self.can_trim,
            trim=self.trim,
            offset_of=self.offset_of,
            generate_fn=self.generate_fn,
        )


class CommonPrefixTests(unittest.TestCase):
    def test_basic(self):
        self.assertEqual(refine.common_prefix_length([1, 2, 3], [1, 2, 9]), 2)
        self.assertEqual(refine.common_prefix_length([1, 2], [1, 2]), 2)
        self.assertEqual(refine.common_prefix_length([], [1]), 0)


class RefineSessionTests(unittest.TestCase):
    """The invariant: the cache's retained content always equals the fed prompt's prefix."""

    def test_second_request_feeds_only_the_suffix(self):
        rig = FakeRig()
        session = rig.session()
        session.run([1, 2, 3, 10, 11], 8)   # system prefix 1,2,3 + user 10,11
        session.run([1, 2, 3, 20, 21], 8)   # same system, new user text
        self.assertEqual(rig.fed[0], [1, 2, 3, 10, 11])
        self.assertEqual(rig.fed[1], [20, 21])  # only the new user suffix
        # Cache holds exactly prefix + fed suffix + generation.
        self.assertEqual(session.cache.tokens, [1, 2, 3, 20, 21, 7, 8])

    def test_generated_tokens_are_trimmed_by_ground_truth_offset(self):
        rig = FakeRig()
        session = rig.session()
        session.run([1, 2, 3, 10], 8)
        # offset now 4 prompt + 2 generated = 6; next request must trim 6 - 3 = 3.
        session.run([1, 2, 3, 30], 8)
        self.assertEqual(session.cache.tokens, [1, 2, 3, 30, 7, 8])

    def test_identical_prompt_still_feeds_the_final_token(self):
        rig = FakeRig()
        session = rig.session()
        session.run([1, 2, 3, 10], 8)
        session.run([1, 2, 3, 10], 8)
        self.assertEqual(rig.fed[1], [10])

    def test_untrimmable_cache_falls_back_to_plain_generation(self):
        rig = FakeRig(trimmable=False)
        session = rig.session()
        session.run([1, 2, 3], 8)
        session.run([1, 2, 4], 8)
        self.assertEqual(rig.fed, [[1, 2, 3], [1, 2, 4]])  # full prompt both times
        self.assertIs(session.cache, False)

    def test_generation_error_resets_the_cache(self):
        rig = FakeRig()
        session = rig.session()
        session.run([1, 2, 3, 10], 8)
        rig.fail_generation = True
        with self.assertRaises(RuntimeError):
            session.run([1, 2, 3, 20], 8)
        self.assertIsNone(session.cache)  # never reuse a cache in an unknown state
        rig.fail_generation = False
        session.run([1, 2, 3, 30], 8)
        self.assertEqual(rig.fed[-1], [1, 2, 3, 30])  # rebuilt from scratch


class ProvenanceCache(FakeCache):
    """F630: also records, per position, which feed computed it. A real KV entry's value depends
    on the chunk it was computed in (a batched matmul does not round like a one-token one), so the
    same tokens computed by a different feed are not the same cache."""

    def __init__(self, tokens=(), origins=()):
        super().__init__()
        self.tokens = list(tokens)
        self.origins = list(origins)


class AnchorRig(FakeRig):
    """The session's collaborators over a ProvenanceCache. Every prompt below is a system prompt
    plus a user turn; `PREFIXES` says where each one's user turn starts, as `find_last_span` does
    in the real helper."""

    def __init__(self):
        super().__init__()
        self.current = None    # label of the feed in progress
        self.prefills = []     # the token lists prefilled, in order
        self.prefix_of = {}

    def make_cache(self):
        return ProvenanceCache()

    def trim(self, cache, n):
        n = super().trim(cache, n)
        if n:
            cache.origins = cache.origins[:-n]
        return n

    def generate_fn(self, tokens, max_tokens, cache):
        text = super().generate_fn(tokens, max_tokens, cache)
        if cache is not None:
            cache.origins.extend([self.current] * (len(tokens) + len(self.generated)))
        return text

    def prefill(self, tokens, cache):
        self.prefills.append(list(tokens))
        cache.tokens.extend(tokens)
        cache.origins.extend([("prefill", tuple(tokens))] * len(tokens))

    def snapshot(self, cache, n):
        return list(cache.tokens[:n]), list(cache.origins[:n])

    def restore(self, snapshot, n):
        tokens, origins = snapshot
        return ProvenanceCache(tokens[:n], origins[:n])

    def session(self):
        return refine.RefineSession(
            make_cache=self.make_cache,
            can_trim=self.can_trim,
            trim=self.trim,
            offset_of=self.offset_of,
            generate_fn=self.generate_fn,
            prefill=self.prefill,
            snapshot=self.snapshot,
            restore=self.restore,
        )

    def run(self, session, tokens, prefix_length):
        self.current = ("request", tuple(tokens))
        return session.run(list(tokens), 8, prefix_length=prefix_length)


GENERIC_SYSTEM = (1, 2, 3, 4, 5)        # the generic system prompt and the user header
PINNED_SYSTEM = (1, 2, 3, 4, 6, 7)      # a longer system prompt: leaves the generic one at 4
PRIME = GENERIC_SYSTEM + (90,)          # the app's prime: "ready" under the generic prompt
GENERIC = GENERIC_SYSTEM + (10, 11)     # a dictation under the generic prompt
LOOKALIKE = GENERIC_SYSTEM + (10, 12)   # shares MORE with GENERIC than the prime does
PINNED = PINNED_SYSTEM + (20, 21)       # a dictation under the pinned prompt


def prefix(tokens):
    return len(PINNED_SYSTEM) if tokens[:len(PINNED_SYSTEM)] == PINNED_SYSTEM else len(GENERIC_SYSTEM)


class AnchoredSessionTests(unittest.TestCase):
    """F630: a request's reply must not depend on the requests before it on the same helper.

    Measured on the installed Qwen3-8B-4bit: one primed helper, the same 30 requests in six seeded
    orders — two requests came back different in two orders each, one of them translated ("Our
    deadline is this Friday." for "我们的 deadline 是这个星期五。"). Reusing the common prefix with the
    PREVIOUS request means a request reuses cache entries an earlier dictation computed, in a chunk
    that dictation chose, and feeds the rest from wherever that dictation diverged. The rule now:
    each system prompt's prefix is computed once, from a fixed base (the first prefix, alone on an
    empty cache), and every request starts from its prefix's snapshot and feeds its own turn in
    one chunk.
    """

    def what_generic_sees(self, history):
        """(tokens GENERIC's request fed, who computed each cache entry it reused)."""
        rig = AnchorRig()
        session = rig.session()
        for tokens in (PRIME,) + tuple(history):
            rig.run(session, tokens, prefix(tokens))
        rig.run(session, GENERIC, prefix(GENERIC))
        fed = rig.fed[-1]
        reused = len(GENERIC) - len(fed)
        return fed, session.cache.origins[:reused]

    def test_a_request_sees_the_same_cache_whatever_came_before(self):
        fresh = self.what_generic_sees([])
        for history in ([PINNED], [LOOKALIKE], [GENERIC], [PINNED, LOOKALIKE, PINNED]):
            with self.subTest(history=history):
                self.assertEqual(self.what_generic_sees(history), fresh)
        # And what that one cache is: the prompt's own prefill, then the dictation's own turn.
        self.assertEqual(fresh, ([10, 11], [("prefill", GENERIC_SYSTEM)] * 5))

    def test_a_new_prompt_is_built_once_from_the_base_and_then_reused_whole(self):
        rig = AnchorRig()
        session = rig.session()
        for tokens in (PRIME, PINNED, GENERIC, PINNED):
            rig.run(session, tokens, prefix(tokens))
        # The prime's prompt alone on an empty cache (the base); the pinned prompt as the base's
        # shared part plus one prefill of its own sentences, not the whole prompt again.
        self.assertEqual(rig.prefills, [list(GENERIC_SYSTEM), [6, 7]])
        # The second pinned dictation reuses its whole system prompt, language sentences included.
        self.assertEqual(rig.fed[-1], [20, 21])
        self.assertEqual(session.cache.origins[:6],
                         [("prefill", GENERIC_SYSTEM)] * 4 + [("prefill", (6, 7))] * 2)

    def test_a_new_prompt_is_built_the_same_whatever_came_before(self):
        def what_pinned_sees(history):
            rig = AnchorRig()
            session = rig.session()
            for tokens in (PRIME,) + tuple(history) + (PINNED,):
                rig.run(session, tokens, prefix(tokens))
            fed = rig.fed[-1]
            return fed, session.cache.origins[:len(PINNED) - len(fed)]

        first = what_pinned_sees([])
        for history in ([GENERIC], [LOOKALIKE, GENERIC], [GENERIC, GENERIC, LOOKALIKE]):
            with self.subTest(history=history):
                self.assertEqual(what_pinned_sees(history), first)

    def test_an_anchor_survives_a_generation_error(self):
        rig = AnchorRig()
        session = rig.session()
        rig.run(session, PRIME, prefix(PRIME))
        rig.fail_generation = True
        with self.assertRaises(RuntimeError):
            rig.run(session, PINNED, prefix(PINNED))
        rig.fail_generation = False
        rig.run(session, GENERIC, prefix(GENERIC))
        self.assertEqual(rig.fed[-1], [10, 11])
        self.assertEqual(rig.prefills, [list(GENERIC_SYSTEM), [6, 7]])

    def test_a_request_with_no_prefix_starts_from_an_empty_cache(self):
        # find_last_span found no dictated text in the prompt: no reuse rather than reuse of
        # whatever the previous request left.
        rig = AnchorRig()
        session = rig.session()
        rig.run(session, PRIME, prefix(PRIME))
        rig.run(session, GENERIC, None)
        self.assertEqual(rig.fed[-1], list(GENERIC))

    def test_forget_drops_every_anchor(self):
        rig = AnchorRig()
        session = rig.session()
        rig.run(session, PRIME, prefix(PRIME))
        session.forget()
        rig.run(session, GENERIC, prefix(GENERIC))
        self.assertEqual(rig.prefills, [list(GENERIC_SYSTEM), list(GENERIC_SYSTEM)])

    def test_a_cache_the_snapshot_declines_falls_back_to_the_previous_rule(self):
        # main()'s snapshot answers None for any cache type it cannot restore faithfully.
        rig = AnchorRig()
        rig.snapshot = lambda cache, n: None
        session = rig.session()
        for tokens in (PRIME, PINNED, GENERIC):
            rig.run(session, tokens, prefix(tokens))
        self.assertEqual(session.anchors, {})
        self.assertEqual(rig.fed[-1], [5, 10, 11])

    def test_without_the_collaborators_the_session_reuses_the_previous_request_as_before(self):
        rig = FakeRig()
        session = rig.session()
        for tokens in (PRIME, PINNED, GENERIC):
            session.run(list(tokens), 8, prefix_length=prefix(tokens))
        self.assertEqual(rig.fed[-1], [5, 10, 11])


class AnchorEvictionTests(unittest.TestCase):
    """F851: past MAX_ANCHORS the oldest anchor is dropped, the base never is, and a dropped prompt
    comes back exactly as it was the first time — eviction costs time, not determinism."""

    @staticmethod
    def system(i):
        return (1, 2, 3, 4, 100 + i, 200 + i)   # shares 1, 2, 3, 4 with the generic prompt

    def prefix_of(self, tokens):
        return 6 if tokens[4] >= 100 else len(GENERIC_SYSTEM)

    def test_the_oldest_anchor_is_evicted_and_rebuilt_the_same_from_the_base(self):
        rig = AnchorRig()
        session = rig.session()
        rig.run(session, PRIME, len(GENERIC_SYSTEM))
        prompts = [self.system(i) + (50 + i,) for i in range(refine.RefineSession.MAX_ANCHORS)]
        for tokens in prompts:
            rig.run(session, tokens, self.prefix_of(tokens))
        # The prime's anchor and eight more is nine: the prime's — the oldest — was dropped.
        self.assertEqual(len(session.anchors), refine.RefineSession.MAX_ANCHORS)
        self.assertNotIn(GENERIC_SYSTEM, session.anchors)
        self.assertEqual(session.base[0], GENERIC_SYSTEM, "the base must never be evicted")

        first_build = rig.prefills[1]
        rig.run(session, prompts[0], 6)
        reused_before = session.cache.origins[:6]
        prefills_so_far = len(rig.prefills)
        rig.run(session, GENERIC, len(GENERIC_SYSTEM))   # evicted: rebuilt from the base
        self.assertEqual(len(rig.prefills), prefills_so_far, "the generic prompt IS the base: nothing to prefill")
        self.assertEqual(rig.fed[-1], [10, 11])
        self.assertEqual(session.cache.origins[:5], [("prefill", GENERIC_SYSTEM)] * 5)
        # It is back, and now another one is out: still the bound.
        self.assertIn(GENERIC_SYSTEM, session.anchors)
        self.assertEqual(len(session.anchors), refine.RefineSession.MAX_ANCHORS)
        self.assertNotIn(self.system(0), session.anchors)

        # The prompt evicted second comes back as its first build made it: the base's shared part
        # plus the same one prefill of its own sentences.
        rig.run(session, prompts[0], 6)
        self.assertEqual(rig.prefills[-1], first_build)
        self.assertEqual(session.cache.origins[:6], reused_before)


class _FakeBuffer:
    """A KV buffer `steps` long; indexing it as the snapshot does returns a VIEW of it."""

    def __init__(self, steps):
        self.steps = steps

    def __getitem__(self, index):
        return _FakeView(self, index[1].stop)


class _FakeView:
    def __init__(self, buffer, count):
        self.buffer = buffer
        self.count = count


class _FakeCompact:
    def __init__(self, count):
        self.count = count


def _fake_contiguous(array):
    """mx.contiguous's contract for a strided slice: a copy of only the sliced positions."""
    return _FakeCompact(array.count) if isinstance(array, _FakeView) else array


class _FakeKVCache:
    def __init__(self, steps):
        self.keys = _FakeBuffer(steps)
        self.values = _FakeBuffer(steps)


class CompactSnapshotTests(unittest.TestCase):
    """F851: an anchor kept as slices of its cache's buffer pins the whole buffer — measured on the
    installed Qwen3-8B, ~54 MiB per anchor built from the base where its ~19 MiB of prompt would do.
    The snapshot keeps compact copies of exactly the anchored positions."""

    def test_an_anchor_holds_copies_of_its_positions_not_views_of_the_buffer(self):
        cache = [_FakeKVCache(377) for _ in range(3)]
        evaluated = []
        layers = refine.snapshot_kv_layers(cache, 121, _FakeKVCache, _fake_contiguous, evaluated.append)
        self.assertEqual(len(layers), 3)
        for keys, values in layers:
            for array in (keys, values):
                self.assertIsInstance(array, _FakeCompact, "an anchor still references its cache's buffer")
                self.assertEqual(array.count, 121)
        self.assertEqual(evaluated, [layers], "the copies must be evaluated now, while the cache is intact")

    def test_any_other_cache_type_is_not_anchored(self):
        self.assertIsNone(refine.snapshot_kv_layers(
            [_FakeKVCache(256), object()], 10, _FakeKVCache, _fake_contiguous, lambda _: None))


class FindLastSpanTests(unittest.TestCase):
    def test_the_last_occurrence_is_the_user_turn(self):
        # A dictation that repeats words of the system prompt ("you know") is found after it.
        self.assertEqual(refine.find_last_span([7, 8, 1, 2, 9, 1, 2, 3], [1, 2]), 5)
        self.assertIsNone(refine.find_last_span([1, 2], []))
        self.assertIsNone(refine.find_last_span([1, 2], [3]))


EOS = 999


class TruthModel:
    """A fake model for `lookup_generate` (F212) whose predictions depend on the cache CONTENT.

    `truth` is the whole sequence the model 'believes in' (prompt + reply + EOS). After feeding a
    token at cache position i, the model predicts truth[i+1] — but only if the token actually at
    position i is truth[i]; a stale or wrong token in the cache yields a garbage prediction. So a
    draft that was rejected but not trimmed, or trimmed by the wrong amount, corrupts every later
    prediction instead of being silently tolerated.
    """

    GARBAGE = -1

    def __init__(self, truth):
        self.truth = list(truth)
        self.cache = []
        self.steps = 0

    def step(self, fed):
        self.steps += 1
        predictions = []
        for token in fed:
            self.cache.append(token)
            i = len(self.cache) - 1
            if i < len(self.truth) and self.cache[i] == self.truth[i] and i + 1 < len(self.truth):
                predictions.append(self.truth[i + 1])
            else:
                predictions.append(self.GARBAGE)
        return predictions

    def trim(self, n):
        assert 0 <= n <= len(self.cache), (n, len(self.cache))
        if n:
            del self.cache[-n:]


class NgramDraftTests(unittest.TestCase):
    def test_draft_is_the_continuation_of_the_latest_earlier_match(self):
        #            0  1  2  3  4  5  6  7  8
        sequence = [1, 2, 3, 4, 5, 1, 2, 3, 9, 1, 2, 3]
        # Trigram [1,2,3] last occurred at 5 (followed by 9), before that at 0 (followed by 4).
        self.assertEqual(refine.ngram_draft(sequence, 4), [9, 1, 2, 3])

    def test_falls_back_to_a_bigram_when_no_trigram_matches(self):
        sequence = [7, 8, 20, 21, 5, 8, 20]
        self.assertEqual(refine.ngram_draft(sequence, 3), [21, 5, 8])

    def test_no_match_or_no_budget_gives_an_empty_draft(self):
        self.assertEqual(refine.ngram_draft([1, 2, 3, 4], 4), [])
        self.assertEqual(refine.ngram_draft([1, 2, 1, 2], 0), [])
        self.assertEqual(refine.ngram_draft([1, 2], 4), [])

    def test_draft_respects_max_draft(self):
        sequence = [1, 2, 3, 4, 5, 6, 7, 1, 2, 3]
        self.assertEqual(refine.ngram_draft(sequence, 2), [4, 5])


class SourcePointerTests(unittest.TestCase):
    SOURCE = [10, 11, 12, 13, 14, 15, 16, 17]

    def test_exact_copy_advances_one_per_token(self):
        self.assertEqual(refine.source_pointer(self.SOURCE, [10, 11, 12]), 3)
        self.assertEqual(refine.source_draft(self.SOURCE, [10, 11, 12], 3), [13, 14, 15])

    def test_inserted_token_leaves_the_pointer_alone(self):
        # Punctuation the model added has no source counterpart.
        self.assertEqual(refine.source_pointer(self.SOURCE, [10, 11, 999]), 2)
        self.assertEqual(refine.source_draft(self.SOURCE, [10, 11, 999], 2), [12, 13])

    def test_substituted_token_is_skipped_when_the_next_one_matches(self):
        # "we" -> "We": 777 replaces 12, then 13 re-syncs past it.
        self.assertEqual(refine.source_pointer(self.SOURCE, [10, 11, 777, 13]), 4)

    def test_removed_fillers_within_the_window_are_skipped(self):
        # 11, 12 and 13 dropped ("um", "you know"): 14 is found within the window.
        self.assertEqual(refine.source_pointer(self.SOURCE, [10, 14]), 5)
        self.assertEqual(refine.source_pointer(self.SOURCE, [10, 16], window=4), 1)  # 16 is 5 away

    def test_beyond_the_window_the_pointer_holds_and_the_draft_runs_out(self):
        self.assertEqual(refine.source_pointer(self.SOURCE, [10, 17], window=4), 1)
        self.assertEqual(refine.source_draft(self.SOURCE, [10, 11, 12, 13, 14, 15, 16, 17], 4), [])
        self.assertEqual(refine.source_draft([], [10], 4), [])
        self.assertEqual(refine.source_draft(self.SOURCE, [10], 0), [])

    def test_find_span(self):
        self.assertEqual(refine.find_span([1, 2, 3, 4, 5], [3, 4]), 2)
        self.assertIsNone(refine.find_span([1, 2, 3], [3, 4]))
        self.assertIsNone(refine.find_span([1, 2], []))


class CopyDrafterTests(unittest.TestCase):
    def test_length_adapts_to_acceptance(self):
        drafter = refine.CopyDrafter([1, 2, 3, 4, 5, 6, 7, 8, 9], initial=4, minimum=2, maximum=6)
        self.assertEqual(drafter.draft([], [], 10), [1, 2, 3, 4])
        drafter.observe(4, 4)
        self.assertEqual(drafter.draft([], [1, 2, 3, 4], 10), [5, 6, 7, 8, 9])  # 6 asked, 5 left
        drafter.observe(5, 0)
        self.assertEqual(drafter.draft([], [1, 2, 3, 4], 10), [5, 6, 7, 8])      # back to 4
        drafter.observe(4, 0)
        self.assertEqual(drafter.draft([], [1, 2, 3, 4], 10), [5, 6])            # floor 2
        drafter.observe(2, 1)
        self.assertEqual(drafter.draft([], [1, 2, 3, 4], 1), [5])                # budget wins
        drafter.observe(0, 0)                                                     # no draft: no change
        self.assertEqual(drafter.length, 2)

    def test_falls_back_to_ngrams_once_the_source_is_used_up(self):
        drafter = refine.CopyDrafter([1, 2, 3])
        context = [1, 2, 3, 40, 1, 2, 3]
        self.assertEqual(drafter.draft(context, [1, 2, 3], 4), [40, 1, 2, 3])


class LookupGenerateTests(unittest.TestCase):
    SYSTEM = [100, 101, 102, 103, EOS]           # "system ... <|im_end|>"
    USER = [10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25]

    def prompt(self):
        return self.SYSTEM + [200] + self.USER + [EOS, 201]  # user text, <|im_end|>, assistant tag

    def run_model(self, reply, max_tokens=256, max_draft=8, drafter=None):
        prompt = self.prompt()
        model = TruthModel(prompt + reply + [EOS])
        generated = refine.lookup_generate(
            model.step, model.trim, prompt, max_tokens, {EOS}, drafter, max_draft=max_draft
        )
        return model, generated

    def test_copy_drafter_follows_the_dictated_text_through_edits(self):
        # Capitalised first token (substitution), a removed filler, an inserted punctuation token.
        reply = [77, 11, 12, 14, 15, 16, 17, 18, 500, 19, 20, 21, 22, 23, 24, 25]
        drafter = refine.CopyDrafter(self.USER)
        model, generated = self.run_model(reply, drafter=drafter)
        self.assertEqual(generated, reply)
        self.assertEqual(model.cache, model.truth[:len(model.cache)])
        # 16 tokens with three edits still needs well under one step per token.
        self.assertLess(model.steps, 10)

    def test_copy_drafter_without_a_source_uses_ngrams(self):
        drafter = refine.CopyDrafter([])
        model, generated = self.run_model(list(self.USER), drafter=drafter)
        self.assertEqual(generated, self.USER)
        self.assertLess(model.steps, len(self.USER) // 2)

    def test_verbatim_copy_is_exact_and_needs_far_fewer_steps_than_tokens(self):
        model, generated = self.run_model(list(self.USER))
        self.assertEqual(generated, self.USER)
        # 16 tokens copied from the prompt: 1 prefill + a handful of verified 8-token drafts,
        # not one step per token.
        self.assertLess(model.steps, len(self.USER) // 2)

    def test_edits_inside_the_copy_are_verified_not_guessed(self):
        reply = [10, 11, 12, 77, 14, 15, 16, 88, 89, 17, 18, 19, 20, 21, 22, 23, 24, 25]
        model, generated = self.run_model(reply)
        self.assertEqual(generated, reply)

    def test_cache_never_holds_a_rejected_or_post_eos_token(self):
        reply = [10, 11, 12, 77, 14, 15, 16, 17, 18, 19, 20, 21, 22, 23, 24, 25]
        model, generated = self.run_model(reply)
        self.assertEqual(generated, reply)
        # The cache is a clean prefix of the true sequence — nothing stale, nothing past the EOS.
        self.assertEqual(model.cache, model.truth[:len(model.cache)])
        self.assertNotIn(EOS, model.cache[len(self.prompt()):])

    def test_eos_drafted_from_the_prompt_ends_the_reply(self):
        # The copied user text is followed by <|im_end|> in the prompt, so the draft that finishes
        # the copy also drafts the EOS; the model agrees, and generation must stop there.
        model, generated = self.run_model(list(self.USER))
        self.assertEqual(generated, self.USER)
        self.assertNotIn(EOS, generated)

    def test_max_tokens_caps_the_reply_even_mid_draft(self):
        model, generated = self.run_model(list(self.USER), max_tokens=5)
        self.assertEqual(generated, self.USER[:5])
        model, generated = self.run_model(list(self.USER), max_tokens=0)
        self.assertEqual(generated, [])

    def test_no_match_degrades_to_plain_greedy(self):
        reply = [300, 301, 302, 303]  # nothing in the prompt to draft from
        model, generated = self.run_model(reply)
        self.assertEqual(generated, reply)
        self.assertEqual(model.steps, 1 + len(reply))

    def test_wrong_trim_would_be_detected(self):
        # Sanity check on the fake: a loop that forgets to trim rejected drafts diverges.
        reply = [10, 11, 12, 77, 14, 15, 16, 17, 18]
        prompt = self.prompt()
        model = TruthModel(prompt + reply + [EOS])
        generated = refine.lookup_generate(
            model.step, lambda n: None, prompt, 256, {EOS}, max_draft=8
        )
        self.assertNotEqual(generated, reply)


if __name__ == "__main__":
    unittest.main(verbosity=2)
