# Ticket board

**The rules for this board — how to file, claim, close, and log tickets, plus the ID scheme, status
vocabulary, definition of done, and the ticket template — live in [`../AGENTS.md`](../AGENTS.md).
Read them before touching this file.** This file holds **open** work only; closed tickets move to
[`TICKET_LOG.md`](TICKET_LOG.md), and tickets blocked on a human action or decision move to
[`NEEDS_HUMAN.md`](NEEDS_HUMAN.md).

**Next free ID: `F134`.**

---

# Open tickets

### F31 — Qwen meeting transcription reports no progress or ETA

- **Status:** blocked
- **Owner:** —
- **Severity:** medium
- **Area:** transcription
- **Filed:** 2026-07-30 by Claude Code (two-axis review, spec)
- **Blocked by:** F101 — the determinate bar needs the Qwen helper (`Scripts/qwen_transcribe.py`) to
  emit per-chunk progress. Verified 2026-07-31: the helper emits **zero** stdout/stderr during a real
  run, so there is nothing for `QwenASRClient` to stream-parse until the helper is changed.

**Problem.** `QwenASRClient.transcribe` (`Sources/WhisperCore/QwenASRClient.swift:117-118`) emits only
`.preparing` / `.loadingModel` and never `.transcribing` with a fraction, and its `run(...)`
(`:174`) reads the subprocess output only at EOF (`readDataToEndOfFile`) rather than streaming it.
`transcriptionProgressBar` (`Sources/WhisperMeet/ContentView.swift`) therefore shows an indeterminate
bar labelled "Loading the recognition model…" for the entire run.

**Impact.** A one-hour Qwen meeting looks hung. The "transcription progress + ETA" delivered in
Round 0 (`ROADMAP.md`) silently does not apply to the newer engine.

**Root of the block (verified 2026-07-31).** Unlike the Whisper CLI — whose `tqdm` bar streams to
stderr and is parsed live (`LocalWhisperClient.run`, `WhisperProgressParser`) — the Qwen helper runs
`asr.generate(...)` with `verbose` defaulting to `False`, and mlx-audio 0.3.1 only shows its
"Processing chunks" `tqdm` bar when `verbose and len(chunks) > 1`
(`…/mlx_audio/stt/models/qwen3_asr/qwen3_asr.py:1108-1111`). So the helper produces no parseable
progress today. The Swift-side streaming is ready to build the moment the helper emits
something; the helper change is the blocker.

**Verification.** A long Qwen run advances a determinate bar.

### F101 — Qwen helper must emit per-chunk progress so a meeting run can show a determinate bar

- **Status:** open
- **Owner:** —
- **Severity:** medium
- **Area:** build
- **Filed:** 2026-07-31 by Claude Code (dependency for F31)

**Problem.** F31 needs a determinate progress bar for a long Qwen meeting, but the Qwen helper emits
no progress signal to parse. `Scripts/qwen_transcribe.py:129` calls `asr.generate(audio,
language=…, chunk_duration=240.0, min_chunk_duration=0.1)` with `verbose` defaulting to `False`.
In the pinned **mlx-audio 0.3.1** source, `Qwen3ASR.generate` chunks the audio and iterates
`tqdm(chunks, desc="Processing chunks", disable=not verbose or len(chunks) == 1)`
(`…/site-packages/mlx_audio/stt/models/qwen3_asr/qwen3_asr.py:1078,1108-1111`), so **no bar is
written unless `verbose=True` and there is more than one chunk**. A `stream=True` path also exists
that yields a `StreamingResult` per chunk (`qwen3_asr.py:1180,1244-1278`). Verified empirically on
2026-07-31: a real helper run over `Scripts/bench/clips/en2.wav` produced **zero** stdout/stderr.

**Why separate from F31.** The helper change (Python, under `Scripts/`) and the Swift consumer (F31:
streaming `QwenASRClient.run` + a Qwen progress parser mirroring `LocalWhisperClient.run` /
`WhisperProgressParser`) are two distinct changes with a natural order — the Swift half is ready to
build as soon as a stable progress format exists, but it must not guess the format before the helper
emits one.

**Proposed fix (coordinate the two halves).**
1. **Helper (`Scripts/qwen_transcribe.py`):** make the per-chunk progress observable on a stream the client reads.
   Lowest-risk is `verbose=True` so mlx-audio's own "Processing chunks" `tqdm` bar streams to stderr
   (matching the Whisper precedent of parsing `tqdm`); note it is suppressed for single-chunk
   (short) runs, which is acceptable since those finish quickly. A more explicit and single-chunk-safe
   alternative is to switch to `stream=True` and print one dedicated progress line per yielded chunk
   (e.g. a stable `QWEN_PROGRESS <done>/<total>` token on stderr). Re-verify the chosen call against
   the pinned mlx-audio 0.3.1 source per AGENTS.md and record the citation.
