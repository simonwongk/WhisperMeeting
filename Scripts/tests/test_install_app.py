#!/usr/bin/env python3
"""The packaging half of F188's Verification, which had been written down and never asserted.

Run: python3 Scripts/tests/test_install_app.py

F188's Verification names three packaging clauses:

  1. `install-app.sh` still stages a bundle;
  2. `quality-check.sh` never installs to `/Applications`;
  3. a stale, copied, or running instance cannot write the production library.

Clause 3 was F188's item 3. No code implements it and none will: F380 decided that two copies may
both write, and recorded the reasoning in `PRODUCT_SPEC.md`. It is deliberately absent here rather
than asserted in some weaker form.

**Clause 1 runs the real script, unmodified.** `install-app.sh` resolves its repo root from
`${0:A:h}/..`, so a verbatim copy inside a throwaway tree picks that tree up: its `build-app.sh` is
a stub that emits a minimal ad-hoc-signed bundle, and its destination is a temporary directory.
Neither this checkout nor `/Applications` is touched.

Two things are supplied rather than mocked away. `codesign` is the real one, because "the installer
verifies the signature before and after the swap" is half of what staging is FOR, and a stub would
assert nothing. `pgrep` is a shim on `PATH`, because the guard under test is "refuse while
WhisperMeet is running" and the honest way to drive both answers is to control the answer — the
alternative makes the suite pass or fail depending on whether the user happens to have the app
open, which is not a property of the installer.

**Corrected 2026-09-23 (F408).** The first version of this file could not fail on the properties it
was written for, and two independent mutations proved it. Both were reproduced here before being
fixed, in a throwaway copy of the tree so the real installer was never edited:

  * **Staging was never asserted.** Replacing the whole staging/verify/swap block with a bare
    `rm -rf "$destination"; ditto "$app_path" "$destination"` left all 7 tests passing. The suite
    checked that the destination existed, that it verified afterwards, and that no staging
    leftovers remained — every one of which is also true of an installer that never staged. The
    old `WhisperMeet.previous.app` assertion could not fail either: the backup lives inside
    `$staging_root`, so looking for it in the destination's parent asserts nothing.
  * **The `pgrep` shim answered the same on every call.** `install-app.sh` checks three times —
    before the build, after it, and after staging — and a constant shim means the "running" case
    always trips the first guard and the "not running" case never reaches the other two. Deleting
    guards 2 and 3 left all 7 tests passing.

Both are fixed by observing what the installer *did* rather than what it left behind: `codesign`,
`ditto` and `mv` are shimmed to log their arguments and then exec the real binary, and `pgrep`
counts its calls so each guard can be targeted individually.

**The gate runs this file, and therefore runs the real installer** — `quality-check.sh` globs
`Scripts/tests/test_*.py`. The only thing between that and the user's `/Applications` is
`install-app.sh:6`'s `destination="${1:-/Applications/WhisperMeet.app}"` honouring `$1`.
`GateIsNotAnInstallerTests` greps the gate's *text* and cannot see this, so `setUp` refuses to run
an installer that has stopped taking its destination from `$1`.
"""

import os
import re
import shutil
import stat
import subprocess
import tempfile
import unittest

_HERE = os.path.dirname(os.path.abspath(__file__))
_REPO = os.path.normpath(os.path.join(_HERE, "..", ".."))
_SCRIPTS = os.path.join(_REPO, "Scripts")

# The one line that keeps this suite — and so the quality gate — out of `/Applications`.
_DESTINATION_FROM_ARGV = 'destination="${1:-'

