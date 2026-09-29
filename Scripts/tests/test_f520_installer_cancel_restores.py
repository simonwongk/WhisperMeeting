#!/usr/bin/env python3
"""F520 — a cancelled or quit-interrupted install restores the runtime it was replacing.

Run: python3 Scripts/tests/test_f520_installer_cancel_restores.py

F520 makes every model install cancellable (Settings' Cancel, and Quit) by sending SIGTERM to the
installer's process group — `ProcessGroupRunner.cancel()`. That is only safe if each script, killed
that way at the point a user would realistically press Cancel (mid-download), leaves the live
runtime exactly as it was and cleans up after itself. The scripts' `trap 'exit 130' HUP INT TERM`
plus their EXIT trap were written for this; these tests are the first to deliver the signal.

They also cover the two script changes F520 made to setup-local-whisper.sh:

- **A cancel during the post-swap verification rolled nothing back.** Whisper is the one installer
  with a blocking step between the swap and `activation_complete=1` (the relocated `whisper --help`,
  seconds with real torch). Its trap restored the backup only when the live path was *missing*, so
  a cancel there left the unverified new venv live and the working one stranded in a hidden
  `.venv-backup-<pid>`.
- **`WHISPER_INSTALL_RECOVERY_ONLY=1`** reclaims an interrupted install and exits before Homebrew,
  as the Qwen, summarizer and speaker-analysis installers already did (F33/F167/F219). The app
  runs it at launch (`AppModel.reclaimInterruptedWhisperInstall`).

Every run is the real script via `installer_harness` (only Homebrew, the free-space probe, pip, the
model downloads and curl are stood in for), in its own process group, signalled exactly as
`ProcessGroupRunner` signals it.
"""

import os
import re
import shutil
import unittest

import installer_harness as harness


def _write(path, content=""):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(content)


