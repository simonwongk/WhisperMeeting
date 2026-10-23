#!/bin/zsh
# Removes agent worktrees under .claude/worktrees that are done with, so they cannot fill the disk (F1091).
#
#   Scripts/prune-worktrees.sh                  # remove what is safe to remove
#   Scripts/prune-worktrees.sh --dry-run        # say what it would do, change nothing
#   Scripts/prune-worktrees.sh --idle-hours 6   # "idle" means untouched this long (default 24)
#   PRUNE_REPO=/tmp/x Scripts/prune-worktrees.sh   # another repository (the test suite)
#
# Why: on 2026-10-23, 96 worktrees left by sub-agents and lanes held 95 GB, 93 GB of it their `.build` folders. The harness
# removes a sub-agent's worktree only when it is unchanged, and nothing removed one that had made commits.
#
# A worktree is removed only when removing it loses nothing:
#   - it is under <main checkout>/.claude/worktrees, and not locked (`git worktree lock`);
#   - no process has its working directory inside it;
#   - nothing in it (to three levels down) and not its HEAD log changed in the last --idle-hours;
#   - `git status` is empty: no modified tracked file and no untracked file (ignored ones, like `.build`, are caches);
#   - its HEAD is on some branch, local or remote, so every commit stays reachable once the folder is gone. Its own branch
#     is never deleted.
# A worktree kept only because it is dirty or holds a commit no branch has still has its `.build` cleared when idle: that is
# a cache, rebuilt by the next `swift build`.
#
# When a check cannot be made, the worktree is kept (a deferred removal can be retried; a deleted change cannot).

set -euo pipefail

dry_run=0
idle_hours=24
quiet=0
while (( $# > 0 )); do
  case "$1" in
    --dry-run) dry_run=1 ;;
    --idle-hours) shift; idle_hours="$1" ;;
    --quiet) quiet=1 ;;
    *) print -u2 "usage: $0 [--dry-run] [--idle-hours N] [--quiet]"; exit 2 ;;
  esac
  shift
done
[[ "$idle_hours" == <-> ]] || { print -u2 "--idle-hours takes a whole number of hours"; exit 2 }

say() { (( quiet )) || print -- "$@" }

# The main checkout, wherever this runs from: a worktree's common git directory is the main checkout's `.git`.
repo="${PRUNE_REPO:-${0:A:h}/..}"
common=$(git -C "$repo" rev-parse --path-format=absolute --git-common-dir)
main=${common:h}
root="$main/.claude/worktrees"
[[ -d "$root" ]] || { say "No $root — nothing to prune."; exit 0 }

idle_minutes=$(( idle_hours * 60 ))
# Every process's working directory, once. A failed lsof leaves this empty, so the other checks still have to pass.
cwds=("${(@f)$(lsof -d cwd -F n 2>/dev/null | sed -n 's/^n//p')}")

kilobytes() { du -sk "$1" 2>/dev/null | cut -f1 || print 0 }

recently_used() {
  local w="$1" gitdir="$2"
  [[ -n "$(find "$w" -maxdepth 3 -mmin "-$idle_minutes" -print -quit 2>/dev/null)" ]] && return 0
  # Its HEAD log moves on every commit and checkout. Not its index: `git status` rewrites that to refresh it, so any survey —
  # this script's own included — would make every worktree look used.
  [[ -n "$(find "$gitdir/logs/HEAD" -mmin "-$idle_minutes" -print -quit 2>/dev/null)" ]] && return 0
  return 1
}

in_use() {
  local w="$1" cwd
  for cwd in $cwds; do
    [[ "$cwd" == "$w" || "$cwd" == "$w"/* ]] && return 0
  done
  return 1
}

removed=0 cleared=0 kept=0 freed=0

# `git worktree list --porcelain`: a "worktree <path>" line, then its attributes, then a blank line.
# (Not `path`: zsh ties that name to PATH.)
paths=() locks=()
while IFS= read -r line; do
  case "$line" in
    "worktree "*) paths+=("${line#worktree }"); locks+=(0) ;;
    locked*) locks[-1]=1 ;;
  esac
done < <(git -C "$main" worktree list --porcelain)

for (( i = 1; i <= ${#paths}; i++ )); do
  w="${paths[i]}"
  [[ "$w" == "$root"/* ]] || continue
  name="${w:t}"
  if [[ ! -d "$w" ]]; then
    continue   # a stale record; `git worktree prune` below handles it
  fi
  gitdir=$(git -C "$w" rev-parse --path-format=absolute --git-dir 2>/dev/null) || { say "keep  $name — not a readable worktree"; (( ++kept )); continue }

  if (( locks[i] )); then say "keep  $name — locked"; (( ++kept )); continue; fi
  if in_use "$w"; then say "keep  $name — a process is working in it"; (( ++kept )); continue; fi
  if recently_used "$w" "$gitdir"; then say "keep  $name — used in the last $idle_hours h"; (( ++kept )); continue; fi

  why=""
  if ! dirty=$(git --no-optional-locks -C "$w" status --porcelain 2>/dev/null); then
    why="its status could not be read"
  elif [[ -n "$dirty" ]]; then
    why="it has uncommitted changes"
  else
    head=$(git -C "$w" rev-parse HEAD 2>/dev/null) || head=""
    if [[ -z "$head" ]]; then
      why="its HEAD could not be read"
    elif [[ -z "$(git -C "$main" branch -a --contains "$head" 2>/dev/null | grep -v '^[*+ ] *(HEAD detached' | head -1)" ]]; then
      why="its HEAD is on no branch"
    fi
  fi

  if [[ -n "$why" ]]; then
    if [[ -d "$w/.build" ]]; then
      size=$(kilobytes "$w/.build")
      say "keep  $name — $why; clearing its build cache ($(( size / 1024 )) MB)"
      if (( ! dry_run )); then rm -rf "$w/.build"; fi
      (( freed += size, ++cleared ))
    else
      say "keep  $name — $why"
    fi
    (( ++kept ))
    continue
  fi

  size=$(kilobytes "$w")
  say "remove $name ($(( size / 1024 )) MB)"
  if (( ! dry_run )); then
    rm -rf "$w/.build"
    if ! git -C "$main" worktree remove "$w" 2>/dev/null; then
      say "keep  $name — git refused to remove it"
      (( ++kept ))
      continue
    fi
  fi
  (( freed += size, ++removed ))
done

(( dry_run )) || git -C "$main" worktree prune
verb=$([[ $dry_run == 1 ]] && print "would free" || print "freed")
print "prune-worktrees: removed $removed, cleared $cleared build caches, kept $kept; $verb $(( freed / 1048576 )).$(( freed % 1048576 * 10 / 1048576 )) GB"
