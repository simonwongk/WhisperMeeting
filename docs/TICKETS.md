# Ticket board

**The rules for this board — how to file, claim, close, and log tickets, plus the ID scheme, status
vocabulary, definition of done, and the ticket template — live in [`../AGENTS.md`](../AGENTS.md).
Read them before touching this file.** This file holds **open** work only; closed tickets move to
[`TICKET_LOG.md`](TICKET_LOG.md), and tickets blocked on a human action or decision move to
[`NEEDS_HUMAN.md`](NEEDS_HUMAN.md).

**Next free ID: `F134`.**

---

# Open tickets

### F121 — Serial quality gate can still hang inside the Swift test helper

- **Status:** open
- **Owner:** —
- **Severity:** medium
- **Area:** build
- **Filed:** 2026-07-31 by Codex /root (new-build review)

**Problem.** The first post-F120 `Scripts/quality-check.sh` run completed its build and started the
serial Swift suite, then stopped emitting output for more than a minute. Process inspection showed
only `swiftpm-testing-helper --no-parallel` alive, with no child test subprocess. Interrupting that
run left no helper processes; an immediate identical gate retry completed all 259 tests in 5.429 s.
This is a fresh recurrence after F115 claimed the constrained-runner hang class fixed.

**Impact.** A nondeterministic local/CI hang can withhold the quality signal and waste the full job
timeout even though the candidate is healthy. It also weakens F115's claim that serial execution
removed the whole class of subprocess-wait contention.

**Proposed fix.** Reproduce with per-test timing/last-started-test capture around the serial gate;
identify whether the Swift testing helper, an async teardown, or a subprocess test remains live.
Keep a bounded watchdog around CI test execution so a recurrence produces diagnostics rather than a
silent 40-minute timeout. Do not weaken or skip tests.

**Verification.** Repeated serial full-suite runs complete under a bounded timeout and a deliberately
wedged fixture produces the diagnostic/timeout path. Capture the last-started test when reproducing.

### F118 — Qwen cannot transcribe imported mp4/mov/aiff/caf recordings; failure message calls it transient

- **Status:** open
- **Owner:** —
- **Severity:** medium
- **Area:** transcription
- **Filed:** 2026-07-31 by Claude Code (Fable 5, apple-design redesign session; user-reported failure)

**Problem.** The import feature accepts audio *and video* (`fileImporter(allowedContentTypes:
[.audio, .movie, .audiovisualContent])`, `Sources/WhisperMeet/ContentView.swift:333`) and copies the
file byte-for-byte with its original extension (`AppModel.copyImportedRecording`,
`AppModel.swift:811-817`). But the Qwen helper loads audio via mlx-audio's `load_audio`
(`Scripts/qwen_transcribe.py:126` → installed `mlx_audio/stt/utils.py:53` → `audio_io.py read()`),
which routes **only `.m4a`/`.aac` to ffmpeg** and everything else to **miniaudio**
(`…/site-packages/mlx_audio/audio_io.py:196-223`, pinned mlx-audio 0.3.1), which decodes only
wav/flac/mp3/ogg-vorbis. Any imported `.mp4`/`.mov`/`.aiff`/`.caf`/… therefore fails
deterministically at load with `miniaudio.DecodeError: unsupported file format` — reproduced
byte-for-byte against the installed runtime with synthetic fixtures (bench-clip conversions; user
recordings untouched). The same `.mp4` fixture transcribes cleanly through the installed Whisper
turbo (ffmpeg decode, `…/Runtime/venv/…/whisper/audio.py:43-46`). Corrupt/truncated WAVs produce a
*different* message ("could not open/decode file"), so this error signature specifically indicates
the format-dispatch case, not a damaged file. In-app recordings (16-bit PCM `meeting.wav`) are
unaffected.

