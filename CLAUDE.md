# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

WhisperMeet is a native macOS app (SwiftPM, no Xcode project) that records a meeting's
microphone + Mac system audio and produces an accurate **post-meeting** transcript by running
the open-source `openai/whisper` CLI **locally as a subprocess**. No API key, no cloud upload,
no realtime transcription for the record/transcribe path. Transcripts stay in the original spoken
language (English or Mandarin) via Whisper's `transcribe` task — never translation.

The **one exception** to local-only is the opt-in **Claude summaries** feature: when the user
pastes a Claude API key in Settings and presses Summarize, the transcript is sent to Anthropic's
Claude API to produce a summary + key points + action items. Nothing is uploaded without a saved
key and an explicit press (with a confirmation). See `docs/CLAUDE_SUMMARIES.md`.

## Commands

```bash
swift build                      # build the WhisperCore library + WhisperMeet executable
swift test                       # run the WhisperCoreTests suite (does NOT download a model)
swift test --filter "original language"   # run a single test by name substring (Swift Testing)
Scripts/build-app.sh             # build + ad-hoc-sign .build/WhisperMeet.app (release)
open .build/WhisperMeet.app      # run the GUI app
Scripts/setup-local-whisper.sh   # install the local Whisper runtime from this checkout
```

Tests use the **Swift Testing** framework (`@Test`/`#expect`), not XCTest — `--filter` matches
the string in the `@Test("...")` display name. Only `WhisperCore` has tests; the `WhisperMeet`
GUI target has none (it depends on AppKit/ScreenCaptureKit and can't run headless).

## Architecture

Two SwiftPM targets, and the split is the key design decision:

- **`WhisperCore`** (library, tested) — pure, `Sendable`, framework-free logic. Contains the
  Whisper subprocess contract (`LocalWhisperClient`, `LocalWhisperRuntime`), the transcript data
  model (`TranscriptModels.swift`), the crash-safe index store (`BackupJSONStore`),
  interrupted-recording rebuild (`InterruptedRecordingRecovery`), and the Claude summarizer
  (`MeetingSummarizer` protocol + `ClaudeSummarizer`, a raw-HTTPS `URLSession` client — no Swift
  SDK exists). No AppKit/SwiftUI import — this is why it's unit-testable without a GUI (the
  summarizer is tested with a `URLProtocol` stub).
- **`WhisperMeet`** (executable, macOS 15+) — everything that touches Apple frameworks:
  `AudioCaptureEngine` (ScreenCaptureKit), `MeetingStore`, `AppModel`, SwiftUI `ContentView`,
  `VocabularyExtractor`. Keep macOS-framework code out of `WhisperCore`.

**Pipeline (record → transcribe):**
`AppEntry` → `AppModel` (`@MainActor` orchestrator, owns recording/transcription state machines)
→ `AudioCaptureEngine.start/stop` captures **two separate Float32 tracks** (system + mic) via one
`SCStream`, then `FloatTrackMixer` time-aligns them (padding by first-presentation-time offset)
into a 16-bit mono `meeting.wav` and writes `source-tracks.json` → `MeetingStore.upsert` persists
the `MeetingRecord` → `AppModel.beginTranscription` spawns `LocalWhisperClient.transcribe`, which
runs the `whisper` CLI as a `Process`, parses its JSON output into `TranscriptSegment`s, and writes
the result back into `MeetingStore`.

**Concurrency model:** `AppModel` and `MeetingStore` are `@MainActor`. All of `WhisperCore` is
`Sendable`. Blocking work (subprocess runs, the installer, WAV rebuild) is pushed to
`Task.detached`. Only one transcription runs at a time (guarded by `activeTranscriptionID`).

## Non-negotiable invariants

These come from `docs/PRODUCT_SPEC.md` and are enforced throughout — do not regress them:

- **The recording is the source of truth.** Transcription failure or cancellation must NEVER
  modify or delete the audio. `LocalWhisperClient` only *reads* the finished WAV, so every failure
  is retryable via "Transcribe".
- **Layered recovery, non-destructive:** `BackupJSONStore` keeps a previous-readable backup of the
  meeting/vocabulary indexes (double-write: old good copy → backup, then new → primary).
  `AudioCaptureEngine` preserves partial raw tracks on finalization failure.
  `InterruptedRecordingRecovery` rebuilds a WAV from raw `.f32` tracks on next launch **without
  deleting the originals**, and `AppModel.performStartupRecovery` re-indexes orphaned recording
  folders. Only **Cancel Recording** and **Delete Meeting** are intentionally destructive.
- **No speaker diarization.** Whisper produces timestamped segments only; `TranscriptSegment.speaker`
  is always `nil`. Never present segments as identified speakers. The separate mic/system source
  tracks are retained on disk so a future local diarization module can be added without rerecording.
- **Original language only:** always `--task transcribe`, never translate.
- **Vocabulary is Whisper's `--initial_prompt`** (with `--carry_initial_prompt True`), capped at
  ~100 terms / ~1000 chars. `VocabularyExtractor` pulls candidate proper nouns from imported
  PDF/DOCX/TXT/MD/CSV; the user reviews before terms take effect.

## The Whisper CLI contract (`LocalWhisperClient.commandArguments`)

This is the integration boundary with an external tool. Before changing model names or CLI flags,
**follow `AGENTS.md`**: fetch the current official docs at https://github.com/openai/whisper and
verify against the live source — do not guess flags or model names. Current contract:
models `large` (accuracy default) and `turbo`; `--task transcribe`; `--output_format json`;
`--model_dir` points at the app's local model cache; omit `--language` for auto-detect.

## Storage layout

Everything lives under `~/Library/Application Support/WhisperMeet/`:
`Runtime/venv/bin/whisper` (installed runtime), `Models/` (downloaded once on first use),
`Recordings/<meeting-uuid>/` (`meeting.wav`, `system-audio.f32`, `microphone-audio.f32`,
`source-tracks.json`), and `meetings.json` / `vocabulary.json` (+ their `.backup.json`).
`LocalWhisperRuntime.findExecutable()` also falls back to Homebrew/`~/.local/bin` installs.

## Build config note

`swift-tools-version: 6.0` but `swiftLanguageModes: [.v5]` — the code compiles under the **Swift 5
language mode** (with explicit `Sendable`/`@MainActor` annotations), not full Swift 6 strict
concurrency. `WhisperMeet` links its Apple frameworks explicitly in `Package.swift`.

See `README.md` for the end-user workflow and `docs/RECOVERY.md` for exact recovery file locations.
