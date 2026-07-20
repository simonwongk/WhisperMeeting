# Changelog

Autonomous improvement work on WhisperMeet. Every round: design → implement (TDD for pure logic)
→ `swift test` + `swift build` → adversarial multi-agent review → fix confirmed findings → build
and deploy `/Applications/WhisperMeet.app`. Test count grew 28 → 53. Non-negotiable invariants
(local-only except Claude summaries; recording is the source of truth; no diarization; original
language only) preserved throughout.

## Round 0 — Recording & transcription visibility
- Recording-health panel that explains itself: one-word status (healthy / check / at-risk),
  per-channel state chips, and a "How this is measured" explainer.
- Live volume bar reacting to whoever is speaking (~15 Hz level stream).
- Predicted recording size while recording (deliverable WAV + honest on-disk footprint).
- Transcription progress bar + ETA, parsed live from the `whisper` CLI's tqdm output
  (`WhisperProgressParser`) — no CLI-contract change; distinguishes model-download from transcribe.
- Import (upload) an existing audio/video file and transcribe it.
- Review: 7 findings fixed (cancellation/termination race, capture-init data race, parser
  de-dup, indeterminate progress bar, import-vs-record state race, size undercount, imported-file
  recovery gap).

## Round 1 — Extract & organize
- Multi-format export: SRT, WebVTT, Markdown, plain, timestamped, JSON (`TranscriptExporter`).
- Global meeting search over titles + transcripts (`TextSearch`).
- Inline meeting rename; duration on sidebar rows; disk-space guard before importing.
- Review: 5 findings fixed (≥100-min timestamp regex, rename focus-commit, search allocation,
  size-aware import guard, recovered-import duration).

## Round 2 — Read & navigate
- Segment-synced playback: tap a line to seek, live highlight of the playing segment, and a
  "Follow" toggle for auto-scroll (`TranscriptPlayback`).
- Find-in-transcript with live filtering; per-segment copy (with/without timestamp).
- Read/Edit toggle for the transcript.
- Review: 3 findings fixed, incl. a latent transcript-edit data-loss bug (normalization now runs
  once via a persisted `transcriptNormalized` flag).

## Round 3 — Throughput & automation
- Transcription queue (`TranscriptionQueue`): recordings/imports transcribe one at a time,
  automatically; queued state with Remove.
- Batch import: select many files at once, each copied in and enqueued.
- Delete now dequeues/cancels first (no queue ghosts); safer missing-meeting handling.

## Round 4 — Suggest vocabulary
- "Suggest Vocab" finds names/key terms in a transcript and offers them in a review sheet;
  nothing is added without explicit confirmation.

## Round 5 — Meeting Notes export
- One-click Markdown "Meeting Notes" combining the Claude summary and the full transcript
  (`MeetingNotesExporter`).

## New tested WhisperCore modules
`WhisperProgressParser`, `RecordingSizeEstimator`, `RecordingLevels` / `RecordingHealthStatus`,
`TranscriptExporter`, `TextSearch`, `TranscriptPlayback`, `TranscriptionQueue`,
`MeetingNotesExporter`, plus `TranscriptFormatter.clock`/`stripTimestamps`.
