#!/bin/zsh
set -euo pipefail

cd "${0:A:h}/.."

cache_root="${TMPDIR:-/tmp}/whispermeet-quality"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$cache_root/clang}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$cache_root/xdg}"

print "[1/4] Checking the candidate diff for whitespace errors"
if [[ -n "${DIFF_BASE:-}" ]] && git cat-file -e "${DIFF_BASE}^{commit}" 2>/dev/null; then
  git diff --check "${DIFF_BASE}...HEAD"
else
  untracked_files="$(git ls-files --others --exclude-standard)"
  if [[ -n "$untracked_files" ]]; then
    print -u2 "Stage new candidate files before running the quality gate so they are included in diff validation:"
    print -u2 -- "$untracked_files"
    exit 1
  fi
  # Includes both staged and unstaged edits once new candidate files have been staged.
  git diff HEAD --check
fi

print "[2/4] Running the complete test suite"
swift test --disable-sandbox

print "[3/4] Building production code with warnings as errors"
swift build --disable-sandbox -c release -Xswiftc -warnings-as-errors

print "[4/4] Packaging and signing WhisperMeet.app"
Scripts/build-app.sh

print "Quality check passed. Review the behavioral diff before committing:"
git status --short
