# Changelog

Improvement work on WhisperMeet. The earlier autonomous rounds followed design → implementation (TDD
for pure logic) → `swift test` + `swift build` → adversarial multi-agent review → confirmed fixes →
build and deploy. Later maintenance cycles record their own verification and deployment status
explicitly. The test suite has grown steadily from 28 across rounds — see each cycle's own recorded
count below for the figure at that point. Non-negotiable invariants (local-only except Claude summaries;
recording is the source of truth; no diarization; original language only) are preserved.

## Maintenance cycle — on-device summaries by default, plus AI transcript correction

- **Local meeting summaries are now the default (F164).** Summaries run on a bundled Qwen3 model on
  this Mac — no API key, fully offline — picked by RAM (Qwen3-8B-4bit on ≥ 16 GB, a 4B model below).
  Claude cloud summaries become an opt-in premium and still require a saved key and an explicit,
  confirmed press. A new keyless `LocalSummarizer` spawns `summarize_local.py` (mlx_lm, thinking
  disabled) against a dedicated `Runtime/Summarizer` runtime, kept separate from the opt-in Qwen3-ASR
  runtime because summaries are now a default and must not depend on it. The local prompt reuses
  `ClaudeSummarizer.systemPrompt` as the single source of truth; the helper's `parse_summary`
  degrades, never raises.
- **AI transcript correction toward your business vocabulary (F165).** A new "Correct with local AI"
  action asks the on-device model to fix domain terms (names, products, jargon) that ASR mis-heard,
  guided by the Business Vocabulary list. It reuses the summary model + venv via a sibling
  `correct_local.py`, so it needs no extra download. Corrections are proposal-only: they flow through
  the same review sheet as glossary corrections, the raw recording is never modified, a hand-edited
  transcript is skipped, and any span whose `from` text is not present verbatim in the transcript is
  dropped so a hallucination can never be applied.
- **Fixed a latent suite-wide hang the correction tests exposed (F169).** All four local subprocess
  engines (`LocalWhisperClient`, `QwenASRClient`, `LocalSummarizer`, `LocalTranscriptCorrector`)
  awaited their Python helper with `Process.waitUntilExit()`, which spins a run loop on the calling
  thread; on a Swift-concurrency cooperative worker the child's termination wake-up can land on a
  different worker and the wait wedges forever. F165's extra subprocess tests tipped this into a
  deterministic full-suite stall past the 600 s watchdog. A shared `armedExitStream(for:)` arms
  `terminationHandler` before launch and replaces the blocking wait with a non-blocking `await`.
- **Verification.** Full suite **325/325** (up from 316, none dropped), via the F166 swift-testing
  framework-path workaround; the complete gate (`quality-check.sh`) passes end to end — release build
  with warnings-as-errors plus a signed app package, exit 0. Python helper suites
  (`test_summarize_local.py`, `test_correct_local.py`) green. Exercised against the **real installed
  Qwen3-8B-4bit model**: a synthetic transcript was corrected "Kew Bernetes"→"Kubernetes" and
  "Post Grease"→"Postgres" while already-correct terms were left untouched (8.0 s), and F164's
  summaries produced valid Mandarin-in/Mandarin-out and English JSON. The app was rebuilt and
  installed to `/Applications/WhisperMeet.app` (signed with the stable "WhisperMeet Dev" identity) and
  launches clean.

## Maintenance cycle — warm Whisper dictation never actually warmed

- Fixed a pre-existing defect that silently disabled the warm path for **Whisper Turbo, the default
  Quick Dictation engine**. `whisper_dictate_server.py` passed `verbose=False` to
  `mlx_whisper.transcribe`. Whisper documents `False` as "minimal details" and guards its prints
  with `if verbose is not None`, so `False` still wrote `Detected language: X` to **stdout** — the
  same stream carrying this helper's newline-delimited JSON protocol. Verified against the live
  openai/whisper source and the installed `mlx_whisper/transcribe.py:175` per `AGENTS.md`.
