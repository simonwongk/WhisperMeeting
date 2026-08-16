# Recording Safety and Recovery

WhisperMeet treats the recording as the source of truth. Transcription reads a finished WAV file; it
never edits or deletes that file. A failed or cancelled transcription therefore does not remove the
meeting audio.

## What is kept

Each meeting is stored in:

```text
~/Library/Application Support/WhisperMeet/Recordings/<meeting-id>/
```

A normally completed recording contains:

- `meeting.wav` — the combined file used for transcription.
- `system-audio.f32` — the original Mac system-audio track.
- `microphone-audio.f32` — the original microphone track.
- `source-tracks.json` — timing and format information for the source tracks.

Each `Recordings/<meeting-id>/` folder also holds a human-readable `notes.md` mirroring that
meeting's transcript, summary and action items, regenerated automatically as they change. It is
write-only insurance — the app never reads it back — and safe to read or copy with any editor.

The meeting list, business vocabulary, replacement rules, and dictation log each have a primary and
a previous-readable copy:

```text
meetings.json
meetings.backup.json
vocabulary.json
vocabulary.backup.json
replacement-rules.json
replacement-rules.backup.json
dictation-log.json
dictation-log.backup.json
```

The backup is deliberately one version behind after an ordinary save. Audio folders are independent
of these index files.

## Failure behavior

| Event | Automatic behavior | What remains safe |
|---|---|---|
| The selected local engine fails, exits, or produces invalid output | The meeting changes to **Needs Attention** and can be transcribed again. | The combined WAV and both source tracks. |
| The user cancels transcription | The selected local process stops and the meeting returns to **Ready**. | The combined WAV and both source tracks. |
| The app quits during transcription | On the next launch, the meeting returns from **Processing** to **Ready**. | The recording and any previously saved transcript. |
| Recording finalization fails | The app closes the raw track files instead of deleting them, then attempts to rebuild `meeting-recovered.wav`. | All source files that reached disk. |
| The app or Mac stops during recording | On the next launch, the app finds the unindexed recording folder and attempts to rebuild a WAV from the raw tracks. | Raw source tracks; the recovered WAV when enough audio was written. |
| Recording permission or startup fails before any file is created | The verified-empty meeting folder is removed automatically and is not shown as an interrupted recording. | No audio existed to preserve. Any non-empty folder remains protected. |
| Any meeting-library index (`meetings.json`, `vocabulary.json`, or `replacement-rules.json`) is damaged | The app opens that index's previous readable backup, which may be one save behind, and leaves the damaged primary exactly as it is. The **whole** library opens read-only — a damaged index anywhere means the app cannot be sure what you had, so editing, deleting, recording, importing and transcribing are all refused until recovery is resolved, whichever index it was. | The backup, the damaged primary, and every recording folder. |
| Neither index copy can be read | The exact bytes are copied aside as `<name>.unreadable-<timestamp>.json`, the library opens read-only, and no mutation, recording, import, transcription or deletion is permitted until recovery is resolved. | Every recording folder, and both original index files. |
| An interrupted imported file is empty or not playable | Empty files are never promoted. Other compressed candidates are verified with AVFoundation; an unverified candidate is indexed as **Needs Attention**, not as ready audio. | The original imported file and its folder remain untouched for replacement or manual inspection. |
| An imported WAV is truncated or declares more audio than the file contains | The WAV is not promoted as playable and the meeting is indexed as **Needs Attention**. | The original WAV and folder remain untouched for manual inspection or replacement. |
| An index save fails, including a full disk | The app shows an error and keeps the last readable index copy. | Existing recording files and the last readable index. New unsaved metadata may need to be entered again after storage is available. |
| A link import is interrupted mid-download (cancel, failure, or quit) | The partial download and its folder are removed; no meeting is created, and there is no resume in this version. Start the link again. | Everything already in your library. A `source.json` sidecar is written into the folder *before* the audio arrives, so a folder left behind by a crash identifies itself as a link import rather than an anonymous orphan. |

Before a new meeting, WhisperMeet refuses to start when less than 500 MB is available. During a
meeting it warns when available storage falls below 2 GB, while leaving the user in control of when
to stop. These checks reduce risk but do not replace the recovery behavior above.

When recovery must mix raw tracks without the original timing manifest, the two tracks are aligned
from their beginnings. The app labels that meeting as recovered because precise start-time alignment
cannot be guaranteed. The raw tracks are retained so a more exact manual recovery remains possible.

## Finding and recovering files manually

Select a meeting and choose **Show Recording in Finder**. If a meeting is missing from history,
open:

```text
~/Library/Application Support/WhisperMeet/Recordings
```

Do not rename or remove a recording folder while WhisperMeet is open. Copy the entire folder
elsewhere before attempting manual repair. A `.f32` source track is mono, 48,000 Hz, 32-bit
little-endian floating-point audio.

## Intentional deletion

Recovery protects against errors and interruptions. It does not override an explicit deletion:

- **Cancel Recording** discards the active, unfinished recording.
- **Delete Meeting** removes that meeting’s local recording folder and transcript.

Copy the recording folder first if either action should remain reversible.
