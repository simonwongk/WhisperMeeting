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
