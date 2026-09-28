#!/usr/bin/env python3
"""F545 — Local Whisper "Repair or Update" could silently strip Quick Dictation and link import.

Run: python3 Scripts/tests/test_f545_whisper_repair_keeps_optional_tools.py

`setup-local-whisper.sh` installs mlx-whisper (Quick Dictation) and yt-dlp (import from a link)
best-effort into its STAGING venv: a pip failure only prints a "Note:". It then swapped the staging
venv in over the live one and deleted the backup — which had both — and exited 0, so the app said
"ready". On a flaky connection, a repair of a working install therefore removed two features and
reported success.

These run the real script (via `installer_harness`: only Homebrew is stood in for) against a temp
runtime whose live venv is a working install, with the fake pip failing the one package the
scenario is about.
"""

import os
import unittest

import installer_harness as harness


class RepairKeepsWorkingOptionalToolsTests(unittest.TestCase):
    def setUp(self):
        self.sandbox = harness.InstallerSandbox("setup-local-whisper.sh")
        self.addCleanup(self.sandbox.cleanup)
        self.runtime = os.path.join(self.sandbox.root, "Runtime")
        self.venv = os.path.join(self.runtime, "venv")

    def assert_live_install_untouched(self, result):
        output = result.stdout + result.stderr
        self.assertNotEqual(result.returncode, 0, "a repair that would lose a tool must not report success\n" + output)
        self.assertNotIn("Local Whisper is ready", result.stdout, output)
        self.assertEqual(harness.read(os.path.join(self.venv, "MARKER")), "old", "the working venv was replaced\n" + output)
        self.assertEqual(harness.hidden_entries(self.runtime, ".venv-install-"), [], "staging left behind")
        self.assertEqual(harness.hidden_entries(self.runtime, ".venv-backup-"), [], "backup left behind")
        self.assertFalse(os.path.exists(os.path.join(self.runtime, ".venv-install.lock")))

    def test_a_repair_that_cannot_reinstall_mlx_whisper_keeps_the_working_install(self):
        harness.fake_whisper_venv(self.venv, "old", with_mlx_whisper=True, with_yt_dlp=True)
        result = self.sandbox.run(self.runtime, FAKE_PIP_FAIL="mlx-whisper")
        self.assert_live_install_untouched(result)
        self.assertTrue(os.path.exists(os.path.join(self.venv, "site", "mlx_whisper")))
        # The reason is the script's LAST line, which is what the app shows (F567).
        last_line = result.stderr.strip().splitlines()[-1]
        self.assertIn("Quick Dictation", last_line)
        self.assertIn("kept", last_line)

    def test_a_repair_that_cannot_reinstall_yt_dlp_keeps_the_working_install(self):
        harness.fake_whisper_venv(self.venv, "old", with_mlx_whisper=True, with_yt_dlp=True)
        result = self.sandbox.run(self.runtime, FAKE_PIP_FAIL="yt-dlp")
        self.assert_live_install_untouched(result)
        self.assertTrue(os.path.exists(os.path.join(self.venv, "bin", "yt-dlp")))
        self.assertIn("link", result.stderr.strip().splitlines()[-1])

    def test_a_tool_the_install_never_had_stays_best_effort(self):
        """The pre-F545 behaviour is still right when nothing working would be lost: a first
        install, or one that never had either tool, still completes without them."""
        harness.fake_whisper_venv(self.venv, "old")
        result = self.sandbox.run(self.runtime, FAKE_PIP_FAIL="mlx-whisper,yt-dlp")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(harness.read(os.path.join(self.venv, "MARKER")), "new")
        self.assertIn("Local Whisper is ready", result.stdout)

    def test_a_broken_meetings_runtime_is_still_repaired_without_the_tool(self):
        """Keeping a venv whose `whisper` does not run, to save Quick Dictation, would trade the
        meetings runtime for an optional feature — so only a WORKING install is protected."""
        harness.fake_whisper_venv(self.venv, "old", with_mlx_whisper=True)
        harness.write_executable(os.path.join(self.venv, "bin", "whisper"), "#!/bin/sh\nexit 1\n")
        result = self.sandbox.run(self.runtime, FAKE_PIP_FAIL="mlx-whisper")
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(harness.read(os.path.join(self.venv, "MARKER")), "new")

    def test_a_repair_where_everything_installs_swaps_in_the_new_venv(self):
        harness.fake_whisper_venv(self.venv, "old", with_mlx_whisper=True, with_yt_dlp=True)
        result = self.sandbox.run(self.runtime)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(harness.read(os.path.join(self.venv, "MARKER")), "new")
        self.assertTrue(os.path.exists(os.path.join(self.venv, "site", "mlx_whisper")))
        self.assertTrue(os.path.exists(os.path.join(self.venv, "bin", "yt-dlp")))
        self.assertEqual(harness.hidden_entries(self.runtime, ".venv-backup-"), [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
