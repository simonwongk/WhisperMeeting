#!/usr/bin/env python3
"""F654 — a Cancel that lands after an install has switched over finishes it, and says so.

Run: python3 Scripts/tests/test_f654_cancel_after_switch_over.py

F520 made installs cancellable: SIGTERM to the installer's process group, whose `trap 'exit 130'`
runs the EXIT trap that puts the previous runtime back. That is right until the new runtime has
been switched in. After that there is nothing to put back — only the old copy's deletion (up to
~4.5 GB for Qwen) is left — yet the script still exited 130, and the app reported "Installation
cancelled. The previous version was kept." with the new version live (review probe P3).

Each installer now ignores HUP/INT/TERM from the moment it starts the switch-over, so a Cancel or
Quit there lets it finish and exit 0; the app reads a cancelled run that exited 0 as installed.
These deliver the signal at that point to the real scripts (via `installer_harness`), with a shim
that holds the step until the signal has been sent and then lets it continue.
"""

import os
import re
import unittest

import installer_harness as harness

# The switch-over in each installer: the first line that moves the live runtime aside.
_SWITCH_OVER = {
    "setup-local-whisper.sh": 'mv "$venv_target" "$backup_venv"',
    "setup-qwen-asr.sh": 'mv "$target_directory" "$backup_directory"',
    "setup-local-summarizer.sh": 'mv "$target_directory/embedding-model" "$staging_directory/embedding-model"',
    "setup-speaker-diarization.sh": 'mv "$target_directory" "$backup_directory"',
    "setup-ask-embeddings.sh": 'mv "$target" "$previous"',
}
_IGNORE = "trap '' HUP INT TERM"


def _write(path, content=""):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(content)


def _code_lines(name):
    with open(os.path.join(harness.SCRIPTS, name), encoding="utf-8") as handle:
        return [line.strip() for line in handle if not line.strip().startswith("#")]


class SwitchOverIgnoresTerminationTests(unittest.TestCase):
    """Where the line sits is the guarantee, so it is pinned for all five installers — including
    speaker analysis and the search model, whose switch-over the behavioural tests below cannot
    reach without their real downloads."""

    def test_each_installer_stops_honouring_cancel_exactly_where_there_is_nothing_left_to_put_back(self):
        for name, first_move in _SWITCH_OVER.items():
            with self.subTest(name=name):
                lines = _code_lines(name)
                self.assertEqual(lines.count(_IGNORE), 1, "{}: expected one `{}`".format(name, _IGNORE))
                ignore_at = lines.index(_IGNORE)
                moves = [i for i, line in enumerate(lines) if first_move in line]
                self.assertTrue(moves, "{}: the switch-over `{}` moved; update this test".format(name, first_move))
                if name == "setup-local-whisper.sh":
                    # Whisper's new venv is verified at the live path after the move — seconds, with
                    # real torch — and F520's rollback of that must stay cancellable. Its point of no
                    # return is activation.
                    activation = lines.index("activation_complete=1")
                    self.assertEqual(ignore_at, activation + 1, name)
                else:
                    self.assertLess(ignore_at, moves[0], "{}: signals are still honoured during the switch-over".format(name))
                    # Nothing that can still fail — no verification, no `exit 1` — sits between.
                    between = lines[ignore_at + 1:moves[0]]
                    self.assertFalse([line for line in between if "exit 1" in line], name)


