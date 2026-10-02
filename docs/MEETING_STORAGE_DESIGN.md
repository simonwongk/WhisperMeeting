# Meeting storage: see it, shrink it (F795)

**Status:** design, written 2026-10-02 for the user's review. No code exists yet. Ticket `F795`; it depends on `F796`.

## What this is for

A finished one-hour meeting takes about **1.73 GB**, and the app never says so. This design adds two things:

1. **See** how much disk each meeting uses, and the library total.
2. **Shrink** a meeting by hand to the smallest useful size: one compressed recording. A one-hour meeting goes from
   about 1.73 GB to about 15 MB.

### Who decided what

The user decided these on 2026-10-02, when asked:

- **Smallest possible size**, which means lossy compression. They chose this over lossless-only, which keeps bit-exact
  audio and saves less.
- **Only when the user presses it.** They chose this over shrinking older meetings automatically.
- **Originals are deleted at once** after the compressed copy is verified. They chose this over moving them to the
  Trash, which I had recommended.

I chose everything else: the codec and its settings, the file names, the refusal list, keeping the library format
unchanged, and the order of the steps. My reasons are below. The user can override any of them by reviewing this
document.

## What a meeting folder holds today

These figures come from the code. The capture format is fixed: 48 kHz (`AudioCaptureEngine.swift:48`), and each track
is mono float32 (`:1152-1161`). The arithmetic matches `RecordingSizeEstimator.swift:38-47`.

| File | Per hour | Read after a meeting is finished by |
|---|---|---|
| `system-audio.f32`, `microphone-audio.f32` | 691.2 MB each | Rebuild Audio (offered only when `meeting.wav` is incomplete), recovery of *unindexed* folders, Verify Library's size check, backups |
| `meeting.wav` (16-bit mono, 48 kHz) | 345.6 MB | playback, Transcribe Again, Second Opinion, segment re-run, speaker analysis |
| `source-tracks.json` | a few KB | Rebuild Audio, Verify Library |
| `meeting-recovered.wav`, `meeting-recovered-superseded-<n>.wav` | 345.6 MB each | the first is the recording after a rebuild; superseded copies are kept by `SourceRebuild.swift:100-108` |
| `notes.md`, `session.json`, `diarization.json`, `ask-embeddings.*` | KB | transcript mirror, title and markers, speaker labels, search by meaning |

Imports keep one `recording.<ext>`, copied byte for byte. Link imports keep a 16 kHz mono `recording.wav` (115.2 MB/h),
plus `source.json` and sometimes captions. Nothing in `Sources/` reads an allocated size or shows a meeting's size.
Nothing encodes to AAC. Every temp file the engines make goes to the system temp directory, not the meeting folder.

## Part 1 — Seeing storage

**What is counted.** A meeting's size is the total over every regular file in its folder, recursively. Each file
counts its allocated size on disk (`totalFileAllocatedSizeKey`), falling back to `fileAllocatedSizeKey` and then to
`fileSizeKey`. A fresh `URL` is built for every measurement, because Foundation caches resource values per `URL`
instance (the F698 finding). The library total is the sum over the meetings in the index. Folders that are not in the
index, such as interrupted captures awaiting recovery, are not counted. The label says "Meetings use …", which claims
nothing more.

**Where it is shown.**
- **The meeting's page:** "Storage: 1.73 GB" in the header near **Show Recording in Finder**. Beside it is **Shrink…** when there is
  something to save, or the reason it can't run (part 2).
- **Settings ▸ Meeting library:** a **Storage** row showing the library total and a **Show Storage…** button. That
  button opens a sheet listing every meeting, largest first, with its title, date, size and a Shrink button. Rows can be
  multi-selected and shrunk with **Shrink Selected…**. Nothing runs without a press.

**When it is measured.** Measurement runs off the main actor, in `Task.detached`. Sizes are cached per meeting in
`AppModel`. They are measured when the sheet opens and when a meeting is selected. A meeting's cached size is
invalidated after Stop, import, Shrink, Rebuild Audio and delete. Sizes are formatted with `ByteCountFormatter` in its
`.file` style, the style the app's existing storage labels already use.

## Part 2 — Shrink

### The output

- **Format:** AAC-LC, 16 kHz, mono, a 32 kbps target, in an `.m4a`.
  - I measured it on `Scripts/bench/clips/en1.wav` upsampled to 48 kHz. The result was 32,928 bit/s, which is about
    **14.8 MB per hour**, and its duration matched the input to the microsecond.
  - At 24 kbps it was 25,252 bit/s. That stays in reserve if the accuracy run below allows it.
