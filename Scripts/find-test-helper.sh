#!/bin/zsh
#
# Prints the pids of a process tree's own `swiftpm-testing-helper` descendants (F371).
#
# The quality gate's test watchdog used `pgrep -x swiftpm-testing-helper | head -1`, which matches
# EVERY such process on the machine and takes an arbitrary one. AGENTS.md's "Working alongside
# another agent session" section establishes that two sessions routinely share this checkout and
# this machine, so session A's watchdog would sample and `kill -9` session B's healthy test run —
# and B would see its suite die with no diagnostic and no cause in its own output, because the
# cause was in another process's log.
#
# Measured on this machine before the fix was written: `swift test` keeps its pid through the exec
# to `swift-test`, and the helper is its DIRECT child.
#
#     19523 19521 …/usr/bin/swift-test
#     19537 19523 …/libexec/swift/pm/swiftpm-testing-helper
#
# A descendant walk rather than `pgrep -P` anyway: one level is what SwiftPM does today, and a
# toolchain that inserts a wrapper would silently make a one-level check find nothing.
#
# Prints nothing when there is no such descendant. That is a real answer, not a failure: a helper
# whose parent already died is reparented to launchd and leaves the tree, and at that point nothing
# can prove it is ours. The caller must then kill only the process it started — never one it cannot
# prove it owns, which is the whole point of this script.
#
# Usage: Scripts/find-test-helper.sh <root-pid> [process-name]

set -euo pipefail

root="${1:?usage: find-test-helper.sh <root-pid> [process-name]}"
name="${2:-swiftpm-testing-helper}"

typeset -A parent_of comm_of
while read -r pid ppid command; do
  parent_of[$pid]="$ppid"
  # `:t` is zsh's basename. `ps -o comm=` gives the executable's path, and the caller names a
  # process, not a path — which is also what makes the decoy in the test a fair one.
  comm_of[$pid]="${command:t}"
done < <(ps -axo pid=,ppid=,comm=)

# Transitive closure. The table is small (hundreds of rows), so repeated passes are cheaper to read
# than a recursive walk and cannot loop forever on a malformed parent chain.
typeset -A in_tree
in_tree[$root]=1
changed=1
while (( changed )); do
  changed=0
  for pid in ${(k)parent_of}; do
    if [[ -z "${in_tree[$pid]:-}" && -n "${in_tree[${parent_of[$pid]:-0}]:-}" ]]; then
      in_tree[$pid]=1
      changed=1
    fi
  done
done

for pid in ${(k)in_tree}; do
  [[ "$pid" == "$root" ]] && continue
  [[ "${comm_of[$pid]:-}" == "$name" ]] && print -r -- "$pid"
done

exit 0
