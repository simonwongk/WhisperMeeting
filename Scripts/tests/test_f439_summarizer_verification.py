#!/usr/bin/env python3
"""F439 part 1 — the summarizer installer's pre-swap verification could not fail on a broken
mlx_lm install.

Run: python3 Scripts/tests/test_f439_summarizer_verification.py

`summarize_local.py`, `correct_local.py` and `refine_server.py` all call `parser.parse_args()` —
which `--help` short-circuits via argparse's own `sys.exit(0)` — BEFORE their deferred
`from mlx_lm import ...`, so those helpers stay importable in WhisperCore-style tests without
mlx_lm installed. That is also exactly why `--help` on all three, the only check
`setup-local-summarizer.sh` ran between `pip install mlx-lm==$mlx_lm_version` and deleting the
previous runtime, could never detect a broken or incompatible mlx_lm install: none of the three
ever reach the import.

**Extracts and runs the real verification lines**, not a duplicate: from the first `--help` line
through the `python -c` import check this ticket adds, read out of the current
setup-local-summarizer.sh with a regex anchored on stable substrings. Run against a staged
directory with a controllable stub `venv/bin/python` — one that answers `--help` successfully but
fails a real `import mlx_lm` the way a broken pip resolution would.
"""

import os
import re
import shutil
import stat
import subprocess
import tempfile
import unittest

_HERE = os.path.dirname(os.path.abspath(__file__))
_SCRIPTS = os.path.normpath(os.path.join(_HERE, ".."))
_SOURCE = os.path.join(_SCRIPTS, "setup-local-summarizer.sh")

_VERIFICATION_PATTERN = re.compile(
    r'"\$staging_directory/venv/bin/python" "\$staging_directory/summarize_local\.py" --help.*?'
    r"\n'\n",
    re.DOTALL,
)


def _extract_verification_block():
    with open(_SOURCE, encoding="utf-8") as handle:
        source = handle.read()
    match = _VERIFICATION_PATTERN.search(source)
    if match is None:
        raise AssertionError(
            "could not find the pre-swap verification block in setup-local-summarizer.sh; did it "
            "move? Update the anchor regex to match."
        )
    return match.group(0)


def _write_file(path, content=""):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(content)


def _write_executable(path, body):
    _write_file(path, body)
    os.chmod(path, os.stat(path).st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


class SummarizerVerificationTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="whispermeet-f439-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.staging_directory = os.path.join(self.tmp, ".Summarizer-install-12345")
        for name in ("summarize_local.py", "correct_local.py", "refine_server.py"):
            _write_file(os.path.join(self.staging_directory, name), "# stub helper, not run\n")

    def _run_verification(self, python_stub):
        _write_executable(
            os.path.join(self.staging_directory, "venv", "bin", "python"), python_stub
        )
        script = "\n".join([
            "#!/bin/zsh",
            "set -euo pipefail",
            'staging_directory="{}"'.format(self.staging_directory),
            _extract_verification_block(),
            'print "verification passed"',
        ])
        script_path = os.path.join(self.tmp, "run-verification.sh")
        _write_executable(script_path, script)
        return subprocess.run([script_path], capture_output=True, text=True)

    def test_a_broken_mlx_lm_install_fails_verification(self):
        """The property this ticket adds: a python whose --help works but whose mlx_lm import
        fails (a broken pip resolution, reproduced here without actually installing one) must
        fail BEFORE the swap, not silently pass."""
        python_stub = "\n".join([
            "#!/bin/sh",
            'if [ "$1" = "--help" ] || [ "$2" = "--help" ]; then exit 0; fi',
            'if [ "$1" = "-c" ]; then',
            "  echo 'ModuleNotFoundError: broken transitive dependency' >&2",
            "  exit 1",
            "fi",
            "exit 0",
        ])
        result = self._run_verification(python_stub)
        self.assertNotEqual(
            result.returncode, 0,
            "verification must fail when mlx_lm cannot actually be imported: " + result.stdout,
        )
        self.assertNotIn("verification passed", result.stdout)

    def test_a_working_mlx_lm_install_passes_verification(self):
        python_stub = "#!/bin/sh\nexit 0\n"
        result = self._run_verification(python_stub)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("verification passed", result.stdout)


class VerificationBlockCanaryTests(unittest.TestCase):
    def test_the_verification_block_actually_imports_mlx_lm(self):
        block = _extract_verification_block()
        self.assertIn("--help", block)
        self.assertIn("from mlx_lm import load, stream_generate", block)
        self.assertIn("from mlx_lm.sample_utils import make_sampler", block)


if __name__ == "__main__":
    unittest.main(verbosity=2)
