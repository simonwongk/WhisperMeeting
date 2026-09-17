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

# A full run builds twice and runs the whole Swift suite; the last known-good baseline was 3m22s.
# Anything far below that died before the Swift suite and is not a result either way — this is the
# cheapest signal available and it is why the script reports duration, not just conclusion.
readonly SUSPICIOUSLY_FAST_SECONDS=60
readonly POLL_SECONDS=20
readonly MAX_POLLS=90   # 30 minutes; the workflow's own timeout is 40

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

for _ in $(seq 1 $MAX_POLLS); do
  # `|| true` so one failed API call cannot kill the watch.
  row="$(gh run list --limit 20 \
        --json headSha,status,conclusion,startedAt,updatedAt,databaseId \
        --jq ".[] | select(.headSha == \"$sha\") | \
             \"\(.status)\t\(.conclusion // \"-\")\t\(.startedAt)\t\(.updatedAt)\t\(.databaseId)\"" \
        2>/dev/null | head -1 || true)"

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

  if (( duration > 0 && duration < SUSPICIOUSLY_FAST_SECONDS )); then
    print -u2 ""
    print -u2 "WARNING: ${duration}s is far below a real run. The gate almost certainly died before"
    print -u2 "the Swift suite, so this result — pass OR fail — tested nothing. Read the log:"
    print -u2 "  gh run view $run_id --log-failed"
  fi

  if [[ "$run_conclusion" == "success" ]]; then
    (( duration < SUSPICIOUSLY_FAST_SECONDS )) && exit 1
    print "CI is green on $short."
    exit 0
  fi

  print -u2 ""
  print -u2 "CI is NOT green. First failing lines:"
  gh run view "$run_id" --log-failed 2>/dev/null \
    | sed 's/.*Z //' \
    | grep -aE "error:|recorded an issue|failed after|Test run with" \
    | grep -av "skipped" \
    | head -10 || true
  exit 1
done

print -u2 "Gave up watching after $((MAX_POLLS * POLL_SECONDS / 60)) minutes. The run may still be going:"
print -u2 "  gh run list --limit 1"
exit 2
