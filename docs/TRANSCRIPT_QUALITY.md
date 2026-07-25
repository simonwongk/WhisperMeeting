# Transcript quality review

WhisperMeet's core promise is an *accurate* post-meeting transcript. Whisper is good but not
perfect: in silence it can hallucinate filler ("Thank you for watching."), on hard audio it emits
low-confidence guesses, and it occasionally loops into repetitive/degenerate text. Whisper already
knows when this is likely — it computes per-segment confidence metrics and even uses them to reject
decodes internally — but the CLI only *reports* them, it doesn't act on every case, and until now
WhisperMeet discarded them.

This feature keeps those metrics and turns them into a focused proofreading aid: it flags the
segments most likely to be wrong so the user can review a handful instead of re-reading everything.
It is entirely **read-only** — it never edits the transcript and never touches the audio.

## The metrics (verified against the installed `openai/whisper` source)

Each segment in Whisper's JSON output carries three quality signals (`transcribe.py`, the segment
dict written per-segment):

- `avg_logprob` — average token log-probability. Higher (closer to 0) = more confident.
- `no_speech_prob` — model's probability that the segment is silence / no speech.
- `compression_ratio` — gzip compression ratio of the text. High = repetitive/degenerate.

Whisper's own decode-rejection defaults (same file) define the thresholds we reuse verbatim, so our
flags mean the same thing Whisper's internal quality gate means:

| threshold | default | meaning |
|---|---|---|
| `logprob_threshold` | **-1.0** | below this → low confidence |
| `compression_ratio_threshold` | **2.4** | above this → repetitive / degenerate |
| `no_speech_threshold` | **0.6** | above this (with low logprob) → treat as silence |

## Classification (`TranscriptQuality`, pure `WhisperCore`, tested)

Per scored segment (one with metrics present; older transcripts have none and are simply *unscored*,
never flagged):

- **`.repetitive`** — `compression_ratio > 2.4`. Looping/degenerate output.
- **`.likelySilence`** — `no_speech_prob > 0.6` **and** `avg_logprob < -1.0`. This is exactly
  Whisper's own "consider the segment silent" rule; the classic silence-hallucination case.
- **`.lowConfidence`** — `avg_logprob < -1.0` (and not already caught above). A shaky guess.

`review(_:)` returns a `TranscriptQualityReport`: the flagged segments (with reasons), how many
segments were scored, and an overall `confidence` (fraction of scored segments with no flags). A
transcript with no metrics returns an empty, `unscored` report and the UI stays silent.

## UI

The transcript detail shows an unobtrusive banner only when there is something to review
("N segments may need a look"), with a control to step through the flagged segments (reusing the
find-in-transcript navigation). Flagged segments get a subtle margin marker. Nothing is auto-changed.

The flags describe Whisper's original segments. Once you edit the transcript (its text diverges from
the segment rendering — `TranscriptFormatter.isEdited`), the review banner and per-line markers are
hidden, because they no longer describe the text you're looking at. Read view then notes that it
shows the original transcription and that your edits live in Edit view.

## Invariants respected

Local-only (metrics come from the local run), recording is the source of truth (read-only; audio
untouched), no diarization (`speaker` stays `nil`), original language only (unchanged).
