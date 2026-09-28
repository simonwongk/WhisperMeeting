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
