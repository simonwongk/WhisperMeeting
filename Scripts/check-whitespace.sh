#!/bin/zsh
# Step 1 of Scripts/quality-check.sh: whitespace errors in the candidate change (CI's `git diff --check`).
#
# With DIFF_BASE (CI sets it to the pushed range's base): the committed range AND the working tree,
# because `DIFF_BASE...HEAD` is committed history only and a local run before committing would
# otherwise check the previous commit's diff and ignore the change about to be made (F191, observed
# 2026-09-17: a trailing blank line passed a local gate with DIFF_BASE set and failed CI at this step).
#
# Without DIFF_BASE: the working tree, which is all the local gate checked until F806 — so a gate run
# AFTER committing, the usual "gate the branch, then merge" order, checked nothing and said nothing,
# and every committed whitespace error went red on CI after a green local gate (observed 2026-10-02,
# run 37052994583).
# Runs over the repository at the current directory: the gate has already changed to its root, and
# the test runs it inside scratch repositories.
set -euo pipefail

if [[ -n "${DIFF_BASE:-}" ]] && git cat-file -e "${DIFF_BASE}^{commit}" 2>/dev/null; then
  git diff --check "${DIFF_BASE}...HEAD"
  git diff HEAD --check
else
  untracked_files="$(git ls-files --others --exclude-standard)"
  if [[ -n "$untracked_files" ]]; then
    print -u2 "Stage new candidate files before running the quality gate so they are included in diff validation:"
    print -u2 -- "$untracked_files"
    exit 1
  fi
  # Includes both staged and unstaged edits once new candidate files have been staged.
  git diff HEAD --check
  # And the commits since origin/main (F806): what CI will diff when this is pushed. The merge base,
  # not origin/main itself, so an error already upstream is not this candidate's to fail; and a tree
  # with no origin/main says so rather than passing in silence.
  if base="$(git merge-base HEAD origin/main 2>/dev/null)"; then
    if [[ "$base" == "$(git rev-parse HEAD)" ]]; then
      print "  committed history: no commits beyond origin/main"
    else
      print "  committed history: ${base:0:7}..HEAD (since the merge base with origin/main)"
      git diff --check "$base" HEAD
    fi
  else
    print "  committed history: not checked — no origin/main to measure it against"
  fi
fi
