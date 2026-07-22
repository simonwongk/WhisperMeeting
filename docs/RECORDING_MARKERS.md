# Recording markers

In a long meeting the moments that matter — a decision, an action item, "come back to this" — are a
handful of points in an hour of audio. Recording markers let you flag them *as they happen* with one
click (or a keyboard shortcut), then jump straight back to them afterwards in playback and see them in
your exported notes. You never have to scrub through the whole recording to find the part you cared
about.

Markers are pure metadata. Dropping one records only a timestamp — it **never touches the audio**, so
the recording stays the exact source of truth it was before. Markers are stored in the meeting index
(`meetings.json`) alongside the transcript, not in the WAV.

## Model (`RecordingMarker` + `RecordingMarkers`, pure `WhisperCore`, tested)

A `RecordingMarker` is `{ id, offset, label? }` where `offset` is seconds from the start of the
recording. `RecordingMarkers` provides the pure helpers:

- `inserting(_:into:)` — adds a marker, clamps a negative offset to 0, and keeps the list sorted by
  offset.
- `displayLabel(for:at:)` — the marker's own label if it has one, else `"Marker N"` (1-based).
- `segmentText(at:in:)` — the transcript segment active at a marker's offset, for context.
- `markdownSection(markers:segments:)` — a `## Markers` section for exported notes: one line per
  marker, `- **MM:SS** label — <transcript at that moment>`.

`MeetingRecord` gains an optional `markers` field (optional so meeting indexes written before this
feature still decode, exactly like `transcriptNormalized`).

## Capture and playback (`WhisperMeet`)

While recording, an "Add Marker" button (and the `⌘M` shortcut) records `now − startedAt` as the
offset; pending markers are held on `AppModel` and persisted into the `MeetingRecord` when the meeting
is saved. Cancelling a recording discards them with the rest of the disposable state. In the transcript
detail, markers appear as a list you can click to seek the player, and they're written into the Meeting
Notes export.

## Invariants respected

Local-only (markers are on-device metadata), the recording is the source of truth (audio is never
modified — a marker is just a timestamp), no diarization, original language only. Only Cancel Recording
and Delete Meeting discard markers, consistent with the existing destructive-action rule.
