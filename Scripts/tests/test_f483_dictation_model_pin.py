#!/usr/bin/env python3
"""F483 (AI8) — the Quick Dictation model was fetched from an unpinned, unverified HF ref.

Run: python3 Scripts/tests/test_f483_dictation_model_pin.py

`whisper_dictate_server.py` used to fetch `mlx-community/whisper-large-v3-turbo` from whatever its
mutable `main` branch held the first time dictation warmed up, verifying nothing — unlike every
other model download in this repo (Ask embeddings, the summarizer, Qwen, diarization), which all
pin a revision and check SHA-256. `setup-local-whisper.sh` now pre-downloads and pins it the same
way.

**Two test classes.**

`DictationModelPinShapeTests` runs always (no network): parses the real script text and checks the
pinned constants are self-consistent and match the live-fetched values recorded below (fetched
once, by hand, against the real Hugging Face API — see `dictation_pin_evidence()`).

`DictationModelPinRealDownloadTests` is opt-in and heavy (~1.6 GB): it extracts the exact
download/verify/refs-write block from the real script and runs it for real against the real
Hugging Face-hosted repo, using a real `huggingface_hub` (a throwaway venv, never the real
`~/Library/Application Support/WhisperMeet`). Set `WHISPERMEET_TEST_REAL_DICTATION_DOWNLOAD=1` and
point `WHISPERMEET_TEST_PYTHON` at a `python` with `huggingface_hub` installed to run it. Skipped
by default — this is exactly the shape `DiarizationInstallManifestTests.swift`'s
`smokeTestModels`-gated tests already use for a real-network/real-model case the routine gate must
not pay for on every run.
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
_SOURCE = os.path.join(_SCRIPTS, "setup-local-whisper.sh")

_BLOCK_PATTERN = re.compile(
    r'dictation_repository="mlx-community/whisper-large-v3-turbo".*?\n  rm -rf "\$dictation_staging"\nfi\n',
    re.DOTALL,
)


def _read_source():
    with open(_SOURCE, encoding="utf-8") as handle:
        return handle.read()


def _extract_block():
    match = _BLOCK_PATTERN.search(_read_source())
    if match is None:
        raise AssertionError(
            "could not find the F483 dictation-model pin block in setup-local-whisper.sh; did it "
            "move? Update the anchor regex to match."
        )
    return match.group(0)


def dictation_pin_evidence():
    """What was fetched from the live Hugging Face API/CDN to derive the pins below, so the next
    person does not have to take the constants on faith:

      curl https://huggingface.co/api/models/mlx-community/whisper-large-v3-turbo/revision/main
        -> sha: a4aaeec0636e6fef84abdcbe3544cb2bf7e9f6fb, lastModified: 2026-04-12T10:39:07Z
      curl "…/revision/main?blobs=true" siblings[weights.safetensors].lfs.sha256
        -> 951ed3fc1203e6a62467abb2144a96ce7eafca8fa77e3704fdb8635ff3e7f8a6
      curl -L …/resolve/a4aaeec.../config.json | shasum -a 256
        -> b34fc29e4e11e0a25e812775dd67f4dd16fc2c8eb43d28ae25ff7d660ecb6379 (268 bytes, matching
           the API's reported size for config.json)
    """
    return {
        "revision": "a4aaeec0636e6fef84abdcbe3544cb2bf7e9f6fb",
        "config_sha256": "b34fc29e4e11e0a25e812775dd67f4dd16fc2c8eb43d28ae25ff7d660ecb6379",
        "weights_sha256": "951ed3fc1203e6a62467abb2144a96ce7eafca8fa77e3704fdb8635ff3e7f8a6",
    }


class DictationModelPinShapeTests(unittest.TestCase):
    def test_the_script_pins_a_revision_and_both_hashes(self):
        source = _read_source()
        evidence = dictation_pin_evidence()
        self.assertIn('dictation_repository="mlx-community/whisper-large-v3-turbo"', source)
        self.assertIn(
            'dictation_revision="{}"'.format(evidence["revision"]), source,
            "the pinned revision must match the one fetched from the live HF API (see "
            "dictation_pin_evidence's docstring)",
        )
        self.assertIn('dictation_config_sha256="{}"'.format(evidence["config_sha256"]), source)
        self.assertIn('dictation_weights_sha256="{}"'.format(evidence["weights_sha256"]), source)

    def test_the_download_is_gated_on_mlx_whisper_actually_being_usable(self):
        block = _extract_block()
        self.assertTrue(
            block.startswith('dictation_repository=') or 'import mlx_whisper' in block
        )
        self.assertIn('import mlx_whisper" >/dev/null 2>&1; then', block)

    def test_a_failed_download_or_verification_never_aborts_the_script(self):
        """Best-effort, matching the mlx-whisper package install right above it: Quick Dictation
        must never block the meetings runtime."""
        block = _extract_block()
        self.assertIn("could not pre-download the Quick Dictation model", block)
        self.assertIn("failed verification", block)
        # Neither failure message is followed by `exit 1` inside this block.
        for message in ("could not pre-download", "failed verification"):
            index = block.index(message)
            tail = block[index:index + 200]
            self.assertNotIn("exit 1", tail)


class DictationModelPinRealDownloadTests(unittest.TestCase):
    """Opt-in, real network, real ~1.6 GB download. See the module docstring."""

    @unittest.skipUnless(
        os.environ.get("WHISPERMEET_TEST_REAL_DICTATION_DOWNLOAD") == "1",
        "set WHISPERMEET_TEST_REAL_DICTATION_DOWNLOAD=1 and WHISPERMEET_TEST_VENV to run this "
        "real, ~1.6 GB, network-hitting test",
    )
    def test_the_real_block_downloads_verifies_and_pins_the_real_model(self):
        # A venv ROOT, not a bare python executable: the script always calls
        # "$staging_venv/bin/python", and a venv's site-packages resolution depends on its own
        # pyvenv.cfg sitting next to bin/ — a python binary symlinked into a fake venv layout from
        # elsewhere cannot find its real site-packages and "import mlx_whisper" silently fails,
        # which was this test's own first failure mode.
        staging_venv = os.environ.get("WHISPERMEET_TEST_VENV")
        self.assertTrue(
            staging_venv and os.path.isfile(os.path.join(staging_venv, "bin", "python")),
            "WHISPERMEET_TEST_VENV must be a venv ROOT (containing bin/python) with mlx_whisper "
            "and huggingface_hub installed",
        )

        tmp = tempfile.mkdtemp(prefix="whispermeet-f483-real-")
        self.addCleanup(shutil.rmtree, tmp, True)
        runtime_directory = os.path.join(tmp, "Runtime")
        os.makedirs(runtime_directory)

        script = "\n".join([
            "#!/bin/zsh",
            "set -euo pipefail",
            'runtime_directory="{}"'.format(runtime_directory),
            'staging_venv="{}"'.format(staging_venv),
            _extract_block(),
            'print "pin step finished"',
        ])
        script_path = os.path.join(tmp, "run-pin.sh")
        with open(script_path, "w", encoding="utf-8") as handle:
            handle.write(script)
        os.chmod(script_path, os.stat(script_path).st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)

        result = subprocess.run([script_path], capture_output=True, text=True, timeout=1800)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("pin step finished", result.stdout)
        self.assertNotIn("Note:", result.stderr, "a best-effort note means the real download failed")

        evidence = dictation_pin_evidence()
        snapshot = os.path.join(
            runtime_directory, "..", "Models", "hf", "hub",
            "models--mlx-community--whisper-large-v3-turbo", "snapshots", evidence["revision"],
        )
        snapshot = os.path.normpath(snapshot)
        self.assertTrue(os.path.isfile(os.path.join(snapshot, "config.json")))
        self.assertTrue(os.path.isfile(os.path.join(snapshot, "weights.safetensors")))
        refs_main = os.path.join(os.path.dirname(os.path.dirname(snapshot)), "refs", "main")
        with open(refs_main, encoding="utf-8") as handle:
            self.assertEqual(handle.read().strip(), evidence["revision"])

        # The whole point: HF_HUB_OFFLINE=1 resolving the bare repo id (no revision — exactly how
        # mlx_whisper.load_model calls it) must find this pinned snapshot without any network.
        offline_check = subprocess.run(
            [
                os.path.join(staging_venv, "bin", "python"), "-c",
                "import os; os.environ['HF_HUB_OFFLINE']='1'; "
                "from huggingface_hub import snapshot_download; "
                "p = snapshot_download(repo_id='mlx-community/whisper-large-v3-turbo', "
                "cache_dir=os.path.join('{}', 'hf', 'hub'), "
                "allow_patterns=['config.json']); "
                "print(p)".format(os.path.join(runtime_directory, "..", "Models")),
            ],
            capture_output=True, text=True, timeout=60,
        )
        self.assertEqual(offline_check.returncode, 0, offline_check.stdout + offline_check.stderr)
        self.assertIn(evidence["revision"], offline_check.stdout)


if __name__ == "__main__":
    unittest.main(verbosity=2)
