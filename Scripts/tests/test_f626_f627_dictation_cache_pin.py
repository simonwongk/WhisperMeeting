#!/usr/bin/env python3
"""F626 / F627 — the Quick Dictation model cache is re-verified against F483's pin on a repair, and
the `refs/main` that makes the pin load offline is tested without a network.

Run: python3 Scripts/tests/test_f626_f627_dictation_cache_pin.py

**F626.** `setup-local-whisper.sh` pins the dictation model to one Hugging Face commit and its two
SHA-256s (F483) and, after a pinned download, writes `refs/main`. But a cache that was already on
disk was never looked at: a repair either re-downloaded 1.6 GB it did not need to, or — if the
download could not run — left whatever `main` had resolved to on the day dictation first ran. The
repair now checks the cache it finds against the pin: a match is left alone, a mismatch is replaced
by the verified pinned download, and a match whose `refs/main` names another commit has just that
ref rewritten.

**F627.** `huggingface_hub` was unpinned, and the hand-written `refs/main` depends on how the
installed library resolves a revision-less `snapshot_download` offline. A fresh `pip install
mlx-whisper==0.4.3` resolved huggingface_hub 2.0.0 on 2026-09-29; the runtime on this Mac, which
dictates every day, runs 1.24.0 (its `dist-info`). The script now installs `huggingface_hub==1.24.0`
in the same `pip` call as mlx-whisper.

**How these run.** The real script text is extracted and run under zsh against a temporary
runtime directory, with a stand-in for the staging venv's python that "downloads" a tiny fake model
whose hashes the test substitutes for the pinned ones — so the whole block (verify, stage, swap,
`refs/main`) runs for real, with no network and no model. `LibraryResolutionTests` additionally asks
the real `huggingface_hub` to resolve the cache offline the way `mlx_whisper.load_model` does; it
needs a python that has the library, so it skips unless `WHISPERMEET_TEST_VENV` names a venv root
(the same convention as F483's opt-in real-download test).
"""

import hashlib
import os
import re
import shutil
import stat
import subprocess
import tempfile
import unittest

_HERE = os.path.dirname(os.path.abspath(__file__))
_SOURCE = os.path.join(_HERE, "..", "setup-local-whisper.sh")

REPOSITORY_FOLDER = "models--mlx-community--whisper-large-v3-turbo"
FAKE_REVISION = "b" * 40
FAKE_CONFIG = b'{"n_mels": 128}\n'
FAKE_WEIGHTS = b"pretend weights " * 64
FAKE_CONFIG_SHA = hashlib.sha256(FAKE_CONFIG).hexdigest()
FAKE_WEIGHTS_SHA = hashlib.sha256(FAKE_WEIGHTS).hexdigest()

_BLOCK_PATTERN = re.compile(
    r'dictation_repository="mlx-community/whisper-large-v3-turbo".*?\n  rm -rf "\$dictation_staging"\nfi\n',
    re.DOTALL,
)
_FUNCTION_PATTERN = re.compile(r"^dictation_cache_matches_pin\(\) \{\n.*?^\}\n", re.DOTALL | re.MULTILINE)


def _source():
    with open(_SOURCE, encoding="utf-8") as handle:
        return handle.read()


def _block():
    match = _BLOCK_PATTERN.search(_source())
    if match is None:
        raise AssertionError("could not find the dictation-model pin block in setup-local-whisper.sh")
    text = match.group(0)
    # The pins are the point of the real script; the test swaps in the hashes of its tiny fake model.
    for name, value in (("revision", FAKE_REVISION), ("config_sha256", FAKE_CONFIG_SHA),
                        ("weights_sha256", FAKE_WEIGHTS_SHA)):
        text, count = re.subn(r'^dictation_%s=".*"$' % name, 'dictation_%s="%s"' % (name, value), text,
                              flags=re.MULTILINE)
        if count != 1:
            raise AssertionError("expected exactly one dictation_%s assignment in the block" % name)
    return text


def _function(required=True):
    match = _FUNCTION_PATTERN.search(_source())
    if match is None:
        if not required:
            return ""  # the block-level tests then fail on what the block DOES, which is the point
        raise AssertionError("could not find dictation_cache_matches_pin() in setup-local-whisper.sh")
    return match.group(0)


