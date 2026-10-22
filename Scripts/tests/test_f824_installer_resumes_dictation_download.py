#!/usr/bin/env python3
"""F824 — the installer's Quick Dictation model pre-download restarted 1.6 GB after any Cancel.

Run: python3 Scripts/tests/test_f824_installer_resumes_dictation_download.py

`setup-local-whisper.sh` used the library's `snapshot_download` into `.dictation-model-staging-$$`,
which cannot resume across processes (`file_download.py:1908` in huggingface_hub 1.24.0), in a
directory named for the run that every Cancel and every launch deleted. It now runs the helper's own
resumable download, `ensure_dictation_model`, into the model's cache where it lies.

These tests run the REAL block, extracted from the script as the F626 suite extracts it, with a real
python standing in for the staging venv's, against `test_dictation_model_download.FakeHub` — a local
server with the Hub's shapes for these two files, whose CDN path honours `Range` and can cut a
connection part-way. Only the pinned hashes are swapped for the fake model's, as F626's tests do; the
revision is the real pin, which the fake hub serves. No network, no huggingface_hub, no installed
runtime.
"""

import hashlib
import os
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time
import unittest

_HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, _HERE)
from test_dictation_model_download import COMMIT, CONFIG, CONFIG_SHA256, WEIGHTS, WEIGHTS_SHA256, FakeHub  # noqa: E402

_SCRIPTS = os.path.normpath(os.path.join(_HERE, ".."))
_SOURCE = os.path.join(_SCRIPTS, "setup-local-whisper.sh")
REPOSITORY_FOLDER = "models--mlx-community--whisper-large-v3-turbo"

_BLOCK_PATTERN = re.compile(
    r'dictation_repository="mlx-community/whisper-large-v3-turbo".*?\n    dictation_lock_holder=""\n  fi\nfi\n',
    re.DOTALL,
)


def _block():
    with open(_SOURCE, encoding="utf-8") as handle:
        match = _BLOCK_PATTERN.search(handle.read())
    if match is None:
        raise AssertionError("could not find the dictation-model pin block in setup-local-whisper.sh")
    text = match.group(0)
    revision = re.search(r'^dictation_revision="([0-9a-f]{40})"$', text, re.MULTILINE)
    if revision is None or revision.group(1) != COMMIT:
        raise AssertionError("the block's pinned revision is not the one FakeHub serves; update FakeHub's COMMIT")
    for name, value in (("config_sha256", CONFIG_SHA256), ("weights_sha256", WEIGHTS_SHA256)):
        text, count = re.subn(r'^dictation_%s=".*"$' % name, 'dictation_%s="%s"' % (name, value), text, flags=re.MULTILINE)
        if count != 1:
            raise AssertionError("expected exactly one dictation_%s assignment in the block" % name)
    return text