**Impact.** A user who imports a video or mac-audio recording and selects (or defaults to) the
Qwen engine gets a guaranteed failure dressed as a transient one: the classifier fallback
(`Sources/WhisperCore/TranscriptionFailureClassifier.swift:49`) says "Transcription failed partway
through … try transcribing again", though it failed at 0% and retrying the same engine can never
succeed — plus a raw Python traceback. Nothing tells the user the file is fine and Whisper would
transcribe it.

**Decided direction (Simon, 2026-07-31 — this supersedes fixer's choice).** Accept more formats;
never surface a raw error for a format problem:
1. **Decode first.** When the selected engine cannot read the recording's container, transcode it
   locally (AVFoundation/`afconvert`) to 16 kHz mono WAV — at import time or as a temp file at
   transcription time — and feed the engine that. The original recording is never modified
   (recording-is-source-of-truth invariant); any temp clip is disposable.
2. **If decoding is impossible, guide — don't error.** No Python traceback and no dead-end alert:
   the failure surface must say the format isn't supported by the selected engine and offer
   switching to the other model (Whisper decodes everything via ffmpeg), e.g. an actionable
   message/control that re-runs with the other engine.
3. **Fix the classifier.** Map the `unsupported file format` stderr signature in
   `TranscriptionFailureClassifier` to that guidance — this failure is deterministic, so "try
   transcribing again" must go.
Verify any helper change against the pinned mlx-audio 0.3.1 source per AGENTS.md.

**Verification.** Red-green: a `TranscriptionFailureClassifier` test mapping the captured stderr to
the new guidance (fails before, passes after). Real-runtime: an `.mp4`/`.aiff` conversion of a
bench clip (e.g. `afconvert -f m4af … && cp x.m4a x.mp4`) transcribes successfully on the Qwen path
after the fix; a genuinely undecodable file produces the engine-switch guidance, not a traceback.

**Review note (2026-07-31, Codex /root).** Commit `0eb1a48` landed the classifier/guidance slice
without first setting this ticket `in-progress`, violating AGENTS.md ticket rule 4. The ticket stays
open because the required decode-first conversion and real Qwen imported-format run are still absent.

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

### F90 — Add the BackupCoordinator + Settings "Back up library…" action (delivers F75)

- **Status:** open
- **Owner:** —
- **Severity:** medium
- **Area:** recovery
- **Filed:** 2026-07-31 by Claude Code (Opus 4.8)

**Problem.** `BackupPlan.compute` / `BackupRetention.prune` / `BackupVerification.succeeded`
(`Sources/WhisperCore/BackupPlan.swift:28,57,71`; `BackupPlanTests.swift`) have no wiring. There is no
`BackupCoordinator` in the tree and `SettingsView` (`ContentView.swift:1049`) has no backup action.
The source root already exists (`MeetingStore.rootDirectory`, `MeetingStore.swift:131`).

**Impact.** Users cannot back up recordings/indexes to a chosen folder from the app. The hash-verified,
retention-aware capability ships as dead code; if the primary disk fails, the recordings — the declared
source of truth — are lost with no in-app backup, undercutting the "be trusted" premise.

**Proposed fix.** Add `Sources/WhisperMeet/BackupCoordinator.swift`: enumerate `rootDirectory` into
`[BackupFile]` (path, size, SHA-256), read destination descriptors, `BackupPlan.compute`, copy `.copy`
items in `Task.detached` with a pre-copy free-space check, verify each via `BackupVerification`, and
`BackupRetention.prune` old destination generations. Add a "Back up library…" button + retention picker
to `SettingsView` (`NSOpenPanel`, `canChooseDirectories`). Only copy from the source; never modify/delete
it.

**Verification.** The coordinator is headless-testable in `WhisperMeetTests` with injected temp
source/dest dirs: unchanged→skip, changed/new→copy, each copy verifies, source bytes untouched,
retention drops only oldest dest generations. Settings button/`NSOpenPanel` have no harness — manual:
"Back up library…", pick an empty folder, confirm files appear; run again, confirm unchanged files
skip; confirm the source Recordings/ folder is byte-for-byte unchanged.

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
