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
- **Find-in-transcript** — M/M/L. In-detail search with match highlighting and next/prev. — DONE
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

## Next candidates — ordered
1. **Preflight test recording + playback** — verify both channels with a disposable 10-second sample
   before a critical meeting; keep it separate from the permanent meeting library.
2. **Recording markers** — add a timestamped marker with one click/shortcut during a meeting, then
   surface those moments in playback and exports without touching the audio.
3. **Transcript quality review** — identify likely low-confidence or no-speech segments from the
   local Whisper result and provide a focused correction queue; verify current upstream JSON fields
   before implementation.
4. **Menu-bar controls and keyboard shortcuts** — show status and provide start/stop/marker actions
   while another meeting app is frontmost, with explicit confirmation before destructive cancel.
5. **Local automatic backups** — configurable copy of recordings, source manifests, indexes, and
   transcripts to a user-selected folder, with verification and retention controls.
6. **Diagnostics bundle** — export privacy-safe app logs and recording manifests without audio for
   support, including the recording-start timings and recovery decisions.
7. **Signed release updates** — add a signed update feed only after an Apple signing identity and
   release channel exist; keep the guarded local installer for development builds.

## Explicitly deferred (cost/risk vs. identity)
- Pause/resume recording (SCStream complexity/risk to the source-of-truth audio).
- Any cloud/on-device speaker diarization surfaced as identified speakers (violates invariant;
  source tracks are retained on disk for a *future* local module only).