class InstallerResumesTheDictationDownloadTests(unittest.TestCase):
    def setUp(self):
        self.hub = FakeHub()
        self.addCleanup(self.hub.close)
        self.tmp = tempfile.mkdtemp(prefix="whispermeet-f824-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.runtime = os.path.join(self.tmp, "Library", "Runtime")
        os.makedirs(self.runtime)
        self.hub_dir = os.path.join(self.tmp, "Library", "Models", "hf", "hub")
        self.cache = os.path.join(self.hub_dir, REPOSITORY_FOLDER)
        # The staging venv's python: says mlx_whisper imports, and runs everything else for real.
        self.venv = os.path.join(self.tmp, "stagevenv")
        os.makedirs(os.path.join(self.venv, "bin"))
        python = os.path.join(self.venv, "bin", "python")
        with open(python, "w") as handle:
            handle.write('#!/bin/sh\nif [ "$1" = "-c" ]; then exit 0; fi\nexec "%s" "$@"\n' % sys.executable)
        os.chmod(python, os.stat(python).st_mode | stat.S_IXUSR)
        self.script = os.path.join(self.tmp, "run-block.sh")
        with open(self.script, "w") as handle:
            handle.write("\n".join([
                "#!/bin/zsh",
                "set -euo pipefail",
                'runtime_directory="%s"' % self.runtime,
                'staging_venv="%s"' % self.venv,
                'dictation_helper_source="%s"' % os.path.join(_SCRIPTS, "whisper_dictate_server.py"),
                _block(),
                'print "block finished"',
            ]))
        os.chmod(self.script, os.stat(self.script).st_mode | stat.S_IXUSR)
        self.environment = dict(os.environ, HF_ENDPOINT=self.hub.endpoint)

    def part(self):
        return os.path.join(self.cache, "blobs", WEIGHTS_SHA256 + ".part")

    def read(self, *parts):
        with open(os.path.join(self.cache, *parts), "rb") as handle:
            return handle.read()

    def cancel_mid_download(self, received):
        """Runs the block until the weights' partial file holds `received` bytes, then stops its process
        group as a Cancel does. Every request after the first is cut before a byte, so the run cannot
        finish on its own whenever the stop lands."""
        self.hub.drop_after = [received] + [0] * 20
        block = subprocess.Popen([self.script], env=self.environment, start_new_session=True,
                                 stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        self.addCleanup(lambda: block.poll() is None and os.killpg(block.pid, signal.SIGKILL))
        deadline = time.monotonic() + 60
        while not (os.path.exists(self.part()) and os.path.getsize(self.part()) >= received):
            if block.poll() is not None:
                self.fail("the block ended before its download was cut: %r" % (block.communicate(),))
            self.assertLess(time.monotonic(), deadline, "the partial file never reached %d bytes" % received)
            time.sleep(0.02)
        os.killpg(block.pid, signal.SIGTERM)
        block.communicate(timeout=30)

    def test_a_repair_after_a_cancelled_download_resumes_it(self):
        self.cancel_mid_download(120_000)
        self.assertEqual(os.path.getsize(self.part()), 120_000, "the Cancel did not keep the partial file in the cache")
        self.assertFalse(os.path.exists(os.path.join(self.cache, "refs", "main")), "an unfinished model was advertised")
        self.assertEqual([name for name in os.listdir(self.hub_dir) if name.startswith(".dictation-model-")], [],
                         "a staging or backup directory, which nothing resumes")
        served_before = self.hub.served
        ranges_before = len(self.hub.ranges)

        self.hub.drop_after = []
        result = subprocess.run([self.script], env=self.environment, capture_output=True, text=True, timeout=120)

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("block finished", result.stdout)
        self.assertNotIn("Note:", result.stderr)
        self.assertEqual(self.hub.ranges[ranges_before:], ["bytes=120000-"],
                         "the Repair did not ask for the rest of the file from where the Cancel stopped")
        self.assertEqual(self.hub.served - served_before, len(WEIGHTS) - 120_000, "bytes already on disk were fetched again")
        snapshot = os.path.join("snapshots", COMMIT)
        self.assertEqual(self.read(snapshot, "weights.safetensors"), WEIGHTS)
        self.assertEqual(self.read(snapshot, "config.json"), CONFIG)
        self.assertEqual(self.read("refs", "main").decode(), COMMIT)
        self.assertFalse(os.path.exists(self.part()))
        self.assertEqual(hashlib.sha256(self.read(snapshot, "weights.safetensors")).hexdigest(), WEIGHTS_SHA256)

    def test_a_download_the_helper_left_is_resumed_by_a_repair_too(self):
        """The helper's first-use download and the installer's are one download now: the same cache,
        the same partial file, the same lock (F826) — so a Repair after the helper was stopped
        mid-download continues it instead of fetching beside it."""
        os.makedirs(os.path.join(self.cache, "blobs"))
        with open(self.part(), "wb") as handle:
            handle.write(WEIGHTS[:200_000])

        result = subprocess.run([self.script], env=self.environment, capture_output=True, text=True, timeout=120)

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.hub.ranges, ["bytes=200000-"])
        self.assertEqual(self.hub.served, len(WEIGHTS) - 200_000)
        self.assertEqual(self.read("snapshots", COMMIT, "weights.safetensors"), WEIGHTS)

    def test_a_partial_file_that_is_not_the_pinned_one_is_discarded_not_kept_as_the_model(self):
        """Resuming is not trusting: a partial whose completed file does not hash to the pin is
        discarded by the helper's check, and the Repair says so instead of keeping it."""
        os.makedirs(os.path.join(self.cache, "blobs"))
        with open(self.part(), "wb") as handle:
            handle.write(b"\x00" * 200_000)

        result = subprocess.run([self.script], env=self.environment, capture_output=True, text=True, timeout=120)

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Note: could not pre-download the Quick Dictation model", result.stderr)
        self.assertFalse(os.path.exists(os.path.join(self.cache, "refs", "main")))
        self.assertFalse(os.path.exists(os.path.join(self.cache, "snapshots", COMMIT, "weights.safetensors")))
        self.assertFalse(os.path.exists(self.part()), "corrupt bytes were kept to resume from")


if __name__ == "__main__":
    unittest.main(verbosity=2)
