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


if __name__ == "__main__":
    unittest.main(verbosity=2)