- Effect: the warm-up handshake read `Detected language: English` instead of `{"ready": true}` and
  threw "Dictation helper failed to start.", so `FallbackDictationEngine` quietly dropped to the
  batch Whisper CLI on every dictation. The feature still produced text, which is why it went
  unnoticed — it just never delivered the low-latency warm-model behaviour it exists for.
  Auto-detect is the default language, so this fired on warm-up and on every automatic request.
- Fix is two layers: the helper now passes `verbose=None` (the only silent value), and
  `WarmWhisperDictationEngine.readLine` skips any stdout line that is not a JSON object, recording
  it as diagnostics instead. A single stray line would otherwise desync the stream permanently, with
  every later response answering the previous request. Qwen was never affected — its helper only
  writes JSON.
- Verification: two new tests (real helper script driven with a stubbed `mlx_whisper` that
  reproduces the library's exact print guard; and the engine fed a deliberately chatty helper) fail
  before the fix and pass after. Complete suite **178/178**. Re-ran the real installed models over
  all ten `Scripts/bench/clips` with `language: null`, which is the comparison the previous cycle
  could not complete because Turbo never reached readiness.

  | engine | cold start | warm per clip | en | zh | code-switch |
  |---|---|---|---|---|---|
  | Qwen3-ASR 1.7B | 2.8 s | **0.36 s** | 0.000 | 0.000 | 0.000 |
  | Whisper Turbo | 8.6 s | 1.43 s | 0.025 | 0.049 | 0.000 |

  Turbo's non-zero rates are mostly formatting, not misrecognition (`ten`→`10`, `三点`→`3点`); the one
  true error was `纪要`→`记要`. Measured on the small synthetic corpus, so treat it as a smoke test of
  the wire path, not a general accuracy claim.

  Reproduce with `Scripts/bench/dictation-ab.py` (added under F29; the table above predated it and
  was originally produced by an uncommitted script). It drives the installed production helpers over
  the real wire protocol. The clips are gitignored — run `Scripts/bench/generate_clips.sh` first. A
  second run on the same machine reproduced the **error rates exactly**; latency moved about 15 %
  (2.2 s / 9.5 s cold, 0.31 s / 1.39 s warm), so treat the error columns as deterministic for a
  given clip set and the timings as indicative of the gap rather than as fixed figures.

## Maintenance cycle — selectable Quick Dictation model

- Added a separate Quick Dictation model choice in Settings: Whisper Turbo remains the default,
  while Qwen3-ASR 1.7B is opt-in on Apple-silicon Macs. The meeting model preference remains
  independent, and the new preference changes no recording or transcript format.
- Kept the existing microphone recorder, temporary WAV, cleanup, delivery, and history paths.
  Selection replaces only the transcription engine. Replacing an engine shuts down its resident
  model before the next one warms, preventing Whisper and Qwen from accumulating in unified memory.
- Added a persistent offline Qwen dictation helper that loads only the ASR model. It deliberately
  does not load the 1.2 GB forced aligner used for meeting timestamps, because dictation delivers
  text only. Qwen's current local API has no vocabulary prompt, so that control is disabled and
  explained whenever Qwen is selected rather than silently promising unsupported behavior.
- Added selected-model diagnostics, self-test wording, helper self-healing, installer packaging, and
  per-engine timing/model-change log entries.
- Verification: focused dictation/Qwen tests passed **10/10**; the complete suite passed
  **176/176**; shell syntax, Python compilation, and diff validation passed; the warnings-as-errors
  release build passed; the packaged app contains `qwen_dictate_server.py`, is ad-hoc signed, and
  passed strict signature verification. The installed pinned Qwen runtime also transcribed the
  repository's synthetic English clip exactly. Full command/output history and limitations are
  recorded in
  [`DICTATION_MODEL_SELECTION_LOG_2026-07-30.md`](DICTATION_MODEL_SELECTION_LOG_2026-07-30.md).
- Installed the verified build at `/Applications/WhisperMeet.app` through the guarded updater, which
  refuses to replace the application while WhisperMeet is running and rolls back a failed swap.

## Maintenance cycle — crash-safe recording writes and ASR alternatives

- Replaced every legacy `FileHandle.write(_:)` call in live source-track capture, final WAV mixing,
  interrupted-recording recovery, and the warm dictation helper. That Foundation API raises an
  uncaught `NSFileHandleOperationException` on an I/O failure; all writes now use one throwing
  boundary (`ThrowingFileHandleIO`) so existing recording-preservation and recovery paths receive a
  normal Swift error instead of the app terminating.
- Added a regression test that closes a file handle and proves the failed write throws without
  terminating the test process. Verification: focused test passed; complete suite **157/157**;
  warnings-as-errors release build passed; packaged app built, ad-hoc signed, and passed
  `codesign --verify --deep --strict`.
- Researched and, after explicit approval, isolated and benchmarked current open-source ASR
  alternatives for local English/Mandarin meetings. Qwen3-ASR 1.7B 8-bit was selected over
  SenseVoiceSmall because it combined a 0.38-second warm synthetic result with zero measured English
  WER, Mandarin CER, and code-switch CER. SenseVoice was faster at 0.19 seconds but made a
  code-switch error. Full evidence, versions, hashes, failed/corrected checks, and limitations are
  in [`ASR_EVALUATION_LOG_2026-07-29.md`](ASR_EVALUATION_LOG_2026-07-29.md).
- Added Qwen3-ASR as an opt-in meeting model while keeping Whisper Large as the default. The app
  preserves existing `large`/`turbo` preferences, so no recording or transcript data format changed.
  Qwen runs fully offline after installation, writes only an isolated temporary result before
  updating a meeting, safely falls back to complete text if timestamp alignment cannot be mapped,
  and leaves the recording untouched on failure or cancellation.
- Added a pinned, hash-verifying, staged Qwen installer and installed its 4.2 GB managed runtime
  after approval. Installation/repair cannot run during recording or transcription. The packaged app
  includes both the installer and production helper.
- Final review hardened queued jobs (engine/language snapshots), aligner-failure text preservation,
  Intel availability, installer mutual exclusion, interruption rollback, stale multi-gigabyte
  artifact cleanup, and documentation. Both standards and specification re-reviews reported no
  remaining actionable findings.
- Final verification: shell syntax, Python compilation, and `git diff --check` passed; the complete
  Swift suite passed **169/169**; the warnings-as-errors release build passed; the packaged app
  contains the Qwen installer/helper, is ad-hoc signed, and passed
  `codesign --verify --deep --strict`.

## Round 0 — Recording & transcription visibility
- Recording-health panel that explains itself: one-word status (healthy / check / at-risk),
  per-channel state chips, and a "How this is measured" explainer.
- Live volume bar reacting to whoever is speaking (~15 Hz level stream).
- Predicted recording size while recording (deliverable WAV + honest on-disk footprint).
- Transcription progress bar + ETA, parsed live from the `whisper` CLI's tqdm output
  (`WhisperProgressParser`) — no CLI-contract change; distinguishes model-download from transcribe.
- Import (upload) an existing audio/video file and transcribe it.
- Review: 7 findings fixed (cancellation/termination race, capture-init data race, parser de-dup,
  indeterminate progress bar, import-vs-record state race, size undercount, imported-file recovery
  gap).

## Round 1 — Extract & organize
- Multi-format export: SRT, WebVTT, Markdown, plain, timestamped, JSON (`TranscriptExporter`).
- Global meeting search over titles + transcripts (`TextSearch`).
- Inline meeting rename; duration on sidebar rows; disk-space guard before importing.
- Review: 5 findings fixed (≥100-min timestamp regex, rename focus-commit, search allocation,
  size-aware import guard, recovered-import duration).

## Round 2 — Read & navigate
- Segment-synced playback: tap a line to seek, live highlight of the playing segment, and a "Follow"
  toggle for auto-scroll (`TranscriptPlayback`).
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
- "Suggest Vocab" finds names/key terms in a transcript and offers them in a review sheet; nothing
  is added without explicit confirmation.

## Round 5 — Meeting Notes export
- One-click Markdown "Meeting Notes" combining the Claude summary and the full transcript
  (`MeetingNotesExporter`).

## New tested WhisperCore modules
`WhisperProgressParser`, `RecordingSizeEstimator`, `RecordingLevelMeter` / `RecordingHealthStatus`,
`TranscriptExporter`, `TextSearch`, `TranscriptPlayback`, `TranscriptionQueue`,
`MeetingNotesExporter`, plus `TranscriptFormatter.clock`/`stripTimestamps`.

## Review follow-up — recording performance and correctness
- Replaced raw-linear meters with one tested `RecordingLevelMeter`: perceptual dBFS calibration,
  consistent mic/system/combined scaling, attack/release smoothing, speaking hysteresis, and stale
  channel decay.
- Isolated the ~15 Hz meter stream in a nested observable model so it no longer republishes through
  the root `AppModel` and invalidates the full sidebar/detail hierarchy while recording.
- Closed the local Whisper launch/cancel race with an atomic process-launch handshake; cancellation
  cannot miss a child process that has not quite entered `isRunning` yet.
- Empty interrupted imports are never promoted as recordings. Compressed imports are verified with
  AVFoundation before successful recovery; unverified files remain intact and appear as **Needs
  attention** instead of causing repeated recovery attempts or silent data loss.
- Subtitle and JSON exports now treat the visible, possibly edited transcript as authoritative.
  Precise Whisper timings are retained when lines align; restructured and text-only transcripts get
  safe derived cues instead of stale or empty output. JSON also includes the full transcript text.
- Find-in-transcript now highlights matches and provides match counts plus Previous/Next navigation.
- Playback highlighting now respects segment end times and turns off during silence gaps and after
  the final segment.
- Added 14 regression tests across meter calibration/decay, launch/cancellation races, truncated
  recovery validation, edited/text-only/retimed exports, per-occurrence search, and playback gaps.
- Added one-command quality automation (`Scripts/quality-check.sh`) for diff validation, the full
  test suite, a warnings-as-errors release build, packaging, and signing. The identical gate now
  runs in GitHub Actions for every pull request and `main` push.
- Added a guarded installed-app updater (`Scripts/install-app.sh`) that refuses to replace the app
  while WhisperMeet is running, stages and verifies the replacement, and rolls back if the swap
  fails—protecting active recordings during development updates.
- Recording startup now writes phase timings for ScreenCaptureKit content discovery and stream start
  to the unified macOS log, so any remaining launch lag can be measured instead of guessed.

## Round 6 — Quick Dictation (push-to-talk, any app)
A second, independent feature alongside the meeting recorder: hold **Right Option** anywhere → speak
→ release → local Whisper (`turbo`) transcribes → the text is auto-pasted into the focused field
(clipboard + notification fallback). Menu-bar presence, launch-at-login, and a Quick Dictation
settings section (enable, hold/toggle mode, language, delivery, Accessibility status). 100% local —
no network.
- **Near-instant repeats via a resident "warm" helper** (`whisper_dictate_server.py`): loads the
  model once and serves clips over the child process's stdin/stdout as newline-delimited JSON
  (`DictationProtocol`), so only the first dictation pays the model-load/download cost.
- **Mic-only capture** (`MicDictationRecorder`, AVAudioEngine) — dictation never needs Screen
  Recording permission; clips are ephemeral temp WAVs, never touching `Recordings/` or the meetings
  index.
- **Global push-to-talk** (`HotkeyMonitor`, listen-only CGEventTap) with absolute per-side modifier
  detection; **auto-paste** (`TextInjector`, clipboard + synthesized ⌘V) with an honest clipboard
  fallback; a non-activating floating overlay pill (`DictationOverlay`) that never steals focus.
- Orchestrated by `DictationController` off a pure, tested `DictationSession` state machine;
  disabled while a meeting records (and vice-versa) so the two never contend for the mic.
- New tested `WhisperCore` modules: `WAVWriter` (now the single WAV path, shared with the meeting
  mixer), `DictationSession`, `DictationTextCleanup`, `DictationProtocol`. Suite grew 67 → 78.
- Built subagent-driven with per-task + final adversarial review. Fixes that review caught before
  ship: warm-helper read watchdog (no silent hang); recorder thread-safety + fail-loud empty
  capture; hotkey tap re-enable on OS-disable + correct dual-modifier release; overlay panel
  `canBecomeKey` override (no focus theft); controller coherence (no transcript loss on re-tap, no
  stuck-listening); and — from the whole-branch review — stopping the mic + resetting state when
  dictation is disabled mid-capture (no hot mic after disable), an honest paste result, and a longer
  first-run warm-up.

## Round 7 — Dictation reliability & observability
Driven by a real failure: the dictation helper wasn't installed on a runtime that predated the
feature, so transcription failed with only a "failed" toast. Fixes + a debug surface:
- **Self-healing install**: on enable/launch the app copies the bundled `whisper_dictate_server.py`
  into the runtime if the venv exists but the helper is missing — the "helper not installed" failure
  can no longer happen silently.
- **Customizable trigger key**: a "Change" control in Settings captures whatever key you press
  (validated to modifiers/F-keys, which don't emit text), for keyboards without a Right Option key.
- **Dictation pane** (new sidebar item): a Status/diagnostics panel (runtime, helper, turbo model,
  Microphone, Accessibility, hotkey — each ✓/✗) with a **Run self-test** button that pushes a clip
  through the whole pipeline and reports exactly where it breaks; plus a **persistent local
  history** of every dictation (time, text, outcome: pasted / clipboard / empty /
  failed-with-reason) with Copy and Clear — the fallback for recovering text if a paste misses.
- New tested `WhisperCore` modules `DictationLog` + `DictationKeyName` (suite 78 → 89).
- Review-caught fixes before ship: key-capture event-monitor leak (was hijacking the next keystroke
  app-wide if you left Settings mid-capture), duplicate log entry on a mic-start failure, and a warm
  Whisper process left resident after a self-test while dictation is disabled.

## Round 8 — Quick Dictation runs on MLX (Apple-Silicon), ~3.3× faster
Benchmark-driven engine swap for dictation only. A reproducible local benchmark (`Scripts/bench/`,
10 EN/中文/code-switch clips) compared the current `openai/whisper` turbo (PyTorch, CPU/fp32) against
Apple-native `mlx-whisper` turbo fp16 on this M3 Pro:

| engine | avg release→text | EN WER | 中文 CER | code-switch CER |
|---|---|---|---|---|
| openai/whisper turbo (baseline) | 4.76 s | 0.023 | 0.049 | 0.000 |
| mlx-whisper turbo fp16 | **1.42 s** | 0.023 | 0.049 | 0.000 |

Same `large-v3-turbo` weights and **matched WER/CER on the clips above**, so the accuracy risk is
low — but this is a *synthetic* benchmark (10 TTS clips, one timed pass, fixed engine order, no
noise, accents, long clips, real microphones, vocabulary, or p95/energy measurements), so it shows
"no measured regression here", not "identical output": MLX (Metal fp16) and openai/whisper (CPU
fp32) are different numeric runtimes and are not guaranteed bit-for-bit equal. MLX is purely a
faster (Metal/GPU) runtime. Adopted for dictation; **meetings stay on `openai/whisper` large,
untouched**. Verified the numbers hold in the production stdin/stdout helper path (avg 1.412 s) and
adversarially reviewed. Not "instant like Wispr" (that needs streaming — a separate, deferred bet),
but a real, perceptible win with no downside observed in this benchmark.
- Dictation helper (`whisper_dictate_server.py`) rewritten to `mlx_whisper`, pre-warmed before
  `{"ready":true}`, weights cached locally under app support; `HF_HUB_OFFLINE=1` once cached so
  warm-up never phones home (steady-state 100% local). fp16 (never q4 — protects Mandarin CER).
- Review-hardened before ship: meetings-first setup install (a dictation-only, arm64-only package
  can't abort the meetings runtime), helper auto-syncs into the runtime on version change, warm-up
  errors surfaced to diagnostics, conservative multi-term phantom-echo guard.
- Also this round: business vocabulary now feeds dictation's `initial_prompt` (shared, tested
  `VocabularyPrompt`). Suite grew 89 → 97 tests.

## Round 9 — Transcript quality review
Whisper computes per-segment confidence metrics — `avg_logprob`, `no_speech_prob`,
`compression_ratio` — and uses them internally to reject bad decodes, but the CLI only *reports*
them and WhisperMeet was throwing them away. This round keeps them and turns them into a focused,
**read-only** proofreading aid: the segments Whisper was least sure about are surfaced so the user
reviews a handful instead of re-reading everything. See `docs/TRANSCRIPT_QUALITY.md`.
- `TranscriptSegment` gains optional `avgLogprob`/`noSpeechProb`/`compressionRatio`
  (backward-compatible `Codable` — transcripts stored before this feature decode with `nil` metrics
  and are treated as *unscored*, never flagged). `LocalWhisperClient` parses the fields; the JSON
  schema and thresholds were verified against the installed `openai/whisper` `transcribe.py`.
- New pure, tested `TranscriptQuality` module classifies each scored segment using Whisper's **own**
  default thresholds — `logprob < -1.0`, `no_speech > 0.6`, `compression > 2.4` — so a flag means
  the same thing Whisper's internal quality gate means: `lowConfidence`, `likelySilence` (the
  classic silence hallucination — high no-speech *and* low confidence), or `repetitive`.
- Transcript detail shows an unobtrusive banner ("N segments may need a look") with prev/next
  step-through and a margin marker on flagged rows (suppressed during find-in-transcript). Nothing
  is ever auto-changed; the audio is never touched.
- Adversarially reviewed (no Critical/Important findings); Minor consistency fix applied. Suite 97 →
  110 tests.

## Round 10 — Preflight test recording
Answers the single biggest anxiety of any recorder — *will it actually capture when it matters?*
WhisperMeet records two independent tracks (your mic + the Mac's system audio) and either can fail
silently. Before a critical meeting you can now run a short, **disposable** test that records a few
seconds of both channels, analyzes each for real signal, and tells you plainly whether both are
captured — with specific guidance when one isn't. See `docs/PREFLIGHT_TEST.md`.
- New pure, tested `WhisperCore` modules: `PreflightSignalAnalyzer` (peak/rms → `silent`/`faint`/
  `ok`/`hot`, plus a little-endian Float32 `.f32` decoder) and `PreflightAssessment` (per-channel
  verdict + headline). The two channels are judged differently on purpose: a silent **microphone**
  is a firm failure; silent **system audio** is informational (it's only captured while another app
  is playing sound). 15 tests.
- `AppModel` drives the capture via a **dedicated** `AudioCaptureEngine` into a temp directory —
  never the meeting library, never a `MeetingRecord` — with an 8-second countdown, cancellation, and
  playback of the sample. The Record view gains a "Test Recording…" control opening a countdown →
  analyzing → per-channel result sheet.
- Adversarially reviewed; fixed one Critical + two Important concurrency/lifecycle findings before
  ship: the capture task is now the single owner of the engine (a Cancel during the
  non-cancellation-aware `start()` can no longer orphan a live stream), the error path can't
  resurrect a dismissed sheet, and import is blocked while a test is active. Suite 110 → 125.

## Round 11 — Recording markers
In a long meeting, the moments that matter are a handful of points in an hour of audio. Markers let
you flag them *as they happen* (a button or **⇧⌘M**) — or later from playback — then jump straight
back and see them in your exported notes, without scrubbing the whole recording. A marker is pure
metadata (just a timestamp); the audio is **never touched**. See `docs/RECORDING_MARKERS.md`.
- New pure, tested `WhisperCore` modules: `RecordingMarker` (Codable) and `RecordingMarkers` helpers
  — sorted insert with negative-offset clamp, 1-based display labels, active-segment lookup (robust
  to out-of-order segments), and a `## Markers` Markdown section for Meeting Notes.
- `MeetingRecord` gains an optional `markers` field (backward-compatible, like
  `transcriptNormalized`) and an `orderedMarkers` convenience.
- `AppModel` holds `pendingMarkers` during a live recording (⇧⌘M → offset from the recording timer),
  persists them on stop and through **in-process finalization recovery**, discards them on cancel.
  (A hard crash before Stop still loses markers dropped pre-crash — the audio is always recovered;
  live markers are disposable metadata, see `RECORDING_MARKERS.md`.) Plus add/remove/rename for
  saved meetings.
- UI: an "Add Marker" control + live count in the recording panel; a markers strip in playback
  (click a chip to seek, add at the current position, rename/delete); markers are also viewable and
  manageable before a transcript exists; Meeting Notes export includes the Markers section.
- Adversarially reviewed; fixed the Important "markers invisible until transcribed" gap and two
  Minor issues (out-of-order segment context, the ⌘M/Minimize shortcut clash) before ship;
  documented the bounded live-offset clock and crash-before-save behavior. Suite 125 → 138.

## Round 11.5 — one-click "Copy AI Prompt" for vocabulary
- A button on the Business Vocabulary screen copies a ready-made prompt
  (`VocabularyPrompt. generationPrompt`) to paste into any AI chat; the chat's one-term-per-line
  output pastes straight back into the Add box. Keeps the original script (English/中文), never
  translates, caps at ~80 terms.
- Privacy caution added (Round 12): the prompt is for an *external* chat, so anything pasted there
  leaves this Mac — surfaced in the UI and tooltip so business docs aren't shared unknowingly.

## Round 12 — external-review follow-ups
Independently verified all 23 findings of a code review (0 refuted; 19 confirmed, 4 partial), then
fixed **all 23**, each with tests where the logic is pure `WhisperCore`. Non-negotiable invariants
preserved. Suite 139 → 156.
- **Dictation accuracy (F6):** prompt-echo suppression now requires acoustic corroboration
  (`no_speech_prob ≥ 0.6`) before blanking, so genuinely dictated adjacent vocab terms ("Acme
  Kubernetes") are no longer silently deleted.
- **Dictation reliability (F4, F1, F3, F9):** an interrupted MLX download no longer poisons the
  cache into permanent offline mode (gate on snapshot completeness + self-repair); `shutdown()`
  interrupts in-flight helper work off-queue instead of waiting out the 120s/1800s read timeout;
  `FallbackDictationEngine` wires the batch openai/whisper engine so Intel / no-MLX / broken-install
  machines keep dictation; helper stderr is captured and surfaced in errors (was discarded).
- **Capture ownership (F2, F5):** one `isMicrophoneBusy` guard closes the preflight↔dictation
  double-capture hole and the preflight-cancel teardown race.
- **Preflight honesty (F17):** readiness needs *sustained* signal (crest factor), so a single click
  can't report "ready".
- **Quality review (F12, F22, F18):** `likely-silence` now catches the confident hallucinations
  Whisper actually emits (was an unreachable subset of Whisper's own skip rule); review steps
  through worst-first by severity (no hidden cap), banner shows "% clean"; once a transcript is
  edited its segment-derived quality flags are hidden (they no longer describe the shown text).
- **Markers (F16, F19):** marker-context fallback is bounded to nearby speech (no stale line from
  minutes earlier); export drops segment-derived context once the transcript is edited.
- **Dictation vocabulary (F10):** an optional "use business vocabulary for dictation" toggle
  (default on).
- **Perf (F21, F20):** playback active-segment lookup is linear not O(n²); transcription progress
  persists the `.processing` transition once instead of rewriting the index every tick.
- **Diagnostics / a11y / privacy / docs (F8, F15, F13, F11/F14, F7, F23):** diagnostics check the
  MLX cache not the old `.pt`; marker-delete a11y label; a privacy caution on "Copy AI Prompt";
  benchmark "zero accuracy risk / no downside" claims softened to match the synthetic evidence;
  marker crash-recovery wording corrected; README gained a features section.