class WhisperCancelTests(unittest.TestCase):
    def setUp(self):
        self.sandbox = harness.InstallerSandbox("setup-local-whisper.sh")
        self.addCleanup(self.sandbox.cleanup)
        self.runtime = os.path.join(self.sandbox.root, "Runtime")
        self.venv = os.path.join(self.runtime, "venv")
        harness.fake_whisper_venv(self.venv, "old", with_mlx_whisper=True, with_yt_dlp=True)

    def assert_restored(self, returncode, stderr):
        self.assertEqual(returncode, 130, stderr)
        self.assertEqual(harness.read(os.path.join(self.venv, "MARKER")), "old", "the working venv was not restored\n" + stderr)
        self.assertEqual(harness.hidden_entries(self.runtime, ".venv-install-"), [], "staging left behind")
        self.assertEqual(harness.hidden_entries(self.runtime, ".venv-backup-"), [], "the working venv was stranded in a backup")
        self.assertFalse(os.path.exists(os.path.join(self.runtime, ".venv-install.lock")), "lock left behind")

    def test_a_cancel_mid_download_leaves_the_working_venv(self):
        returncode, stderr = self.sandbox.run_and_terminate_group(self.runtime, "pip:openai-whisper")
        self.assert_restored(returncode, stderr)

    def test_a_cancel_during_the_post_swap_verification_rolls_back(self):
        # The new venv's `whisper --help` is called twice: at the staging path, then at the live
        # path after the swap. Hang on the second.
        returncode, stderr = self.sandbox.run_and_terminate_group(
            self.runtime,
            "whisper-post-swap",
            FAKE_WHISPER_BLOCK_CALL=2,
            FAKE_WHISPER_COUNT=os.path.join(self.sandbox.root, "whisper-calls"),
        )
        self.assert_restored(returncode, stderr)

    def test_a_cancelled_first_install_leaves_no_unverified_venv(self):
        """Nothing to put back on a first install: the unverified venv is removed, so the app
        reports "not installed" rather than a runtime nobody checked."""
        shutil.rmtree(self.venv)
        returncode, stderr = self.sandbox.run_and_terminate_group(
            self.runtime,
            "whisper-post-swap",
            FAKE_WHISPER_BLOCK_CALL=2,
            FAKE_WHISPER_COUNT=os.path.join(self.sandbox.root, "whisper-calls"),
        )
        self.assertEqual(returncode, 130, stderr)
        self.assertFalse(os.path.exists(self.venv), "the unverified venv was left live")
        self.assertEqual(harness.hidden_entries(self.runtime, ".venv-"), [])

    def test_recovery_only_restores_an_orphaned_backup_without_installing(self):
        """What the launch reclaim runs: an interrupted install left the working venv in a backup
        and no live venv. Recovery-only mode restores it and stops — no Homebrew, no venv, no pip."""
        os.rename(self.venv, os.path.join(self.runtime, ".venv-backup-4242"))
        _write(os.path.join(self.runtime, ".venv-install-4242", "bin", "partial"))

        result = self.sandbox.run(self.runtime, WHISPER_INSTALL_RECOVERY_ONLY="1")

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(harness.read(os.path.join(self.venv, "MARKER")), "old")
        self.assertEqual(harness.hidden_entries(self.runtime, ".venv-"), [], "artifacts left behind")
        log = harness.read(self.sandbox.log) if os.path.exists(self.sandbox.log) else ""
        self.assertNotIn("-m venv", log, "recovery-only mode went on to install")
        self.assertNotIn("Local Whisper is ready", result.stdout)

    def test_recovery_only_on_a_clean_runtime_changes_nothing(self):
        result = self.sandbox.run(self.runtime, WHISPER_INSTALL_RECOVERY_ONLY="1")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(harness.read(os.path.join(self.venv, "MARKER")), "old")
        self.assertFalse(os.path.exists(self.sandbox.log), "recovery-only mode ran the interpreter")

    def test_a_cancel_during_a_failed_verifications_rollback_still_restores(self):
        """Review probe P2: the relocated venv fails its `whisper --help`, and the Cancel lands while
        the rollback is removing it. The flag that tells the trap an unverified venv is live was
        cleared before that removal, so the trap left a half-deleted new venv live and the working
        one in a hidden backup."""
        harness.write_executable(
            os.path.join(self.sandbox.shims, "rm"),
            "#!/bin/sh\n"
            'if [ "$1" = "-rf" ] && [ "$2" = "%s" ] && [ ! -e "$FAKE_BLOCK_MARKER" ]; then\n'
            '  /bin/rm -f "$2/bin/whisper"; echo rm > "$FAKE_BLOCK_MARKER"; sleep 60\n'
            "fi\n"
            'exec /bin/rm "$@"\n' % self.venv,
        )
        returncode, stderr = self.sandbox.run_and_terminate_group(
            self.runtime,
            "rollback-rm",
            FAKE_WHISPER_FAIL_CALL=2,
            FAKE_WHISPER_COUNT=os.path.join(self.sandbox.root, "whisper-calls"),
        )
        self.assert_restored(returncode, stderr)
        self.assertTrue(os.path.exists(os.path.join(self.venv, "bin", "whisper")))