class InstallerBlockCase(unittest.TestCase):
    """Runs the extracted block against a temp runtime directory with a fake staging venv."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="whispermeet-f626-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.runtime = os.path.join(self.tmp, "Library", "Runtime")
        os.makedirs(self.runtime)
        self.hub = os.path.join(self.tmp, "Library", "Models", "hf", "hub")
        self.target = os.path.join(self.hub, REPOSITORY_FOLDER)
        self.venv = os.path.join(self.tmp, "stagevenv")
        self.log = os.path.join(self.tmp, "python-invocations.log")
        os.makedirs(os.path.join(self.venv, "bin"))
        python = os.path.join(self.venv, "bin", "python")
        with open(python, "w") as handle:
            handle.write(
                "#!/bin/sh\n"
                'if [ "$1" = "-c" ]; then exit 0; fi\n'  # the `import mlx_whisper` probe
                'echo downloaded >> "%s"\n' % self.log +
                'snapshot="$DICTATION_STAGE/%s/snapshots/$DICTATION_REVISION"\n' % REPOSITORY_FOLDER +
                'mkdir -p "$snapshot"\n'
                "printf '%s' \"$FAKE_CONFIG\" > \"$snapshot/config.json\"\n"
                "printf '%s' \"$FAKE_WEIGHTS\" > \"$snapshot/weights.safetensors\"\n"
                "cat > /dev/null\n"
            )
        os.chmod(python, os.stat(python).st_mode | stat.S_IXUSR)

    # -- fixtures -------------------------------------------------------------------------------

    def write_cache(self, config=FAKE_CONFIG, weights=FAKE_WEIGHTS, revision=FAKE_REVISION, ref=None):
        """A hub cache as `huggingface_hub` lays it out: blobs/, snapshots/<rev>/ symlinks, refs/main."""
        blobs = os.path.join(self.target, "blobs")
        snapshot = os.path.join(self.target, "snapshots", revision)
        os.makedirs(blobs, exist_ok=True)
        os.makedirs(snapshot, exist_ok=True)
        for name, data in (("config.json", config), ("weights.safetensors", weights)):
            blob = os.path.join(blobs, hashlib.sha256(data).hexdigest())
            with open(blob, "wb") as handle:
                handle.write(data)
            link = os.path.join(snapshot, name)
            if os.path.lexists(link):
                os.remove(link)
            os.symlink(os.path.relpath(blob, snapshot), link)
        os.makedirs(os.path.join(self.target, "refs"), exist_ok=True)
        with open(os.path.join(self.target, "refs", "main"), "w") as handle:
            handle.write(ref if ref is not None else revision)

    def run_block(self):
        script = "\n".join([
            "#!/bin/zsh",
            "set -euo pipefail",
            'runtime_directory="%s"' % self.runtime,
            'staging_venv="%s"' % self.venv,
            _function(required=False),
            _block(),
            'print "block finished"',
        ])
        path = os.path.join(self.tmp, "run-block.sh")
        with open(path, "w") as handle:
            handle.write(script)
        os.chmod(path, os.stat(path).st_mode | stat.S_IXUSR)
        environment = dict(os.environ, FAKE_CONFIG=FAKE_CONFIG.decode(), FAKE_WEIGHTS=FAKE_WEIGHTS.decode())
        result = subprocess.run([path], capture_output=True, text=True, timeout=120, env=environment)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("block finished", result.stdout)
        return result

    def downloads(self):
        if not os.path.exists(self.log):
            return 0
        with open(self.log) as handle:
            return len(handle.read().split())

    def snapshot_file(self, name, revision=FAKE_REVISION):
        with open(os.path.join(self.target, "snapshots", revision, name), "rb") as handle:
            return handle.read()

    def ref(self):
        with open(os.path.join(self.target, "refs", "main")) as handle:
            return handle.read()

    def leftovers(self):
        return sorted(name for name in os.listdir(self.hub) if name.startswith(".dictation-model-"))


class RepairReverifiesTheCacheTests(InstallerBlockCase):
    def test_a_cache_that_matches_the_pin_is_left_alone(self):
        self.write_cache()
        weights = os.path.realpath(os.path.join(self.target, "snapshots", FAKE_REVISION, "weights.safetensors"))
        before = os.stat(weights)

        result = self.run_block()

        self.assertEqual(self.downloads(), 0, "an intact pinned model was downloaded again")
        after = os.stat(weights)
        self.assertEqual((before.st_ino, before.st_mtime_ns), (after.st_ino, after.st_mtime_ns))
        self.assertEqual(self.snapshot_file("weights.safetensors"), FAKE_WEIGHTS)
        self.assertEqual(self.ref(), FAKE_REVISION)
        self.assertEqual(self.leftovers(), [])
        self.assertNotIn("Note:", result.stderr)

    def test_a_cache_with_one_wrong_hash_is_replaced_by_the_verified_download(self):
        self.write_cache(weights=b"weights from some other commit " * 8)

        self.run_block()

        self.assertEqual(self.downloads(), 1)
        self.assertEqual(self.snapshot_file("weights.safetensors"), FAKE_WEIGHTS)
        self.assertEqual(self.snapshot_file("config.json"), FAKE_CONFIG)
        self.assertEqual(self.ref(), FAKE_REVISION)
        self.assertEqual(self.leftovers(), [], "the displaced model's backup and the staging copy must be gone")

    def test_a_cache_with_a_wrong_config_is_replaced_too(self):
        self.write_cache(config=b'{"n_mels": 80}\n')

        self.run_block()

        self.assertEqual(self.downloads(), 1)
        self.assertEqual(self.snapshot_file("config.json"), FAKE_CONFIG)

    def test_a_cache_that_was_resolved_from_main_at_another_commit_is_replaced(self):
        """What a first run on an unpinned install leaves: a snapshot named for whatever main was that
        day, and refs/main naming it. Neither is the pinned revision."""
        other = "c" * 40
        self.write_cache(weights=b"a later main " * 8, revision=other)

        self.run_block()

        self.assertEqual(self.downloads(), 1)
        self.assertEqual(self.ref(), FAKE_REVISION)
        self.assertEqual(self.snapshot_file("weights.safetensors"), FAKE_WEIGHTS)

    def test_a_pinned_snapshot_whose_ref_names_another_commit_has_only_the_ref_rewritten(self):
        """F627's case: `mlx_whisper.load_model` asks for revision-less `main`, so offline it follows
        refs/main. The files here verify; the ref pointing elsewhere would load a different model."""
        self.write_cache(ref="c" * 40)
        weights = os.path.realpath(os.path.join(self.target, "snapshots", FAKE_REVISION, "weights.safetensors"))
        before = os.stat(weights)

        self.run_block()

        self.assertEqual(self.ref(), FAKE_REVISION)
        self.assertEqual(self.downloads(), 0, "fixing a ref must not cost a 1.6 GB download")
        self.assertEqual(os.stat(weights).st_ino, before.st_ino)

    def test_a_missing_model_is_downloaded_as_before(self):
        os.makedirs(self.hub)
        self.run_block()

        self.assertEqual(self.downloads(), 1)
        self.assertEqual(self.snapshot_file("weights.safetensors"), FAKE_WEIGHTS)
        self.assertEqual(self.ref(), FAKE_REVISION)

    def test_a_truncated_weights_file_does_not_pass(self):
        self.write_cache(weights=FAKE_WEIGHTS[:-1])
        self.run_block()
        self.assertEqual(self.downloads(), 1)


class FunctionResultTests(unittest.TestCase):
    """`dictation_cache_matches_pin` on its own: its exit status is the contract the block relies on."""

    def run_function(self, repo_dir):
        script = "\n".join([
            "#!/bin/zsh",
            "set -euo pipefail",
            'dictation_revision="%s"' % FAKE_REVISION,
            'dictation_config_sha256="%s"' % FAKE_CONFIG_SHA,
            'dictation_weights_sha256="%s"' % FAKE_WEIGHTS_SHA,
            _function(),
            'if dictation_cache_matches_pin "%s"; then print match; else print mismatch; fi' % repo_dir,
        ])
        return subprocess.run(["/bin/zsh", "-c", script], capture_output=True, text=True, timeout=60).stdout.strip()

    def test_a_directory_that_does_not_exist_is_a_mismatch_not_an_error(self):
        self.assertEqual(self.run_function("/nonexistent/%s" % REPOSITORY_FOLDER), "mismatch")

    def test_the_function_only_reads_when_the_files_match_and_never_deletes(self):
        tmp = tempfile.mkdtemp(prefix="whispermeet-f626-fn-")
        self.addCleanup(shutil.rmtree, tmp, True)
        snapshot = os.path.join(tmp, "snapshots", FAKE_REVISION)
        os.makedirs(snapshot)
        with open(os.path.join(snapshot, "config.json"), "wb") as handle:
            handle.write(FAKE_CONFIG)
        with open(os.path.join(snapshot, "weights.safetensors"), "wb") as handle:
            handle.write(b"wrong")
        self.assertEqual(self.run_function(tmp), "mismatch")
        self.assertTrue(os.path.exists(os.path.join(snapshot, "weights.safetensors")),
                        "a mismatch is the caller's to replace; the check itself deletes nothing")


class InstallerPinsHuggingFaceHubTests(unittest.TestCase):
    def test_huggingface_hub_is_pinned_in_the_same_pip_call_as_mlx_whisper(self):
        """In ONE `pip install`, so the resolver is given both requirements at once — a later or
        separate install could resolve a different hub for mlx-whisper's unpinned `huggingface_hub`."""
        source = _source()
        self.assertIsNotNone(re.search(r'^huggingface_hub_version="1\.24\.0"$', source, re.MULTILINE))
        install = re.search(r'pip install ("mlx-whisper==\$mlx_whisper_version"[^\n]*)', source)
        self.assertIsNotNone(install, "could not find the mlx-whisper install line")
        self.assertIn('"huggingface_hub==$huggingface_hub_version"', install.group(1))

    def test_the_pinned_version_is_named_with_its_evidence(self):
        source = _source()
        self.assertIn("1.24.0", source)
        self.assertIn("2.0.0", source, "the comment should say what an unpinned install resolved instead")


