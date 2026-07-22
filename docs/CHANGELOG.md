# Changelog

Autonomous improvement work on WhisperMeet. Every round: design → implement (TDD for pure logic)
→ `swift test` + `swift build` → adversarial multi-agent review → fix confirmed findings → build
and deploy `/Applications/WhisperMeet.app`. Test count grew 28 → 67. Non-negotiable invariants
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
  test suite, a warnings-as-errors release build, packaging, and signing. The identical gate now runs
  in GitHub Actions for every pull request and `main` push.
- Added a guarded installed-app updater (`Scripts/install-app.sh`) that refuses to replace the app
  while WhisperMeet is running, stages and verifies the replacement, and rolls back if the swap
  fails—protecting active recordings during development updates.
- Recording startup now writes phase timings for ScreenCaptureKit content discovery and stream start
  to the unified macOS log, so any remaining launch lag can be measured instead of guessed.

## Round 6 — Quick Dictation (push-to-talk, any app)
A second, independent feature alongside the meeting recorder: hold **Right Option** anywhere → speak →
release → local Whisper (`turbo`) transcribes → the text is auto-pasted into the focused field
(clipboard + notification fallback). Menu-bar presence, launch-at-login, and a Quick Dictation settings
section (enable, hold/toggle mode, language, delivery, Accessibility status). 100% local — no network.
- **Near-instant repeats via a resident "warm" helper** (`whisper_dictate_server.py`): loads the model
  once and serves clips over the child process's stdin/stdout as newline-delimited JSON
  (`DictationProtocol`), so only the first dictation pays the model-load/download cost.
- **Mic-only capture** (`MicDictationRecorder`, AVAudioEngine) — dictation never needs Screen Recording
  permission; clips are ephemeral temp WAVs, never touching `Recordings/` or the meetings index.
- **Global push-to-talk** (`HotkeyMonitor`, listen-only CGEventTap) with absolute per-side modifier
  detection; **auto-paste** (`TextInjector`, clipboard + synthesized ⌘V) with an honest clipboard
  fallback; a non-activating floating overlay pill (`DictationOverlay`) that never steals focus.
- Orchestrated by `DictationController` off a pure, tested `DictationSession` state machine; disabled
  while a meeting records (and vice-versa) so the two never contend for the mic.
- New tested `WhisperCore` modules: `WAVWriter` (now the single WAV path, shared with the meeting
  mixer), `DictationSession`, `DictationTextCleanup`, `DictationProtocol`. Suite grew 67 → 78.
- Built subagent-driven with per-task + final adversarial review. Fixes that review caught before
  ship: warm-helper read watchdog (no silent hang); recorder thread-safety + fail-loud empty capture;
  hotkey tap re-enable on OS-disable + correct dual-modifier release; overlay panel `canBecomeKey`
  override (no focus theft); controller coherence (no transcript loss on re-tap, no stuck-listening);
  and — from the whole-branch review — stopping the mic + resetting state when dictation is disabled
  mid-capture (no hot mic after disable), an honest paste result, and a longer first-run warm-up.

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
  through the whole pipeline and reports exactly where it breaks; plus a **persistent local history**
  of every dictation (time, text, outcome: pasted / clipboard / empty / failed-with-reason) with Copy
  and Clear — the fallback for recovering text if a paste misses.
- New tested `WhisperCore` modules `DictationLog` + `DictationKeyName` (suite 78 → 89).
- Review-caught fixes before ship: key-capture event-monitor leak (was hijacking the next keystroke
  app-wide if you left Settings mid-capture), duplicate log entry on a mic-start failure, and a warm
  Whisper process left resident after a self-test while dictation is disabled.

## Round 8 — Quick Dictation runs on MLX (Apple-Silicon), ~3.3× faster
Benchmark-driven engine swap for dictation only. A reproducible local benchmark
(`Scripts/bench/`, 10 EN/中文/code-switch clips) compared the current `openai/whisper` turbo
(PyTorch, CPU/fp32) against Apple-native `mlx-whisper` turbo fp16 on this M3 Pro:

| engine | avg release→text | EN WER | 中文 CER | code-switch CER |
|---|---|---|---|---|
| openai/whisper turbo (baseline) | 4.76 s | 0.023 | 0.049 | 0.000 |
| mlx-whisper turbo fp16 | **1.42 s** | 0.023 | 0.049 | 0.000 |

Same `large-v3-turbo` weights → **byte-identical transcripts**, so zero accuracy risk; MLX is
purely a faster (Metal/GPU) runtime. Adopted for dictation; **meetings stay on `openai/whisper`
large, untouched**. Verified the numbers hold in the production stdin/stdout helper path
(avg 1.412 s) and adversarially reviewed. Not "instant like Wispr" (that needs streaming — a
separate, deferred bet), but a real, perceptible win with no downside.
- Dictation helper (`whisper_dictate_server.py`) rewritten to `mlx_whisper`, pre-warmed before
  `{"ready":true}`, weights cached locally under app support; `HF_HUB_OFFLINE=1` once cached so
  warm-up never phones home (steady-state 100% local). fp16 (never q4 — protects Mandarin CER).
- Review-hardened before ship: meetings-first setup install (a dictation-only, arm64-only
  package can't abort the meetings runtime), helper auto-syncs into the runtime on version change,
  warm-up errors surfaced to diagnostics, conservative multi-term phantom-echo guard.
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
  the same thing Whisper's internal quality gate means: `lowConfidence`, `likelySilence` (the classic
  silence hallucination — high no-speech *and* low confidence), or `repetitive`.
- Transcript detail shows an unobtrusive banner ("N segments may need a look") with prev/next
  step-through and a margin marker on flagged rows (suppressed during find-in-transcript). Nothing is
  ever auto-changed; the audio is never touched.
- Adversarially reviewed (no Critical/Important findings); Minor consistency fix applied. Suite
  97 → 110 tests.

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
  playback of the sample. The Record view gains a "Test Recording…" control opening a
  countdown → analyzing → per-channel result sheet.
- Adversarially reviewed; fixed one Critical + two Important concurrency/lifecycle findings before
  ship: the capture task is now the single owner of the engine (a Cancel during the
  non-cancellation-aware `start()` can no longer orphan a live stream), the error path can't
  resurrect a dismissed sheet, and import is blocked while a test is active. Suite 110 → 125.
