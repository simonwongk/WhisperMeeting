#!/usr/bin/env python3
"""F440 — 'Repair or Update' on the local summarizer deleted Ask Meetings' embedding model.

Run: python3 Scripts/tests/test_f440_summarizer_embedding_model.py

setup-ask-embeddings.sh installs the 490 MB search-by-meaning model into
`Runtime/Summarizer/embedding-model` — INSIDE the directory setup-local-summarizer.sh treats as its
own and replaces wholesale on every "Repair or Update" (`mv target backup; mv staging target;
rm -rf backup`). A repair therefore deleted the embedding model with it.

**Running the real, unmodified swap logic — not a duplicate.** The full script cannot run
end-to-end here without Homebrew, a network fetch and a multi-GB model download, none of which
belong in a unit test. Rather than hand-copy the swap into a fixture (which would test the
duplicate, not the script), this extracts the exact current text of the swap block — from the
`# F440:` comment through `activation_complete=1` — with a regex anchored on stable substrings, and
runs it verbatim against a temp-root layout standing in for the real one: an existing
`Summarizer/` (the "before repair" state, complete with `embedding-model/`) and a pre-built
`staging` directory (standing in for what the skipped venv/pip/download steps would have produced).
A future edit that reintroduces the bug — reverting to a bare `mv staging target` with no carry —
fails this without anyone maintaining a second copy of the logic.
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

_SWAP_PATTERN = re.compile(
    r"# F440: setup-ask-embeddings\.sh installs Ask Meetings.*?\nactivation_complete=1\n",
    re.DOTALL,
)


def _extract_swap_block():
    with open(_SOURCE, encoding="utf-8") as handle:
        source = handle.read()
    match = _SWAP_PATTERN.search(source)
    if match is None:
        raise AssertionError(
            "could not find the F440 swap block in setup-local-summarizer.sh; did it move or "
            "get reworded? Update the anchor regex to match."
        )
    return match.group(0)


def _write_file(path, content=""):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(content)


def _write_executable(path, body):
    _write_file(path, body)
    os.chmod(path, os.stat(path).st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


class SummarizerSwapPreservesEmbeddingModelTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="whispermeet-f440-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.target_directory = os.path.join(self.tmp, "Summarizer")
        self.staging_directory = os.path.join(self.tmp, ".Summarizer-install-12345")
        self.backup_directory = os.path.join(self.tmp, ".Summarizer-backup-12345")

    def _run_swap(self, target_has_embedding_model):
        # The "before repair" Summarizer/: a complete-looking prior install, with (or without)
        # Ask's embedding model already installed alongside it — exactly where
        # setup-ask-embeddings.sh puts it, and exactly the layout the real script's
        # `runtime_is_complete` predicate checks.
        _write_executable(
            os.path.join(self.target_directory, "venv", "bin", "python"), "#!/bin/sh\nexit 0\n"
        )
        _write_file(os.path.join(self.target_directory, "summarize_local.py"), "old helper")
        _write_file(
            os.path.join(self.target_directory, "model", "model.safetensors"), "old model bytes"
        )
        if target_has_embedding_model:
            _write_file(
                os.path.join(self.target_directory, "embedding-model", "model.safetensors"),
                "the 490 MB search-by-meaning model — must survive a repair",
            )
            _write_file(
                os.path.join(self.target_directory, "embedding-model", "tokenizer.json"), "{}"
            )

        # The "after download" staging/: what the real script would have built via venv/pip/HF —
        # skipped here since none of that is what this ticket is about.
        _write_executable(
            os.path.join(self.staging_directory, "venv", "bin", "python"), "#!/bin/sh\nexit 0\n"
        )
        _write_file(os.path.join(self.staging_directory, "summarize_local.py"), "new helper")
        _write_file(
            os.path.join(self.staging_directory, "model", "model.safetensors"), "new model bytes"
        )

        script = "\n".join([
            "#!/bin/zsh",
            "set -euo pipefail",
            'target_directory="{}"'.format(self.target_directory),
            'staging_directory="{}"'.format(self.staging_directory),
            'backup_directory="{}"'.format(self.backup_directory),
            _extract_swap_block(),
            'print "swap finished, activation_complete=$activation_complete"',
        ])
        script_path = os.path.join(self.tmp, "run-swap.sh")
        _write_executable(script_path, script)
        return subprocess.run([script_path], capture_output=True, text=True)

    def test_a_repair_with_search_by_meaning_installed_keeps_the_embedding_model(self):
        result = self._run_swap(target_has_embedding_model=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

        # The property this ticket exists for: the embedding model is still there, and it is the
        # SAME one (content-identical), not a stray new directory.
        preserved = os.path.join(self.target_directory, "embedding-model", "model.safetensors")
        self.assertTrue(os.path.isfile(preserved), "embedding-model did not survive the repair")
        with open(preserved, encoding="utf-8") as handle:
            self.assertEqual(
                handle.read(),
                "the 490 MB search-by-meaning model — must survive a repair",
            )
        self.assertTrue(
            os.path.isfile(
                os.path.join(self.target_directory, "embedding-model", "tokenizer.json")
            )
        )

        # The repair itself still happened — the new summarizer content is live.
        with open(os.path.join(self.target_directory, "summarize_local.py"), encoding="utf-8") as handle:
            self.assertEqual(handle.read(), "new helper")

        # Nothing was left behind in a directory named for the old staging path.
        self.assertFalse(os.path.exists(self.staging_directory))

    def test_a_repair_with_no_search_by_meaning_installed_is_unaffected(self):
        """The common case today: most Macs have not installed Ask's embedding model at all."""
        result = self._run_swap(target_has_embedding_model=False)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(
            os.path.exists(os.path.join(self.target_directory, "embedding-model")),
            "no embedding-model should be conjured out of nothing",
        )
        with open(os.path.join(self.target_directory, "summarize_local.py"), encoding="utf-8") as handle:
            self.assertEqual(handle.read(), "new helper")


class SwapBlockCanaryTests(unittest.TestCase):
    """The extraction anchor itself must keep matching the real file."""

    def test_the_swap_block_is_found_in_the_real_script(self):
        block = _extract_swap_block()
        self.assertIn('mv "$target_directory/embedding-model"', block)
        self.assertIn('mv "$staging_directory" "$target_directory"', block)


if __name__ == "__main__":
    unittest.main(verbosity=2)