2. **`QwenASRClient` (`Sources/WhisperCore`):** replace `readDataToEndOfFile` with the streaming
   `AsyncStream<Data>` + `readabilityHandler` pattern already used by `LocalWhisperClient.run`, add a
   `QwenProgressParser` (unit-tested against captured helper output), and emit `.transcribing`
   `LocalTranscriptionProgress` with `fractionCompleted` (done/total) and an ETA.

**Verification.** With the helper change in place, a multi-chunk Qwen run advances a determinate bar
(fraction increases per completed chunk) and the label reads "Transcribing locally…"; a
`QwenProgressParser` unit test maps a captured progress line/`tqdm` frame to the expected fraction
(fails before, passes after).

## Reachability wiring — filed 2026-07-31

Each ticket wires an already-shipped, WhisperCore-tested core to a user-triggerable surface. These
are the deferred user-facing halves of the F55–F77 feature batch, filed under the new **Reachability**
definition-of-done rule; the source log entry cross-references each. (Remove this header when its
last ticket closes.)

### F88 — Wire the "Second opinion" cross-engine comparison (delivers F73)

- **Status:** open
- **Owner:** —
- **Severity:** low
- **Area:** transcription
- **Filed:** 2026-07-31 by Claude Code (Opus 4.8)
- **Dependency (resolved):** F30 (Qwen timestamps) shipped 2026-07-31 (`fd56622`), so the
  Whisper→Qwen direction is no longer blocked and the full cross-engine comparison can be built.

**Problem.** `TranscriptComparison.compare(_:_:)` (`Sources/WhisperCore/TranscriptComparison.swift:26`;
`TranscriptComparisonTests.swift`) has no callers — `grep TranscriptComparison Sources/WhisperMeet` is
empty. No "Second opinion" action runs the non-selected engine on the same `meeting.wav` and feeds both
segment arrays into `compare`.

**Impact.** Users cannot cross-check a transcript against the other local engine to see where they
disagree — the trust/verification workflow the core was built for. The feature does not exist for the
user.

**Proposed fix.** Add a "Second opinion" action on a completed meeting: snapshot the non-selected
engine; run it on the existing WAV through the SAME single-run guard
(`beginTranscription`/`pumpTranscriptionQueue`, `AppModel.swift:807,832`) but into a scratch buffer,
never overwriting the stored transcript; call `compare(...)`; present agree/diverge/nonOverlapping
spans in a `ContentView` sheet with per-span replace/keep. Both engines only read the WAV.

**Verification.** Add a `WhisperMeetTests` case asserting a second-opinion run does NOT mutate the
stored transcript and that the single-run guard rejects a concurrent normal transcription. Sheet is
SwiftUI (manual): transcribe with Whisper, "Second opinion", confirm the span sheet, that replace/keep
applies only on confirm, and keeping leaves the transcript byte-for-byte unchanged.

### F92 — Wire per-segment re-run into the transcript segment menu (delivers F77)

- **Status:** open
- **Owner:** —
- **Severity:** low
- **Area:** transcription
- **Filed:** 2026-07-31 by Claude Code (Opus 4.8)
- **Dependency (resolved):** F30 (Qwen timestamps) shipped 2026-07-31 (`fd56622`), so the Qwen
  menu item is no longer blocked; the Whisper path was already buildable.

**Problem.** `SegmentAudioRange.byteRange` + `TranscriptSegmentSplice.splice`
(`Sources/WhisperCore/SegmentRerun.swift:10,20`; `SegmentRerunTests.swift`) have no callers. The
segment context menu (`Sources/WhisperMeet/ContentView.swift:2438-2445`) exposes only Copy actions —
no "Re-transcribe this segment" — and `AppModel` has no orchestration to read a WAV byte sub-range,
write a temp clip, run the engine, and splice back.

**Impact.** A user who spots a garbled span cannot fix it in place — only re-run the whole meeting or
hand-edit. The quality-review UI (`ContentView.swift:~2085,2371`) flags risky segments but offers no
way to act on them, leaving the review loop open-ended.

**Proposed fix.** Add "Re-transcribe this segment" to the segment menu (`~:2438`) invoking a new
`AppModel` method with the tapped index that computes `SegmentAudioRange.byteRange(...,sampleRate:16000)`,
performs the codebase's first partial WAV read (past the 44-byte header), wraps it via `WAVWriter.wavData`,
runs the snapshot engine under the single-run guard (`activeTranscriptionID`, `:216`), then
`TranscriptSegmentSplice.splice(...)` and persists. Ship Whisper first; gate the Qwen item on F30.
Recording untouched — only a temp clip is written.

**Verification.** Extract the read→temp-clip→run→splice orchestration into an injectable engine seam so
a `WhisperMeetTests` lifecycle test asserts spliced-back segments against a stub without real audio/GUI.
Context menu is SwiftUI (manual until the seam exists): re-transcribe a segment, confirm `meeting.wav` +
`source-tracks.json` are unchanged, the segment updates with ordered neighbouring timestamps, and a
cancel/failure leaves transcript and audio intact and retryable.
