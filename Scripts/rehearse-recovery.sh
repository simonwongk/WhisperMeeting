#!/bin/zsh
# Build a synthetic damaged library and rehearse the restore on it (F192).
#
# The recovery path is the one thing in this app that is only ever exercised on the worst day, by
# whoever is there. F190 shipped the mechanism and `docs/RECOVERY.md` documents the procedure, but
# nothing let a responder PRACTISE it — and a procedure first performed under pressure on real data
# is not a procedure, it is an experiment. This makes a library that is damaged the way the
# 2026-08-14 incident damaged one, in a temp directory, using no user data whatsoever.
#
#   Scripts/rehearse-recovery.sh              # build it, print the steps, verify the by-hand restore
#   Scripts/rehearse-recovery.sh --keep       # leave the directory in place to open in the app
#
# It writes ONLY inside its own temp directory. It never reads, moves, or looks at
# ~/Library/Application Support/WhisperMeet.
set -euo pipefail

keep=0
[[ "${1:-}" == "--keep" ]] && keep=1

root="$(mktemp -d "${TMPDIR:-/tmp}/whispermeet-rehearsal.XXXXXX")"
# NOTE: `history` is a read-only builtin variable in zsh, so this is `history_dir`
# deliberately — the same trap `verify-push.sh` documents for `status`, and it fails at
# runtime rather than at parse time.
history_dir="$root/meetings.history"
mkdir -p "$history_dir"

print "Rehearsal library: $root"
print ""

# Three generations, oldest to newest, ending in the shape that makes this worth rehearsing: a
# healthy generation with meetings, then the empty one that a schema-incompatible build wrote over
# it. That is the incident: 17 meetings replaced by `[]`, twice, 0.6 s apart.
good_meetings='[{"id":"11111111-1111-4111-8111-111111111111","title":"Synthetic meeting one","createdAt":"2026-08-10T10:00:00Z","duration":1800,"recordingPath":"a/meeting.wav","status":"completed","transcriptText":"synthetic transcript one","segments":[],"markers":[],"tags":[],"pinned":false,"notes":""},{"id":"22222222-2222-4222-8222-222222222222","title":"Synthetic meeting two","createdAt":"2026-08-11T10:00:00Z","duration":900,"recordingPath":"b/meeting.wav","status":"completed","transcriptText":"synthetic transcript two","segments":[],"markers":[],"tags":[],"pinned":false,"notes":""}]'

# Content-addressed names: `g-<sequence padded to 9>-<sha256 prefix>.json`. The fingerprint is the
# file's own, so a generation identifies itself even with the ledger gone — which is the property the
# by-hand procedure relies on, and therefore the one a rehearsal should reproduce rather than fake.
archive() {
  local sequence="$1" payload="$2"
  local digest
  digest="$(printf '%s' "$payload" | shasum -a 256 | cut -c1-16)"
  local name
  name="$(printf 'g-%09d-%s.json' "$sequence" "$digest")"
  printf '%s' "$payload" > "$history_dir/$name"
  print "  retained $name  ($(printf '%s' "$payload" | wc -c | tr -d ' ') bytes)"
}

print "Building three generations:"
archive 40 "$good_meetings"
archive 41 "$good_meetings"
archive 42 '[]'
print ""

# The live pair, both wiped — which is what made the incident unrecoverable from the backup copy.
printf '%s' '[]' > "$root/meetings.json"
printf '%s' '[]' > "$root/meetings.backup.json"
print "Live index and backup both written as [] — the incident shape."
print ""

print "Rehearse the by-hand restore (docs/RECOVERY.md § Restoring a past generation by hand):"
print ""
print "  cd $root"
print "  ls -l meetings.history/"
print "  cp meetings.json meetings.json.before-restore"
print "  cp meetings.history/<the generation with meetings> meetings.json"
print "  rm -f meetings.ledger.json"
print ""

# Now do it, so the rehearsal also VERIFIES the documented steps still work. A runbook nobody
# executes is a runbook that has drifted.
newest_with_meetings="$(grep -l 'Synthetic meeting' "$history_dir"/g-*.json | sort | tail -1)"
cp "$root/meetings.json" "$root/meetings.json.before-restore"
cp "$newest_with_meetings" "$root/meetings.json"
rm -f "$root/meetings.ledger.json"

restored_count="$(grep -o '"id"' "$root/meetings.json" | wc -l | tr -d ' ')"
if [[ "$restored_count" != "2" ]]; then
  print -u2 "FAILED: expected 2 meetings after the restore, found $restored_count."
  print -u2 "The documented procedure no longer produces a restored index — fix RECOVERY.md."
  exit 1
fi
print "Restored $(basename "$newest_with_meetings") — $restored_count meetings are back."
print "The replaced index is still at meetings.json.before-restore, so the restore is undoable."
print ""

if (( keep )); then
  print "Kept for practice in the app. Quit WhisperMeet, then launch it against this library only:"
  print "  WHISPERMEET_LIBRARY=\"$root\" /Applications/WhisperMeet.app/Contents/MacOS/WhisperMeet"
  print "Your real library is not opened by that process (F312). Remove it when you are done:"
  print "  rm -rf $root"
else
  rm -rf "$root"
  print "Removed the rehearsal directory. Re-run with --keep to practise in the app."
fi
