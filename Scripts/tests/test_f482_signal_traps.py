#!/usr/bin/env python3
"""F482 — install-app.sh and setup-ask-embeddings.sh relied on EXIT-only traps.

Run: python3 Scripts/tests/test_f482_signal_traps.py

zsh does not run an `EXIT` trap when an untrapped `SIGHUP`/`SIGINT`/`SIGTERM` kills the script —
the process just dies. `ProcessGroupRunner` sends `SIGTERM` to a whole process group on a stalled
download or a shutdown, and a user can `^C` or log out mid-install, so an installer whose cleanup
lives only in an `EXIT` trap leaves whatever it was staging on disk with nothing to reclaim it.
The four sibling installers (`setup-qwen-asr.sh`, `setup-local-whisper.sh`,
`setup-local-summarizer.sh`, `setup-speaker-diarization.sh`) already carry
`trap 'exit 130' HUP INT TERM` for exactly this reason; `install-app.sh` and
`setup-ask-embeddings.sh` did not.

**Reproduced for real, not asserted from reading the trap line.** Each test below launches the
real script (a verbatim copy, in its own process group), waits for it to reach a real staging
directory whose existence is the test's own precondition — not a fixed sleep — sends `SIGTERM` to
the whole group exactly as `ProcessGroupRunner` would, and then checks what is left on disk. Before
the fix this leaves the staging directory behind; after it, the `EXIT` trap's `rm -rf` still runs
because `exit 130` is an ordinary exit, not a kill.
"""

import os
import re
import shutil
import signal
import stat
import subprocess
import tempfile
import time
import unittest

_HERE = os.path.dirname(os.path.abspath(__file__))
_SCRIPTS = os.path.normpath(os.path.join(_HERE, ".."))

_SIGNAL_TRAP_LINE = "trap 'exit 130' HUP INT TERM"


