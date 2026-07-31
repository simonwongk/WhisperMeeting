# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this
repository.

## What this is

WhisperMeet is a native macOS app (SwiftPM, no Xcode project) that records a meeting's microphone +
Mac system audio and produces an accurate **post-meeting** transcript by running an explicitly
selected local subprocess. OpenAI Whisper Large remains the default; Apple-silicon Macs can opt into
Qwen3-ASR 1.7B MLX 8-bit plus its forced aligner. No API key, no cloud upload, and no realtime
transcription for the record/transcribe path. Transcripts stay in the original spoken language
(English or Mandarin) — never translation.

The **one exception** to local-only is the opt-in **Claude summaries** feature: when the user pastes
a Claude API key in Settings and presses Summarize, the transcript is sent to Anthropic's Claude API
to produce a summary + key points + action items. Nothing is uploaded without a saved key and an
explicit press (with a confirmation). See `docs/CLAUDE_SUMMARIES.md`.

The product exists to be *trusted*, which is why so much of this file is about what must not change:
the recording is never mutated, failures are always retryable, and nothing is claimed as verified
without evidence. Treat the invariants below as the point of the project, not as overhead.

## Repository map

| Path | What it is |
|---|---|
| `Sources/WhisperCore/` | Pure, `Sendable`, framework-free logic. |
| `Sources/WhisperMeet/` | Everything touching Apple frameworks: capture, SwiftUI, app state. |
| `Tests/WhisperCoreTests/` | Swift Testing suite (`@Test`/`#expect`) for `WhisperCore`. |
| `Tests/WhisperMeetTests/` | Headless lifecycle tests for injected seams in the app target. |
| `Scripts/` | Build/install/setup scripts and the Python subprocess helpers. |
| `Scripts/bench/clips/` | Synthetic en/zh/code-switch clips — use these, never user recordings. |
| `docs/TICKETS.md` | Open work. Read before starting anything. |
| `docs/TICKET_LOG.md` | Closed tickets, with real command output as evidence. |
| `docs/PRODUCT_SPEC.md` | The non-negotiable product requirements. |
| `docs/ROADMAP.md` | Aspirational feature backlog (not commitments). |
| `docs/CHANGELOG.md` | Narrative record of shipped cycles. |
| `AGENTS.md` | Upstream-documentation rules and ticket rules for every agent. |

## Ticket workflow — required

**`docs/TICKETS.md` is the single source of truth for outstanding work. Read it before starting any
task, and file what you find there.**

- **Before you start:** read `docs/TICKETS.md`. If your task is not on the board, file it as a
  ticket first. Claim a ticket by setting `Status: in-progress` and `Owner` in the same commit that
  begins the work; never take one already `in-progress`.
- **While you work:** every defect, regression, unverified claim, or follow-up you notice gets a
  ticket — even one you are not going to fix. A finding that exists only in a chat reply is lost
  when the session ends. This applies to findings from code review as much as from implementation.
- **When you close one:** move the entry out of `docs/TICKETS.md` and append it to
  `docs/TICKET_LOG.md` with **real command output** — the failing test before the fix and the
  passing test after, plus the build and any real-model run. Never delete a ticket; `wontfix` and
  `invalid` are outcomes that get logged too. Reference the ID in commit messages:
  `fix(dictation): … (F24)`.
- **Do not close `fixed` without meeting the definition of done** in `docs/TICKETS.md` — notably: a
  test that fails before and passes after, and, for anything touching a runtime helper or model
  adapter, verification against the **real installed model** rather than only a stub.

`docs/TICKETS.md` tracks committed, verifiable work; `docs/ROADMAP.md` remains the aspirational
feature backlog; `docs/CHANGELOG.md` remains the human-facing narrative of shipped cycles.

## Commands

```bash
swift build                      # build the WhisperCore library + WhisperMeet executable
swift test                       # run both Swift Testing suites (does NOT download a model)
swift test --filter "original language"   # run a single test by name substring (Swift Testing)
Scripts/build-app.sh             # build + ad-hoc-sign .build/WhisperMeet.app (release)
open .build/WhisperMeet.app      # run the GUI app
Scripts/setup-local-whisper.sh   # install the local Whisper runtime from this checkout
Scripts/setup-qwen-asr.sh        # install pinned Qwen ASR + aligner (Apple silicon, opt-in)
```

Tests use the **Swift Testing** framework (`@Test`/`#expect`), not XCTest — `--filter` matches the
string in the `@Test("...")` display name. `WhisperMeetTests` may exercise app-target lifecycle
logic only through injected seams that avoid permissions, live hardware, and GUI startup.

## Architecture

Two SwiftPM targets, and the split is the key design decision:

