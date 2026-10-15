#!/usr/bin/env python3
"""Tests for Scripts/check-whitespace.sh, step 1 of the quality gate (F806).

Run: python3 Scripts/tests/test_check_whitespace.py

Without DIFF_BASE the local gate used to run only `git diff HEAD --check`, which covers uncommitted
changes. A gate run after the work is committed — the usual order — therefore checked nothing, and a
committed trailing blank line passed locally and failed CI at this very step (2026-10-02, run
37052994583). F191 was the mirror case: with DIFF_BASE set, the working tree was not checked.

Each test builds a scratch repository under a temporary directory, with a bare `origin` whose `main`
stands in for the pushed history, and runs the real script against it. Nothing here touches this
checkout's own git state: the script works on the repository at its current directory, which is the
scratch clone here and the checkout's root when the gate has `cd`ed there, and GIT_DIR/GIT_WORK_TREE
are dropped from the environment so a caller's cannot redirect it.
"""

import os
import subprocess
import tempfile
import unittest

SCRIPT = os.path.abspath(os.path.join(os.path.dirname(__file__), "..", "check-whitespace.sh"))

GIT_IDENTITY = {
    "GIT_AUTHOR_NAME": "gate", "GIT_AUTHOR_EMAIL": "gate@example.invalid",
    "GIT_COMMITTER_NAME": "gate", "GIT_COMMITTER_EMAIL": "gate@example.invalid",
}


def git(repo, *args):
    env = {**os.environ, **GIT_IDENTITY}
    env.pop("GIT_DIR", None)
    env.pop("GIT_WORK_TREE", None)
    return subprocess.run(["git", *args], cwd=repo, env=env, check=True, capture_output=True, text=True).stdout


def write(repo, name, text):
    with open(os.path.join(repo, name), "w") as handle:
        handle.write(text)


def commit(repo, name, text, message):
    write(repo, name, text)
    git(repo, "add", name)
    git(repo, "commit", "-q", "-m", message)


class ScratchRepository:
    """A clone of a bare origin, both under one temporary directory, pushed history on `main`."""

    def __init__(self, with_origin=True):
        self.root = tempfile.mkdtemp(prefix="check-whitespace-")
        self.repo = os.path.join(self.root, "clone")
        os.mkdir(self.repo)
        git(self.repo, "init", "-q", "-b", "main")
        commit(self.repo, "README.md", "# scratch\n", "first")
        if with_origin:
            origin = os.path.join(self.root, "origin.git")
            git(self.repo, "init", "-q", "--bare", "-b", "main", origin)
            git(self.repo, "remote", "add", "origin", origin)
            git(self.repo, "push", "-q", "-u", "origin", "main")

    def run_gate_step(self, **env):
        clean = {k: v for k, v in os.environ.items() if k != "DIFF_BASE"}
        clean.update(GIT_IDENTITY)
        clean.update(env)
        return subprocess.run([SCRIPT], cwd=self.repo, env=clean, capture_output=True, text=True)


class WithoutDiffBase(unittest.TestCase):
    """The local gate's usual run: nothing in the environment says where the candidate change starts."""

    def test_a_committed_trailing_blank_line_fails_the_step(self):
        scratch = ScratchRepository()
        commit(scratch.repo, "docs.md", "text\n\n", "committed with a new blank line at EOF")
        result = scratch.run_gate_step()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("docs.md", result.stdout + result.stderr)

    def test_committed_trailing_whitespace_fails_the_step(self):
        scratch = ScratchRepository()
        commit(scratch.repo, "Notes.swift", "let x = 1 \n", "trailing space")
        result = scratch.run_gate_step()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("Notes.swift", result.stdout + result.stderr)

    def test_clean_commits_beyond_origin_pass_and_say_what_was_checked(self):
        scratch = ScratchRepository()
        commit(scratch.repo, "docs.md", "text\n", "clean")
        commit(scratch.repo, "more.md", "more\n", "also clean")
        result = scratch.run_gate_step()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("origin/main", result.stdout, "the step must say which committed range it checked")

    def test_an_uncommitted_error_still_fails_the_step(self):
        scratch = ScratchRepository()
        write(scratch.repo, "README.md", "# scratch \n")
        result = scratch.run_gate_step()
        self.assertNotEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("README.md", result.stdout + result.stderr)

    def test_an_error_pushed_to_origin_already_is_not_the_candidate_change(self):
        # The range is merge-base..HEAD: what origin/main already holds is not this gate's to fail.
        scratch = ScratchRepository()
        commit(scratch.repo, "old.md", "old \n", "an error that is already upstream")
        git(scratch.repo, "push", "-q", "origin", "main")
        commit(scratch.repo, "new.md", "new\n", "clean candidate")
        result = scratch.run_gate_step()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)

    def test_without_an_origin_the_working_tree_is_checked_and_the_gap_is_named(self):
        scratch = ScratchRepository(with_origin=False)
        commit(scratch.repo, "docs.md", "text\n", "clean")
        result = scratch.run_gate_step()
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertIn("not checked", result.stdout, "the step must say committed history was not checked")

    def test_an_untracked_file_is_refused_as_before(self):
        scratch = ScratchRepository()
        write(scratch.repo, "new.swift", "let y = 2\n")
        result = scratch.run_gate_step()
        self.assertNotEqual(result.returncode, 0)
        self.assertIn("new.swift", result.stderr)


class WithDiffBase(unittest.TestCase):
    """CI's run, and F191's: the range and the working tree are both checked."""

    def test_the_range_and_the_working_tree_are_both_checked(self):
        scratch = ScratchRepository()
        base = git(scratch.repo, "rev-parse", "HEAD").strip()
        commit(scratch.repo, "docs.md", "text\n", "clean")
        self.assertEqual(scratch.run_gate_step(DIFF_BASE=base).returncode, 0)
        commit(scratch.repo, "bad.md", "bad \n", "committed error")
        self.assertNotEqual(scratch.run_gate_step(DIFF_BASE=base).returncode, 0)
        git(scratch.repo, "reset", "-q", "--hard", "HEAD~1")
        write(scratch.repo, "README.md", "# scratch \n")
        self.assertNotEqual(scratch.run_gate_step(DIFF_BASE=base).returncode, 0, "F191: the working tree too")


if __name__ == "__main__":
    unittest.main()