class WhisperDictationModelCancelTests(unittest.TestCase):
    """Review probe P1 and the swap after it: the Quick Dictation model is the install's largest
    single download (~1.5 GB), staged under `Models/hf/hub/.dictation-model-staging-<pid>` — outside
    `Runtime/`, and unknown to the EXIT trap, so a Cancel or Quit during it leaked the partial
    download for good; and a kill between moving the old model aside and moving the new one in
    left the model only in `.dictation-model-backup-<pid>`."""

    def setUp(self):
        self.sandbox = harness.InstallerSandbox("setup-local-whisper.sh")
        self.addCleanup(self.sandbox.cleanup)
        self.runtime = os.path.join(self.sandbox.root, "Runtime")
        self.venv = os.path.join(self.runtime, "venv")
        self.hub = os.path.join(self.sandbox.root, "Models", "hf", "hub")
        self.model = os.path.join(self.hub, "models--mlx-community--whisper-large-v3-turbo")
        harness.fake_whisper_venv(self.venv, "old", with_mlx_whisper=True, with_yt_dlp=True)
        _write(os.path.join(self.model, "MARKER"), "old model")
        # The pinned hashes are what the script checks; `shasum` answers with them.
        pins = dict(re.findall(r'^(dictation_(?:config|weights)_sha256)="([0-9a-f]{64})"$',
                               self.sandbox.source, re.MULTILINE))
        self.assertEqual(len(pins), 2, "the script's pinned hashes moved; update this test")
        harness.write_executable(
            os.path.join(self.sandbox.shims, "shasum"),
            "#!/bin/sh\n"
            'case "$3" in\n'
            '  */config.json) echo "%s  $3" ;;\n'
            '  */weights.safetensors) echo "%s  $3" ;;\n'
            '  *) exec /usr/bin/shasum "$@" ;;\n'
            "esac\n" % (pins["dictation_config_sha256"], pins["dictation_weights_sha256"]),
        )

    def assert_nothing_leaked(self, stderr):
        self.assertEqual(harness.hidden_entries(self.hub, ".dictation-model-"), [],
                         "a dictation-model staging or backup directory was left behind\n" + stderr)

    def test_a_cancel_during_the_model_download_leaves_no_partial_download(self):
        returncode, stderr = self.sandbox.run_and_terminate_group(self.runtime, "download")
        self.assertEqual(returncode, 130, stderr)
        self.assert_nothing_leaked(stderr)
        self.assertEqual(harness.read(os.path.join(self.model, "MARKER")), "old model")
        self.assertEqual(harness.read(os.path.join(self.venv, "MARKER")), "old")

    def test_a_cancel_between_the_model_swaps_puts_the_old_model_back(self):
        # Hang the move of the NEW model into place: the old one has just been moved aside.
        harness.write_executable(
            os.path.join(self.sandbox.shims, "mv"),
            "#!/bin/sh\n"
            'case "$1" in */.dictation-model-staging-*) if [ ! -e "$FAKE_BLOCK_MARKER" ]; then\n'
            '  echo mv > "$FAKE_BLOCK_MARKER"; sleep 60; fi ;; esac\n'
            'exec /bin/mv "$@"\n',
        )
        returncode, stderr = self.sandbox.run_and_terminate_group(
            self.runtime, "model-swap", FAKE_DOWNLOAD_SUCCEEDS=1)
        self.assertEqual(returncode, 130, stderr)
        self.assertEqual(harness.read(os.path.join(self.model, "MARKER")), "old model",
                         "the working dictation model was left only in its backup")
        self.assert_nothing_leaked(stderr)

    def test_a_verified_model_download_replaces_the_old_one(self):
        """The same shims on the happy path: the pinned model lands and nothing is left over."""
        result = self.sandbox.run(self.runtime, FAKE_DOWNLOAD_SUCCEEDS="1")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertFalse(os.path.exists(os.path.join(self.model, "MARKER")))
        self.assertTrue(os.path.isfile(os.path.join(self.model, "refs", "main")))
        self.assert_nothing_leaked(result.stderr)

    def test_the_reclaims_model_directory_is_the_one_the_download_block_derives(self):
        """The reclaim runs before the download block defines `dictation_repository`, so it spells
        the directory out; this keeps the two from drifting."""
        spelled = re.search(r'^dictation_model_directory_name="([^"]+)"$', self.sandbox.source, re.MULTILINE)
        repository = re.search(r'^dictation_repository="([^"]+)"$', self.sandbox.source, re.MULTILINE)
        self.assertIsNotNone(spelled)
        self.assertIsNotNone(repository)
        self.assertEqual(spelled.group(1), "models--" + repository.group(1).replace("/", "--"))

    def test_an_interrupted_installs_model_leftovers_are_reclaimed(self):
        """What a power loss leaves (no trap ran): another PID's staging, and its backup with the
        live model gone. The reclaim — at launch, or at the next install — puts the model back and
        removes the rest, under the same lock as everything else it reclaims."""
        _write(os.path.join(self.hub, ".dictation-model-staging-4242", "blobs", "x.incomplete"), "partial")
        os.rename(self.model, os.path.join(self.hub, ".dictation-model-backup-4242"))
        _write(os.path.join(self.runtime, ".venv-install-4242", "bin", "partial"))

        result = self.sandbox.run(self.runtime, WHISPER_INSTALL_RECOVERY_ONLY="1")

        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(harness.read(os.path.join(self.model, "MARKER")), "old model")
        self.assert_nothing_leaked(result.stderr)


