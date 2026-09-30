#!/usr/bin/env python3
"""verify-push.sh must say when gh itself is failing (F546, F617).

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

F617 split gh's failures in two. An auth failure (gh's documented exit 4, or an HTTP 401 / "Bad
credentials" / "gh auth login" message) cannot recover by waiting, so it ends the watch at the first
poll; anything else is retried up to a longer bound, so a sleep/wake or VPN reconnect does not end
the watch. It also made the red-run excerpt report gh's own error instead of printing nothing.
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
# gh's own "not logged in" answer: exit 4, per `gh help exit-codes`.
NOT_LOGGED_IN = ("", "To get started with GitHub CLI, please run:  gh auth login\n", 4)
NETWORK_FAILURE = ("", "error connecting to api.github.com\n", 1)
NO_RUN_YET = ("", "", 0)
GREEN = ("completed\tsuccess\t2026-09-26T10:00:00Z\t2026-09-26T10:06:00Z\t4242\n", "", 0)
RED = ("completed\tfailure\t2026-09-26T10:00:00Z\t2026-09-26T10:06:00Z\t4242\n", "", 0)

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


def script_constant(name):
    with open(SCRIPT, encoding="utf-8") as handle:
        match = re.search(r"^readonly %s=(\d+)" % name, handle.read(), re.MULTILINE)
    return int(match.group(1)) if match else None


def max_transient_failures():
    return script_constant("MAX_GH_TRANSIENT_FAILURES")


class ShimmedGh(unittest.TestCase):
    """The shims and the runner; no tests of its own."""

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


class VerifyPushReportsGhFailures(ShimmedGh):
    def test_a_gh_that_keeps_failing_is_reported_as_gh_failing(self):
        bound = max_transient_failures()
        self.assertIsNotNone(bound, "verify-push.sh has no MAX_GH_TRANSIENT_FAILURES bound")
        result, calls = self.watch([NETWORK_FAILURE])
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("gh could not query runs", result.stderr, result.stdout)
        self.assertIn("error connecting to api.github.com", result.stderr)
        self.assertNotIn("no run for", result.stdout)
        self.assertNotIn("Gave up watching", result.stderr)
        # It stops at its own bound, not at the end of the 90-poll budget.
        self.assertEqual(calls, bound)
        self.assertLess(bound, script_constant("MAX_POLLS"))

    def test_a_network_blip_longer_than_three_polls_does_not_end_the_watch(self):
        # F546's bound was 3 polls, about 40 s; a wake from sleep or a VPN reconnect can take longer.
        result, calls = self.watch([NETWORK_FAILURE] * 4 + [GREEN])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("CI is green on 0123456.", result.stdout)
        self.assertEqual(calls, 5)

    def test_an_expired_token_ends_the_watch_at_the_first_poll(self):
        result, calls = self.watch([AUTH_FAILURE, GREEN])
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("HTTP 401: Bad credentials", result.stderr)
        self.assertIn("gh auth login", result.stderr)
        self.assertNotIn("CI is green", result.stdout)
        self.assertEqual(calls, 1)

    def test_not_being_logged_in_ends_the_watch_at_the_first_poll(self):
        result, calls = self.watch([NOT_LOGGED_IN, GREEN])
        self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
        self.assertIn("gh auth login", result.stderr)
        self.assertNotIn("CI is green", result.stdout)
        self.assertEqual(calls, 1)

    def test_each_auth_signal_ends_the_watch_on_its_own(self):
        # The fixtures above each carry two signals: the 401 one has "HTTP 401" and "Bad
        # credentials", the not-logged-in one has exit 4 and "gh auth login". So either half of
        # each could be deleted and they would still pass. Each fixture here carries exactly one.
        for label, response in [
            ("exit 4 alone", ("", "authentication required\n", 4)),
            ("HTTP 401 alone", ("", "HTTP 401 (https://api.github.com/graphql)\n", 1)),
            ("Bad credentials alone", ("", "Bad credentials\n", 1)),
            ("gh auth login alone", ("", "try running: gh auth login\n", 1)),
        ]:
            with self.subTest(label):
                calls_file = os.path.join(self.shims, "gh-calls")
                if os.path.exists(calls_file):
                    os.remove(calls_file)  # the call count is per watch, not per test
                result, calls = self.watch([response, GREEN])
                self.assertEqual(result.returncode, 2, result.stdout + result.stderr)
                self.assertIn("gh is not authenticated with GitHub", result.stderr)
                self.assertIn("`gh auth login`", result.stderr)
                self.assertNotIn("CI is green", result.stdout)
                self.assertEqual(calls, 1)

    def test_one_failed_call_does_not_end_the_watch(self):
        result, calls = self.watch([NETWORK_FAILURE, NO_RUN_YET, NETWORK_FAILURE, GREEN])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("CI is green on 0123456.", result.stdout)
        self.assertEqual(calls, 4)

    def test_only_consecutive_failures_count(self):
        bound = max_transient_failures()
        self.assertIsNotNone(bound, "verify-push.sh has no MAX_GH_TRANSIENT_FAILURES bound")
        almost = [NETWORK_FAILURE] * (bound - 1)
        result, calls = self.watch(almost + [NO_RUN_YET] + almost + [GREEN])
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("CI is green on 0123456.", result.stdout)
        self.assertEqual(calls, 2 * bound)


class VerifyPushReportsTheFailedLog(ShimmedGh):
    """The excerpt under a red run (F617): the first gh call is `run list`, the second `run view`."""

    def test_a_failed_log_fetch_shows_gh_s_error(self):
        result, calls = self.watch([RED, NETWORK_FAILURE])
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("CI is NOT green", result.stderr)
        self.assertIn("error connecting to api.github.com", result.stderr)
        self.assertIn("gh run view 4242 --log-failed", result.stderr)
        self.assertEqual(calls, 2)

    def test_a_log_with_no_matching_line_says_so(self):
        log = ("build\t2026-09-26T10:05:00.0000000Z Process completed with exit code 1.\n", "", 0)
        result, calls = self.watch([RED, log])
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("CI is NOT green", result.stderr)
        self.assertIn("gh run view 4242 --log-failed", result.stderr)
        self.assertNotIn("First failing lines:", result.stderr)
        self.assertEqual(calls, 2)

    def test_matching_log_lines_are_excerpted(self):
        log = ("test\t2026-09-26T10:05:00.0000000Z Sources/A.swift:1:1: error: nope\n"
               "test\t2026-09-26T10:05:01.0000000Z unrelated\n", "", 0)
        result, calls = self.watch([RED, log])
        self.assertEqual(result.returncode, 1, result.stdout + result.stderr)
        self.assertIn("First failing lines:", result.stderr)
        self.assertIn("Sources/A.swift:1:1: error: nope", result.stderr)
        self.assertNotIn("unrelated", result.stderr)
        self.assertEqual(calls, 2)


if __name__ == "__main__":
    unittest.main(verbosity=2)