class CancelDuringSwitchOverTests(unittest.TestCase):
    def _shasum_shim(self, sandbox, by_suffix):
        cases = "".join('  */{}) echo "{}  $3" ;;\n'.format(suffix, digest) for suffix, digest in by_suffix)
        harness.write_executable(
            os.path.join(sandbox.shims, "shasum"),
            '#!/bin/sh\ncase "$3" in\n' + cases + '  *) exec /usr/bin/shasum "$@" ;;\nesac\n',
        )

    def _hold(self, sandbox, command, pattern):
        """Hold `command` whose path operand matches `pattern` and exists, until the signal has been
        sent. (Existence skips Whisper's pre-swap `rm -rf` of a same-PID leftover backup, which
        precedes the switch-over and must stay cancellable.)"""
        operand = "$2" if command == "rm" else "$1"
        harness.write_executable(
            os.path.join(sandbox.shims, command),
            "#!/bin/sh\n"
            'case "%s" in %s) if [ -e "%s" ] && [ ! -e "$FAKE_BLOCK_MARKER" ]; then\n%sfi ;; esac\n'
            'exec /bin/%s "$@"\n' % (operand, pattern, operand,
                                     harness.hold_until_released(command), command),
        )

    def _pins(self, sandbox, *names):
        found = dict(re.findall(r'^\s*({})="([0-9a-f]{{64}})"$'.format("|".join(names)),
                                sandbox.source, re.MULTILINE))
        self.assertEqual(set(found), set(names), "pinned hashes moved; update this test")
        return found

    def test_whisper_cancelled_while_deleting_the_old_venv_finishes_and_exits_0(self):
        sandbox = harness.InstallerSandbox("setup-local-whisper.sh")
        self.addCleanup(sandbox.cleanup)
        runtime = os.path.join(sandbox.root, "Runtime")
        venv = os.path.join(runtime, "venv")
        harness.fake_whisper_venv(venv, "old", with_mlx_whisper=True, with_yt_dlp=True)
        self._hold(sandbox, "rm", "*/.venv-backup-*")

        returncode, stderr = sandbox.run_and_terminate_group(runtime, "rm-backup")

        self.assertEqual(returncode, 0, "the switch-over was reported as cancelled\n" + stderr)
        self.assertEqual(harness.read(os.path.join(venv, "MARKER")), "new")
        self.assertEqual(harness.hidden_entries(runtime, ".venv-"), [], "the old venv was left behind")

    def test_qwen_cancelled_during_the_swap_finishes_and_exits_0(self):
        sandbox = harness.InstallerSandbox("setup-qwen-asr.sh")
        self.addCleanup(sandbox.cleanup)
        sandbox.copy_sibling("qwen_transcribe.py")
        sandbox.copy_sibling("qwen_dictate_server.py")
        pins = self._pins(sandbox, "asr_sha256", "aligner_sha256")
        self._shasum_shim(sandbox, [("model/model.safetensors", pins["asr_sha256"]),
                                    ("aligner/model.safetensors", pins["aligner_sha256"])])
        runtime = os.path.join(sandbox.root, "Runtime")
        target = os.path.join(runtime, "Qwen3ASR")
        _write(os.path.join(target, "MARKER"), "old")
        self._hold(sandbox, "mv", "*/.Qwen3ASR-install-*")

        returncode, stderr = sandbox.run_and_terminate_group(target, "swap", FAKE_DOWNLOAD_SUCCEEDS=1)

        self.assertEqual(returncode, 0, "the switch-over was reported as cancelled\n" + stderr)
        self.assertTrue(os.path.isfile(os.path.join(target, "MANIFEST")), "the new runtime is not live")
        self.assertFalse(os.path.exists(os.path.join(target, "MARKER")), "the old runtime is still live")
        self.assertEqual(harness.hidden_entries(runtime, ".Qwen3ASR-"), [])

    def test_summarizer_cancelled_during_the_swap_finishes_and_keeps_the_search_model(self):
        sandbox = harness.InstallerSandbox("setup-local-summarizer.sh")
        self.addCleanup(sandbox.cleanup)
        for helper in ("summarize_local.py", "correct_local.py", "refine_server.py"):
            sandbox.copy_sibling(helper)
        pins = self._pins(sandbox, "default_sha256")
        self._shasum_shim(sandbox, [("model/model.safetensors", pins["default_sha256"])])
        runtime = os.path.join(sandbox.root, "Runtime")
        target = os.path.join(runtime, "Summarizer")
        _write(os.path.join(target, "MARKER"), "old")
        _write(os.path.join(target, "embedding-model", "model.safetensors"), "search model")
        self._hold(sandbox, "mv", "*/.Summarizer-install-*")

        returncode, stderr = sandbox.run_and_terminate_group(target, "swap", FAKE_DOWNLOAD_SUCCEEDS=1)

        self.assertEqual(returncode, 0, "the switch-over was reported as cancelled\n" + stderr)
        self.assertTrue(os.path.isfile(os.path.join(target, "MANIFEST")), "the new model is not live")
        self.assertFalse(os.path.exists(os.path.join(target, "MARKER")))
        self.assertEqual(harness.read(os.path.join(target, "embedding-model", "model.safetensors")), "search model")
        self.assertEqual(harness.hidden_entries(runtime, ".Summarizer-"), [])


if __name__ == "__main__":
    unittest.main(verbosity=2)
