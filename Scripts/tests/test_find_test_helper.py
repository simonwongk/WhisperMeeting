#!/usr/bin/env python3
"""F371 — the gate's test watchdog must kill its own helper and nobody else's.

Run: python3 Scripts/tests/test_find_test_helper.py

`Scripts/quality-check.sh` used to resolve the wedged helper with
`pgrep -x swiftpm-testing-helper | head -1`, which matches every such process on the machine and
takes an arbitrary one. Two agent sessions routinely share this checkout, so session A's watchdog
could `kill -9` session B's healthy test run — the worst kind of failure to debug, because the
cause lives in another process's log.

The decoy here is a real process with the real name, spawned outside the tree under test. That is
the whole test: a resolver that is right about the tree and wrong about ownership passes every
check that does not have one.
"""

import os
import shutil
import stat
import subprocess
import tempfile
import time
import unittest

_HERE = os.path.dirname(os.path.abspath(__file__))
_RESOLVER = os.path.normpath(os.path.join(_HERE, "..", "find-test-helper.sh"))
_HELPER_NAME = "swiftpm-testing-helper"


def _children_of(pid):
    out = subprocess.run(
        ["ps", "-axo", "pid=,ppid="], capture_output=True, text=True, check=True
    ).stdout
    found = []
    for line in out.splitlines():
        parts = line.split()
        if len(parts) == 2 and parts[1] == str(pid):
            found.append(int(parts[0]))
    return found


class FindTestHelperTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.mkdtemp(prefix="whispermeet-helper-resolver-")
        self.addCleanup(shutil.rmtree, self.tmp, True)
        # A real executable with the real name. `ps -o comm` reports the executable's path, so a
        # copy of /bin/sleep under this name is indistinguishable from the genuine helper to
        # anything that matches on the name — which is exactly what the old resolver did.
        self.helper = os.path.join(self.tmp, _HELPER_NAME)
        # `copyfile`, not `copy2`: copying macOS's file flags into a temp dir raises EPERM.
        shutil.copyfile("/bin/sleep", self.helper)
        os.chmod(self.helper, 0o755)
        # Re-sign, or the copy is SIGKILLed the instant it execs. A system binary's signature is
        # only honoured at its own path; a copy elsewhere is an unsigned Mach-O, which AMFI kills
        # on Apple silicon. Measured before this line was written: exit status 137 and no process.
        subprocess.run(["codesign", "-f", "-s", "-", self.helper], check=True,
                       capture_output=True)
        self.spawned = []

    def tearDown(self):
        for process in self.spawned:
            try:
                process.kill()
                process.wait(timeout=5)
            except Exception:
                pass
        # The shell-spawned grandchildren outlive their parent's kill.
        subprocess.run(["pkill", "-9", "-f", self.helper], capture_output=True)

    def _spawn(self, argv):
        process = subprocess.Popen(argv, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
        self.spawned.append(process)
        return process

    def _spawn_tree_with_helper(self):
        """A parent process whose child is a `swiftpm-testing-helper` — the shape `swift test` has."""
        parent = self._spawn(["/bin/sh", "-c", f'"{self.helper}" 120 & wait'])
        for _ in range(100):
            if _children_of(parent.pid):
                return parent, _children_of(parent.pid)[0]
            time.sleep(0.05)
        self.fail("the fixture's helper child never appeared")

    def _resolve(self, pid):
        result = subprocess.run(
            [_RESOLVER, str(pid)], capture_output=True, text=True
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        return [int(line) for line in result.stdout.split()]

    def test_the_trees_own_helper_is_found(self):
        parent, helper_pid = self._spawn_tree_with_helper()
        self.assertEqual(self._resolve(parent.pid), [helper_pid])

    def test_a_helper_outside_the_tree_is_never_selected(self):
        parent, helper_pid = self._spawn_tree_with_helper()
        decoy = self._spawn([self.helper, "120"])
        # The decoy is a sibling of the whole fixture, not a descendant of `parent` — the shape of
        # another agent session's test run.
        time.sleep(0.2)
        resolved = self._resolve(parent.pid)
        self.assertEqual(resolved, [helper_pid])
        self.assertNotIn(decoy.pid, resolved)

    def test_a_tree_with_no_helper_resolves_to_nothing(self):
        # Not an error and not a fallback to "some helper somewhere": the caller must then kill
        # only the process it started. A resolver that guessed here is the defect being fixed.
        lonely = self._spawn(["/bin/sleep", "120"])
        time.sleep(0.2)
        self.assertEqual(self._resolve(lonely.pid), [])

        # …even while a real-looking helper is running elsewhere on the machine, which is the case
        # that made the old resolver dangerous.
        decoy = self._spawn([self.helper, "120"])
        time.sleep(0.2)
        self.assertEqual(self._resolve(lonely.pid), [], f"selected the decoy {decoy.pid}")

    def test_a_deeper_descendant_is_still_found(self):
        # SwiftPM puts the helper one level down today (measured). A toolchain that inserted a
        # wrapper would make a `pgrep -P` one-level check find nothing and silently stop
        # diagnosing hangs, so the walk is transitive.
        parent = self._spawn(
            ["/bin/sh", "-c", f'/bin/sh -c \'"{self.helper}" 120 & wait\' & wait']
        )
        deadline = time.time() + 5
        resolved = []
        while time.time() < deadline and not resolved:
            resolved = self._resolve(parent.pid)
            if not resolved:
                time.sleep(0.05)
        self.assertEqual(len(resolved), 1, "a grandchild helper must still be found")


class WatchdogUsesTheResolverTests(unittest.TestCase):
    """The gate must actually call it — the resolver is useless sitting beside an unchanged gate."""

    def setUp(self):
        with open(os.path.join(_HERE, "..", "quality-check.sh"), encoding="utf-8") as handle:
            raw = handle.read()
        self.gate = raw
        # Comment lines removed for the negative check below. This is F285's false positive and it
        # bit HERE first: the new watchdog's comment quotes the old `pgrep` command to explain what
        # it replaced, and the assertion that the command is gone was satisfied by the explanation
        # of its removal. Shell comments, so `#` — `SourceAssertion` is Swift-only and lives in the
        # other test target (F384 is the ticket for the nine suites that still strip nothing).
        self.gate_code = "\n".join(
            "" if line.lstrip().startswith("#") else line for line in raw.split("\n")
        )

    # `assertTrue` with a message rather than `assertIn`: a failing `assertIn` prints the whole
    # gate script, which buries the one line that matters.
    def test_the_watchdog_no_longer_matches_every_helper_on_the_machine(self):
        self.assertTrue(
            "pgrep -x swiftpm-testing-helper" not in self.gate_code,
            "quality-check.sh still resolves the helper by a machine-wide name match",
        )

    def test_the_removed_command_is_still_named_in_a_comment(self):
        # The counterpart, so the check above cannot be satisfied by deleting the explanation
        # instead of the command — and so the next reader learns why the resolver exists.
        self.assertTrue("pgrep -x swiftpm-testing-helper" in self.gate)

    def test_the_watchdog_resolves_from_its_own_test_process(self):
        self.assertTrue("find-test-helper.sh" in self.gate_code, "the gate does not use the resolver")
        self.assertTrue(
            'find-test-helper.sh "$test_pid"' in self.gate_code,
            "the resolver must be rooted at the watchdog's own test process",
        )


if __name__ == "__main__":
    unittest.main(verbosity=2)
