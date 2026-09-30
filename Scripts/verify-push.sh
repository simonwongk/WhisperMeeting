#!/bin/zsh
# Watch the CI run for the current HEAD and report a real result.
#
# Why this exists (F270): on 2026-09-15 a push carried a manifest that the `macos-15` runner could
# not build, CI failed on every push for two days across five commits, and nobody looked. A green
# local `Scripts/quality-check.sh` cannot detect that class of failure — the developer toolchain is
# always newer than the runner's, and the developer's Mac has runtimes installed that the runner
# does not. The only remedy is to observe the run.
#
# This pushes NOTHING. Run it after your own push.
#
#   Scripts/verify-push.sh          # watch the run for HEAD
#   Scripts/verify-push.sh <sha>    # watch the run for a specific commit
set -euo pipefail

# NOTE: `status` is a read-only builtin variable in zsh — these are `run_status`/`run_conclusion`
# deliberately. Naming them `status` fails at runtime, not at parse time.

# A full run builds twice and runs the whole Swift suite. Anything far below that died before the
# Swift suite and is not a result either way — this is the cheapest signal available and it is why
# the script reports duration, not just conclusion.
#
# The threshold is a BAND, not a magic number, and the band is what to check against — a constant
# that nobody re-derives silently stops meaning anything, which is what happened to the old 60s. It
# was set from a 3m22s baseline; the suite has since roughly doubled. Observed on this runner,
# 2026-09-17:
#
#   real runs, whole suite executed:   5m17s   5m53s   6m01s   6m52s   7m29s   (361s green)
#   died before the suite:             1m42s   (a type error; the test target did not build)
#
# 180s sits in the empty band between those clusters rather than near either edge. Note what the
# 1m42s case means: the runner compiles the WHOLE test target before running anything, so a single
# inference difference anywhere under `Tests/` is a total build failure, not one red test — and the
# old 60s threshold would not have flagged its duration at all.
#
# When the suite grows again, re-derive this from `gh run list --limit 20` rather than nudging it.
readonly SUSPICIOUSLY_FAST_SECONDS=180
readonly POLL_SECONDS=20
readonly MAX_POLLS=90   # 30 minutes; the workflow's own timeout is 40
# gh failures come in two kinds (F617), and only one of them is worth waiting out.
#
# An AUTH failure cannot recover by waiting: gh exits 4 when it has no login (`gh help exit-codes`),
# and GitHub refuses an expired or revoked token with `HTTP 401: Bad credentials`, which gh need not
# report as exit 4 — so the message is matched as well as the code. Either ends the watch at the
# first poll with the `gh auth login` advice.
#
# Anything else is treated as transient and retried, up to MAX_GH_TRANSIENT_FAILURES consecutive
# failures; any successful call resets the count. F546 set that bound at 3 polls, about 40 s, and a
# wake from sleep or a VPN reconnect can take longer than that. 15 polls is 14 sleeps of 20 s, about
# five minutes: the number is my judgement (whisper-40, F617), not a measurement, chosen to ride out
# a reconnect while an offline Mac still gets a verdict in about a sixth of the 30-minute budget
# rather than at the end of it.
readonly MAX_GH_TRANSIENT_FAILURES=15

if ! command -v gh >/dev/null 2>&1; then
  print -u2 "gh is not installed, so the run cannot be observed. Check the Actions tab by hand:"
  print -u2 "  https://github.com/simonwongk/WhisperMeeting/actions"
  exit 2
fi

# Resolve to the FULL 40-character SHA before anything else. The poll below compares
# `.headSha == "$sha"` as an exact string against what the API returns, which is always full — so an
# abbreviated argument matches nothing, forever. Observed 2026-09-17: `verify-push.sh f2e5494`
# polled for ten minutes reporting "no run for f2e5494 yet…" while run 35180593825 for that very
# commit had already completed green. The no-argument form was never affected, because
# `git rev-parse HEAD` is full — which is exactly why the documented `<sha>` form could stay broken.
if ! sha="$(git rev-parse --verify "${1:-HEAD}^{commit}" 2>/dev/null)"; then
  print -u2 "verify-push.sh: '${1:-HEAD}' is not a commit in this repository."
  exit 2
