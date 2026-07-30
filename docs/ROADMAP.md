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
- **Rounds 6–8** — Quick Dictation (global hotkey → local Whisper → paste), reliability/observability
  hardening, and an MLX (Apple-Silicon) dictation engine (~3.3× faster, byte-identical transcripts).
- **Round 9** — Transcript quality review (`TranscriptQuality`, pure/tested): retain Whisper's
  per-segment confidence metrics (previously discarded) and flag likely low-confidence / silence-
  hallucination / repetitive segments using Whisper's own default thresholds, with an unobtrusive
  banner + prev/next step-through in the transcript detail. Read-only; audio untouched.
- **Round 10** — Preflight test recording (`PreflightSignalAnalyzer` + `PreflightAssessment`,
  pure/tested): a disposable test that records a few seconds of both channels and reports whether
  mic + system audio are actually capturing, with per-channel guidance. Dedicated engine + temp
  dir; never becomes a meeting.
- **Round 11** — Recording markers (`RecordingMarker` + `RecordingMarkers`, pure/tested): flag key
  moments during a meeting (⇧⌘M) or from playback, jump back via a seek strip, rename/delete, and
  export a `## Markers` section in Meeting Notes. Timestamps only — audio never touched.
- **Alternative local ASR, synthetic phase** — Qwen3-ASR 1.7B MLX 8-bit plus its aligner won the
  10-clip English/Mandarin/code-switch comparison and is available as an opt-in model. Whisper
  Large remains the default until Qwen passes the real, long-meeting gate.

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
1. **Qwen real-meeting validation** — the short synthetic gate selected Qwen3-ASR 1.7B and the user
   approved its opt-in integration. Before considering it as the default, benchmark copied,
   manually corrected English/Mandarin/code-switch meetings, including 30–60 minute, noisy, and
   far-field recordings. Measure vocabulary recall, hallucinations, timestamp accuracy, real-time
   factor, peak memory, and chunk-boundary correctness. Keep Whisper as default unless every gate
   in [`ASR_MODEL_ALTERNATIVES.md`](ASR_MODEL_ALTERNATIVES.md) passes.
2. **Menu-bar controls and keyboard shortcuts** — show status and provide start/stop/marker actions
   while another meeting app is frontmost, with explicit confirmation before destructive cancel.
3. **Local automatic backups** — configurable copy of recordings, source manifests, indexes, and
   transcripts to a user-selected folder, with verification and retention controls.
4. **Diagnostics bundle** — export privacy-safe app logs and recording manifests without audio for
   support, including the recording-start timings and recovery decisions.
5. **Signed release updates** — add a signed update feed only after an Apple signing identity and
   release channel exist; keep the guarded local installer for development builds.

## Explicitly deferred (cost/risk vs. identity)
- Pause/resume recording (SCStream complexity/risk to the source-of-truth audio).
- Any cloud/on-device speaker diarization surfaced as identified speakers (violates invariant;
  source tracks are retained on disk for a *future* local module only).
