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

A folder from an interrupted recording may also hold a 0-byte `capture.lock`. Like `.writer.lock`
below, it is not a stale lock: the recording app holds it in an open file descriptor for as long as
it is capturing, and the kernel releases it when that process dies. It is how a second copy of
WhisperMeet tells a recording that is still in progress (lock held: left alone) from one that
crashed (lock free: rebuilt, even while the other copy is open). It is removed once the meeting is
indexed, and is safe to delete by hand — the folder is then treated as it was before the file
existed, which is to say left alone while another copy of the app is open.

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

## The index and its history (F190)

Beside `meetings.json` and `meetings.backup.json` the library now keeps three more things. All of
them are **advisory**: delete any of them and the library still opens exactly as it did before.

```text
~/Library/Application Support/WhisperMeet/
  meetings.json                  the current index
  meetings.backup.json           the previous generation
  meetings.ledger.json           which generation is current, and its lineage (~600 bytes)
  meetings.history/              past generations, one file each
    g-000000041-4f2a…json        g-<sequence>-<fingerprint>.json
    conflict-000000042-…json     a save that lost a race to another writer
  .writer.lock                   0 bytes; which copy of the app holds the write lease
```

The same layout exists for `vocabulary.json`, `replacement-rules.json` and `dictation-log.json`.

`.writer.lock` being present is **not** a stale lock. The lock lives in the open file descriptor and
the kernel releases it when the process dies, including on a force-quit, so there is nothing to clean
up and the file is reused.

### Restoring a past generation from inside the app

A generation file's name contains the number of the save and a fingerprint of its contents, so a
generation identifies itself even if the ledger is lost. WhisperMeet can list them with their meeting
counts and dates, which is the distinction that matters: *"42 · 0 meetings · 3 minutes ago"* beside
*"41 · 17 meetings · yesterday"*.

Restoring is **append-only**. The chosen generation is written as a *new* save, so the generation it
replaced is still on disk and the restore itself can be undone.

If the library is open read-only, restoring still works — it is the one action that is not refused,
because it reads the bytes off disk and verifies them rather than trusting anything in memory. **You
will need to quit and reopen WhisperMeet afterwards** to get back to a writable library.

### Rebuilding the index from the recording folders

If the library is read-only and **no** past generation is retained, *Recover Library…* offers to
rebuild the index from the recording folders themselves instead. It shows what it would produce
before anything is written: one meeting per folder holding finished audio, titled from that folder's
`notes.md` where one exists and by date otherwise. Transcripts, summaries, tags, notes and markers
are **not** restored — each meeting's text is still in its `notes.md` beside the audio, and the
meeting can be transcribed again — and the dialog says so before you confirm. Folders holding only
raw source tracks are left for the interrupted-recording recovery on the next launch.

The rebuild is written the same append-only way as a restore, so the damaged index stays on disk and
the rebuild appears in the restore list like any other generation.

### Rehearsing the restore before you need it

The recovery path is the one part of this app that is only ever used on the worst day, by whoever is
there. A procedure first performed under pressure on real data is not a procedure — it is an
experiment. So there is a rehearsal:

```bash
Scripts/rehearse-recovery.sh          # build, print the steps, verify them, clean up
Scripts/rehearse-recovery.sh --keep   # leave the library in place to practise in the app
```

It builds a synthetic library in a temp directory, damaged the way the 2026-08-14 incident damaged
one: three retained generations, the newest of which is `[]`, with both the live index and its backup
also written as `[]`. It uses **no user data** — the meetings in it are two invented records — and it
writes only inside its own temp directory. It never reads or touches
`~/Library/Application Support/WhisperMeet`.

It then performs the by-hand restore below and checks that the meetings come back, so the rehearsal
also tests that the documented steps still work. A runbook nobody executes is a runbook that has
drifted; if this script fails, these instructions are wrong and that is the bug.

### Restoring a past generation by hand

With WhisperMeet **quit**:

```bash
cd ~/Library/Application\ Support/WhisperMeet
ls -l meetings.history/                 # pick a generation by size and date
cp meetings.json meetings.json.before-restore
cp meetings.history/g-000000041-4f2a….json meetings.json
rm meetings.ledger.json                 # the ledger now describes a generation that is not current
```

Removing the ledger is correct here, not a workaround: it is advisory, so the next launch simply
reads the two index files the way every version of WhisperMeet always has.

### If the app says two versions of the library were found

This is the one state that needs a decision from you. It means the index on disk belongs to no save
WhisperMeet recorded, *and* the save it did record is still available — so there are genuinely two
versions and it will not choose for you. Both are preserved as `.unreadable-<timestamp>.json` copies
before anything is reported.

To take the index that is currently in place and carry on, quit WhisperMeet and:

```bash
rm ~/Library/Application\ Support/WhisperMeet/meetings.ledger.json
```

To take the other version instead, restore it by hand as above.

### A generation is not a backup

`meetings.history/` holds the *index* — titles, transcripts, notes, summaries. It does not hold
audio, and it is deliberately excluded from the app's own backups. It is a short window of undo, not
an archive. Use **Back Up Library** for backups.

## Intentional deletion

Recovery protects against errors and interruptions. It does not override an explicit deletion:

- **Cancel Recording** discards the active, unfinished recording.
- **Delete Meeting** removes that meeting’s local recording folder and transcript.

Copy the recording folder first if either action should remain reversible.

**A deleted meeting's text is not erased immediately (F190).** Deleting a meeting removes its
recording folder straight away, but the *index* generations kept under `meetings.history/` still
contain that meeting's title, transcript, notes and summary until they age out. The window is
bounded — the newest few saves plus an hourly, daily and weekly position — so the longest a deleted
meeting's text normally survives is about a week. One exception has no time bound: the generation
holding the most meetings is pinned indefinitely, because it is the last line of defence against a
library-wiping bug, so if that happens to be a generation from before your deletion, the text stays
until a larger generation replaces it.

The audio is gone at once either way. To remove the text too, quit WhisperMeet and delete
`meetings.history/`; the library opens normally without it. A built-in command for this is tracked
as **F239**.