fi
short="${sha:0:7}"

# REFUSE, rather than warn and poll anyway. Two code paths used to reach the same dead end: a commit
# that was never pushed, and a commit whose branch has no upstream configured. Both mean there is
# nothing to watch, and both sat above a thirty-minute poll that printed one reassuring line every
# twenty seconds. That is how a missing push read as work in progress for 45 minutes on 2026-09-16.
#
# Reachability from any `origin/*`, not `@{upstream}`: the latter is unset on a branch pushed with
# an explicit refspec (`git push origin my-branch:main`) and reports a freshly pushed commit as
# missing. Not `git ls-remote` either — that lists ref TIPS, so every commit but the newest looks
# absent. Fetch first, because a stale remote-tracking ref is the same false negative.
git fetch -q origin 2>/dev/null || true
on_remote=""
for ref in $(git for-each-ref --format='%(refname)' refs/remotes/origin 2>/dev/null); do
  if git merge-base --is-ancestor "$sha" "$ref" 2>/dev/null; then
    on_remote=1
    break
  fi
done
if [[ -z "$on_remote" ]]; then
  print -u2 "verify-push.sh: $short is not on origin, so CI has nothing to run for it."
  print -u2 "  Push first, then run this. This script pushes NOTHING."
  exit 1
fi

print "Watching CI for $short (poll ${POLL_SECONDS}s, give up after $((MAX_POLLS * POLL_SECONDS / 60))m)…"

# gh's exit status and stderr are kept, not discarded (F546). This used to be
# `gh run list … 2>/dev/null | head -1 || true`, so a gh that could not reach GitHub produced an empty
# row, and an empty row is "no run for <sha> yet…" — printed every poll for the full 30 minutes.
gh_stderr="$(mktemp -t verify-push-gh)"
trap 'rm -f -- "$gh_stderr"' EXIT
trap 'exit 130' HUP INT TERM
gh_failures=0

