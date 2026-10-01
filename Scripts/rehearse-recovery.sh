#!/bin/zsh
# Build a synthetic damaged library and rehearse the restore on it (F192).
#
# The recovery path is the one thing in this app that is only ever exercised on the worst day, by
# whoever is there. F190 shipped the mechanism and `docs/RECOVERY.md` documents the procedure, but
# nothing let a responder PRACTISE it — and a procedure first performed under pressure on real data
# is not a procedure, it is an experiment. This makes a library that is damaged the way the
# 2026-08-14 incident damaged one, in a temp directory, using no user data whatsoever.
#
#   Scripts/rehearse-recovery.sh                # build it, print the steps, verify the by-hand restore
#   Scripts/rehearse-recovery.sh --keep         # the same, then keep the RESTORED library
#   Scripts/rehearse-recovery.sh --keep-damaged # keep it DAMAGED, to practise Recover Library in the app
#
# `--keep` runs the by-hand restore before it keeps the directory, so the app opens that library
# healthy and has nothing to recover (F550). `--keep-damaged` stops before the restore, and adds a
# finalized recording beside the empty index: an empty index on its own is a new library, not a
# damaged one, and the app opens it read-only only when a recording says meetings existed.
#
# It writes ONLY inside its own temp directory. It never reads, moves, or looks at
# ~/Library/Application Support/WhisperMeet.
set -euo pipefail

# Here, not inside `archive`: in a zsh function `$0` is the function's name.
script_dir="${0:A:h}"

keep=0
damaged=0
case "${1:-}" in
  "") ;;
  --keep) keep=1 ;;
  --keep-damaged) keep=1; damaged=1 ;;
  # Refused, not ignored: a typo used to run the default mode, which removes its directory, so the
  # responder was left with nothing to open and no message saying why (F550).
  *) print -u2 "Unknown argument: $1 (expected --keep or --keep-damaged)"; exit 2 ;;
esac
(( $# <= 1 )) || { print -u2 "Expected at most one argument, got $#."; exit 2 }

root="$(mktemp -d "${TMPDIR:-/tmp}/whispermeet-rehearsal.XXXXXX")"
# Printed in the form the app keys this library's settings on (F550): symlinks resolved, and the
# leading /private dropped where the rest still names the directory, as Foundation's
# `resolvingSymlinksInPath` does. That keeps the domain printed below the one the app opens, and
# drops the doubled slash a TMPDIR ending in `/` gives the mktemp path.
root="${root:A}"
if [[ "$root" == /private/* && -d "${root#/private}" ]]; then
  root="${root#/private}"
fi
# The app's settings domain for this library: `WhisperMeetLibrary.defaultsSuiteName`, FNV-1a
# over the path's UTF-8. `RecoveryRehearsalLibraryTests` checks it against the Swift.
settings_domain="$(python3 -c '
import sys
h = 0xcbf29ce484222325
for byte in sys.argv[1].encode("utf-8"):
    h = ((h ^ byte) * 0x100000001b3) & 0xFFFFFFFFFFFFFFFF
print("WhisperMeet.library-%016x" % h)
' "$root")"
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

# Content-addressed names: `g-<sequence padded to 9>-<fingerprint>.json`. The fingerprint is the
# file's own, so a generation identifies itself even with the ledger gone — which is the property the
# by-hand procedure relies on, and therefore the one a rehearsal should reproduce rather than fake.
# It is the app's `StoreFingerprint`, computed by `store_fingerprint.py`. It was a SHA-256 prefix
# until F550, and the app refused to restore every generation named that way.
#
# Each file also gets its own date. Without a ledger the app knows a generation's meeting count only
# by restoring it, so Recover Library labels each one only by when its file was written (date and
# time, with no meeting count) — and three files written in the same second would be three
# identical choices.
archive() {
  local sequence="$1" payload="$2" stamp="$3"
  local digest
  digest="$(printf '%s' "$payload" | python3 "$script_dir/store_fingerprint.py")"
  local name
  name="$(printf 'g-%09d-%s.json' "$sequence" "$digest")"
  printf '%s' "$payload" > "$history_dir/$name"
  touch -t "$stamp" "$history_dir/$name"
  print "  retained $name  ($(printf '%s' "$payload" | wc -c | tr -d ' ') bytes)"
}

print "Building three generations:"
archive 40 "$good_meetings" 202608120900
archive 41 "$good_meetings" 202608131700
archive 42 '[]' 202608140930
print ""

# The live pair, both wiped — which is what made the incident unrecoverable from the backup copy.
printf '%s' '[]' > "$root/meetings.json"
printf '%s' '[]' > "$root/meetings.backup.json"
print "Live index and backup both written as [] — the incident shape."
print ""

if (( damaged )); then
  # One finalized recording, in the first meeting's folder, so `MeetingStore` sees an empty index
  # beside a recording it should have known about and opens the library read-only (suspect-empty).
  # A real WAV header whose declared data is on disk — one second of 16 kHz mono 16-bit silence —
  # because a stub file is not a finalized recording and the library would open healthy.
  recording_dir="$root/Recordings/11111111-1111-4111-8111-111111111111"
  mkdir -p "$recording_dir"
  {
    printf 'RIFF\x24\x7d\x00\x00WAVEfmt '
    printf '\x10\x00\x00\x00\x01\x00\x01\x00\x80\x3e\x00\x00\x00\x7d\x00\x00\x02\x00\x10\x00'
    printf 'data\x00\x7d\x00\x00'
    head -c 32000 /dev/zero
  } > "$recording_dir/meeting.wav"
  print "Left one recording in Recordings/, so the empty index reads as damage, not a new library."
  print ""
  print "Kept DAMAGED for practice in the app. Launch WhisperMeet against this library:"
  print "  WHISPERMEET_LIBRARY=\"$root\" /Applications/WhisperMeet.app/Contents/MacOS/WhisperMeet"
  print "It opens read-only. Use Settings ▸ Recover Library…: the 14 Aug copy is the empty one, and"
  print "restoring it keeps the library read-only; the 13 Aug copy brings the 2 meetings back."
  print "That process opens only this library, and keeps its settings apart from your real ones, in"
  print "the preferences domain $settings_domain (F312, F550; docs/RECOVERY.md names what is still shared)."
  print "When you are done, quit that copy and remove both:"
  print "  rm -rf $root"
  print "  defaults delete $settings_domain; rm -f ~/Library/Preferences/$settings_domain.plist"
  exit 0
fi

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
  print "Kept the RESTORED library. It opens healthy, so there is nothing to recover in it."
  print "Use --keep-damaged to practise Recover Library. To open this one:"
  print "  WHISPERMEET_LIBRARY=\"$root\" /Applications/WhisperMeet.app/Contents/MacOS/WhisperMeet"
  print "That process opens only this library, and keeps its settings apart from your real ones, in"
  print "the preferences domain $settings_domain (F312, F550; docs/RECOVERY.md names what is still shared)."
  print "When you are done, quit that copy and remove both:"
  print "  rm -rf $root"
  print "  defaults delete $settings_domain; rm -f ~/Library/Preferences/$settings_domain.plist"
else
  rm -rf "$root"
  print "Removed the rehearsal directory. Re-run with --keep-damaged to practise in the app."
fi
