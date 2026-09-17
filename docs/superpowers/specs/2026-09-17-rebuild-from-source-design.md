# F267 — Rebuild a meeting from its source tracks

**Status:** design, 2026-09-17, whisper-62.
**Ticket:** F267. **Template:** F193's library recovery — show what would happen, never run
automatically, never delete audio, require confirmation.

## Why this is worth doing now

The claim "nothing can re-run recovery on an indexed folder" is load-bearing in two tickets that
are already closed. F256's floor throws rather than index an empty meeting *because* a duration-0
meeting would be final. F279's severity argument rests on a stranded recording being unrecoverable.
Both are correct today, and both are propped up by an accident of `orphanedRecordings()` rather
than by a decision anyone made.

That is the shape of defect worth fixing even at medium severity: a property two closed arguments
depend on, true only by side effect.

## The precondition, and the one refusal that matters

Offer the action when **both** hold:

1. The folder's `.f32` tracks exist and declare more than zero frames.
2. **`meeting.wav` does not exist.**

The second is the important one and it is a refusal, not a filter. `meeting.wav` is written only by
`AudioCaptureEngine.stop()`, so its presence means a capture finished normally. Rebuilding over that
and repointing the index at `meeting-recovered.wav` is precisely the harm F255 exists to prevent —
the complete recording left on disk with nothing referring to it. A user who believes their
`meeting.wav` is bad has the documented manual procedure; the app will not do it for them.

A meeting whose audio file is missing entirely still qualifies, which is the case with the most to
gain.

## Never delete audio, including by overwriting

The rebuild writes `meeting-recovered.wav`, so a second run would destroy the first. That is
deleting audio; the fixed filename just makes it invisible. Before rebuilding, an existing
`meeting-recovered.wav` moves to `meeting-recovered-superseded-<n>.wav`, lowest unused `n` from 1.
Nothing is ever removed, and `recordingPath` stays stable because the new rebuild takes the
original name.

Disk grows by roughly one meeting's audio per rebuild. That is stated in the confirmation rather
than solved — a silent cap that discards the user's audio would be the same defect in a smaller
font.

## What a rebuild may change, and what it may not

May change: `duration`, `recoveryWarning`, and `recordingPath` (in practice unchanged).

May not change, per F148 #1: `title`, `transcriptText`, `segments`, `notes`, `tags`, `summary`,
`markers`, `pinned`. A rebuild that blanks a user's text is worse than the imperfect audio it
replaces. This is what makes the action safe enough to offer at all.

### The transcript now describes audio that no longer exists

If the second rebuild is longer — the expected case, since the first was truncated — an existing
transcript covers only the old prefix and its timestamps point into a different file. Blanking it
is forbidden above and would be the greater harm anyway.

So it stays, and the meeting says so. By F281's rule, a transcript silently describing superseded
audio is a false claim by omission: nothing contradicts it, so it reads as current. A new optional
`MeetingRecord.staleTranscriptWarning: String?` joins the existing three in the `notes.md` caveats
list and the detail view, and is cleared the next time the meeting is transcribed.

Set only when there *is* a transcript and the duration actually moved. A rebuild that reproduces
the same audio says nothing.

## Structure

`InterruptedRecordingRecovery.recover(in:sampleRate:)` currently does two things: returns an already
finalized recording, or rebuilds from raw tracks. The second half becomes
`rebuildFromSourceTracks(in:sampleRate:)`, called by both `recover` and this feature. No behaviour
change — `recover` keeps its short-circuit; F267 needs the half that skips it, because by definition
its folder already has a finalized rebuild.

`SourceRebuild` (WhisperCore, Foundation-only) owns the policy: `offer(in:currentDuration:)`
returning a `SourceRebuild.Offer?` describing what would happen, and `rebuild(_:)` performing the
move-aside and the rebuild. Pure enough to test without a store.

`AppModel` gets the F193 quartet — `pendingSourceRebuild`, `requestSourceRebuild(id:)`,
`performSourceRebuild(confirmed:)`, `cancelSourceRebuild()` — with the same structural guarantee
F193 established: only an offer this model actually produced can be acted on, so "user-reviewed" is
enforced by the code rather than by convention.

`ContentView` gets the button on a meeting that qualifies, and the confirmation showing the current
duration, what the tracks promise, and that the existing audio is kept.

## Verification

Each maps to a ticket requirement.

- A meeting recovered from a truncated rebuild can be rebuilt again and gains the longer duration.
- No offer when the tracks are gone; **no offer when `meeting.wav` exists**, which is the F255
  refusal.
- The superseded WAV still exists afterwards, under its new name, byte-identical.
- Title, transcript, notes, tags, summary and markers are untouched across a rebuild — F148 #1,
  asserted field by field rather than by a spot check.
- A rebuild that lengthens a transcribed meeting sets the stale-transcript caveat; one that changes
  nothing does not.
- `performSourceRebuild(confirmed: false)` does nothing at all.
- An offer the model never produced is refused.
