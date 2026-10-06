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

A recording longer than about 12 hours 25 minutes holds more audio than a classic WAV header can
describe, so its `meeting.wav` is written as **RF64** — the broadcast 64-bit form of WAV, which
macOS audio tools and ffmpeg both read. Every shorter recording is an ordinary WAV, as before.

**A shrunk meeting** (Shrink Meeting, F795) holds one compressed recording instead: `meeting.m4a`
(AAC, 16 kHz mono, about 15 MB an hour), `meeting-recovered.m4a` if its audio had been rebuilt, or
`recording.m4a` for an import. It keeps `notes.md`, speaker labels and the search index. It has no
`meeting.wav`, no raw `.f32` tracks and no `source-tracks.json`, so Rebuild Audio and re-running a
single segment (F660) are not available for it, and Verify Library checks only that the file exists
and is not empty. A whole-library backup made before the meeting was shrunk still holds the original
files.

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

A folder may also hold `ask-embeddings.json` and `ask-embeddings.f32`: the search-by-meaning index
for that meeting's transcript (numbers, not text). Like `notes.md` it is derived — delete it and the
meeting is searched by keyword until the index is rebuilt on the next question.

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
| The meeting index (`meetings.json`) is damaged | The app opens its previous readable backup, which may be one save behind, and leaves the damaged primary exactly as it is. The **whole** library opens read-only — the app cannot be sure what you had, so editing, deleting, recording, importing and transcribing are all refused until recovery is resolved. At launch, in the banner and in Settings → Meeting library it says the index was damaged and that nothing was copied aside, because nothing is: the damaged file stays where it is. | The backup, the damaged primary, and every recording folder. |
| `meetings.json` reads cleanly but is empty, while finished recordings are in `Recordings/` (the 2026-08-14 wipe shape) | The library opens read-only rather than treat those recordings as new. It says the index is empty, how many finished recordings are beside it, and that nothing was copied aside, because the index read cleanly. **Recover Library…** restores an earlier copy of the index, or rebuilds one from the recording folders when no copy was kept. | Every recording folder, the empty index and its backup. |
| The index on disk matches no save WhisperMeet recorded, and the last save it did record is still kept (something else rewrote it) | The library opens read-only and says *Two versions of the meeting library were found*. WhisperMeet does not choose: see [If the app says two versions of the library were found](#if-the-app-says-two-versions-of-the-library-were-found). | Both versions, and every recording folder. |
| Neither meeting-index copy can be read | The exact bytes are copied aside as `meetings.unreadable-<timestamp>.json` and `meetings.backup.unreadable-<timestamp>.json`, the library opens read-only, and no mutation, recording, import, transcription or deletion is permitted until recovery is resolved. | Every recording folder, and both original index files. |
| `vocabulary.json` or `replacement-rules.json` is damaged, unreadable, or was edited outside the app (F464) | Only **that list** becomes read-only; recording, importing, transcribing and every meeting stay available. The list shows its previous readable backup, the edited copy, or — when neither copy reads — nothing, with the unreadable bytes copied aside as `<name>.unreadable-<timestamp>.json`. Business Vocabulary says which, beside a *Keep This List* (or *Start a New List*) button that saves what is shown as the current copy. | The damaged or edited file is copied aside before anything replaces it, and the version the app last saved stays in `<name>.history/`. |
| An interrupted imported file is empty or not playable | Empty files are never promoted. Other compressed candidates are verified with AVFoundation; an unverified candidate is indexed as **Needs Attention**, not as ready audio. | The original imported file and its folder remain untouched for replacement or manual inspection. |
| An imported WAV is truncated or declares more audio than the file contains | The WAV is not promoted as playable and the meeting is indexed as **Needs Attention**. | The original WAV and folder remain untouched for manual inspection or replacement. |
| An index save fails, including a full disk | The app shows an error and keeps the last readable index copy. | Existing recording files and the last readable index. New unsaved metadata may need to be entered again after storage is available. |
| A link import is cancelled, or its download fails | The partial download and its folder are removed; no meeting is created, and there is no resume in this version. Start the link again. | Everything already in your library. |
| WhisperMeet quits, crashes or loses power while a link import is downloading | Nothing is removed. At the next launch the folder is listed as a failed **Interrupted import from _host_** entry that keeps the link, so the source can be opened and imported again. There is no resume. Deleting that entry also removes its folder, with the partial download and the saved link, so the entry is not listed again at the next launch (F576). | Everything already in your library. A `source.json` sidecar is written into the folder *before* the audio arrives, which is how the leftover folder identifies itself as a link import rather than an anonymous orphan. |

Before a new meeting, WhisperMeet refuses to start when less than 500 MB is available. During a
meeting it warns when available storage falls below the space Stop needs to write `meeting.wav` for
the audio recorded so far (about 96 KB per recorded second) plus 10 minutes of the raw tracks' growth
(about 230 MB), the time allowed for noticing the warning and stopping. The threshold is never less
than the same 500 MB the start check uses; that floor decides for about the first 47 minutes, and
after that the threshold grows with the recording (`RecordingHealthMonitor`, F530, F597). The
warning leaves the user in control of when to stop. These checks reduce risk but do not replace the
recovery behavior above.

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
  meetings.ledger.json           which generation is current, and its lineage (~15 KB once 64 saves in)
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

WhisperMeet offers this, as *Recover Library…*, only while the library is open read-only: on a library
it can read, putting an older index back would discard every newer meeting, so it is refused there and
the manual steps below are the way (F457). On a read-only library restoring is not refused, because it
reads the bytes off disk and verifies them rather than trusting anything in memory. When the
restored generation reads cleanly, the library is writable again straight away and WhisperMeet
finishes the startup work it skipped while the library was read-only; there is no need to quit and
reopen. If it still cannot be read, the library stays read-only and WhisperMeet says so.

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

### Restoring a whole backup

*Restore…* in Settings brings back one dated folder made by *Back up library…* — recordings and
indexes together. It works while the library is read-only too, since that is the state it exists to
repair: when the index and its backup copy are unreadable and no past generation was kept, a full
backup is the way out. Before anything is written, the files it would replace are copied into a
hidden `.pre-restore-<time>` folder inside the library and kept afterwards, so the restore can be
undone. While it runs, WhisperMeet takes no other changes to the library.

### Rehearsing the restore before you need it

The recovery path is the one part of this app that is only ever used on the worst day, by whoever is
there. A procedure first performed under pressure on real data is not a procedure — it is an
experiment. So there is a rehearsal:

```bash
Scripts/rehearse-recovery.sh                 # build, print the steps, verify them, clean up
Scripts/rehearse-recovery.sh --keep          # the same, then keep the restored library
Scripts/rehearse-recovery.sh --keep-damaged  # keep the library damaged, to practise in the app
```

It builds a synthetic library in a temp directory, damaged the way the 2026-08-14 incident damaged
one: three retained generations, the newest of which is `[]`, with both the live index and its backup
also written as `[]`. It uses **no user data** — the meetings in it are two invented records — and it
writes only inside its own temp directory. It never reads or touches
`~/Library/Application Support/WhisperMeet`.

It then performs the by-hand restore below and checks that the meetings come back, so the rehearsal
also tests that the documented steps still work. A runbook nobody executes is a runbook that has
drifted; if this script fails, these instructions are wrong and that is the bug.

`--keep` therefore hands over a library that is already repaired: WhisperMeet opens it healthy, with
no read-only notice and no *Recover Library…* button, so there is nothing to practise on in it. To
practise the in-app restore, use `--keep-damaged`. It stops before the by-hand restore and also puts
one finished recording in `Recordings/`: an empty index on its own looks like a new library, and
WhisperMeet opens an empty index read-only only when a recording shows meetings existed. Launch
WhisperMeet against the directory it prints:

```bash
WHISPERMEET_LIBRARY="/path/printed/by/the/script" /Applications/WhisperMeet.app/Contents/MacOS/WhisperMeet
```

It opens read-only. Choose *Recover Library…* in Settings. The rehearsal has no ledger, so each copy
is labelled only by when it was written, a date and a time with no meeting count, which is also what
you see after a real incident that lost the ledger. The newest copy, dated 14 August, is the empty
one. Restoring it leaves the library read-only and WhisperMeet says so. Choose *Recover Library…*
again and restore the 13 August copy, which brings the 2 meetings back.

`WHISPERMEET_LIBRARY` moves the whole library for that process: the index, dictation log, `Runtime/`
and `Models/`, and since F550 its settings. They are kept in a preferences domain derived from the
directory's path, named `WhisperMeet.library-` and 16 hex digits, which the script prints. The
rehearsal therefore starts with default settings, in which the watched folder and dictation are off.
Unless you turn the watched folder on inside the rehearsal, it cannot take a file from your watched
folder, and its settings changes do not reach your real ones. Three exceptions remain: the summary
style and meeting template are still shared; so is the Claude API key, which is in the Keychain; and
so is *Launch at login*, which registers the app itself as a login item (`SMAppService`), so
switching it in the rehearsal switches it for your real copy.
The path must be absolute. Setting `HOME` does **not** do this, because macOS resolves Application
Support from the account, not from `HOME`.

You do not have to quit the ordinary copy first. Each library has its own `.writer.lock`, so the two
never report each other as "another copy of WhisperMeet is open". But if dictation is on in both
copies, both respond to the same global hotkey. When you are done, quit the rehearsal copy and run
the two cleanup lines the script prints: `rm -rf` of the directory, then `defaults delete` of the
settings domain and `rm -f` of its file in `~/Library/Preferences`. `defaults delete` alone empties
that file but leaves it in place.

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

This is the one state that needs a decision from you. The app says it at launch, in the banner above a
meeting and in Settings → Meeting library, as *Two versions of the meeting library were found*. It
means the index on disk belongs to no save WhisperMeet recorded, *and* the save it did record is still
available — so there are genuinely two versions and it will not choose for you. Both are preserved as
`.unreadable-<timestamp>.json` copies before anything is reported, and neither has been changed.

To take the other version, the last save WhisperMeet recorded, open Settings → Meeting library →
**Recover Library…** and choose it from the list; or restore it by hand as above.

To take the index that is currently in place and carry on, quit WhisperMeet and:

```bash
rm ~/Library/Application\ Support/WhisperMeet/meetings.ledger.json
```

There is no button for that second choice yet; the banner points here for it.

### A generation is not a backup

`meetings.history/` holds the *index* — titles, transcripts, notes, summaries. It does not hold
audio, and it is deliberately excluded from the app's own backups. It is a short window of undo, not
an archive. Use **Back Up Library** for backups.

## Intentional deletion

Recovery protects against errors and interruptions. It does not override an explicit deletion:

- **Cancel Recording** discards the active, unfinished recording.
- **Delete Meeting** removes that meeting’s local recording folder and transcript.
- **Shrink Meeting** replaces a meeting’s audio with one compressed recording and deletes the
  original WAV, both raw tracks and their manifest. Nothing is deleted until the compressed copy
  has been decoded in full, matched to the original's length, flushed to disk, and committed: saved
  into the index, or, for an import that was already AAC, swapped atomically into place.

Copy the recording folder first if any of these should remain reversible.

**A deleted meeting's text is erased from the saved history a week later (F295).** Deleting a
meeting removes its recording folder straight away. Its title, transcript, notes and summary stay in
the backup copy and the index generations under `meetings.history/` for one week — the same window
the recovery list covers — so if the library is lost or damaged in that week, an earlier generation
can still bring it back. That is protection for the library, not an undo button: WhisperMeet offers
*Recover Library…* only while the library cannot be read (F457). To bring back one meeting you
deleted on purpose, restore a generation by hand as above, which also undoes every change saved
since that generation. After that week (checked at each launch and after each delete) every generation
that held the meeting is re-recorded without it under a new name, and the backup copy is rotated if
it still holds the meeting. The backup is rotated only when the index itself loads cleanly; if it
does not (it was replaced or damaged since WhisperMeet read it), the backup keeps the meeting and the
meeting stays queued until a check finds the index readable again (F680). Generations that never held
it are not touched, so the ability to undo a
bad save is kept for every other meeting. The rewrite removes only that meeting's entry: everything
else in each generation stays as it was written, including anything a newer version of WhisperMeet
added that this one does not understand (F552). The same removal reaches the index's other copies
(F457): quarantined copies (`meetings.unreadable-*.json`, `meetings.backup.unreadable-*.json`) and the
index files in a restore's `.pre-restore-*/` folder lose that meeting's entry and keep the rest. Two
kinds of copy cannot be cleaned that way, and both are named in a message by their path in the
library folder rather than skipped (F668): a copy that cannot be rewritten (a permission error, say)
stays queued and is tried again at the next launch; a copy that is not a readable index cannot have
one meeting removed from it, so it is left as it is and named once each launch while its bytes still
name the meeting — it may still contain the text; delete it yourself if you no longer need it. A copy
that cannot be opened at all is named too, because WhisperMeet could not check it. The recording folders a
restore set aside in `.pre-restore-*/`, **including each meeting's `notes.md` with its transcript
and summary**, are not touched by any of this (F664). The queue of pending deletions is
`meetings.pending-shred.json`.

Bringing a deleted meeting back inside that week — restoring an earlier generation from the recovery
list, or restoring a backup — cancels its shred: a meeting that is in the library again is never
removed from the history (F498). A deletion's recorded date is never rewritten from a later clock
(F603), so a launch with the clock set behind cannot shorten the week. A launch with the clock set
ahead still can — the deletion then looks a week old early — and so can a clock that was behind
when the meeting was deleted, since the date it recorded is already in the past; nothing on disk can
tell either from a correct clock. A deletion recorded more than
a week in the future — a date no deletion can have — waits a week from when WhisperMeet first sees
it that way instead, so its week starts then rather than never; once the clock is right again and
the date is no longer impossible, the recorded date applies.

If the shred cannot complete (a permission error on the history directory, say), the meeting is still
deleted and the app says so; *Forget History* in Settings → Meeting library removes the saved
history at once, and quitting WhisperMeet and deleting `meetings.history/` by hand does the same.
Forget History is unavailable while the library is read-only, because the history is then what
*Recover Library…* restores from. It keeps conflict copies (`meetings.history/conflict-*.json`, a save
another copy of WhisperMeet made at the same moment) unless you choose to remove them too, and it
never removes quarantined copies or `.pre-restore-*/` folders; its dialog and result name what it kept
(F457).
