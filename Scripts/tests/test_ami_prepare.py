#!/usr/bin/env python3
"""F490 part 2 — resample_to_16k_mono's docstring pointed at a `--strict` refusal mode that does
not exist.

Run: python3 Scripts/tests/test_ami_prepare.py

The docstring said a non-16 kHz/mono shard gets nearest-neighbour decimation and "`--strict`
refuses instead" — but `build_parser` has only ever defined `--manifest`, `--out`, `--gap` and
`--self-test`. A reader pointed at that safeguard by the docstring, while working on a different
function in the same file (F418), gets `argparse: error: unrecognized arguments: --strict` and no
such refusal mode to fall back on.
"""

import importlib.util
import os
import sys
import unittest

_HERE = os.path.dirname(os.path.abspath(__file__))
_MODULE_PATH = os.path.normpath(
    os.path.join(_HERE, "..", "bench", "diarization", "ami_prepare.py")
)


def _load_module():
    spec = importlib.util.spec_from_file_location("ami_prepare", _MODULE_PATH)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


class StrictFlagClaimTests(unittest.TestCase):
    def setUp(self):
        self.module = _load_module()

    def test_the_docstring_no_longer_claims_a_nonexistent_strict_flag(self):
        doc = self.module.resample_to_16k_mono.__doc__ or ""
        self.assertNotIn(
            "refuses instead", doc,
            "resample_to_16k_mono's docstring must not claim a --strict flag exists when "
            "build_parser does not define one",
        )

    def test_build_parser_genuinely_has_no_strict_flag(self):
        parser = self.module.build_parser()
        with self.assertRaises(SystemExit):
            # argparse writes its error to stderr and calls sys.exit(2); redirect stderr so the
            # test's own output stays clean.
            original_stderr = sys.stderr
            sys.stderr = open(os.devnull, "w")
            try:
                parser.parse_args(["--strict"])
            finally:
                sys.stderr.close()
                sys.stderr = original_stderr


if __name__ == "__main__":
    unittest.main(verbosity=2)
