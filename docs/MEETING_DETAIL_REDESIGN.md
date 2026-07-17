# Meeting Detail Redesign — Player + Unified Transcript

*2026-07-16*

## Goal

Change the meeting detail page so a completed meeting shows an **audio player** for its
recording, and below it the transcript as a **single editable text box** — replacing the
per-segment timestamped rows.

## Decisions

- **Timestamps:** kept as inline prefixes, one segment per line (`MM:SS␠␠text`), inside one box.
- **Editing:** the box is freeform and **auto-saves** to `transcriptText` as the user types.
- **Player:** native `AVPlayerView` (AVKit) with the standard inline transport bar.

## Layout (completed meetings)

`header → status card → audio player → single transcript box`. The old per-segment
`transcriptSegments` view is removed.

## Implementation

- **`WhisperCore/TranscriptModels.swift`** — add `TranscriptFormatter` (pure, testable):
  - `timestamped([TranscriptSegment]) -> String` renders `MM:SS␠␠text` lines.
  - `isTimestamped(String) -> Bool` detects whether text already has timestamp prefixes.
- **`Package.swift`** — link `AVKit` in the `WhisperMeet` target.
- **`AppModel.apply(result:)`** — store the timestamped rendering in `transcriptText` on
  completion (falls back to plain `result.text` when there are no segments). `segments` are
  still saved unchanged.
- **`ContentView.TranscriptDetailView`**:
  - Add `AudioPlayerView` (`NSViewRepresentable` wrapping `AVPlayerView`); show a
    "Recording unavailable" note when the WAV is missing.
  - Replace `transcriptSegments`/`transcriptEditor` with one `TextEditor` bound directly to
    `transcriptText` via a `store.update` binding (auto-save). Keep Copy / Export.
  - **One-time normalization on open:** if a completed meeting has segments but its
    `transcriptText` is not yet timestamped, rebuild it once from `segments`. This upgrades
    meetings recorded before this change.

## Invariants preserved

`segments` remain on disk untouched (recording is still the source of truth; no diarization
change). Only `transcriptText` is edited. Copy/Export now carry the inline timestamps.
