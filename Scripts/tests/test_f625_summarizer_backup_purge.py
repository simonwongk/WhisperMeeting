#!/usr/bin/env python3
"""F625 — the summarizer installer's launch-time reclaim, run for real over a temp root.

Run: python3 Scripts/tests/test_f625_summarizer_backup_purge.py

F439 part 2 made `setup-local-summarizer.sh` purge a COMPLETE `.Summarizer-backup-<pid>` once the
live `Summarizer/` is complete, as `setup-qwen-asr.sh` and `setup-speaker-diarization.sh` already
did. Before it, only INCOMPLETE backups were removed, so a complete one (gigabytes of model) was
kept forever. That change was checked only by reading the three scripts side by side. The two
siblings have behavioural fixtures in Swift (`qwenInstallerRecovery` in
QwenInstallerRecoveryTests.swift, `diarizationInstallerRecoveryPromotesACompleteBackup` in
DiarizationInstallerScriptShapeTests.swift); this ports them to the summarizer.

Every test runs the real script, unmodified, with `SUMMARIZER_INSTALL_RECOVERY_ONLY=1` and a temp
target. That mode takes the lock, does the reclaim, and exits 0 before Homebrew, the free-space
check or any download (setup-local-summarizer.sh, the `exit 0` after the staging purge). It also
skips the Apple-silicon check, so no stand-ins are needed and this runs on any Mac. The script path
is resolved from this file's own location, so a copy of `Scripts/` runs against its own copy of
the installer.
"""

import os
import shutil
import subprocess
import tempfile
import unittest

_HERE = os.path.dirname(os.path.abspath(__file__))
_SCRIPT = os.path.normpath(os.path.join(_HERE, "..", "setup-local-summarizer.sh"))


def _write(path, content):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(content)


def _read(path):
    with open(path, encoding="utf-8") as handle:
        return handle.read()


def make_complete(directory, marker):
    """Exactly the three paths `runtime_is_complete` checks, plus a marker saying which copy this is."""
    python = os.path.join(directory, "venv", "bin", "python")
    _write(python, "#!/bin/sh\nexit 0\n")
    os.chmod(python, 0o755)
    _write(os.path.join(directory, "summarize_local.py"), "helper")
    _write(os.path.join(directory, "model", "model.safetensors"), "weights")
    _write(os.path.join(directory, "MARKER"), marker)
    return directory


def make_incomplete(directory, marker):
    """A complete runtime with its model removed, like a download that never finished."""
    make_complete(directory, marker)
    os.remove(os.path.join(directory, "model", "model.safetensors"))
    return directory


class SummarizerReclaimTests(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp(prefix="whispermeet-f625-")
        self.addCleanup(shutil.rmtree, self.root, True)
        self.target = os.path.join(self.root, "Summarizer")
        self.lock = os.path.join(self.root, ".Summarizer-install.lock")

    def hidden(self, prefix):
        return sorted(name for name in os.listdir(self.root) if name.startswith(prefix))

    def reclaim(self):
        environment = dict(os.environ)
        for key in list(environment):
            if key.endswith("_INSTALL_RECOVERY_ONLY"):
                del environment[key]
        # An inherited unknown model would make the script exit 1 before the reclaim.
        environment.pop("SUMMARIZER_REPOSITORY", None)
        environment["SUMMARIZER_INSTALL_RECOVERY_ONLY"] = "1"
        # zsh reads $ZDOTDIR/.zshenv even for a script; keep the host's out of it.
        environment["ZDOTDIR"] = self.root
        result = subprocess.run(
            ["/bin/zsh", _SCRIPT, self.target],
            env=environment,
            capture_output=True,
            text=True,
            timeout=60,
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertFalse(os.path.exists(self.lock), "the lock must be released on exit")
        return result

    def test_a_complete_backup_beside_a_complete_live_runtime_is_purged_and_the_live_one_kept(self):
        # The F439 part 2 case. The pre-F439 loop kept `.Summarizer-backup-444` here forever.
        make_complete(self.target, "live")
        _write(os.path.join(self.target, "embedding-model", "model.safetensors"), "search model")
        make_complete(os.path.join(self.root, ".Summarizer-backup-444"), "stale")
        make_incomplete(os.path.join(self.root, ".Summarizer-backup-555"), "half")
        os.makedirs(os.path.join(self.root, ".Summarizer-install-666"))

        self.reclaim()

        self.assertEqual(self.hidden(".Summarizer-backup-"), [], "a complete live runtime makes every backup stale")
        self.assertEqual(self.hidden(".Summarizer-install-"), [])
        self.assertEqual(_read(os.path.join(self.target, "MARKER")), "live", "the live runtime must never be replaced")
        self.assertEqual(
            _read(os.path.join(self.target, "embedding-model", "model.safetensors")), "search model",
            "Ask Meetings' model lives inside Summarizer/ and must survive the reclaim",
        )

    def test_with_no_live_runtime_a_complete_backup_is_promoted_and_the_rest_removed(self):
        make_complete(os.path.join(self.root, ".Summarizer-backup-111"), "old")
        make_incomplete(os.path.join(self.root, ".Summarizer-backup-222"), "half")
        os.makedirs(os.path.join(self.root, ".Summarizer-install-333"))

        result = self.reclaim()

        self.assertEqual(_read(os.path.join(self.target, "MARKER")), "old")
        self.assertIn("Restored the previous summarization model", result.stderr)
        self.assertEqual(self.hidden(".Summarizer-backup-"), [])
        self.assertEqual(self.hidden(".Summarizer-install-"), [])

    def test_the_promoted_runtime_then_purges_a_later_complete_backup(self):
        # Both phases of the Swift sibling fixtures, in order, over the same root.
        make_complete(os.path.join(self.root, ".Summarizer-backup-111"), "old")
        self.reclaim()
        make_complete(os.path.join(self.root, ".Summarizer-backup-444"), "stale")
        os.makedirs(os.path.join(self.root, ".Summarizer-install-555"))

        self.reclaim()

        self.assertEqual(self.hidden(".Summarizer-backup-"), [])
        self.assertEqual(self.hidden(".Summarizer-install-"), [])
        self.assertEqual(_read(os.path.join(self.target, "MARKER")), "old")

    def test_a_complete_backup_is_kept_while_the_live_runtime_is_incomplete(self):
        # The other side of the same condition: when Summarizer/ exists but is broken, the complete
        # backup is the only working copy left, so the purge must not take it. Only the incomplete
        # backup goes.
        make_incomplete(self.target, "broken live")
        make_complete(os.path.join(self.root, ".Summarizer-backup-777"), "good")
        make_incomplete(os.path.join(self.root, ".Summarizer-backup-888"), "half")

        self.reclaim()

        self.assertEqual(self.hidden(".Summarizer-backup-"), [".Summarizer-backup-777"])
        self.assertEqual(_read(os.path.join(self.root, ".Summarizer-backup-777", "MARKER")), "good")
        self.assertEqual(_read(os.path.join(self.target, "MARKER")), "broken live")


if __name__ == "__main__":
    unittest.main(verbosity=2)
