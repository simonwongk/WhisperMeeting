#!/bin/zsh
set -euo pipefail

cd "${0:A:h}/.."

cache_root="${TMPDIR:-/tmp}/whispermeet-quality"
export CLANG_MODULE_CACHE_PATH="${CLANG_MODULE_CACHE_PATH:-$cache_root/clang}"
export XDG_CACHE_HOME="${XDG_CACHE_HOME:-$cache_root/xdg}"

# swift-testing framework resolution (F166). Some Command Line Tools toolchains don't place
# Testing.framework / lib_TestingInterop.dylib on the default search + rpath, so `swift test` fails
# with "no such module 'Testing'" and then a dlopen error. Add the active developer dir's framework +
# lib paths when they exist; these are harmless additive search paths on machines (e.g. full Xcode)
# where swift-testing already resolves. Applied only to `swift test`, never to the release build.
testing_flags=()
developer_dir="$(xcode-select -p 2>/dev/null || true)"
testing_frameworks="$developer_dir/Library/Developer/Frameworks"
testing_libs="$developer_dir/Library/Developer/usr/lib"
if [[ -n "$developer_dir" && -d "$testing_frameworks" ]]; then
  testing_flags=(-Xswiftc -F -Xswiftc "$testing_frameworks" -Xlinker -rpath -Xlinker "$testing_frameworks")
  [[ -d "$testing_libs" ]] && testing_flags+=(-Xlinker -rpath -Xlinker "$testing_libs")
fi

print "[1/5] Checking the candidate diff for whitespace errors"
if [[ -n "${DIFF_BASE:-}" ]] && git cat-file -e "${DIFF_BASE}^{commit}" 2>/dev/null; then
  git diff --check "${DIFF_BASE}...HEAD"
  # AND the working tree, which the range above cannot see.
  #
  # `DIFF_BASE...HEAD` is committed history only. CI sets DIFF_BASE and has nothing uncommitted, so
  # that range is exactly right there. Run locally BEFORE committing — which is the whole point of
  # a pre-commit gate — it checks the previous commit's diff and silently ignores the change you
  # are about to make. Observed 2026-09-17: a trailing blank line passed a local gate with
  # DIFF_BASE set and failed CI at this very step, 14 seconds in. Every other step reads the
  # working tree, so step 1 was the only one looking at the wrong thing.
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
fi

print "[2/5] Running script regression suites"
# Globbed, not listed. A hardcoded list is how a test file silently stops running: when this was a
# list of seven, `test_generate_tickets_dashboard.py` was not in it and neither was
# `test_fidelity_score.py` when it was added — both passed locally and neither was gated, which
# is indistinguishable from not having written them.
#
# `(N)` so an empty directory is not a literal glob passed to python3, and the loop prints each file
# because a suite that runs and says nothing is the same problem one step later.
#
# A glob also gets the gitignored ticketing suites right, where a list could not (F231). It NAMES no
# local-only file — so a fresh clone, which has neither `generate-tickets-dashboard.py` nor its test,
# simply finds fewer files and passes — while a working copy that has them runs them. That is how
# `test_generate_tickets_dashboard.py` caught this very change: it had never run in the gate, and
# the first thing it did once it could was fail on the list this glob replaced.
script_suites=(Scripts/tests/test_*.py(N))
if (( ${#script_suites} == 0 )); then
  print -u2 "No script suites found under Scripts/tests — that is a bug in this gate, not a pass."
  exit 1
fi
for suite in $script_suites; do
  print "  $suite"
  python3 "$suite"
done

# Run serially: several tests block a cooperative thread waiting on a real
# subprocess (Qwen's readDataToEndOfFile, the warm dictation engine's readLine).
# In parallel on a low-core CI runner those blocking waits exhaust the Swift
# concurrency pool, so the tasks that cancel/terminate them are starved and the
# suite stalls until timeouts (F115). One-at-a-time keeps a thread free.
#
# Build the tests BEFORE the timed section, so the watchdog bounds the RUN and not the compile
# (F168). `swift test` does both, and on a cold `.build/debug` — a fresh checkout, or after `.build`
# is cleared — a from-scratch build alone exceeds the 600 s bound. The watchdog then fired and the
# gate exited 1 reporting an "F121 helper hang" when nothing had hung, wasting the whole run.
#
# Scaling the timeout was the alternative and this is better: it keeps the F121 bound tight where it
# belongs instead of loosening it for every run to accommodate one, and it makes the watchdog's own
# claim below — "normal runs finish in seconds" — true rather than aspirational. The build is
# incremental, so `swift test` afterwards has nothing left to compile.
print "[3/5] Building the test target (outside the watchdog — see F168)"
swift build --build-tests --disable-sandbox "${testing_flags[@]}"

print "[3/5] Running the complete Swift test suite"

# Bounded watchdog (F121): even serially the helper can still wedge on a loaded/low-core machine, and
# the residual hang used to sit SILENTLY until CI's 40-minute job cap. Bound the step: if it exceeds
# WHISPERMEET_TEST_TIMEOUT seconds, sample the wedged swiftpm-testing-helper (so the stall is
# diagnosable, not a silent timeout), print the last-started test, SIGKILL the helper, and fail loudly.
# Normal runs finish in seconds — far under the bound, and since F168 that is about the run alone.
test_log="$(mktemp -t whispermeet-test.XXXXXX)"
swift test --disable-sandbox --no-parallel "${testing_flags[@]}" >"$test_log" 2>&1 &
test_pid=$!
test_timeout="${WHISPERMEET_TEST_TIMEOUT:-600}"
elapsed=0
while kill -0 "$test_pid" 2>/dev/null; do
  sleep 2
  elapsed=$((elapsed + 2))
  if (( elapsed >= test_timeout )); then
    print -u2 "[3/5] TEST WATCHDOG: the suite exceeded ${test_timeout}s — the F121 helper hang."
    print -u2 "  last-started test: $(grep -aE '◇ Test ' "$test_log" | tail -1)"
    # OUR helper, not any helper (F371). This used to be
    # `pgrep -x swiftpm-testing-helper | head -1`, which matches every such process on the machine
    # and takes an arbitrary one — so with two agent sessions sharing this checkout, A's watchdog
    # could SIGKILL B's healthy run, and B would see its suite die with no cause in its own output.
    # `|| true` because a no-match must not exit the watchdog before it samples.
    helper_pids=("${(@f)$(Scripts/find-test-helper.sh "$test_pid" 2>/dev/null || true)}")
    helper_pids=("${(@)helper_pids:#}")
    if (( ${#helper_pids} > 0 )); then
      for helper_pid in $helper_pids; do
        print -u2 "  sampling swiftpm-testing-helper (pid $helper_pid, a descendant of $test_pid):"
        sample "$helper_pid" 2 2>/dev/null | sed -n '1,30p' >&2 || true
        kill -9 "$helper_pid" 2>/dev/null || true
      done
    else
      # Said out loud rather than silently falling back to a global match. A helper whose parent
      # already died is reparented to launchd, and at that point nothing can prove it is ours.
      print -u2 "  no swiftpm-testing-helper descendant of $test_pid — killing only the test process."
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

print "[4/5] Building production code with warnings as errors"
swift build --disable-sandbox -c release -Xswiftc -warnings-as-errors

print "[5/5] Packaging and signing WhisperMeet.app"
Scripts/build-app.sh

print "Quality check passed. Review the behavioral diff before committing:"
git status --short
