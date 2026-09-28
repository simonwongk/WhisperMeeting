"""Runs the REAL installer scripts against a temp root, with only Homebrew and the network stood in.

Not a suite (no `test_` prefix, so `Scripts/quality-check.sh`'s glob does not run it on its own) —
`test_f545_whisper_repair_keeps_optional_tools.py` and `test_f520_installer_cancel_restores.py`
import it.

**What is real and what is not.** Every line of the installer runs verbatim — the lock, the
reclaim, the staging, the swap, the traps — except the Homebrew block (which would install
FFmpeg/Python on the host) and the free-space probe (whose answer is a property of the host, which a
test must never assert on). Those two are replaced by one literal each, found by anchored patterns
that fail loudly if the script is reworded, so this cannot silently start testing a different
script. `pip`, the Hugging Face download and `curl` are served by a fake interpreter and PATH shims
that behave like the real ones as far as the script can observe: they create the files the script
checks for, fail on request, or block on request so a test can deliver a signal mid-install.
"""

import os
import re
import shutil
import signal
import stat
import subprocess
import sys
import tempfile
import time

_HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPTS = os.path.normpath(os.path.join(_HERE, ".."))
REPOSITORY = os.path.normpath(os.path.join(SCRIPTS, ".."))

# From the Homebrew probe through the line that derives the interpreter from it. The same shape in
# setup-local-whisper.sh (with the FFmpeg install inside it), setup-qwen-asr.sh and
# setup-local-summarizer.sh.
_HOMEBREW_BLOCK = re.compile(
    r"if \[\[ -x /opt/homebrew/bin/brew \]\]; then\n.*?\n"
    r'python_executable="\$\(\$brew_executable --prefix python@3\.11\)/bin/python3\.11"\n',
    re.DOTALL,
)
_FREE_SPACE_PROBE = re.compile(
    r"""available_kib="\$\(df -Pk "\$runtime_parent" \| awk 'NR == 2 \{ print \$4 \}'\)"\n"""
)

# The fake interpreter. It is copied into every venv the script creates, so `venv/bin/python` is
# this file and it knows which venv it belongs to from its own path.
_FAKE_PYTHON = r'''#!{real_python}
import os, sys, time

REAL_PYTHON = {real_python!r}
HERE = os.path.dirname(os.path.abspath(__file__))
VENV = os.path.dirname(HERE)
args = sys.argv[1:]
failing = set(filter(None, os.environ.get("FAKE_PIP_FAIL", "").split(",")))


def log(line):
    path = os.environ.get("FAKE_LOG")
    if path:
        with open(path, "a", encoding="utf-8") as handle:
            handle.write(line + "\n")


def maybe_block(step):
    """Create the marker and hang, so a test can signal the process group mid-step."""
    if os.environ.get("FAKE_BLOCK_AT") == step:
        with open(os.environ["FAKE_BLOCK_MARKER"], "w", encoding="utf-8") as handle:
            handle.write(step)
        time.sleep(60)


def write_executable(path, body):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(body)
    os.chmod(path, 0o755)


log("python " + " ".join(args))

if args[:2] == ["-m", "venv"]:
    target = args[2]
    os.makedirs(os.path.join(target, "bin"), exist_ok=True)
    with open(os.path.abspath(__file__), encoding="utf-8") as handle:
        write_executable(os.path.join(target, "bin", "python"), handle.read())
    with open(os.path.join(target, "MARKER"), "w", encoding="utf-8") as handle:
        handle.write(os.environ.get("FAKE_NEW_MARKER", "new"))
    sys.exit(0)

if args[:2] == ["-m", "pip"]:
    spec = args[-1]
    name = spec.split("==")[0]
    maybe_block("pip:" + name)
    if name in failing:
        print("ERROR: No matching distribution found for " + spec, file=sys.stderr)
        sys.exit(1)
    if name == "openai-whisper":
        # A console script that answers --help, and can hang on its Nth call so a test can
        # signal the post-swap verification.
        write_executable(os.path.join(VENV, "bin", "whisper"),
            "#!/bin/sh\n"
            'if [ -n "$FAKE_WHISPER_BLOCK_CALL" ]; then\n'
            '  count_file="$FAKE_WHISPER_COUNT"\n'
            '  n=$(cat "$count_file" 2>/dev/null || echo 0); n=$((n + 1)); echo "$n" > "$count_file"\n'
            '  if [ "$n" = "$FAKE_WHISPER_BLOCK_CALL" ]; then echo whisper > "$FAKE_BLOCK_MARKER"; sleep 60; fi\n'
            "fi\n"
            "exit 0\n")
    elif name == "yt-dlp":
        write_executable(os.path.join(VENV, "bin", "yt-dlp"), "#!/bin/sh\nexit 0\n")
    else:
        os.makedirs(os.path.join(VENV, "site"), exist_ok=True)
        open(os.path.join(VENV, "site", name.replace("-", "_")), "w").close()
    sys.exit(0)

if args[:1] == ["-c"]:
    code = args[1]
    for module in ("mlx_whisper", "mlx_lm"):
        if "import " + module in code or "from " + module in code:
            sys.exit(0 if os.path.exists(os.path.join(VENV, "site", module)) else 1)
    sys.exit(0)

if args[:1] == ["-"]:
    if len(args) > 1:
        # setup-local-whisper.sh's shebang rewrite: run the script's own code for real.
        os.execv(REAL_PYTHON, [REAL_PYTHON, "-"] + args[1:])
    # A Hugging Face download heredoc. No network in a test: fail like a dead connection.
    maybe_block("download")
    print("huggingface_hub.errors.LocalEntryNotFoundError: no network in this test", file=sys.stderr)
    sys.exit(1)

# `<helper>.py --help` and anything else: succeed.
sys.exit(0)
'''


