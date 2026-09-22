#!/usr/bin/env python3
"""The packaging half of F188's Verification, which had been written down and never asserted.

Run: python3 Scripts/tests/test_install_app.py

F188's Verification names three packaging clauses:

  1. `install-app.sh` still stages a bundle;
  2. `quality-check.sh` never installs to `/Applications`;
  3. a stale, copied, or running instance cannot write the production library.

Clause 3 is F188's item 3 and no code implements it, so it is deliberately absent here rather than
asserted in some weaker form. Clauses 1 and 2 were both testable on 2026-08-14 and neither was
tested: until this file, nothing under `Tests/` or `Scripts/tests/` mentioned `install-app.sh` at
all, so the separation between packaging and installation — the rule the post-mortem drew out of a
library-index wipe — rested entirely on nobody editing the scripts.

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
"""

import os
import shutil
import stat
import subprocess
import tempfile
import unittest

_HERE = os.path.dirname(os.path.abspath(__file__))
_REPO = os.path.normpath(os.path.join(_HERE, "..", ".."))
_SCRIPTS = os.path.join(_REPO, "Scripts")

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
        shutil.copy2(
            os.path.join(_SCRIPTS, "install-app.sh"),
            os.path.join(self.repo, "Scripts", "install-app.sh"),
        )
        _write_executable(os.path.join(self.repo, "Scripts", "build-app.sh"), _STUB_BUILD_APP)

        self.destination_parent = os.path.join(self.tmp, "Applications-stand-in")
        os.makedirs(self.destination_parent)
        self.destination = os.path.join(self.destination_parent, "WhisperMeet.app")

        self.shims = os.path.join(self.tmp, "shim-bin")
        os.makedirs(self.shims)

    def _set_app_running(self, running):
        """`pgrep -x WhisperMeet` answers yes (0) or no (1), on demand."""
        _write_executable(
            os.path.join(self.shims, "pgrep"),
            "#!/bin/sh\nexit {}\n".format(0 if running else 1),
        )

    def _run_installer(self):
        environment = dict(os.environ)
        environment["PATH"] = self.shims + os.pathsep + environment.get("PATH", "")
        return subprocess.run(
            [os.path.join(self.repo, "Scripts", "install-app.sh"), self.destination],
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

    def test_a_bundle_is_staged_verified_and_swapped_into_place(self):
        self._set_app_running(False)
        result = self._run_installer()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Installed WhisperMeet at", result.stdout)

        # The bundle arrived whole, and with a signature the system will accept — the installer
        # verifies it twice, once in staging and once after the swap, and the second check is what
        # stops a half-copied bundle being left where the user launches it.
        self.assertTrue(os.path.isdir(self.destination))
        self.assertTrue(os.path.isfile(os.path.join(self.destination, "Contents", "MacOS", "WhisperMeet")))
        subprocess.run(
            ["codesign", "--verify", "--deep", "--strict", self.destination], check=True
        )

        # Staged, not built in place: the destination's parent holds no `.WhisperMeet.update.*`
        # directory afterwards, because the installer cleans up the one it made.
        self.assertEqual(self._staging_leftovers(), [])

    def test_an_existing_install_is_replaced_and_its_backup_is_not_left_behind(self):
        os.makedirs(os.path.join(self.destination, "Contents"))
        with open(os.path.join(self.destination, "Contents", "previous-marker"), "w") as handle:
            handle.write("the app that was here before")

        self._set_app_running(False)
        result = self._run_installer()
        self.assertEqual(result.returncode, 0, result.stderr)

        # The previous bundle is moved aside into staging and removed with it, not orphaned next to
        # the installed app where a later launch could pick it up. A second launchable bundle beside
        # the first is the exact condition F188 exists to eliminate.
        self.assertFalse(os.path.exists(os.path.join(self.destination, "Contents", "previous-marker")))
        self.assertEqual(self._staging_leftovers(), [])
        self.assertFalse(os.path.exists(os.path.join(self.destination_parent, "WhisperMeet.previous.app")))

    def test_the_installer_refuses_while_the_app_is_running(self):
        os.makedirs(os.path.join(self.destination, "Contents"))
        with open(os.path.join(self.destination, "Contents", "previous-marker"), "w") as handle:
            handle.write("the app that was here before")

        self._set_app_running(True)
        result = self._run_installer()
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("WhisperMeet is running", result.stderr)

        # Nothing was staged and nothing was replaced. Replacing a bundle mid-capture would break
        # the recording-first rule, and the guard is only worth having if it fires before any of
        # the destructive steps.
        self.assertTrue(os.path.exists(os.path.join(self.destination, "Contents", "previous-marker")))
        self.assertEqual(self._staging_leftovers(), [])


class GateIsNotAnInstallerTests(unittest.TestCase):
    """Clause 2: `quality-check.sh` never installs to `/Applications`.

    A source assertion, and it is the right shape for this clause: the property is the *absence*
    of an action, and the only way to observe an absence by running the gate would be to run the
    whole gate and then look at `/Applications` — which is the experiment the rule exists to stop
    anyone performing.
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
