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
# Run serially: several tests block a cooperative thread waiting on a real
# subprocess (Qwen's readDataToEndOfFile, the warm dictation engine's readLine).
# In parallel on a low-core CI runner those blocking waits exhaust the Swift
# concurrency pool, so the tasks that cancel/terminate them are starved and the
# suite stalls until timeouts (F115). One-at-a-time keeps a thread free.
#
# Bounded watchdog (F121): even serially the helper can still wedge on a loaded/low-core machine, and
# the residual hang used to sit SILENTLY until CI's 40-minute job cap. Bound the step: if it exceeds
# WHISPERMEET_TEST_TIMEOUT seconds, sample the wedged swiftpm-testing-helper (so the stall is
# diagnosable, not a silent timeout), print the last-started test, SIGKILL the helper, and fail loudly.
# Normal runs finish in seconds — far under the bound.
test_log="$(mktemp -t whispermeet-test.XXXXXX)"
swift test --disable-sandbox --no-parallel >"$test_log" 2>&1 &
test_pid=$!
test_timeout="${WHISPERMEET_TEST_TIMEOUT:-600}"
elapsed=0
while kill -0 "$test_pid" 2>/dev/null; do
  sleep 2
  elapsed=$((elapsed + 2))
  if (( elapsed >= test_timeout )); then
    print -u2 "[2/4] TEST WATCHDOG: the suite exceeded ${test_timeout}s — the F121 helper hang."
    print -u2 "  last-started test: $(grep -aE '◇ Test ' "$test_log" | tail -1)"
    # `|| true`: under `set -euo pipefail` a no-match pgrep returns nonzero, which would exit the
    # watchdog before it samples and kills the wedged process. Keep going so the diagnostic runs.
    helper_pid="$(pgrep -x swiftpm-testing-helper | head -1 || true)"
    if [[ -n "$helper_pid" ]]; then
      print -u2 "  sampling swiftpm-testing-helper (pid $helper_pid):"
      sample "$helper_pid" 2 2>/dev/null | sed -n '1,30p' >&2 || true
      kill -9 "$helper_pid" 2>/dev/null || true
    fi
    kill -9 "$test_pid" 2>/dev/null || true
    cat "$test_log" >&2
    rm -f "$test_log"
    exit 1
  fi
done
if wait "$test_pid"; then test_rc=0; else test_rc=$?; fi
cat "$test_log"
rm -f "$test_log"
if (( test_rc != 0 )); then exit "$test_rc"; fi

print "[3/4] Building production code with warnings as errors"
swift build --disable-sandbox -c release -Xswiftc -warnings-as-errors

print "[4/4] Packaging and signing WhisperMeet.app"
Scripts/build-app.sh

print "Quality check passed. Review the behavioral diff before committing:"
git status --short