# A stub `build-app.sh`: same contract as the real one — build into `.build/WhisperMeet.app`, sign
# it, print the path — with the release build replaced by a two-file bundle. The real packager is
# exercised by the quality gate's step 5; what is under test here is the installer's handling of
# whatever the packager produced.
_STUB_BUILD_APP = """#!/bin/zsh
set -euo pipefail
cd "${0:A:h}/.."
app_dir=".build/WhisperMeet.app"
rm -rf "$app_dir"
mkdir -p "$app_dir/Contents/MacOS"
printf '#!/bin/sh\\nexit 0\\n' > "$app_dir/Contents/MacOS/WhisperMeet"
chmod +x "$app_dir/Contents/MacOS/WhisperMeet"
cat > "$app_dir/Contents/Info.plist" <<'PLIST'
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>CFBundleExecutable</key><string>WhisperMeet</string>
<key>CFBundleIdentifier</key><string>test.whispermeet.installer-fixture</string>
<key>CFBundleName</key><string>WhisperMeet</string>
<key>CFBundlePackageType</key><string>APPL</string>
</dict></plist>
PLIST
codesign --force --deep --sign - "$app_dir"
print -r -- "$PWD/$app_dir"
"""

# The same stub, but the bundle is corrupted *after* signing, so `codesign --verify --deep --strict`
# rejects it. This is what lets the staged-verification branch be driven at all: the installer's
# whole reason for verifying in staging is that a bad bundle must never reach the destination.
_STUB_BUILD_APP_BAD_SIGNATURE = _STUB_BUILD_APP.replace(
    'print -r -- "$PWD/$app_dir"',
    'printf \'tampered\\n\' >> "$app_dir/Contents/MacOS/WhisperMeet"\n'
    'print -r -- "$PWD/$app_dir"',
)


def _write_executable(path, body):
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(body)
    os.chmod(path, os.stat(path).st_mode | stat.S_IXUSR | stat.S_IXGRP | stat.S_IXOTH)