- **Why 16 kHz.** Every reader the app has works at 16 kHz:
  - Qwen and speaker analysis decode to 16 kHz (`AudioTranscoder.targetSampleRate`).
  - Whisper resamples to 16 kHz itself.
  - Nothing the models use is removed, and playback keeps wideband speech up to 8 kHz.
  - Accuracy is **not assumed**. Part 4 measures it.
- **Two encode steps, because one step loses audio.**
  - **Step 1** decodes to a temporary 16 kHz mono WAV with `AudioTranscoder.transcodeToWAV`, which gains `--mix` under
    F796.
  - **Step 2** encodes that WAV with `afconvert -f m4af -d aac -b 32000`.
  - I measured both alternatives. afconvert's `-c 1` alone keeps only the left channel. `--mix` fixes that for WAV output
    but **not** for AAC output: a right-only stereo file encoded straight to AAC with `-c 1 --mix` decoded to silence.
  - The two-step path kept it (RMS 4240 against 4242 for the mixed WAV). Native captures are mono, so this matters for
    stereo imports.
- **Name:** the stem is kept and only the extension changes.
  - `meeting.wav` becomes `meeting.m4a`.
  - `meeting-recovered.wav` becomes `meeting-recovered.m4a`.
  - `recording.<ext>` becomes `recording.m4a`.
  - The stem is how `InterruptedRecordingRecovery.finalizedRecording` tells a clean capture, a rebuild (F273's
    provenance) and an import apart. Keeping it means a folder can still be read correctly if the index is ever lost.

### The sequence

This is `AppModel.shrinkMeeting(id:)`, one meeting at a time. Nothing original is removed until the replacement has been
verified and the index saved.

1. **Guards** are re-checked on the main actor (see *Refusals*), and `shrinkRunningID` is set.
2. **Free space:** refuse if the volume has less free space than the temporary WAV (32,000 bytes per second of
   audio), plus the predicted `.m4a`, plus 100 MB.
3. **Encode** into hidden temp files in the meeting's own folder, `.shrink-<uuid>.wav` and then `.shrink-<uuid>.m4a`.
   The same volume is what makes the final rename atomic. No recogniser matches a dot-prefixed `.shrink-` name.
4. **Verify:**
   - Decode the **whole** `.m4a` with `AVAudioFile` and count its frames.
   - Its duration must match the original's within 0.5 s. The original's duration comes from the WAV header, or from
     `AVAudioFile` for a non-WAV import.
   - A truncated or corrupt encode fails here. On failure the temp files are removed and nothing else changes.
5. **Is it worth it?**
   - Let *R* be the total size of the files step 7 would remove, and *E* the size of the encoded `.m4a`.
   - If *E* > 0.75 × *R* (the shrink would save less than a quarter of *R*), discard the temp files and report "already
     compact". This covers imports that are already compressed.
6. **Commit:**
   - Rename the temp `.m4a` to its final name.
   - Update the record's `recordingPath` and save the index through the store's normal compare-and-swap save.
   - **If the save fails,** remove the new `.m4a`, keep every original, and report the error.
   - **Special case:** if the final name *equals* the original's, as when an import is already `recording.m4a`, the
     commit point is an atomic `replaceItemAt` and the index is unchanged.
7. **Delete** the originals, using an explicit list of names. Anything not on the list stays.
   - **Deleted:**
     - `meeting.wav`, `meeting-recovered.wav` and `meeting-recovered-superseded-*.wav`;
     - `system-audio.f32` and `microphone-audio.f32`;
     - `source-tracks.json` and `source-tracks.recovered.json`;
     - the import's original `recording.<ext>`, when it is not the output;
     - stale `.shrink-*` and `.meeting.wav.mixing` files.
   - **Kept:** `notes.md`, `session.json`, `diarization*.json`, `ask-embeddings.*`, `source.json`, `captions.*.vtt`, and
     anything else.
   - The manifest goes with the tracks. Left behind, it would make Verify Library report "the system source track is
     shorter than recorded (0 of N frames)" on every launch (`MeetingIntegrityChecker.swift:147-151, 237-243`).
   - **Deletion order:**
     1. the manifests;
     2. the raw tracks;
     3. superseded rebuilds and stale temp files;
     4. last, the old recording itself.

     So whenever the app stops, the folder never looks damaged:
     - The tracks never outlive their manifest, so Verify Library never reports a frame mismatch. With the manifest
       gone, a remaining track is only `.sourceTrackManifestMissing`, which is not counted as a problem.
     - A WAV whose header is complete never sits beside tracks with no WAV left. That is the state in which
       `SourceRebuild.offer` would offer Rebuild Audio (`SourceRebuild.swift:75-77`).
8. **Report.** Measure the folder again and say "Shrunk 'Weekly sync' from 1.73 GB to 14.6 MB." If any delete failed,
   say that the meeting is shrunk, that N files could not be removed, and that Shrink will finish the job.
