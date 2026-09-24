# WhisperMeet v1 Product Specification

## Goal

Build an easy-to-use native Mac application whose primary outcome is the most accurate possible
post-meeting transcript in the meeting’s original language, with all speech processing kept local.

## Requirements

- Record both microphone and Mac system audio.
- Preserve separate source tracks and prepare a combined speech-focused WAV after the meeting.
- Do not require realtime transcription.
- Run open-source speech recognition locally; do not require an API key or upload meeting audio.
  Keep OpenAI Whisper Large as the default and offer the tested Qwen3-ASR path only as an explicit
  Apple-silicon opt-in until it passes long, real-meeting validation.
- Automatically detect English or Mandarin, with an option to select either language for a normally
  single-language meeting.
- Preserve the original spoken language by using the `transcribe` task, never automatic translation.
- Default to the multilingual `large` model for accuracy and offer `turbo` as a faster option.
- Produce editable timestamped transcript segments. When the optional Qwen3-ASR path cannot
  reconcile its forced-alignment word timings with the recognized text, preserve the complete
  transcript text without per-segment timestamps and surface a plain-language notice explaining that
  timing is unavailable — never drop the transcript or the explanation silently.
- Allow PDF, DOCX, TXT, Markdown, and CSV documents to supply a reviewable business-vocabulary list
  used as Whisper’s `initial_prompt`.
- Keep recording and transcription local, and summarize on-device by default: a local mlx_lm model
  (Apple silicon) produces the summary with no API key and nothing uploaded. The one optional cloud
  path is a Claude summary — it is opt-in, requires a user-saved API key plus an explicit, confirmed
  Summarize press, sends only the completed transcript, and never changes the recording or transcript.
- Store recordings and transcripts locally and provide meeting history, editing, copying, export,
  cancellation, and recovery after interruption.
- Treat recorded audio as the source of truth: transcription failures and transcription cancellation
  must never modify or delete the recording.
- Preserve partial raw tracks when recording shutdown or finalization fails, and recover unindexed
  recording folders on the next launch.
- Before recording, show microphone and system-audio permission state, the current default
  microphone, and available storage; refuse to begin when storage is critically low.
- During recording, show independent microphone/system meters derived from the samples written to
  the source tracks, warn about missing capture, clipping, and low storage, and prevent idle system
  sleep.
- Keep a previous-readable backup of meeting and vocabulary indexes. If an index copy cannot be
  read, copy its exact bytes aside before writing anything, and never overwrite bytes that failed to
  parse without first preserving a byte-exact copy — if that copy cannot be written, refuse the write
  entirely. When the meeting index cannot be fully read, open the library read-only and block every
  mutation, including recording, import and transcription. A damaged vocabulary or replacement-rules
  file is quarantined and makes only that list read-only: recording, import, transcription and meeting
  edits continue, and the list's own notice offers to keep the loaded copy or start a new list. Take no
  automatic action on recording folders: never rebuild history from them, and never delete audio.
  Restoring a damaged library is the Settings ▸ Recover Library… flow, which offers retained index
  generations, and Restore… from a whole-library backup (`docs/RECOVERY.md`); the app never rebuilds
  a library on its own.
- Surface recovery and storage failures in plain language, state whether the recording is safe, and
  let the user reveal a meeting's recording in Finder.
- On Macs with Homebrew installed, provide a one-click local runtime installer for FFmpeg, Python
  3.11, and `openai-whisper`; explain the prerequisite in Settings and the README.
- On Apple-silicon Macs, optionally provide a staged, hash-verifying Qwen3-ASR installer that cannot
  run concurrently with capture or transcription and preserves the previous runtime on failure.

## Verified local Whisper contract

- The official package is installed with `pip install -U openai-whisper` and requires FFmpeg.
- Current multilingual model choices include `large` and `turbo`; `large` is the accuracy-first
  default.
- `--task transcribe` returns the original spoken language.
- Omitting `--language` enables language detection; `--language English` and `--language Chinese`
  select a known meeting language.
- `--output_format json` writes text, detected language, and timestamped segments.
- `--initial_prompt` supports custom vocabulary and proper nouns; `--carry_initial_prompt True`
  applies it across decode windows.
- `--model_dir` keeps downloaded model files under the app’s local data directory.

## Explicit limitation

WhisperMeet may offer an explicit, post-meeting, entirely local speaker-turn analysis for a
completed recording. It may assign anonymous, per-meeting voice-cluster labels and let the user
rename those labels for that meeting. It must not infer, enroll, or verify a real person's identity;
match voices across meetings; infer role, gender, demographic attributes, or sentiment; or send
audio, embeddings, speaker turns, or user-entered aliases to a service.