class InstallerStagingTests(unittest.TestCase):
    """Clause 1: `install-app.sh` still stages a bundle."""

    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="whispermeet-installer-test-")
        self.addCleanup(shutil.rmtree, self.tmp, True)

        self.repo = os.path.join(self.tmp, "repo")
        os.makedirs(os.path.join(self.repo, "Scripts"))
        # The real installer, byte for byte. Copying rather than editing is the point: a test that
        # runs a rewritten script proves something about the rewrite.
        self.installer = os.path.join(self.repo, "Scripts", "install-app.sh")
        shutil.copy2(os.path.join(_SCRIPTS, "install-app.sh"), self.installer)
        self._refuse_to_run_an_installer_that_ignores_argv(self.installer)
        _write_executable(os.path.join(self.repo, "Scripts", "build-app.sh"), _STUB_BUILD_APP)

        self.destination_parent = os.path.join(self.tmp, "Applications-stand-in")
        os.makedirs(self.destination_parent)
        self.destination = os.path.join(self.destination_parent, "WhisperMeet.app")

        self.shims = os.path.join(self.tmp, "shim-bin")
        os.makedirs(self.shims)
        self.command_log = os.path.join(self.tmp, "commands.log")
        self.pgrep_counter = os.path.join(self.tmp, "pgrep-calls")
        for name, real in (("codesign", "/usr/bin/codesign"),
                           ("ditto", "/usr/bin/ditto"),
                           ("mv", "/bin/mv")):
            self._install_logging_shim(name, real)

    # -- the /Applications canary (F408 part 3) ------------------------------------------------

    def _refuse_to_run_an_installer_that_ignores_argv(self, path):
        """Fail loudly rather than run an installer whose destination might not be `$1`.

        The quality gate globs `Scripts/tests/test_*.py`, so this file — and therefore the real
        `install-app.sh` — executes on every gate run. `_run_installer` passes the destination as
        `argv[1]` and nothing else constrains where the script writes. If a later edit hardcoded
        the destination or swallowed `$1` in a flag parser, the gate would move the user's
        installed app into a temporary staging directory, install a two-file stub over
        `/Applications/WhisperMeet.app`, and then `rm -rf` the staging root — with `pgrep` shimmed
        to "not running", so it would do this even mid-recording.

        Checking the text is enough because the failure mode is a *change to that line*. A test
        that discovered the problem by looking at `/Applications` afterwards would be performing
        the experiment this exists to prevent.
        """
        with open(path, encoding="utf-8") as handle:
            source = handle.read()
        self.assertIn(
            _DESTINATION_FROM_ARGV, source,
            "install-app.sh must take its destination from $1 before this suite may run it; "
            "the quality gate runs this file, so a hardcoded destination would install to the "
            "real /Applications on every gate run",
        )

    # -- observing what the installer did, not what it left behind (F408 part 1) ----------------

    def _install_logging_shim(self, name, real_path):
        """A `PATH` shim that records its arguments and then execs the real binary.

        Logging rather than faking: the installer's behaviour must not change, because the
        properties under test are about the *order* of real operations. Absolute paths on the
        `exec` line, or the shim would find itself.
        """
        _write_executable(
            os.path.join(self.shims, name),
            "#!/bin/sh\n"
            'printf "%s" "{name}" >> "{log}"\n'
            'for arg in "$@"; do printf "\\t%s" "$arg" >> "{log}"; done\n'
            'printf "\\n" >> "{log}"\n'
            'exec {real} "$@"\n'.format(name=name, log=self.command_log, real=real_path),
        )

    def _commands(self):
        if not os.path.exists(self.command_log):
            return []
        with open(self.command_log, encoding="utf-8") as handle:
            return [line.rstrip("\n").split("\t") for line in handle if line.strip()]

    def _first_index(self, predicate):
        for index, argv in enumerate(self._commands()):
            if predicate(argv):
                return index
        return None

    @staticmethod
    def _is_staging_path(value):
        return ".WhisperMeet.update." in value

    # -- driving the three running-app guards individually (F408 part 2) ------------------------

    def _set_app_running(self, running):
        """`pgrep -x WhisperMeet` answers yes (0) or no (1) on every call."""
        _write_executable(
            os.path.join(self.shims, "pgrep"),
            "#!/bin/sh\nexit {}\n".format(0 if running else 1),
        )

    def _set_app_running_on_call(self, trip):
        """Answer "not running" until call `trip`, then "running".

        `install-app.sh` asks three times — before the build, immediately after it, and after
        staging and verifying the copy — and each answer guards a different amount of destructive
        work. A shim that answers the same every time can only ever exercise the first of them,
        which is how guards 2 and 3 came to be deletable with the suite still green.
        """
        with open(self.pgrep_counter, "w", encoding="utf-8") as handle:
            handle.write("0")
        _write_executable(
            os.path.join(self.shims, "pgrep"),
            "#!/bin/sh\n"
            'calls=$(cat "{counter}" 2>/dev/null || printf 0)\n'
            "calls=$((calls + 1))\n"
            'printf "%s" "$calls" > "{counter}"\n'
            '[ "$calls" -eq {trip} ] && exit 0\n'
            "exit 1\n".format(counter=self.pgrep_counter, trip=trip),
        )

    def _pgrep_calls(self):
        with open(self.pgrep_counter, encoding="utf-8") as handle:
            return int(handle.read().strip() or 0)

    # -- shared plumbing ------------------------------------------------------------------------

    def _run_installer(self):
        environment = dict(os.environ)
        environment["PATH"] = self.shims + os.pathsep + environment.get("PATH", "")
        return subprocess.run(
            [self.installer, self.destination],
            capture_output=True,
            text=True,
            env=environment,
        )

    def _staging_leftovers(self):
        return [
            name
            for name in os.listdir(self.destination_parent)
            if name.startswith(".WhisperMeet.update.")
        ]

    def _place_previous_app(self):
        """An existing install, with a marker file so its survival can be told from its absence."""
        os.makedirs(os.path.join(self.destination, "Contents"), exist_ok=True)
        with open(os.path.join(self.destination, "Contents", "previous-marker"), "w") as handle:
            handle.write("the app that was here before")

    def _previous_app_survives(self):
        return os.path.exists(os.path.join(self.destination, "Contents", "previous-marker"))

    # -- clause 1 -------------------------------------------------------------------------------

    def test_a_bundle_is_staged_verified_and_swapped_into_place(self):
        self._set_app_running(False)
        result = self._run_installer()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Installed WhisperMeet at", result.stdout)

        self.assertTrue(os.path.isdir(self.destination))
        self.assertTrue(os.path.isfile(os.path.join(self.destination, "Contents", "MacOS", "WhisperMeet")))
        subprocess.run(
            ["codesign", "--verify", "--deep", "--strict", self.destination], check=True
        )
        self.assertEqual(self._staging_leftovers(), [])

    def test_the_staged_copy_is_verified_before_the_destination_is_touched(self):
        """The property an installer that never staged would fail, and the old suite could not.

        Existence, a passing signature and no leftovers are all true of `rm -rf "$destination";
        ditto "$app_path" "$destination"`, which is precisely the shape — destroy first, hope
        second — that staging exists to rule out. What distinguishes them is *order*, so order is
        what this asserts.
        """
        self._place_previous_app()
        self._set_app_running(False)
        result = self._run_installer()
        self.assertEqual(result.returncode, 0, result.stderr)

        verified_staged = self._first_index(
            lambda argv: argv[0] == "codesign" and "--verify" in argv
            and any(self._is_staging_path(a) for a in argv[1:])
        )
        self.assertIsNotNone(
            verified_staged,
            "no `codesign --verify` ran against a staged path; commands were:\n"
            + "\n".join(" ".join(a) for a in self._commands()),
        )

        touched_destination = self._first_index(
            lambda argv: argv[0] in ("mv", "ditto", "rm")
            and any(a == self.destination for a in argv[1:])
        )
        self.assertIsNotNone(touched_destination, "the destination was never written at all")
        self.assertLess(
            verified_staged, touched_destination,
            "the staged bundle must be verified BEFORE anything touches the installed app",
        )

    def test_the_destination_is_filled_by_moving_the_staged_bundle(self):
        """Not by copying over the live bundle in place, which is the same race under another name."""
        self._set_app_running(False)
        self.assertEqual(self._run_installer().returncode, 0)

        moved_into_place = [
            argv for argv in self._commands()
            if argv[0] == "mv" and len(argv) >= 3
            and self._is_staging_path(argv[-2]) and argv[-1] == self.destination
        ]
        self.assertTrue(
            moved_into_place,
            "expected `mv <staging>/WhisperMeet.app <destination>`; commands were:\n"
            + "\n".join(" ".join(a) for a in self._commands()),
        )
        copied_onto_destination = [
            argv for argv in self._commands()
            if argv[0] == "ditto" and argv[-1] == self.destination
        ]
        self.assertEqual(
            copied_onto_destination, [],
            "the installed bundle must never be written into directly",
        )

    def test_a_staged_bundle_that_fails_verification_never_reaches_the_destination(self):
        """The reason staging is worth its complexity, asserted from the failing side.

        Overlaps F381's first rollback branch; F381 still owns the other two (a failed swap, and a
        bundle that fails verification *after* the swap).
        """
        _write_executable(
            os.path.join(self.repo, "Scripts", "build-app.sh"), _STUB_BUILD_APP_BAD_SIGNATURE
        )
        self._place_previous_app()
        self._set_app_running(False)

        result = self._run_installer()
        self.assertNotEqual(result.returncode, 0, "a bundle failing codesign must not install")
        self.assertTrue(
            self._previous_app_survives(),
            "the previous app must still be there after a rejected update",
        )
        self.assertEqual(self._staging_leftovers(), [])

    # -- the running-app guards, one test each --------------------------------------------------

    def test_the_installer_refuses_while_the_app_is_running(self):
        self._place_previous_app()
        self._set_app_running(True)
        result = self._run_installer()
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("WhisperMeet is running", result.stderr)
        self.assertTrue(self._previous_app_survives())
        self.assertEqual(self._staging_leftovers(), [])

    def test_the_installer_refuses_when_the_app_starts_during_the_build(self):
        """Guard 2. The release build takes minutes, and the user can open the app inside them."""
        self._place_previous_app()
        self._set_app_running_on_call(2)
        result = self._run_installer()

        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("started while the update was being prepared", result.stderr)
        self.assertEqual(self._pgrep_calls(), 2, "guard 2 is the one that should have fired")
        self.assertTrue(self._previous_app_survives())
        self.assertEqual(self._staging_leftovers(), [])

    def test_the_installer_refuses_when_the_app_starts_after_staging(self):
        """Guard 3 — the last moment before the swap, and the only one with a staged bundle to clean up."""
        self._place_previous_app()
        self._set_app_running_on_call(3)
        result = self._run_installer()

        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("started before installation", result.stderr)
        self.assertEqual(self._pgrep_calls(), 3, "guard 3 is the one that should have fired")
        self.assertTrue(
            self._previous_app_survives(),
            "refusing at guard 3 must leave the installed app exactly as it was",
        )
        self.assertEqual(
            self._staging_leftovers(), [],
            "the staged bundle must be cleaned up when the installer refuses",
        )

    def _corrupt_the_bundle_as_it_is_swapped_in(self):
        """An `mv` shim that really moves, then damages what it moved (F381 branch 3).

        Deliberately not a `codesign` shim that lies about the verdict. The post-swap check is the
        installer's last safety property, and a test that fakes its answer proves only that the
        script reads a variable. Here the real `mv` runs, one byte is appended to the executable
        afterwards, and the real `codesign --verify --deep --strict` then rejects the bundle for a
        real reason — which is also the actual failure being modelled: a bundle that was fine in
        staging and is not fine at the destination.
        """
        _write_executable(
            os.path.join(self.shims, "mv"),
            "#!/bin/sh\n"
            'printf "%s" "mv" >> "{log}"\n'
            'for arg in "$@"; do printf "\\t%s" "$arg" >> "{log}"; done\n'
            'printf "\\n" >> "{log}"\n'
            '/bin/mv "$@" || exit $?\n'
            'for last in "$@"; do :; done\n'
            'if [ "$last" = "{destination}" ] && [ -f "$last/Contents/MacOS/WhisperMeet" ]; then\n'
            '  printf "tampered\\n" >> "$last/Contents/MacOS/WhisperMeet"\n'
            "fi\n".format(log=self.command_log, destination=self.destination),
        )

    def test_a_bundle_damaged_during_the_swap_is_rolled_back(self):
        """F381 branch 3 — `install-app.sh`'s post-swap verification failure.

        The branch that stands between a failed update and no working app, and the one nobody had
        seen run. What is asserted is the ticket's own Verification: the destination holds the
        previous bundle's contents, and the exit status is 1.
        """
        self._place_previous_app()
        self._set_app_running(False)
        self._corrupt_the_bundle_as_it_is_swapped_in()

        result = self._run_installer()

        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("failed signature verification", result.stderr)
        self.assertIn("previous app was restored", result.stderr)
        self.assertTrue(
            self._previous_app_survives(),
            "the previous bundle must be back at the destination after a rejected swap",
        )
        self.assertEqual(
            self._staging_leftovers(), [],
            "a successful rollback cleans up its staging directory",
        )

    def test_the_rollback_message_names_a_path_that_exists(self):
        """The half of these branches that is only a promise: what the user is told to look at.

        Two of the three rollback branches preserve the backup and print where it is. If that
        sentence ever names a path that was removed, the user is sent to an empty directory at the
        worst possible moment — so when a message names a path, the path is checked.
        """
        self._place_previous_app()
        self._set_app_running(False)
        self._corrupt_the_bundle_as_it_is_swapped_in()
        result = self._run_installer()

        for token in result.stderr.split():
            # `codesign` prefixes its own diagnostics with `<path>:`, so trailing punctuation has
            # to come off before the path is real. Stripping too little turns this into a test of
            # the tokenizer, which is how it first failed.
            candidate = token.rstrip(".:,")
            if candidate.startswith(self.tmp) and "WhisperMeet" in candidate:
                self.assertTrue(
                    os.path.exists(candidate),
                    "stderr names {!r}, which does not exist".format(candidate),
                )

    def test_the_installer_replaces_an_existing_install_and_leaves_no_backup(self):
        self._place_previous_app()
        self._set_app_running(False)
        result = self._run_installer()
        self.assertEqual(result.returncode, 0, result.stderr)

        self.assertFalse(self._previous_app_survives())
        self.assertEqual(self._staging_leftovers(), [])
        # The backup lives inside `$staging_root`, so the old assertion — looking for it in the
        # destination's parent — could never fail. Assert where it actually goes: nowhere, because
        # the staging root it lived in was removed.
        self.assertEqual(
            [name for name in os.listdir(self.destination_parent) if "previous" in name], []
        )