def write_executable(path, body):
    os.makedirs(os.path.dirname(path), exist_ok=True)
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(body)
    os.chmod(path, os.stat(path).st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


def wait_until(predicate, timeout, description):
    """A bounded poll whose own success IS the precondition for what follows; it raises rather
    than letting the caller assert a consequence of a wait that never happened."""
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(0.05)
    raise AssertionError("timed out waiting for: " + description)


class InstallerSandbox:
    """A temp root holding a copy of one real installer, its runtime directory, and the stand-ins."""

    def __init__(self, script_name):
        self.root = tempfile.mkdtemp(prefix="whispermeet-installer-")
        self.repo = os.path.join(self.root, "repo")
        self.scripts = os.path.join(self.repo, "Scripts")
        os.makedirs(self.scripts)
        self.shims = os.path.join(self.root, "shims")
        os.makedirs(self.shims)
        self.block_marker = os.path.join(self.root, "blocked")
        self.log = os.path.join(self.root, "fake.log")
        self.fake_python = os.path.join(self.root, "fake-python", "python3.11")
        write_executable(self.fake_python, _FAKE_PYTHON.format(real_python=sys.executable))
        # Qwen, the summarizer and speaker analysis refuse Intel; the host's architecture is not
        # what these tests are about.
        write_executable(
            os.path.join(self.shims, "uname"),
            '#!/bin/sh\ncase "$1" in -m) echo arm64 ;; *) echo Darwin ;; esac\n',
        )
        self.script = os.path.join(self.scripts, script_name)
        with open(os.path.join(SCRIPTS, script_name), encoding="utf-8") as handle:
            source = handle.read()
        self.source = source
        with open(self.script, "w", encoding="utf-8") as handle:
            handle.write(self._stand_in_for_the_host(source))
        os.chmod(self.script, 0o755)

    def _stand_in_for_the_host(self, source):
        if "python_executable=" in source:
            source, count = _HOMEBREW_BLOCK.subn(
                'python_executable="{}"\n'.format(self.fake_python), source
            )
            if count != 1:
                raise AssertionError(
                    "the Homebrew block in {} was not found exactly once; did it move or get "
                    "reworded? Update installer_harness._HOMEBREW_BLOCK.".format(self.script)
                )
        if "available_kib=" in source:
            source, count = _FREE_SPACE_PROBE.subn('available_kib="999999999"\n', source)
            if count != 1:
                raise AssertionError(
                    "the free-space probe in {} was not found exactly once; update "
                    "installer_harness._FREE_SPACE_PROBE.".format(self.script)
                )
        return source

    def cleanup(self):
        shutil.rmtree(self.root, True)

    def copy_sibling(self, name):
        shutil.copy2(os.path.join(SCRIPTS, name), os.path.join(self.scripts, name))

    def environment(self, **overrides):
        environment = dict(os.environ)
        for key in list(environment):
            if key.endswith("_INSTALL_RECOVERY_ONLY") or key.startswith("FAKE_"):
                del environment[key]
        environment["PATH"] = self.shims + os.pathsep + environment.get("PATH", "")
        environment["FAKE_LOG"] = self.log
        environment["FAKE_BLOCK_MARKER"] = self.block_marker
        environment.update({key: str(value) for key, value in overrides.items()})
        return environment

    def run(self, argument, timeout=60, **overrides):
        return subprocess.run(
            [self.script, argument],
            cwd=self.repo,
            env=self.environment(**overrides),
            capture_output=True,
            text=True,
            timeout=timeout,
        )

    def run_and_terminate_group(self, argument, blocked_step, **overrides):
        """Starts the installer in its own process group, waits until the fake reaches
        `blocked_step`, then sends SIGTERM to the whole group — exactly what
        `ProcessGroupRunner.cancel()` does — and returns (returncode, stderr)."""
        stderr_path = os.path.join(self.root, "stderr.txt")
        with open(stderr_path, "w", encoding="utf-8") as stderr:
            process = subprocess.Popen(
                [self.script, argument],
                cwd=self.repo,
                env=self.environment(FAKE_BLOCK_AT=blocked_step, **overrides),
                stdout=subprocess.DEVNULL,
                stderr=stderr,
                start_new_session=True,
            )
            try:
                wait_until(
                    lambda: os.path.exists(self.block_marker) or process.poll() is not None,
                    timeout=30,
                    description="the installer to reach " + blocked_step,
                )
                if process.poll() is not None:
                    with open(stderr_path, encoding="utf-8") as handle:
                        raise AssertionError(
                            "the installer exited ({}) before reaching {}:\n{}".format(
                                process.returncode, blocked_step, handle.read()
                            )
                        )
                os.killpg(os.getpgid(process.pid), signal.SIGTERM)
                process.wait(timeout=30)
            finally:
                if process.poll() is None:
                    os.killpg(os.getpgid(process.pid), signal.SIGKILL)
                    process.wait(timeout=10)
        with open(stderr_path, encoding="utf-8") as handle:
            return process.returncode, handle.read()


def fake_whisper_venv(path, marker, with_mlx_whisper=False, with_yt_dlp=False):
    """A working Local Whisper venv as the installer sees one: `bin/whisper --help` runs, `MARKER`
    says which install this is, and the optional tools are present when asked for."""
    write_executable(os.path.join(path, "bin", "whisper"), "#!/bin/sh\nexit 0\n")
    write_executable(
        os.path.join(path, "bin", "python"),
        _FAKE_PYTHON.format(real_python=sys.executable),
    )
    with open(os.path.join(path, "MARKER"), "w", encoding="utf-8") as handle:
        handle.write(marker)
    if with_mlx_whisper:
        os.makedirs(os.path.join(path, "site"), exist_ok=True)
        open(os.path.join(path, "site", "mlx_whisper"), "w").close()
    if with_yt_dlp:
        write_executable(os.path.join(path, "bin", "yt-dlp"), "#!/bin/sh\nexit 0\n")
    return path


def read(path):
    with open(path, encoding="utf-8") as handle:
        return handle.read()


def hidden_entries(directory, prefix):
    if not os.path.isdir(directory):
        return []
    return sorted(name for name in os.listdir(directory) if name.startswith(prefix))