class QwenCancelTests(unittest.TestCase):
    def test_a_cancel_mid_download_leaves_the_working_runtime(self):
        sandbox = harness.InstallerSandbox("setup-qwen-asr.sh")
        self.addCleanup(sandbox.cleanup)
        sandbox.copy_sibling("qwen_transcribe.py")
        sandbox.copy_sibling("qwen_dictate_server.py")
        runtime = os.path.join(sandbox.root, "Runtime")
        target = os.path.join(runtime, "Qwen3ASR")
        _write(os.path.join(target, "MARKER"), "old")

        returncode, stderr = sandbox.run_and_terminate_group(target, "pip:mlx-audio")

        self.assertEqual(returncode, 130, stderr)
        self.assertEqual(harness.read(os.path.join(target, "MARKER")), "old")
        self.assertEqual(harness.hidden_entries(runtime, ".Qwen3ASR-install-"), [])
        self.assertEqual(harness.hidden_entries(runtime, ".Qwen3ASR-backup-"), [])
        self.assertFalse(os.path.exists(os.path.join(runtime, ".Qwen3ASR-install.lock")))


class SummarizerCancelTests(unittest.TestCase):
    def test_a_cancel_mid_download_leaves_the_working_model_and_search_model(self):
        sandbox = harness.InstallerSandbox("setup-local-summarizer.sh")
        self.addCleanup(sandbox.cleanup)
        for helper in ("summarize_local.py", "correct_local.py", "refine_server.py"):
            sandbox.copy_sibling(helper)
        runtime = os.path.join(sandbox.root, "Runtime")
        target = os.path.join(runtime, "Summarizer")
        _write(os.path.join(target, "MARKER"), "old")
        _write(os.path.join(target, "embedding-model", "model.safetensors"), "search model")

        returncode, stderr = sandbox.run_and_terminate_group(target, "pip:mlx-lm")

        self.assertEqual(returncode, 130, stderr)
        self.assertEqual(harness.read(os.path.join(target, "MARKER")), "old")
        self.assertEqual(harness.read(os.path.join(target, "embedding-model", "model.safetensors")), "search model")
        self.assertEqual(harness.hidden_entries(runtime, ".Summarizer-install-"), [])
        self.assertEqual(harness.hidden_entries(runtime, ".Summarizer-backup-"), [])
        self.assertFalse(os.path.exists(os.path.join(runtime, ".Summarizer-install.lock")))


class SpeakerAnalysisCancelTests(unittest.TestCase):
    def test_a_cancel_mid_download_leaves_the_working_runtime(self):
        sandbox = harness.InstallerSandbox("setup-speaker-diarization.sh")
        self.addCleanup(sandbox.cleanup)
        _write(os.path.join(sandbox.repo, "Resources", "THIRD-PARTY-NOTICES.txt"), "notices")
        harness.write_executable(os.path.join(sandbox.repo, ".build", "debug", "WhisperMeet"), "#!/bin/sh\nexit 0\n")
        harness.write_executable(
            os.path.join(sandbox.shims, "curl"),
            '#!/bin/sh\necho curl > "$FAKE_BLOCK_MARKER"\nsleep 60\n',
        )
        runtime = os.path.join(sandbox.root, "Runtime")
        target = os.path.join(runtime, "Diarization")
        _write(os.path.join(target, "MARKER"), "old")

        returncode, stderr = sandbox.run_and_terminate_group(target, "curl")

        self.assertEqual(returncode, 130, stderr)
        self.assertEqual(harness.read(os.path.join(target, "MARKER")), "old")
        self.assertEqual(harness.hidden_entries(runtime, ".Diarization-install-"), [])
        self.assertEqual(harness.hidden_entries(runtime, ".Diarization-backup-"), [])
        self.assertFalse(os.path.exists(os.path.join(runtime, ".Diarization-install.lock")))


if __name__ == "__main__":
    unittest.main(verbosity=2)
