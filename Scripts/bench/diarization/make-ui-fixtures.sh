#!/bin/zsh
set -euo pipefail

# Generates the fixtures F230 needs and could not find, plus a safe way to reach the
# model-not-installed state. Everything it writes lives in a scratch directory you choose; it never
# touches the meeting library, and the one command that does touch installed state is reversible and
# says so.
#
#   make-ui-fixtures.sh audio <dir>      generate the fixture WAVs
#   make-ui-fixtures.sh models off       move the installed models aside (reversible)
#   make-ui-fixtures.sh models on        put them back
#   make-ui-fixtures.sh models status    say which it is
#
# Why these exist: the installed library has no single-speaker meeting, and a real 46-minute meeting
# analyses in about 15 seconds — far too fast to click Cancel. Both states are reachable with audio
# built for the purpose, and neither needs a real recording.

command="${1:-help}"

runtime="${HOME}/Library/Application Support/WhisperMeet/Runtime/Diarization"
parked="${runtime}.parked-for-testing"

generate_audio() {
  target="${1:?usage: make-ui-fixtures.sh audio <dir>}"
  mkdir -p "$target"
  work="$(mktemp -d)"
  trap 'rm -rf "$work"' EXIT

  # --- 1. Single voice -------------------------------------------------------------------------
  # One `say` voice, one continuous passage. Analysis should find exactly one cluster, which is the
  # state where the app must show NO labels and say "Only one voice could be told apart" — labelling
  # every row "Speaker 1" and letting someone rename it is how one person's words end up under
  # another person's name.
  print "Generating single-voice fixture…"
  say -v Samantha -o "$work/mono.aiff" \
    "Let me walk through the three items on the agenda. The first is the ingest pipeline, which \
     finished its backfill overnight and processed about four hundred thousand records without an \
     error. The second is the retry budget, which I want to make explicit in the configuration \
     rather than leaving it to be discovered later. The third is the release date. I would like a \
     decision on that today rather than next week, because the review queue is the only thing \
     standing between us and a build. If nobody has a blocker on any of those, we can move quickly \
     and finish early. I will take the documentation myself, since the setup guide still refers to \
     the old configuration format and that is going to confuse somebody."
  /usr/bin/afconvert -f WAVE -d LEI16@16000 -c 1 "$work/mono.aiff" "$target/ui-single-voice.wav"
  print "  -> $target/ui-single-voice.wav"

  # --- 2. Long enough to cancel ----------------------------------------------------------------
  # Real-time factor is about 0.005, so a 46-minute meeting is done in ~15 s. Roughly three hours of
  # audio gives about a minute of analysis — enough to reach for Cancel without racing it.
  print "Generating long fixture for the cancel test (this takes a minute)…"
  say -v Daniel -o "$work/long.aiff" \
    "This is a deliberately long passage used only to keep speaker analysis running long enough \
     that a person can press cancel while it is working. It carries no meaning and repeats."
  /usr/bin/afconvert -f WAVE -d LEI16@16000 -c 1 "$work/long.aiff" "$work/unit.wav"

  python3 - "$work/unit.wav" "$target/ui-long-cancel.wav" <<'PY'
import sys, wave
source, destination = sys.argv[1], sys.argv[2]
with wave.open(source) as src:
    frames, params = src.readframes(src.getnframes()), src.getparams()
    seconds = params.nframes / params.framerate
repeats = max(1, int(3 * 60 * 60 / seconds))          # about three hours
with wave.open(destination, "wb") as out:
    out.setnchannels(1); out.setsampwidth(2); out.setframerate(16000)
    for _ in range(repeats):
        out.writeframes(frames)
print("  -> %s (%.0f min)" % (destination, repeats * seconds / 60))
PY

  print ""
  print "Import both with File > Import Recordings… , then:"
  print "  ui-single-voice.wav  — transcribe it, then Analyze Speaker Turns."
  print "                         Expect NO labels and \"Only one voice could be told apart\"."
  print "  ui-long-cancel.wav   — transcribe it, then Analyze and press Cancel mid-run."
  print "                         Expect the transcript intact and no diarization.json written."
  print ""
  print "For the no-transcript state: import either file and do NOT transcribe it. The Improve"
  print "menu's Analyze item must be absent or disabled, with a footnote saying why."
  print ""
  print "Delete both meetings when you are done — they are fixtures, not recordings."
}

case "$command" in
  audio)
    generate_audio "${2:-}"
    ;;
  models)
    case "${2:-status}" in
      off)
        if [[ -d "$parked" ]]; then
          print "Models are already parked at: $parked"
        elif [[ -d "$runtime" ]]; then
          mv "$runtime" "$parked"
          print "Models moved aside. The app will now report speaker analysis as not installed."
          print "Restore with: $0 models on"
        else
          print "No installed models found; the app should already report not installed."
        fi
        ;;
      on)
        if [[ -d "$parked" ]]; then
          if [[ -d "$runtime" ]]; then
            print -u2 "Both a live runtime and a parked copy exist. Not guessing — inspect:"
            print -u2 "  live:   $runtime"
            print -u2 "  parked: $parked"
            exit 1
          fi
          mv "$parked" "$runtime"
          print "Models restored."
        else
          print "Nothing parked; models are already in place (or were never installed)."
        fi
        ;;
      status)
        [[ -d "$runtime" ]] && print "installed:  $runtime"
        [[ -d "$parked" ]] && print "parked:     $parked"
        [[ ! -d "$runtime" && ! -d "$parked" ]] && print "not installed"
        ;;
      *) print -u2 "usage: $0 models {off|on|status}"; exit 1 ;;
    esac
    ;;
  *)
    print "usage:"
    print "  $0 audio <dir>        generate the single-voice and long-cancel fixtures"
    print "  $0 models off|on|status   park or restore the installed models (reversible)"
    ;;
esac
