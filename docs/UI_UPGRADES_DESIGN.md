# Recording & Transcription UX Upgrades — Design

Date: 2026-07-20

Five upgrades requested, all preserving the non-negotiable invariants in
`docs/PRODUCT_SPEC.md` (recording is the source of truth; local-only except Claude
summaries; no diarization; original language only). The split between the tested,
framework-free `WhisperCore` library and the AppKit/ScreenCaptureKit `WhisperMeet`
executable is respected: every new piece of *pure logic* lands in `WhisperCore` with
unit tests; everything touching Apple frameworks stays in `WhisperMeet`.

## 1. Recording health that explains itself

Problem: the current health panel shows two bare `ProgressView` meters (`rms * 4`) and a
list of warnings, with no indication of what "healthy" means or how it is judged.

Design:
- Add a pure, additive `overallStatus: RecordingHealthStatus` (`good` / `caution` /
  `atRisk`) computed from the existing `RecordingHealthSnapshot.warnings`. `atRisk` when a
  channel stopped or storage is low; `caution` for clipping or system-audio-not-detected;
  `good` otherwise. Unit-tested. Existing `warnings` and monitor logic are unchanged, so all
  current `RecordingHealthMonitorTests` keep passing.
- Redesign the panel: a colored status banner with a one-line reason, per-channel rows that
  each show a live meter plus a plain-language **state chip** ("Receiving audio", "Silent —
  normal until someone speaks", "No audio for 4s", "Too loud"), the storage line, and a
  collapsible **"How this is measured"** explainer (meters = loudness of the exact samples
  being written to disk; checks run once per second; the specific thresholds).
- Rewrite `docs/RECORDING_HEALTH.md` to match.

## 2. Live volume bar

Problem: levels only update once per second (the health timer) — too coarse to feel "live",
and there is no single "someone is talking" indicator.

Design:
- `AudioCaptureEngine` already computes an `RecordingAudioLevel` (rms+peak) for every captured
  buffer of each channel. Add a second, **throttled (~15 Hz)** callback `onLevels` that pushes a
  `RecordingLevels { microphone, systemAudio }` (new `Sendable` `WhisperCore` type) to the main
  actor, independent of the 1 Hz health snapshot used for warnings.
- `AppModel` gains `@Published recordingLevels`. The record screen shows a prominent **combined
  volume bar** driven by `max(mic.peak, system.peak)` with a "Speaking" highlight when it
  crosses a threshold, plus the two per-channel meters (now fed by the fast stream for
  smoothness). Warnings/status still come from the 1 Hz health snapshot.

## 3. Predicted recording size while recording

Design: new pure `RecordingSizeEstimator` in `WhisperCore` (unit-tested), constant-bitrate math
from elapsed time — no disk I/O:
- `meeting.wav` = 16-bit mono @ 48 kHz = 96 KB/s (the deliverable the user reasons about).
- Working footprint = wav + two float32 source tracks (48 kHz mono ×2) = 480 KB/s total.
The record screen shows "Estimated recording size: X" (final wav) with the working footprint as
secondary context, next to the live duration.

## 4. Transcription progress bar + ETA

Design: parse the tqdm bar the `whisper` CLI already prints under `--verbose False` (verified
against upstream `whisper/transcribe.py` and `whisper/__init__.py`, per `AGENTS.md` — **no CLI
contract change**).
- New pure `WhisperProgressParser` in `WhisperCore` (unit-tested). Consumes raw output chunks
  (splitting on `\r` and `\n` since tqdm rewrites in place). Distinguishes the **transcription**
  bar (`unit="frames"`, plain-integer `current/total`) from the first-use **model-download** bar
  (`unit="iB"`, byte-scaled `1.42G/3.09G`). Extracts `fractionCompleted` and
  `estimatedSecondsRemaining` (from tqdm's `<MM:SS` remaining field).
- `LocalTranscriptionProgress` is upgraded from a 2-case enum to a struct
  `{ phase: (preparing|loadingModel|downloadingModel|transcribing), fractionCompleted?, estimatedSecondsRemaining? }`.
- `LocalWhisperClient.run` is reworked to **stream** the merged stdout+stderr pipe (via a
  `readabilityHandler`-backed `AsyncStream`) instead of only reading a log file at the end. It
  still accumulates the full text for error diagnostics (existing failure/cancel tests keep
  passing) and still reads the JSON output file for the result. Merging both streams into one
  pipe avoids the classic two-pipe deadlock.
- `TranscriptDetailView` status card shows a determinate progress bar, a phase label
  ("Downloading model… 45%", "Transcribing… 62%"), and "About 2m 30s left" when known.

## 5. Import (upload) an existing recording and transcribe it

Design: `AppModel.importRecording(from:title:)` copies the chosen audio/video file into a fresh
`Recordings/<uuid>/` folder (copying honors the "recording is the source of truth" invariant and
keeps the app self-contained), reads its duration via `AVURLAsset`, upserts a `MeetingRecord`
(status `.recorded`, no source tracks — fine; startup recovery ignores indexed folders), then
begins transcription (whisper decodes any ffmpeg-supported format directly). The record screen
gets a secondary **"Import a Recording…"** button with a `.fileImporter` for common audio/video
types; on success it navigates to the new meeting. A transient `isImporting` flag covers the copy.

## Build & deploy

`Scripts/build-app.sh` (release build + ad-hoc sign) then replace `/Applications/WhisperMeet.app`
with the freshly built bundle so the installed app reflects the changes.

## Verification

- `swift test` — new unit tests for `WhisperProgressParser`, `RecordingSizeEstimator`, and
  `RecordingHealthSnapshot.overallStatus`; existing suites unchanged and green.
- `swift build` clean.
- Adversarial multi-lens code review over the diff (correctness/concurrency, Whisper-CLI
  contract, SwiftUI, invariant preservation) before deploy.