class LibraryResolutionTests(InstallerBlockCase):
    """F627 — the part no always-run check can see: how the installed library resolves the cache the
    installer lays down. Opt in with WHISPERMEET_TEST_VENV=<a venv root that has huggingface_hub>."""

    @unittest.skipUnless(
        os.environ.get("WHISPERMEET_TEST_VENV"),
        "set WHISPERMEET_TEST_VENV to a venv root containing huggingface_hub to run this offline check",
    )
    def test_the_cache_the_installer_writes_resolves_offline_the_way_mlx_whisper_loads_it(self):
        python = os.path.join(os.environ["WHISPERMEET_TEST_VENV"], "bin", "python")
        # Start from a cache whose refs/main points at some other commit — the state before F626's
        # rewrite. A revision-less offline resolution follows that ref, and must not land on it.
        self.write_cache(ref="c" * 40)
        self.run_block()

        probe = (
            "import os, sys\n"
            "os.environ['HF_HUB_OFFLINE'] = '1'\n"
            "from huggingface_hub import snapshot_download, try_to_load_from_cache\n"
            # exactly `mlx_whisper.load_models.load_model`: no revision, no allow_patterns
            "path = snapshot_download(repo_id='mlx-community/whisper-large-v3-turbo', cache_dir=sys.argv[1])\n"
            "cached = try_to_load_from_cache('mlx-community/whisper-large-v3-turbo', 'weights.safetensors', cache_dir=sys.argv[1])\n"
            "print(path)\n"
            "print(cached)\n"
        )
        result = subprocess.run([python, "-c", probe, self.hub], capture_output=True, text=True, timeout=120)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        resolved, cached = result.stdout.strip().splitlines()[-2:]
        self.assertTrue(resolved.endswith("snapshots/" + FAKE_REVISION), resolved)
        self.assertTrue(cached.endswith("snapshots/%s/weights.safetensors" % FAKE_REVISION), cached)


if __name__ == "__main__":
    unittest.main(verbosity=2)
