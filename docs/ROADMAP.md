# WhisperMeet Roadmap

A living, prioritized backlog for autonomous improvement rounds. Every item must respect the
non-negotiable invariants in `PRODUCT_SPEC.md`: local-only (except opt-in Claude summaries), the
recording is the source of truth, no speaker diarization, original language only. Features should
deepen the product's identity — a private, accurate, post-meeting transcription tool — not sprawl.

Legend: impact (H/M/L) · effort (H/M/L) · risk (H/M/L).

## Shipped
- **Round 0** — recording health that explains itself; live volume bar; predicted recording size;
  transcription progress + ETA; import/upload a recording.
- **Round 1** — multi-format export (SRT/VTT/Markdown/plain/timestamped/JSON); global meeting
  search; inline rename; sidebar duration; import disk-space guard.
- **Round 2** — segment-synced playback (tap-to-seek, live highlight, follow-playback auto-scroll);
  find-in-transcript; per-segment copy; Read/Edit toggle. Fixed a latent transcript-edit data-loss
  bug (one-time normalization via a persisted flag).
- **Round 3** — transcription queue (`TranscriptionQueue`, pure/tested): multiple recordings or
  imports run one at a time automatically; batch import (multi-select); queued state + Remove;
  delete now dequeues/cancels safely.
- **Round 4** — suggest vocabulary from a transcript (name/entity detection, review-before-add
  sheet); fresh per-meeting detail identity so state never leaks across selection.
- **Round 5** — Meeting Notes export (`MeetingNotesExporter`, pure/tested): one Markdown document
  combining the Claude summary and full transcript.

## Round 1 — Extract & organize (mostly pure logic, low risk) — DONE
- **Subtitle & document export (SRT, VTT, Markdown, JSON)** — H/L/L. Pure `TranscriptExporter` in
  `WhisperCore`, unit-tested; wire into the existing Export button as a format menu. Turns
  transcripts into deliverables (captions, docs) without leaving the Mac.
- **Global meeting search** — H/M/L. A sidebar search field filtering meetings by title and
  transcript text. Pure filter in a helper, tested.
- **Rename a meeting** — M/L/L. Editable title in the detail header (persists via `store.update`).
- **Sidebar duration + status at a glance** — L/L/L. Show duration on each meeting row.
- **Pre-transcription disk-space guard for large imports** — M/L/L. Warn before transcribing when
  free space is tight, consistent with the recording storage guard.

## Round 2 — Read & navigate
- **Segment-synced playback** — H/M/M. A read mode that lists timestamped segments; clicking one
  seeks the audio player, and the current segment highlights during playback. Segments already
  carry start/end times; no diarization implied.
- **Find-in-transcript** — M/M/L. In-detail search with match highlighting and next/prev.
- **Copy a single segment / copy with timestamps toggle** — M/L/L.

## Round 3 — Throughput & automation
- **Transcription queue** — H/M/M. Queue multiple recorded/imported meetings and transcribe them
  one at a time automatically (still single-process, honoring `activeTranscriptionID`).
- **Batch import** — H/L/L. Allow selecting several files at once; enqueue each.
- **Auto-suggest vocabulary from a finished transcript** — M/M/L. Reuse `VocabularyExtractor`
  ideas to propose proper nouns the user can accept.

## Ongoing — quality
- Accessibility: VoiceOver labels, Dynamic Type, keyboard shortcuts.
- Reliability: clearer errors, retry ergonomics, short/empty-audio handling.
- Recording: input-level peak-hold / short history sparkline.

## Explicitly deferred (cost/risk vs. identity)
- Pause/resume recording (SCStream complexity/risk to the source-of-truth audio).
- Any cloud/on-device speaker diarization surfaced as identified speakers (violates invariant;
  source tracks are retained on disk for a *future* local module only).