class InstallerCanaryTests(unittest.TestCase):
    """Part 3's own red/green: the canary must actually catch a destination regression."""

    def test_the_canary_rejects_an_installer_that_hardcodes_the_destination(self):
        # Never against the real script: a copy in this test's own tmp directory, mutated the way
        # a careless edit would mutate it.
        with open(os.path.join(_SCRIPTS, "install-app.sh"), encoding="utf-8") as handle:
            source = handle.read()
        self.assertIn(_DESTINATION_FROM_ARGV, source)

        hardcoded = re.sub(
            r'destination="\$\{1:-[^"]*"', 'destination="/Applications/WhisperMeet.app"', source
        )
        self.assertNotIn(_DESTINATION_FROM_ARGV, hardcoded,
                         "the mutation must actually remove the argv default")

        case = InstallerStagingTests("test_a_bundle_is_staged_verified_and_swapped_into_place")
        tmp = tempfile.mkdtemp(prefix="whispermeet-canary-")
        self.addCleanup(shutil.rmtree, tmp, True)
        path = os.path.join(tmp, "install-app.sh")
        with open(path, "w", encoding="utf-8") as handle:
            handle.write(hardcoded)

        with self.assertRaises(AssertionError):
            case._refuse_to_run_an_installer_that_ignores_argv(path)