The recording and original transcript remain unchanged. Failed, cancelled, ambiguous, overlapping,
unsupported, or timing-unavailable analysis preserves them and explains the limitation plainly.
Voice embeddings and model scratch output are temporary; no voice profile is persisted. Default
transcript views, notes sidecars, ordinary exports, search, and both local and Claude summaries
exclude speaker labels. A person must explicitly request any labeled export.

Two boundaries survive this allowance and remain absolute. ASR itself performs no diarization, so
timestamped Whisper or Qwen segments are never presented as identified speakers — a label may come
only from the separate analysis above. And the allowance is for analysis performed on this Mac:
imported third-party captions still never carry a speaker claim into a transcript, so the subtitle
parser goes on stripping `>>`, `JOHN:`, and `[Speaker 1]` before any segment is constructed.

The app preserves microphone and system-audio source tracks as capture provenance. They are never
treated as people: one track can carry several voices, and one voice can appear on both.

## Recovery boundary

Automatic recovery protects against process failures, app interruption, corrupt indexes, and
incomplete recording finalization. It preserves all audio files it finds. **Cancel Recording** and
**Delete Meeting** are explicit user deletion actions and remain intentionally destructive; the
interface and recovery documentation must state that boundary clearly.

## Two copies of the app, one library — a deliberate limit

If two copies of WhisperMeet open the same library, **both may write it.** The app does not, and
will not, make a library read-only because another copy holds the single-writer lease.

What it guarantees instead is that a lost race is **detected, reported and recoverable**: each save
is a compare-and-swap against the generation it read, a refused commit raises a visible message
rather than failing silently, the refused body is kept on disk as a branch, and the pre-existing
generations remain restorable. Nothing is overwritten unseen.

This is a trade made deliberately and it can be re-opened, so the reasoning belongs here rather
than in a commit message. Preventing the lost update means refusing writes on a lease, and a lease
that can make a library read-only is a new way to lock somebody out of their own meetings — which
is the harm this whole family of protections exists to prevent. The failure it would prevent is
recoverable; the failure it would introduce is not. A false refusal costs a user their app for as
long as it lasts, and a lost update costs them a re-save.

One reading that would weaken this has to be closed off, because an earlier draft of this section
got it backwards. F188 added a lease *refresh*, which looks as though it retires the classic
objection to refusing writes — that an instance which once saw a rival stays read-only for the rest
of its life. It does not, for the case that matters. `refreshWriterLease()` has a single caller,
inside `performStartupRecovery()`, and the only in-session route back into that method is an in-app
Restore, which `requestLibraryRecovery()` refuses outright for a library that is not degraded. An
instance that launches on a *healthy* library, sees a rival, and outlives it therefore never
re-asks. The objection stands, and the decision above is the safer one because of it rather than in
spite of it (F407).

## A recording whose writes are failing is reported, never stopped

When appends to the capture tracks keep failing — a full disk is the case this is really about —
the app tells the user, loudly and in every surface it has: the menu-bar title takes its warning
mark, the risk announcer speaks it once, the HUD says "Audio is not being saved — stop and check
disk space", and the in-window banner says to stop. **It does not stop the recording itself, and
it will not.**

The cost of that is real and is not hidden here: someone who starts a recording and walks away is
not looking at any of those surfaces, and if the disk stays full they come back to an hour of
elapsed time and a file that ends where the disk filled.

It is still the right trade, because **continuing is honest.** A write that fails does not shift
the timeline: the next write that succeeds compares the buffer's presentation time against the
frames actually on disk and makes up the difference in silence, so a capture that recovers yields
a correct recording with a silent stretch in it rather than a file whose every later timestamp is
wrong. Stopping would throw that recovery away. The failures this guards against are not all
permanent, and the one that is — a full disk — loses the same audio either way.

The other half is that ending somebody's meeting recording without being asked is a large action
taken on a heuristic, and a false positive ends a real meeting. The app's standing rule is that it
never stops a recording on its own, the sleep path excepted, where the OS is ending it anyway.

What holds this up is a property, not an intention, so it is pinned by a test rather than by this
paragraph: `failedWritesAreReconciledToWallClock` drives a run of failed writes through the real
writer and asserts the track still spans its wall clock, and its companion asserts the recording
comes back short without the reconciliation. If that property ever stops being true, this decision
should be revisited rather than preserved — a dishonest timeline would make stopping the better
answer.