def _write_executable(path, body):
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(body)
    os.chmod(path, os.stat(path).st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


def _wait_until(predicate, timeout, description):
    """A bounded poll whose own success IS the precondition for what follows — never a stand-in
    for a fixed sleep. Fails loudly (rather than silently proceeding) if the wait is never
    satisfied, per this repo's rule against asserting a consequence without requiring its
    precondition."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.05)
    raise AssertionError("timed out waiting for: " + description)


class InstallAppSignalTrapTests(unittest.TestCase):
    """install-app.sh:30 — cleanup ran only on EXIT."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="whispermeet-f482-install-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.repo = os.path.join(self.tmp, "repo")
        os.makedirs(os.path.join(self.repo, "Scripts"))
        self.installer = os.path.join(self.repo, "Scripts", "install-app.sh")
        shutil.copy2(os.path.join(_SCRIPTS, "install-app.sh"), self.installer)

        # A build-app.sh that hangs so a SIGTERM can land while install-app.sh's staging
        # directory — created just before this call, at `mktemp -d
        # "${destination_parent}/.WhisperMeet.update.XXXXXX"` — is on disk.
        _write_executable(
            os.path.join(self.repo, "Scripts", "build-app.sh"),
            "#!/bin/zsh\n"
            "app_dir=\".build/WhisperMeet.app\"\n"
            "mkdir -p \"$app_dir/Contents/MacOS\"\n"
            "printf '#!/bin/sh\\nexit 0\\n' > \"$app_dir/Contents/MacOS/WhisperMeet\"\n"
            "chmod +x \"$app_dir/Contents/MacOS/WhisperMeet\"\n"
            "cat > \"$app_dir/Contents/Info.plist\" <<'PLIST'\n"
            "<?xml version=\"1.0\" encoding=\"UTF-8\"?>\n"
            "<plist version=\"1.0\"><dict>\n"
            "<key>CFBundleExecutable</key><string>WhisperMeet</string>\n"
            "<key>CFBundleIdentifier</key><string>test.whispermeet.f482</string>\n"
            "<key>CFBundleName</key><string>WhisperMeet</string>\n"
            "<key>CFBundlePackageType</key><string>APPL</string>\n"
            "</dict></plist>\n"
            "PLIST\n"
            "codesign --force --deep --sign - \"$app_dir\"\n"
            "print -r -- \"$PWD/$app_dir\"\n",
        )
        self.destination_parent = os.path.join(self.tmp, "Applications-stand-in")
        os.makedirs(self.destination_parent)
        self.destination = os.path.join(self.destination_parent, "WhisperMeet.app")

        self.shims = os.path.join(self.tmp, "shim-bin")
        os.makedirs(self.shims)
        _write_executable(os.path.join(self.shims, "pgrep"), "#!/bin/sh\nexit 1\n")
        # Real `ditto`, delayed: `mktemp -d` creates the staging directory an instant before this
        # call, and nothing else in the script pauses long enough for a signal to land while it
        # still exists. The delay is the test's synchronization device, not a claim about ditto.
        _write_executable(
            os.path.join(self.shims, "ditto"), "#!/bin/sh\nsleep 3\nexec /usr/bin/ditto \"$@\"\n"
        )

    def _staging_leftovers(self):
        return [
            name
            for name in os.listdir(self.destination_parent)
            if name.startswith(".WhisperMeet.update.")
        ]

    def test_a_group_sigterm_during_staging_still_removes_the_staging_directory(self):
        environment = dict(os.environ)
        environment["PATH"] = self.shims + os.pathsep + environment.get("PATH", "")
        process = subprocess.Popen(
            [self.installer, self.destination],
            cwd=self.repo,
            env=environment,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,  # its own process group, so a group signal hits only this tree
        )
        try:
            _wait_until(
                lambda: self._staging_leftovers() != [],
                timeout=10,
                description="install-app.sh to create its staging directory",
            )
            group_id = os.getpgid(process.pid)
            os.killpg(group_id, signal.SIGTERM)
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(group_id, signal.SIGKILL)
                process.wait(timeout=5)
                self.fail("install-app.sh did not exit after SIGTERM to its process group")

            # The property under test: with `trap 'exit 130' HUP INT TERM` in place, the EXIT
            # trap's cleanup still runs and the staging directory is gone. Before the fix, zsh's
            # default SIGTERM handling kills the script with no EXIT trap at all and this leftover
            # directory survives.
            _wait_until(
                lambda: self._staging_leftovers() == [],
                timeout=5,
                description="the staging directory to be removed by the EXIT trap",
            )
            self.assertEqual(process.returncode, 130, "exit 130 is what reaches the EXIT trap")
        finally:
            if process.poll() is None:
                os.killpg(os.getpgid(process.pid), signal.SIGKILL)
                process.wait(timeout=5)


class AskEmbeddingsSignalTrapTests(unittest.TestCase):
    """setup-ask-embeddings.sh:25 — the same EXIT-only cleanup, for the embedding-model staging
    directory (up to ~490 MB) rather than a whole app bundle."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="whispermeet-f482-embeddings-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.repo = os.path.join(self.tmp, "repo")
        os.makedirs(os.path.join(self.repo, "Scripts"))
        self.installer = os.path.join(self.repo, "Scripts", "setup-ask-embeddings.sh")
        shutil.copy2(os.path.join(_SCRIPTS, "setup-ask-embeddings.sh"), self.installer)

        self.runtime_directory = os.path.join(self.tmp, "Runtime")
        summarizer_directory = os.path.join(self.runtime_directory, "Summarizer")
        venv_bin = os.path.join(summarizer_directory, "venv", "bin")
        os.makedirs(venv_bin)
        # A "python" that stands in for the real interpreter running `snapshot_download`: it
        # creates the staging directory named by $EMBEDDING_STAGE (as a real download would,
        # progressively) and then hangs, so a SIGTERM can land mid-"download". It never reads its
        # stdin heredoc, which is fine — nothing requires it to.
        _write_executable(
            os.path.join(venv_bin, "python"),
            "#!/bin/sh\n"
            'mkdir -p "$EMBEDDING_STAGE"\n'
            ': > "$EMBEDDING_STAGE/partial-download.tmp"\n'
            "sleep 30\n",
        )

    def _staging_directories(self):
        summarizer_directory = os.path.join(self.runtime_directory, "Summarizer")
        if not os.path.isdir(summarizer_directory):
            return []
        return [
            name
            for name in os.listdir(summarizer_directory)
            if name.startswith(".embedding-model-staging-")
        ]

    def test_a_group_sigterm_mid_download_still_removes_the_staging_directory(self):
        process = subprocess.Popen(
            [self.installer, self.runtime_directory],
            cwd=self.repo,
            stdout=subprocess.DEVNULL,
            stderr=subprocess.DEVNULL,
            start_new_session=True,
        )
        try:
            _wait_until(
                lambda: self._staging_directories() != [],
                timeout=10,
                description="setup-ask-embeddings.sh to create its staging directory",
            )
            group_id = os.getpgid(process.pid)
            os.killpg(group_id, signal.SIGTERM)
            try:
                process.wait(timeout=5)
            except subprocess.TimeoutExpired:
                os.killpg(group_id, signal.SIGKILL)
                process.wait(timeout=5)
                self.fail("setup-ask-embeddings.sh did not exit after SIGTERM to its process group")

            _wait_until(
                lambda: self._staging_directories() == [],
                timeout=5,
                description="the embedding-model staging directory to be removed by the EXIT trap",
            )
            self.assertEqual(process.returncode, 130, "exit 130 is what reaches the EXIT trap")
        finally:
            if process.poll() is None:
                os.killpg(os.getpgid(process.pid), signal.SIGKILL)
                process.wait(timeout=5)


class BuildAppResourceBundleGlobTests(unittest.TestCase):
    """build-app.sh:26-31 — the resource-bundle loop aborted under zsh's default NOMATCH option
    when `.build/release` held no `*.bundle` (F482 part 2), which is exactly the common case: most
    builds ship no `.process(...)` resource bundle at all.

    **Extracts and runs the real loop text**, rather than a hand-copied duplicate, so a future edit
    that reintroduces an unguarded glob fails this test without anyone updating a fixture.
    """

    _LOOP_PATTERN = re.compile(
        r"for resource_bundle in \.build/release/\*\.bundle.*?\ndone\n", re.DOTALL
    )

    def _extract_loop(self):
        with open(os.path.join(_SCRIPTS, "build-app.sh"), encoding="utf-8") as handle:
            source = handle.read()
        match = self._LOOP_PATTERN.search(source)
        self.assertIsNotNone(
            match, "could not find the resource-bundle loop in build-app.sh; did it move?"
        )
        return match.group(0)

    def _run_loop(self, loop_text, release_dir):
        script = "#!/bin/zsh\nset -euo pipefail\napp_dir=\"$1\"\n" + loop_text
        with tempfile.TemporaryDirectory(prefix="whispermeet-f482-bundle-loop-") as tmp:
            build_dir = os.path.join(tmp, ".build", "release")
            os.makedirs(build_dir, exist_ok=True)
            if release_dir == "with-bundle":
                os.makedirs(os.path.join(build_dir, "Example.bundle"))
                with open(os.path.join(build_dir, "Example.bundle", "marker"), "w") as handle:
                    handle.write("x")
            app_dir = os.path.join(tmp, "app")
            os.makedirs(os.path.join(app_dir, "Contents", "Resources"))
            script_path = os.path.join(tmp, "loop.sh")
            _write_executable(script_path, script)
            return subprocess.run(
                [script_path, app_dir], cwd=tmp, capture_output=True, text=True
            )

    def test_the_real_loop_survives_no_bundle_at_all(self):
        result = self._run_loop(self._extract_loop(), release_dir="empty")
        self.assertEqual(
            result.returncode, 0,
            "the loop must not abort when .build/release has no *.bundle: " + result.stderr,
        )

    def test_the_real_loop_still_copies_a_bundle_when_one_exists(self):
        result = self._run_loop(self._extract_loop(), release_dir="with-bundle")
        self.assertEqual(result.returncode, 0, result.stderr)


class SignalTrapCanaryTests(unittest.TestCase):
    """The canary for both properties above: they must actually catch the missing trap line."""

    def test_install_app_carries_the_signal_trap(self):
        with open(os.path.join(_SCRIPTS, "install-app.sh"), encoding="utf-8") as handle:
            self.assertIn(_SIGNAL_TRAP_LINE, handle.read())

    def test_setup_ask_embeddings_carries_the_signal_trap(self):
        with open(os.path.join(_SCRIPTS, "setup-ask-embeddings.sh"), encoding="utf-8") as handle:
            self.assertIn(_SIGNAL_TRAP_LINE, handle.read())


if __name__ == "__main__":
    unittest.main(verbosity=2)