9. **Player:** if this meeting's recording is loaded, reload it from the new URL.

**Resuming.** If the app stops during step 7, the index already points at the `.m4a`. Shrink stays available because
removable files remain. On a meeting whose recording is already the shrunk `.m4a`, Shrink only removes the leftovers,
in the same order. It does not encode again. The "damaged" and "nothing to gain" refusals do not apply in this mode:
they are about the recording that would be encoded, and here there is none. A meeting whose recording is `meeting.m4a`
or `meeting-recovered.m4a` and that has nothing left to remove shows "Already shrunk".

**Batch.** Shrink Selected runs the same sequence one meeting after another. Ineligible meetings are skipped with
their reasons, and one summary at the end lists what was shrunk, skipped and failed.

### Refusals

The button is disabled with the reason underneath, the same pattern as `speakerAnalysisUnavailability`. Each guard is
re-made when the action runs. The reasons, in the order a person can act on them:

- **The recording is damaged.** Verify Library has a finding for it, or `SourceRebuild.offer` would offer a rebuild.
  The message is "Rebuild Audio first". Shrinking would lock the damage in and delete the tracks that can repair it.
- **The recording file is missing.**
- **Nothing to gain.** This is step 5's rule, *E* > 0.75 × *R*. Before encoding, *E* is predicted as the record's
  duration × 4,100 B/s. The measured *E* at step 5 is the authority. This is how an already shrunk `recording.m4a`
  import is refused without encoding it again: its stem cannot show that it was shrunk, but its size can.
- **The library is read-only** (`libraryAcceptsChanges`, F187).
- **A recording or an import is in progress.** This follows `backUpLibrary`'s own guard.
- **This meeting is busy:**
  - transcribing or queued;
  - running speaker analysis (`diarizationRunningID`);
  - running a segment re-run (`segmentReTranscriptionRunningID`);
  - running Rebuild Audio (`sourceRebuildRunningID`);
  - or another shrink is running.
- **A backup is running.** Nothing records that today: `backUpLibrary` awaits its detached run without a published
  flag. So this adds `backupRunning`, and `backUpLibrary` refuses while a shrink runs, which keeps the two symmetric.

### The confirmation

> **Shrink "Weekly sync"?**
> This replaces the recording with compressed audio: about 1.73 GB → about 15 MB. The original recording and its raw
> tracks are **deleted permanently**. Playback, transcription and summaries keep working. Rebuild Audio and
> re-running a single segment will no longer be available for this meeting.

Extra sentences are added when they apply:

- "This meeting hasn't been transcribed yet; transcription will use the compressed audio."
- For a video import: "The video picture is removed; only the audio is kept."

The **Shrink** button uses the destructive style. For a batch, the dialog reads "Shrink 5 meetings? About 8.6 GB →
about 75 MB." with the same body.

## Part 3 — Changes outside the feature

- **`AudioTranscoder` downmix (F796)** is a prerequisite and a fix in its own right. Qwen transcription of stereo imports
  drops the right channel today.
- **Speaker analysis.** `nativeRecordingFileNames` gains `meeting.m4a` and `meeting-recovered.m4a`. Its audio already
  goes through `AudioTranscoder` (`AppModel.swift:1953-1956`), which decodes `.m4a`. Imports stay excluded, because their
  name stays `recording.*`.
- **Folder rebuild after a lost index.** `finalizedRecording` learns `meeting.m4a` (as `.existingCapture`) and
  `meeting-recovered.m4a` (as `.rebuiltSourceTracks`), each checked after both WAV names and accepted when non-empty.
  WhisperCore cannot decode AAC, so the duration is handled the way a non-WAV import's is today. The plan confirms what
  that path does.
- **`MeetingStore.recordingURL(for:)`.** When the indexed file is missing and the same stem with `.m4a` exists in that
  folder, it returns the `.m4a`. Two things reach this path:
  - an older index generation restored by Recover Library, which still points at `meeting.wav`;
  - a second app copy holding a stale record.
- **Pinned by tests, not changed:**
  - A shrunk folder has neither tracks nor manifest, so Verify Library reports nothing. The `.m4a` is checked the way
    any non-WAV recording is: it exists and is non-empty (`MeetingIntegrityChecker.swift:204-209`).
  - `SourceRebuild.offer` offers nothing, because no tracks exist.
- **No library-format change.** `meetings.json` gains no field: the `.m4a` name carries the fact that a meeting is
  compressed. An older build reads a shrunk meeting's record unchanged. It plays and transcribes it, refuses speaker
  analysis, and does not find it in a folder rebuild after a lost index.
- **Docs, in the same change:**
  - `PRODUCT_SPEC.md`: "Preserve separate source tracks…" gains "…until the user shrinks the meeting". The recovery
    boundary names **Shrink Meeting** as a third explicit, intentionally destructive action.
  - `RECOVERY.md`: what a shrunk folder holds, and what it can no longer do.
  - `README.md`: a line for the feature.
  - `CHANGELOG.md`: written when it ships.