- **`WhisperCore`** (library, tested) — pure, `Sendable`, framework-free logic. Contains the local
  subprocess contracts (`LocalWhisperClient`/`LocalWhisperRuntime` and
  `QwenASRClient`/`QwenASRRuntime`), the transcript data model (`TranscriptModels.swift`), the
  crash-safe index store (`BackupJSONStore`), interrupted-recording rebuild
  (`InterruptedRecordingRecovery`), and the Claude summarizer (`MeetingSummarizer` protocol +
  `ClaudeSummarizer`, a raw-HTTPS `URLSession` client — no Swift SDK exists). No AppKit/SwiftUI
  import — this is why it's unit-testable without a GUI (the summarizer is tested with a
  `URLProtocol` stub).
- **`WhisperMeet`** (executable, macOS 15+) — everything that touches Apple frameworks:
  `AudioCaptureEngine` (ScreenCaptureKit), `MeetingStore`, `AppModel`, SwiftUI `ContentView`,
  `VocabularyExtractor`. Keep macOS-framework code out of `WhisperCore`.

**Pipeline (record → transcribe):** `AppEntry` → `AppModel` (`@MainActor` orchestrator, owns
recording/transcription state machines) → `AudioCaptureEngine.start/stop` captures **two separate
Float32 tracks** (system + mic) via one `SCStream`, then `FloatTrackMixer` time-aligns them (padding
by first-presentation-time offset) into a 16-bit mono `meeting.wav` and writes `source-tracks.json`
→ `MeetingStore.upsert` persists the `MeetingRecord` → `AppModel.beginTranscription` snapshots the
selected engine/language and queues the job. Whisper runs its CLI contract; Qwen runs the bundled
`qwen_transcribe.py` against pinned local models and maps forced alignment back to timestamped
sentences. Either complete result is then written into `MeetingStore`; if Qwen alignment fails, its
complete text remains authoritative.

**Concurrency model:** `AppModel` and `MeetingStore` are `@MainActor`. All of `WhisperCore` is
`Sendable`. Blocking work (subprocess runs, the installer, WAV rebuild) is pushed to
`Task.detached`. Only one transcription runs at a time (guarded by `activeTranscriptionID`).

## Non-negotiable invariants

These come from `docs/PRODUCT_SPEC.md` and are enforced throughout — do not regress them:

- **The recording is the source of truth.** Transcription failure or cancellation must NEVER modify
  or delete the audio. Both clients only *read* the finished WAV, so every failure is retryable via
  "Transcribe".
- **Layered recovery, non-destructive:** `BackupJSONStore` keeps a previous-readable backup of the
  meeting/vocabulary indexes (double-write: old good copy → backup, then new → primary).
  `AudioCaptureEngine` preserves partial raw tracks on finalization failure.
  `InterruptedRecordingRecovery` rebuilds a WAV from raw `.f32` tracks on next launch **without
  deleting the originals**, and `AppModel.performStartupRecovery` re-indexes orphaned recording
  folders. Only **Cancel Recording** and **Delete Meeting** are intentionally destructive.
- **No speaker diarization.** Whisper produces timestamped segments only;
  `TranscriptSegment.speaker` is always `nil`. Never present segments as identified speakers. The
  separate mic/system source tracks are retained on disk so a future local diarization module can be
  added without rerecording.
- **Original language only:** never translate. Whisper must always use `--task transcribe`; Qwen
  must return original-language recognition.
- **Vocabulary is Whisper's `--initial_prompt`** (with `--carry_initial_prompt True`), capped at
  ~100 terms / ~1000 chars. `VocabularyExtractor` pulls candidate proper nouns from imported
  PDF/DOCX/TXT/MD/CSV; the user reviews before terms take effect. Qwen does not currently consume
  this prompt, and Settings discloses that limitation.

## The Whisper CLI contract (`LocalWhisperClient.commandArguments`)

This is the integration boundary with an external tool. Before changing model names or CLI flags,
**follow `AGENTS.md`**: fetch the current official docs at https://github.com/openai/whisper and
verify against the live source — do not guess flags or model names. Current contract: models `large`
(accuracy default) and `turbo`; `--task transcribe`; `--output_format json`; `--model_dir` points at
the app's local model cache; omit `--language` for auto-detect.

## Storage layout

Everything lives under `~/Library/Application Support/WhisperMeet/`: `Runtime/venv/bin/whisper`
(installed runtime), `Models/` (downloaded once on first use), `Runtime/Qwen3ASR/` (optional Qwen
environment, ASR model, aligner, helper, and manifest), `Recordings/<meeting-uuid>/` (`meeting.wav`,
`system-audio.f32`, `microphone-audio.f32`, `source-tracks.json`), and `meetings.json` /
`vocabulary.json` (+ their `.backup.json`). `LocalWhisperRuntime.findExecutable()` also falls back
to Homebrew/`~/.local/bin` installs.

## Build config note

`swift-tools-version: 6.0` but `swiftLanguageModes: [.v5]` — the code compiles under the **Swift 5
language mode** (with explicit `Sendable`/`@MainActor` annotations), not full Swift 6 strict
concurrency. `WhisperMeet` links its Apple frameworks explicitly in `Package.swift`.

See `README.md` for the end-user workflow and `docs/RECOVERY.md` for exact recovery file locations.
