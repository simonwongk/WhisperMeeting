#!/usr/bin/env python3
"""verify-push.sh must say when gh itself is failing (F546).

Run: python3 Scripts/tests/test_verify_push.py

Each poll used to run `gh run list … 2>/dev/null | head -1 || true`, so an expired token or an
offline Mac produced an empty row, and an empty row printed "no run for <sha> yet…" — the line for
CI not having started — every 20 s for 30 minutes, then "The run may still be going".

The real script runs unmodified, from a temporary directory, with `gh`, `git` and `sleep` shimmed on
`PATH`: `gh` replays scripted responses and counts its calls, `git` answers the four questions the
script asks as if the commit were on origin, and `sleep` returns at once, so exhausting the 90-poll
budget takes seconds rather than 30 minutes. Nothing here reaches the network or this checkout's
remote. `ZDOTDIR` points at the temporary directory so the user's `.zshenv` cannot put a real `gh`
back in front of the shim.
"""

import os
import re
import shutil
import stat
import subprocess
import tempfile
import unittest

HERE = os.path.dirname(os.path.abspath(__file__))
SCRIPT = os.path.join(os.path.dirname(HERE), "verify-push.sh")
SHA = "0123456789abcdef0123456789abcdef01234567"

AUTH_FAILURE = ("", "HTTP 401: Bad credentials (https://api.github.com/graphql)\n", 1)
NO_RUN_YET = ("", "", 0)
GREEN = ("completed\tsuccess\t2026-09-26T10:00:00Z\t2026-09-26T10:06:00Z\t4242\n", "", 0)

FAKE_GH = """#!/bin/sh
dir=$(dirname "$0")
echo "$*" >> "$dir/gh-calls"
n=$(wc -l < "$dir/gh-calls" | tr -d ' ')
last=$(cat "$dir/gh-last")
[ "$n" -gt "$last" ] && n=$last
cat "$dir/gh-$n.out"
cat "$dir/gh-$n.err" >&2
exit "$(cat "$dir/gh-$n.rc")"
"""

FAKE_GIT = """#!/bin/sh
case "$1" in
  rev-parse) echo %s ;;
  fetch|merge-base) exit 0 ;;
  for-each-ref) echo refs/remotes/origin/main ;;
  *) echo "fake git: unexpected $*" >&2; exit 97 ;;
esac
""" % SHA


def max_gh_failures():
    with open(SCRIPT, encoding="utf-8") as handle:
        match = re.search(r"^readonly MAX_GH_FAILURES=(\d+)", handle.read(), re.MULTILINE)
    return int(match.group(1)) if match else None


class VerifyPushReportsGhFailures(unittest.TestCase):
    def setUp(self):
        self.root = tempfile.mkdtemp()
        self.shims = os.path.join(self.root, "bin")
        os.makedirs(self.shims)
        for name, body in (("gh", FAKE_GH), ("git", FAKE_GIT), ("sleep", "#!/bin/sh\nexit 0\n")):
            path = os.path.join(self.shims, name)
            with open(path, "w", encoding="utf-8") as handle:
                handle.write(body)
            os.chmod(path, os.stat(path).st_mode | stat.S_IXUSR)

    def tearDown(self):
        shutil.rmtree(self.root)

    def watch(self, responses):
        """Run the script; the last response repeats for every call after it."""
        for index, (out, err, rc) in enumerate(responses, start=1):
            for suffix, content in (("out", out), ("err", err), ("rc", str(rc))):
                with open(os.path.join(self.shims, "gh-%d.%s" % (index, suffix)), "w") as handle:
                    handle.write(content)
        with open(os.path.join(self.shims, "gh-last"), "w") as handle:
            handle.write(str(len(responses)))
        environment = dict(os.environ)
        environment["PATH"] = self.shims + os.pathsep + environment.get("PATH", "")
        environment["ZDOTDIR"] = self.root
        result = subprocess.run([SCRIPT], cwd=self.root, env=environment,
                                capture_output=True, text=True, timeout=60)
        try:
            with open(os.path.join(self.shims, "gh-calls")) as handle:
                calls = len(handle.readlines())
        except FileNotFoundError:
            calls = 0
        return result, calls

    def test_a_gh_that_keeps_failing_is_reported_as_gh_failing(self):
        result, calls = self.watch([AUTH_FAILURE])
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("gh could not query runs", result.stderr, result.stdout)
        self.assertIn("HTTP 401: Bad credentials", result.stderr)
        self.assertNotIn("no run for", result.stdout)
        self.assertNotIn("Gave up watching", result.stderr)
        # It stops at its own bound, not at the end of the 90-poll budget.
        self.assertEqual(calls, max_gh_failures())

    def test_one_failed_call_does_not_end_the_watch(self):
        result, calls = self.watch([AUTH_FAILURE, NO_RUN_YET, AUTH_FAILURE, GREEN])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("CI is green on 0123456.", result.stdout)
        self.assertEqual(calls, 4)

    def test_only_consecutive_failures_count(self):
        bound = max_gh_failures()
        self.assertIsNotNone(bound, "verify-push.sh has no MAX_GH_FAILURES bound")
        almost = [AUTH_FAILURE] * (bound - 1)
        result, calls = self.watch(almost + [NO_RUN_YET] + almost + [GREEN])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("CI is green on 0123456.", result.stdout)
        self.assertEqual(calls, 2 * bound)


if __name__ == "__main__":
    unittest.main(verbosity=2)
