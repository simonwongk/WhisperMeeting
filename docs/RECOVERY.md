# Recording Safety and Recovery

WhisperMeet treats the recording as the source of truth. Transcription reads a finished WAV file; it never edits or deletes that file. A failed or cancelled transcription therefore does not remove the meeting audio.

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

The meeting list and business vocabulary have primary and previous-readable copies:

```text
meetings.json
meetings.backup.json
vocabulary.json
vocabulary.backup.json
```

The backup is deliberately one version behind after an ordinary save. Audio folders are independent of these index files.

## Failure behavior

| Event | Automatic behavior | What remains safe |
|---|---|---|
| Local Whisper fails, exits, or produces invalid output | The meeting changes to **Needs Attention** and can be transcribed again. | The combined WAV and both source tracks. |
| The user cancels transcription | The Whisper process stops and the meeting returns to **Ready**. | The combined WAV and both source tracks. |
| The app quits during transcription | On the next launch, the meeting returns from **Processing** to **Ready**. | The recording and any previously saved transcript. |
| Recording finalization fails | The app closes the raw track files instead of deleting them, then attempts to rebuild `meeting-recovered.wav`. | All source files that reached disk. |
| The app or Mac stops during recording | On the next launch, the app finds the unindexed recording folder and attempts to rebuild a WAV from the raw tracks. | Raw source tracks; the recovered WAV when enough audio was written. |
| Recording permission or startup fails before any file is created | The verified-empty meeting folder is removed automatically and is not shown as an interrupted recording. | No audio existed to preserve. Any non-empty folder remains protected. |
| `meetings.json` or `vocabulary.json` is damaged | The app opens the previous readable backup and repairs the primary copy. | The backup and every recording folder. |
| Both an index and its backup are unreadable | Both damaged files are left untouched. Recording folders are scanned and usable recordings are added back to history. | The damaged files for manual inspection and every recording folder. Transcript text present only in the damaged index may require manual recovery or retranscription. |
| An index save fails, including a full disk | The app shows an error and keeps the last readable index copy. | Existing recording files and the last readable index. New unsaved metadata may need to be entered again after storage is available. |

Before a new meeting, WhisperMeet refuses to start when less than 500 MB is available. During a meeting it warns when available storage falls below 2 GB, while leaving the user in control of when to stop. These checks reduce risk but do not replace the recovery behavior above.

When recovery must mix raw tracks without the original timing manifest, the two tracks are aligned from their beginnings. The app labels that meeting as recovered because precise start-time alignment cannot be guaranteed. The raw tracks are retained so a more exact manual recovery remains possible.

## Finding and recovering files manually

Select a meeting and choose **Show Recording in Finder**. If a meeting is missing from history, open:

```text
~/Library/Application Support/WhisperMeet/Recordings
```

Do not rename or remove a recording folder while WhisperMeet is open. Copy the entire folder elsewhere before attempting manual repair. A `.f32` source track is mono, 48,000 Hz, 32-bit little-endian floating-point audio.

## Intentional deletion

Recovery protects against errors and interruptions. It does not override an explicit deletion:

- **Cancel Recording** discards the active, unfinished recording.
- **Delete Meeting** removes that meeting’s local recording folder and transcript.

Copy the recording folder first if either action should remain reversible.
