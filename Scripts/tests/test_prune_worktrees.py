#!/usr/bin/env python3
"""F1091 — Scripts/prune-worktrees.sh removes agent worktrees that lose nothing, and keeps every other one.

Run: python3 Scripts/tests/test_prune_worktrees.py

On 2026-10-23, 96 worktrees under .claude/worktrees held 95 GB, 93 GB of it their `.build` folders. The script removes a
worktree only when it is clean, idle, unlocked, not in use and its HEAD is on a branch; a kept one that is idle still has its
`.build` cleared. Each test builds a scratch repository with worktrees in those states and reads what is left on disk.
"""

import os
import shutil
import subprocess
import tempfile
import time
import unittest

_HERE = os.path.dirname(os.path.abspath(__file__))
_SCRIPT = os.path.normpath(os.path.join(_HERE, "..", "prune-worktrees.sh"))
_THREE_DAYS_AGO = time.time() - 3 * 24 * 3600


def git(*args, cwd):
    return subprocess.run(["git", *args], cwd=cwd, check=True, capture_output=True, text=True).stdout


class PruneWorktreesTests(unittest.TestCase):
    def setUp(self):
        self.tmp = os.path.realpath(tempfile.mkdtemp(prefix="whispermeet-prune-"))
        self.addCleanup(shutil.rmtree, self.tmp, True)
        self.main = os.path.join(self.tmp, "main")
        os.makedirs(self.main)
        git("init", "-q", "-b", "main", cwd=self.main)
        git("config", "user.email", "test@example.com", cwd=self.main)
        git("config", "user.name", "test", cwd=self.main)
        with open(os.path.join(self.main, ".gitignore"), "w") as f:
            f.write(".build/\n.claude/\n")
        with open(os.path.join(self.main, "README"), "w") as f:
            f.write("x\n")
        git("add", ".gitignore", "README", cwd=self.main)
        git("commit", "-q", "-m", "first", cwd=self.main)
        self.root = os.path.join(self.main, ".claude", "worktrees")
        os.makedirs(self.root)

    def add(self, name, branch=None, build=True, age=True):
        path = os.path.join(self.root, name)
        if branch:
            git("worktree", "add", "-q", "-b", branch, path, cwd=self.main)
        else:
            git("worktree", "add", "-q", "--detach", path, cwd=self.main)
        if build:
            os.makedirs(os.path.join(path, ".build", "arm64-apple-macosx", "debug"))
            with open(os.path.join(path, ".build", "arm64-apple-macosx", "debug", "cache.o"), "wb") as f:
                f.write(b"\0" * 4096)
        if age:
            self.age(name)
        return path

    def age(self, name, path=None):
        """Every file and folder in the worktree, and its HEAD log, as last changed three days ago."""
        path = path or os.path.join(self.root, name)
        for folder, dirs, files in os.walk(path, topdown=False):
            for entry in files + dirs:
                os.utime(os.path.join(folder, entry), (_THREE_DAYS_AGO, _THREE_DAYS_AGO), follow_symlinks=False)
        os.utime(path, (_THREE_DAYS_AGO, _THREE_DAYS_AGO))
        head_log = os.path.join(self.main, ".git", "worktrees", name, "logs", "HEAD")
        if os.path.exists(head_log):
            os.utime(head_log, (_THREE_DAYS_AGO, _THREE_DAYS_AGO))

    def prune(self, *args):
        result = subprocess.run(
            [_SCRIPT, *args], env={**os.environ, "PRUNE_REPO": self.main}, capture_output=True, text=True
        )
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        return result.stdout

    def worktrees(self):
        listing = git("worktree", "list", "--porcelain", cwd=self.main)
        return {os.path.basename(line.split(" ", 1)[1]) for line in listing.splitlines() if line.startswith("worktree ")}

    def test_removes_an_idle_clean_worktree_and_keeps_its_branch(self):
        path = self.add("done", branch="worktree-done")
        with open(os.path.join(path, "README"), "a") as f:
            f.write("work\n")
        git("commit", "-q", "-am", "agent work", cwd=path)
        self.age("done")
        output = self.prune()
        self.assertFalse(os.path.exists(path), output)
        self.assertNotIn("done", self.worktrees())
        self.assertIn("worktree-done", git("branch", "--list", "worktree-done", cwd=self.main))
        self.assertIn("removed 1,", output)

    def test_removes_an_idle_detached_worktree_whose_head_is_in_main(self):
        path = self.add("gate")
        output = self.prune()
        self.assertFalse(os.path.exists(path), output)

    def test_keeps_a_worktree_with_uncommitted_changes_but_clears_its_build_cache(self):
        path = self.add("dirty", branch="worktree-dirty", age=False)
        with open(os.path.join(path, "notes.txt"), "w") as f:
            f.write("not committed\n")
        self.age("dirty")
        output = self.prune()
        self.assertTrue(os.path.exists(os.path.join(path, "notes.txt")), output)
        self.assertFalse(os.path.exists(os.path.join(path, ".build")), output)
        self.assertIn("uncommitted changes", output)

    def test_keeps_a_detached_commit_no_branch_holds(self):
        path = self.add("orphan", age=False)
        with open(os.path.join(path, "README"), "a") as f:
            f.write("only here\n")
        git("commit", "-q", "-am", "detached work", cwd=path)
        self.age("orphan")
        output = self.prune()
        self.assertTrue(os.path.exists(path), output)
        self.assertIn("on no branch", output)
        self.assertFalse(os.path.exists(os.path.join(path, ".build")), output)

    def test_keeps_a_worktree_used_recently(self):
        path = self.add("recent", branch="worktree-recent", age=False)
        output = self.prune("--idle-hours", "24")
        self.assertTrue(os.path.exists(os.path.join(path, ".build")), output)
        self.assertIn("used in the last 24 h", output)

    def test_a_commit_moments_ago_keeps_it_even_when_its_files_are_old(self):
        path = self.add("committed", branch="worktree-committed")
        with open(os.path.join(path, "README"), "a") as f:
            f.write("work\n")
        git("commit", "-q", "-am", "agent work", cwd=path)
        self.age("committed")
        os.utime(os.path.join(self.main, ".git", "worktrees", "committed", "logs", "HEAD"), None)
        output = self.prune()
        self.assertTrue(os.path.exists(path), output)

    def test_keeps_a_locked_worktree(self):
        path = self.add("locked", branch="worktree-locked")
        git("worktree", "lock", path, cwd=self.main)
        output = self.prune()
        self.assertTrue(os.path.exists(os.path.join(path, ".build")), output)
        self.assertIn("locked", output)

    def test_keeps_a_worktree_a_process_is_working_in(self):
        path = self.add("busy", branch="worktree-busy")
        holder = subprocess.Popen(["sleep", "60"], cwd=path)
        self.addCleanup(holder.wait)
        self.addCleanup(holder.kill)
        output = self.prune()
        self.assertTrue(os.path.exists(os.path.join(path, ".build")), output)
        self.assertIn("a process is working in it", output)

    def test_a_dry_run_changes_nothing(self):
        done = self.add("done", branch="worktree-done")
        dirty = self.add("dirty", branch="worktree-dirty", age=False)
        with open(os.path.join(dirty, "notes.txt"), "w") as f:
            f.write("x\n")
        self.age("dirty")
        output = self.prune("--dry-run")
        self.assertTrue(os.path.exists(os.path.join(done, ".build")), output)
        self.assertTrue(os.path.exists(os.path.join(dirty, ".build")), output)
        self.assertIn("would free", output)

    def test_leaves_worktrees_outside_its_folder_alone(self):
        outside = os.path.join(self.tmp, "elsewhere")
        git("worktree", "add", "-q", "--detach", outside, cwd=self.main)
        self.age("elsewhere", path=outside)
        output = self.prune()
        self.assertTrue(os.path.exists(outside), output)


if __name__ == "__main__":
    unittest.main(verbosity=2)