for _ in $(seq 1 $MAX_POLLS); do
  gh_rc=0
  listing="$(gh run list --limit 20 \
        --json headSha,status,conclusion,startedAt,updatedAt,databaseId \
        --jq ".[] | select(.headSha == \"$sha\") | \
             \"\(.status)\t\(.conclusion // \"-\")\t\(.startedAt)\t\(.updatedAt)\t\(.databaseId)\"" \
        2>"$gh_stderr")" || gh_rc=$?

  if (( gh_rc != 0 )); then
    gh_failures=$((gh_failures + 1))
    gh_error="$(<"$gh_stderr")"
    gh_error="${gh_error:-(no message)}"
    if (( gh_rc == 4 )) || [[ "$gh_error" == *"HTTP 401"* || "$gh_error" == *"Bad credentials"* \
                              || "$gh_error" == *"gh auth login"* ]]; then
      print -u2 ""
      print -u2 "gh is not authenticated with GitHub: $gh_error"
      print -u2 "Waiting cannot fix that, so nothing is known about CI for $short. Run"
      print -u2 "\`gh auth login\` (\`gh auth status\` shows what is wrong), then run this again."
      exit 2
    fi
    if (( gh_failures >= MAX_GH_TRANSIENT_FAILURES )); then
      print -u2 ""
      print -u2 "gh could not query runs: $gh_error"
      print -u2 "That is gh run list exiting $gh_rc on $gh_failures polls in a row, so nothing is known"
      print -u2 "about CI for $short. Check the network and \`gh auth status\`, then run this again."
      exit 2
    fi
    print -u2 "  gh run list exited $gh_rc ($gh_failures of $MAX_GH_TRANSIENT_FAILURES before giving up): $gh_error"
    sleep $POLL_SECONDS
    continue
  fi
  gh_failures=0
  row="${listing%%$'\n'*}"

  if [[ -z "$row" ]]; then
    print "  no run for $short yet…"
    sleep $POLL_SECONDS
    continue
  fi

  run_status="${row%%$'\t'*}"
  rest="${row#*$'\t'}"
  run_conclusion="${rest%%$'\t'*}"
  rest="${rest#*$'\t'}"
  started="${rest%%$'\t'*}"
  rest="${rest#*$'\t'}"
  updated="${rest%%$'\t'*}"
  run_id="${rest##*$'\t'}"

  if [[ "$run_status" != "completed" ]]; then
    print "  $run_status…"
    sleep $POLL_SECONDS
    continue
  fi

  # Duration in seconds, via epoch conversion of the two ISO-8601 stamps.
  begin_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$started" +%s 2>/dev/null || echo 0)
  end_epoch=$(date -j -f "%Y-%m-%dT%H:%M:%SZ" "$updated" +%s 2>/dev/null || echo 0)
  duration=$(( end_epoch - begin_epoch ))
  (( duration < 0 )) && duration=0

  print ""
  print "Run $run_id for $short: $run_conclusion in ${duration}s"

  # `cancelled` is NOT a failure — it is the absence of a result, and reporting it as red sends
  # someone hunting a break that never happened. Observed 2026-09-17: a run for 3d7c0d8 was
  # cancelled at 62s because a second push superseded it seconds later (the workflow cancels
  # in-progress runs for the same ref), and this script said "CI is NOT green".
  #
  # Exit 2, the same code as "gave up watching", because both mean *no verdict* rather than a bad
  # one — and the message names the likely cause, since a newer push is by far the common one.
  if [[ "$run_conclusion" == "cancelled" ]]; then
    print -u2 ""
    print -u2 "This run was CANCELLED, so it is not a result either way — not a failure."
    print -u2 "The usual cause is a newer push to the same branch superseding it. Watch that one:"
    print -u2 "  Scripts/verify-push.sh \$(git rev-parse HEAD)"
    exit 2
  fi

  if (( duration > 0 && duration < SUSPICIOUSLY_FAST_SECONDS )); then
    print -u2 ""
    print -u2 "WARNING: ${duration}s is below the ${SUSPICIOUSLY_FAST_SECONDS}s floor for a real run"
    print -u2 "on this runner (observed range 5-8 min). The gate almost certainly died before the"
    print -u2 "Swift suite — most likely the test target did not build, which fails everything at"
    print -u2 "once — so this result, pass OR fail, tested nothing. Read the log:"
    print -u2 "  gh run view $run_id --log-failed"
    print -u2 "Read it whole. Do not pipe it through grep: the line you need is often a warning"
    print -u2 "away from the line you searched for."
  fi

  if [[ "$run_conclusion" == "success" ]]; then
    (( duration < SUSPICIOUSLY_FAST_SECONDS )) && exit 1
    print "CI is green on $short."
    exit 0
  fi

  # The log is fetched on its own, with gh's stderr and status kept (F617). It used to be piped
  # straight into the filter with `2>/dev/null … || true`, so a failed fetch and a log with no
  # matching line both printed "First failing lines:" and then nothing. The excerpt now goes to
  # stderr with its heading; it used to go to stdout, apart from it.
  print -u2 ""
  log_rc=0
  failed_log="$(gh run view "$run_id" --log-failed 2>"$gh_stderr")" || log_rc=$?
  if (( log_rc != 0 )); then
    gh_error="$(<"$gh_stderr")"
    print -u2 "CI is NOT green, and its failed log could not be fetched:"
    print -u2 "  gh run view exited $log_rc: ${gh_error:-(no message)}"
    print -u2 "Read it by hand:  gh run view $run_id --log-failed"
    exit 1
  fi
  excerpt="$(print -r -- "$failed_log" \
    | sed 's/.*Z //' \
    | grep -aE "error:|recorded an issue|failed after|Test run with" \
    | grep -av "skipped" \
    | head -10)" || true
  if [[ -z "$excerpt" ]]; then
    print -u2 "CI is NOT green, and no line of its failed log matched the excerpt filter."
    print -u2 "Read it whole:  gh run view $run_id --log-failed"
    exit 1
  fi
  print -u2 "CI is NOT green. First failing lines:"
  print -u2 -r -- "$excerpt"
  exit 1
done

print -u2 "Gave up watching after $((MAX_POLLS * POLL_SECONDS / 60)) minutes. The run may still be going:"
print -u2 "  gh run list --limit 1"
exit 2
