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
- `segmentText(at:in:)` — the transcript segment active at a marker's offset, for context: the
  segment containing the offset, or (if the marker landed in a brief pause) the segment that just
  ended, within a few seconds. A marker dropped deep into silence gets no context rather than a
  stale line from minutes earlier.
- `markdownSection(markers:segments:)` — a `## Markers` section for exported notes: one line per
  marker, `- **MM:SS** label — <transcript at that moment>`. Once the transcript has been edited
  (`TranscriptFormatter.isEdited`), the exporter passes no segments here, so markers list without a
  context clause that would contradict the edited body.

`MeetingRecord` gains an optional `markers` field (optional so meeting indexes written before this
feature still decode, exactly like `transcriptNormalized`).

## Capture and playback (`WhisperMeet`)

While recording, an "Add Marker" button (and the `⇧⌘M` shortcut — `⌘M` is left to the system Minimize)
records `now − startedAt` as the offset; pending markers are held on `AppModel` and persisted into the
`MeetingRecord` when the meeting is saved (and through crash recovery). Cancelling a recording discards
them with the rest of the disposable state. In the transcript detail, markers appear as a strip you can
click to seek the player, add at the current position, or rename/delete; a meeting without a transcript
yet still shows its markers so they can be reviewed or removed. Markers are written into the Meeting
Notes export.

### Known limitations

- **Offset reference.** A live marker's offset is measured from `startedAt`, the same clock the on-screen
  recording timer uses — so a marker lands where the timer read when you pressed it. That clock can differ
  from the mixed WAV's t=0 by the capture spin-up (typically sub-second when permissions are already
  granted). Markers added later from playback use the exact audio position.
- **Crash before save.** Live markers live in memory until the meeting is saved. A hard crash mid-recording
  loses markers dropped before the crash (the audio itself is still recovered); markers already written to
  `meetings.json` always survive.

## Invariants respected

Local-only (markers are on-device metadata), the recording is the source of truth (audio is never
modified — a marker is just a timestamp), no diarization, original language only. Only Cancel Recording
and Delete Meeting discard markers, consistent with the existing destructive-action rule.