class GateIsNotAnInstallerTests(unittest.TestCase):
    """Clause 2: `quality-check.sh` never installs to `/Applications`.

    A source assertion, and it is the right shape for this clause: the property is the *absence*
    of an action, and the only way to observe an absence by running the gate would be to run the
    whole gate and then look at `/Applications` — which is the experiment the rule exists to stop
    anyone performing.

    Its blind spot is named in this module's docstring and covered by `InstallerCanaryTests`: the
    gate does not *name* the installer, but it globs `Scripts/tests/test_*.py` and so runs it.
    """

    def _read(self, name):
        with open(os.path.join(_SCRIPTS, name), encoding="utf-8") as handle:
            return handle.read()

    def test_the_quality_gate_never_names_the_applications_folder(self):
        self.assertNotIn("/Applications", self._read("quality-check.sh"))

    def test_the_quality_gate_never_invokes_the_installer(self):
        # The gate packages (step 5 runs `build-app.sh`) and stops there. Packaging and guarded
        # installation stay separate: `install-app.sh` refuses while the app is running and
        # verifies signatures on both sides of the swap, and a gate that installed would perform
        # those swaps on every run.
        self.assertNotIn("install-app.sh", self._read("quality-check.sh"))

    def test_the_packager_is_not_an_installer_either(self):
        packager = self._read("build-app.sh")
        self.assertNotIn("/Applications", packager)
        self.assertNotIn("install-app.sh", packager)

    def test_the_installer_is_the_one_script_that_knows_about_applications(self):
        # The counterpart assertion: the two absences above mean something only if the default
        # destination lives somewhere, and it lives here.
        self.assertIn("/Applications/WhisperMeet.app", self._read("install-app.sh"))


if __name__ == "__main__":
    unittest.main(verbosity=2)