## Part 4 — Proof

**WhisperCore, a pure planner** (proposed name `MeetingStoragePlan`). From a folder listing of names and sizes, plus
the facts the app knows, it computes:
- the files to remove and the files to keep;
- the output name;
- the predicted output size;
- the refusal reason, if any.

Unit tests cover each rule, including "an unknown file is kept".

**AppModel layer, F47-style seams.** These are `encodeForShrink` and `decodedDuration`, injectable `@Sendable` closures
that are real by default. The tests run over a temp `MeetingStore` fixture library. Each fails before the
implementation exists and passes after:

1. When the first original is removed, the store's persisted `recordingPath` already names the `.m4a`.
2. A failed index save leaves every original in place and no `.m4a`.
3. A duration mismatch, or an encoder that throws, leaves everything in place and no temp files.
4. Each refusal touches nothing.
5. A file not on the delete list survives.
6. "Already compact" changes nothing.
7. A resume with leftovers removes them without encoding again.
8. The `recordingURL` fallback works.
9. A shrunk folder gets no Verify Library finding and no Rebuild Audio offer. The same holds after every prefix of
   step 7's deletion order, which simulates the app stopping at each point.

**Real encoder, a normal test.** `/usr/bin/afconvert` ships with macOS, the CI runner included, so this needs no gate.
It encodes a bench clip and asserts:
- the result is mono, 16 kHz and AAC;
- its decoded duration matches;
- its size is within the expected band;
- a right-only stereo input is not silent (F796).

**Real-model accuracy, logged as evidence.**
- Transcribe all ten `Scripts/bench/clips` (English, Mandarin, code-switched) with the real installed Whisper `large`,
  original and shrunk. Score them with the bench's references and report each clip's error rate both ways.
- **Acceptance:** no clip's error rate rises by more than one percentage point.
  - If one does, retry at 48 kbps and measure again.
  - If 24 kbps also passes, I'll report that and leave the choice to the user.
- Also one Qwen run, and one speaker analysis on a shrunk synthetic clip. Those check correctness only: synthetic voices
  cannot calibrate diarization.

**Reachability.** A comment-stripped source guard asserts that `ContentView` references the shrink action and its
unavailability gate, as F306 requires. The manual click-through goes in the log: the page label, the sheet, a single
Shrink, Shrink Selected, and a refusal.

## Limits and risks

- **Segment re-run is unavailable on a shrunk meeting until F660 lands.** F660 waits on F581, which is in progress in
  another session and is not touched here.
- **Lossy.** A transcript made after shrinking may differ slightly from one made before. Part 4 measures how much.
  Not planned: making a shrunk meeting bit-exact again. The original is gone by the user's choice.
- **Two app copies.** An *older* build running at the same time and queued to transcribe this meeting's `meeting.wav`
  will fail with a missing file. Newer builds resolve it through the `recordingURL` fallback. Not planned: this sits
  inside `PRODUCT_SPEC.md`'s deliberate two-copies limit.
- **Speaker labels.** `diarization.json` keeps the SHA-256 of the pre-shrink recording. Nothing checks that hash today
  (`currentRecordingSHA256` is never passed). Not planned unless that check is enabled. Whoever enables it must treat a
  shrink as keeping the timeline intact, because the labels stay valid.
- **Backups.** A whole-library backup made before shrinking still holds the originals. Restoring it brings them back,
  with an index that points at them.
- **Disk accounting.** APFS local snapshots, such as Time Machine's, can hold deleted bytes for a while, so Finder's
  free space may lag behind the meeting's new size. Not planned: this is OS behaviour.
- **Video imports lose their picture.** The confirmation says so.

## Rejected alternatives

- **Lossless only** (ALAC, tracks deleted): bit-exact, but saves less. The user chose smallest.
- **Move originals to the Trash:** recoverable, but the space only returns when the Trash is emptied. The user chose
  immediate deletion.
- **Automatic shrinking of older meetings:** the user chose manual only.
- **A persisted `compactedAt` field:** the file name already carries the fact. A field would add a schema change and
  fixtures in both directions, and an older build's next write would drop it anyway.
- **Opus:** better at low bitrates. I have not verified that AVPlayer, afconvert and Whisper's ffmpeg all read it in a
  container the app can write. AAC is read by all three today.
- **In-process `AVAudioConverter` encoding:** viable. afconvert is already the app's decoder, so one tool is used for
  both. This remains the fallback if the subprocess becomes a problem.
- **Keeping `source-tracks.json` after deleting the tracks:** Verify Library would report a damaged track on every
  launch (see step 7).
