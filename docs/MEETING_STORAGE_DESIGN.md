# Meeting storage: see it, shrink it (F795)

**Status:** approved by the user on 2026-10-02. The implementation plan is [`MEETING_STORAGE_PLAN.md`](MEETING_STORAGE_PLAN.md). Ticket `F795`; it depends on `F796`.

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
  - **Step 0, for a recording with several audio tracks or more than two channels (F942, 2026-10-12) — held back
    until F980.** As shipped, such a recording is refused (*Refusals*): `MeetingStoragePlan.shrinkMixesRecordings`,
    the switch, is off, because the second review of F942 deleted originals through step 4's check of a mix. With
    the switch on, the recording is first mixed into a 16 kHz mono WAV, `.shrink-<uuid>.mix.wav`, by `RecordingMixer`, by a capture's rule: each track's
    channels averaged into its own signal, as a capture averages a microphone's channels (F659), each track placed at
    its own time, and the tracks summed as a capture sums its two (`FloatTrackMixer.limitedSample`: 0.95 of the sum
    while it fits, a smooth limiter above, never full scale). Steps 1 and 2 then run on the mix. Before F942 such a
    recording was refused (below).
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
   - Its level must match the original's (F801): the RMS of its decoded audio must be between a quarter of and four
     times the RMS of the original, decoded the same way and taken over all its channels' samples, before any mixing.
     A copy that came out silent has the right length and fails here, and so does one that the mono mix silenced (a
     stereo recording whose channels cancel). A silent original is not compared.
   - And per five-second window: in every window where the original is audible (at least a tenth of its whole-file
     level), the copy must keep at least a quarter of that window's level. A copy of the right length that lost a long
     stretch of the recording fails here. Measured with the real encoder (second review, 2026-10-11): a lost stretch of
     steady sound is caught from 4.7 s when it falls inside one window, missed up to 9.3 s at the worst alignment, and
     always caught from 9.4 s; of speech, a lost 1–2 s is never caught, 7 s in 10 of 15 placements, 10 s in 13 of 13.
     Shorter losses are not caught: the check is a backstop against an encoder losing a stretch. The refusal names the
     first stretch it found ("missing sound the recording has at about 0:10") and nothing after it.
   - For a mixed recording (F942) the level checks above are replaced, because levels cannot show a track lost while
     another sounds over it, nor a track whose channels cancel when combined: the review deleted an original both ways
     (review of F942, R2 and M8). Instead `RecordingMixer.audit` reads every channel of every track again, the way the
     mixer reads them, in step with the copy, and `RecordingMixPlan.firstFinding` judges each five-second window:
     every channel the recording's own decode hears was read for the mix; every track that sounds keeps at least a
     quarter of its sound when its channels are combined (a track in opposite polarity is refused); the copy keeps at
     least a quarter of the mix's level; a least-squares fit of the copy's waveform onto the tracks gives every track
     that is a measurable part of the copy at least 0.6 of what the mix gives it; a fit onto every channel gives each
     channel that sounds apart from the others at least a quarter; and every track that sounds was measured somewhere.
     Anything else keeps the original. Measured through the real mix and encode (round 2 probes): tracks and channels
     in the copy fit at 0.82 to 0.95 of what the mix gives them, also 23 dB under another track, and a lost track or
     channel within 0.015 of 0. More than 16 channels are not fitted one by one, and are refused up front.
     For a mix, the expected length is the mix's own, every track's end included; the mixer refuses a decode that
     stops more than 0.5 s short of where the audio tracks end — not the movie's length, which counts its picture
     (review of F942, R1). **Held back with step 0 (F980).** The second review of F942 found two ways past this
     check with the real mixer: a quiet track whose stereo channels cancel, under a tenth of the whole recording's
     level, gets none of these checks even where it sounds alone (D1); and one NaN channel of a float WAV silenced
     the mix while the check read the NaN as silence (D2) — round 1's level band had refused a non-finite level,
     and replacing it reopened that. It also refused good copies of ffmpeg-made files about half the time, because
     AVAssetReader does not read such a file the same way twice, and copies of near-identical tracks.
   - A truncated or corrupt encode fails here. On failure the temp files are removed and nothing else changes.
5. **Is it worth it?**
   - Let *R* be the total size of the files step 7 would remove, and *E* the size of the encoded `.m4a`.
   - If *E* > 0.75 × *R* (the shrink would save less than a quarter of *R*), discard the temp files and report "already
     compact". This covers imports that are already compressed.
6. **Commit:**
   - Rename the temp `.m4a` to its final name.
   - Update the record's `recordingPath` and save the index through the store's normal compare-and-swap save.
   - **If the save fails,** keep every original and report the error. *(Amended after the final review: the new
     `.m4a` is now left in place, not removed. See [Amendments](#amendments-after-the-final-review-2026-10-02).)*
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
   - **Only what the checks ran on** (F949, 2026-10-12). The list is taken from the folder just before the removal,
     but a name on it is removed only if the listing the checks ran on (step 1's facts) held it with the same size on
     disk and logical length. A file that appeared or changed during the encode was never measured — F911's check that
     another `recording.<ext>` holds no more audio than the recording never saw it — so it stays, counted among the
     files not removed, and the next Shrink measures it. A dataless file (no bytes on disk, its content in iCloud or a
     File Provider) is not taken for empty: emptiness is read from its logical length too.
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

A leftover with several audio tracks or more than two channels is kept as shipped (F955, F980): a copy made before
F942 holds only the first track or channel, and the leftover then holds the last copy of the rest, which a resume
used to delete; showing that a copy holds it is step 4's check of a mix, held back until F980. With the switch on,
such a leftover is removed only after the copy is checked against it with that check. A leftover whose tracks are
alternatives, or cannot be read, is kept either way, and so, outside a resume, is any other `recording.<ext>` with
more tracks than a plain encode keeps, since nothing compares it with the copy there.

**Batch.** Shrink Selected runs the same sequence one meeting after another. Ineligible meetings are skipped with
their reasons, and one summary at the end lists what was shrunk, skipped and failed.

### Refusals

The button is disabled with the reason underneath, the same pattern as `speakerAnalysisUnavailability`. Each guard is
re-made when the action runs. The reasons, in the order a person can act on them:

- **The recording is damaged.** Verify Library has a finding for it, or `SourceRebuild.offer` would offer a rebuild.
  The message is "Rebuild Audio first". Shrinking would lock the damage in and delete the tracks that can repair it.
- **The recording file is missing.**
- **The recording has more than one audio track, or more than two channels** (F801, F942, F980). An import keeps
  the container it came in, and a movie or MPEG-4 file can carry a track per side of a call; a "poly" WAV can carry a
  microphone per channel. As shipped every such recording is refused, because the mixing Shrink of step 0 is held
  back until F980: "This recording has 2 audio tracks; shrinking it isn't available yet, so its audio is kept as it
  is." (or "…6 channels; …"). With the switch on, such a recording is mixed into the copy (step 0), whatever its
  layout (F953). Refused either way: audio tracks in different languages that are alternatives of each other
  ("…in different languages, alternatives to each other…"), and a recording whose tracks could not be read, where the plain encode
  would keep track 1, or channel 1 of a WAV with no layout ("…can't be read to mix them into one…", saying how many
  tracks or channels). See the 2026-10-09 amendment and the F942 amendment below.
- **Another `recording.<ext>` in the folder may hold more audio than the recording** (F911). It names the file and
  says whether it runs longer or could not be measured. This one applies in resume mode too. See the 2026-10-10
  amendment below.
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

## Amendments after the final review (2026-10-02)

An independent review of the finished branch found the defects below. I changed the design as follows. The user
approved the original text and has not yet reviewed these changes.

- **A failed save leaves the verified `.m4a` in place.** Removing it was the one path that could leave a meeting with no
  audio. With two copies of the app, copy A can overwrite copy B's committed `meeting.m4a` and then lose its own save.
  If A then removed the file, B's index would name nothing. An unreferenced verified copy is harmless, and the next
  shrink replaces it.
- **A flush before anything is committed or removed.** The temp `.m4a` gets `F_FULLFSYNC` after its full decode, and its
  folder is flushed after the rename. Only then is the index saved and anything deleted. A full decode reads the page
  cache, which proves the bytes are right but not that they would survive a power loss. A failed flush changes nothing.
- **"Rebuild offered" means a rebuild would recover more audio.** It now means the tracks hold more than a second beyond
  the recording, which is F256's truncation. A recovered folder never has a complete `meeting.wav`, so an offer always
  exists there, and reading every offer as damage had made recovered meetings unshrinkable.
- **An interrupted import shrink is finished, not encoded again.** `recording.m4a` beside a leftover `recording.<ext>`
  can only come from Shrink's own commit, so it is resume mode, like `meeting*.m4a`.
- **Restore and Shrink exclude each other,** and a restore has its own refusal ("Wait for the library restore to
  finish."). After the encode's `await`, the record and the library state are checked again before anything is
  committed.
- **Only top-level files are ever deleted.** A nested `sub/recording.txt` is never on the list.
- **The library total counts only meetings still in the index.**

## Amendment for F801 (2026-10-09)

The final review found that step 4 checked only the length, so two losses could pass it. I changed the design as
follows; the user has not reviewed this yet.

- **The compressed copy's level is compared with the original's.** An encode that comes out silent has the right
  length. Both are decoded in full with `AVAudioFile`, and the copy's RMS must be between a quarter of and four times
  the original's. The original's RMS is taken over all its channels' samples, before any mixing: measured after the
  mono mix, as first written, a stereo recording whose channels cancel in that mix read as silence on both sides and
  was shrunk to silence (found in review, 2026-10-10). Measured through Shrink's own encode on synthetic audio and the
  bench clips: speech 0.997 of the original, a mono tone 1.000, stereo with identical channels 1.000, one side per
  channel or right-only 0.707, white noise 0.535 (the 16 kHz working WAV drops everything above 8 kHz), right-only
  white noise 0.379, and a silent encode or a fully cancelling stereo pair 0. An original below about -80 dBFS is
  silence and is not compared.
- **And per five-second window.** The whole-file band let a copy of the right length that held only part of the
  recording through: one holding the first fifth reads sqrt(0.2) ≈ 0.45. In every window where the original is
  audible (at least a tenth of its whole-file level), the copy must keep at least a quarter of that window's level.
  Lower bound only, since the windows look for missing sound. Measured per window: lowest legitimate ratio 0.377
  (right-only white noise), speech at least 0.996, also at a fifth of the level after a loud start. What it catches,
  measured in the second review: steady sound from 4.7 s inside one window and always from 9.4 s (missed up to 9.3 s
  across two windows); speech 7 s in 10 of 15 placements, 10 s in 13 of 13, and 1–2 s never. Finer windows would
  catch shorter losses but need the false-refusal measurements repeated, and no encoder has been seen to drop a
  stretch while keeping the length, so they are not planned.
- **A recording with more than one audio track is not shrunk.** afconvert, which the encode runs, decodes only the
  first audio track of a container, as do `AVAudioFile` and (measured on a two-track `.mov`) Whisper's ffmpeg decode.
  Shrinking such an import would keep track 1 and delete the others with the original. I chose to refuse, with a
  reason that says how many tracks would be lost, over warning in the confirmation (a permanent loss one click away)
  and over mixing the tracks into one (new work). Mixing is the option that loses no voice, though the tracks could
  not be separated again afterwards: per-speaker tracks would be gone for good, which matters for speaker analysis or
  editing. It is a decision for the user, not taken here, and the same question covers the channel rule below.
- **Nor is a recording with more than two channels** (found in the second review, 2026-10-11). The encode's
  `afconvert -c 1 --mix` mixes stereo (F796) and a layout that gives each channel a position (3.0, quad, 5.1 and 7.1
  were measured; LFE is dropped). Of a WAV with more than two channels and no layout — plain PCM, or extensible with
  channel mask 0, measured at 3, 4, 6 and 8 channels — it keeps channel 1 alone. With the channels at equal levels,
  channel 1's level is the level over all of them, in the whole file and in every window, so both level checks passed
  a four-channel import and channels 2–4 were deleted with the original. Field and podcast recorders write such "poly"
  WAVs, and conference systems record a floor microphone and its interpreters this way. The channel count is read from
  the header (`AVAudioFile`), and more than two is refused whatever the layout, so a positioned 5.1 import, which the
  mix would have kept, is refused too (F953). `AVAudioFile` reported the right count for every shape measured. Outside
  resume mode, like the track rule: a resume encodes nothing and keeps the recording, which is already the copy. The
  fail-closed fix was the integrating session's decision (whisper-27), not the user's; reading the layout to keep
  positioned recordings shrinkable is F953.

## Amendment for F942 and F953 (2026-10-12): several tracks, or more than two channels, are mixed

The user answered the question above on 2026-10-12: keep refusing for now, and mix all tracks into one for both
transcription and Shrink. Wave 6 built the mixing, for both.

**Shrink's half is held back (F980, the same day).** The second review of F942 found Shrink's check of a mixed copy
still deleting originals whose sound was not in the copy (step 4), so the integrator decided, following the user's
"keep refusing for now": Shrink refuses every recording that needs mixing until F980 proves the check, and a resume
keeps such a leftover. Transcription mixes as described here, since it deletes nothing. The mixing Shrink described
below is in place behind `MeetingStoragePlan.shrinkMixesRecordings`, which is off, and its tests run with it on.

- **What is mixed.** A recording with several audio tracks, or one track of more than two channels
  (`RecordingMixPlan`). One track of one or two channels is not: the encode's `--mix` mixes stereo (F796), as the
  engines' own decodes do. Alternate tracks in different languages — one alternate group, of which a player plays one
  — are not summed, since that would garble both; Shrink refuses them, and transcription keeps decoding the default
  one. A group alone is not enough: ffmpeg's MP4 and QuickTime muxer puts every audio track it writes in one group
  tagged `und`, so a call saved a side per track by ffmpeg, or a tool built on it, is mixed (review of F942, R3).
- **How.** `RecordingMixer` reads each track with AVFoundation at 16 kHz with its own channel count, and for more than
  two channels a discrete layout, so nothing is downmixed on the way: asked for one channel, AVFoundation keeps only
  channel 1 of a WAV with no layout. Each track's audio is placed on the timeline by its presentation time, within the
  audio's own length: a time past the audio tracks' end and a second is refused as corrupt rather than padded to, and
  a track that starts late stores nothing for the silence before it (review of F942). Then a
  capture's rule: each track's channels are averaged into its own signal, as a capture averages a microphone's
  channels (F659), and the tracks are summed as a capture sums its two (0.95 of the sum, a limiter above full scale).
  So a voice alone on its track keeps nearly its level and no sum clips — dividing by the number of tracks would make
  every voice of a call recorded a side per track quieter by 6 dB — and a stereo track is as loud beside another
  track as alone. (Round 1 summed every channel, and the review found a voice on both sides of a stereo track twice
  as loud as on every other path, into the limiter's knee.) Within a track every channel counts the same, LFE
  included: a positioned 5.1 recording keeps all six (F953), where afconvert's positioned downmix dropped LFE; a track
  of N channels with one speaking is heard at 1/N of that voice, as a capture would hear it.
- **What it costs.** The tracks cannot be separated again once the original is deleted: per-speaker tracks are gone
  for good. The confirmation says so ("…mixed into one; they can't be separated again afterwards").
- **How it is checked.** Step 4's checks of a mix, above (round 2: fits of the copy's waveform onto every track and
  channel, and a refusal of a track whose channels cancel). What they cannot show is a quiet track masked under a
  loud one in a stretch where it is more than 24 dB down: AAC itself spends the fewest bits there, so such a stretch
  is judged only by the copy's level against the mix's; a track that is never measurable anywhere is refused. Nor,
  the second review found, a quiet track under a tenth of the recording's level (D1), nor a NaN channel (D2), nor a
  stretch shorter than half a second; and it refuses good copies of ffmpeg-made files and of near-identical tracks.
  F980 collects these; until it is done, Shrink does not mix.
- **Resume mode** encodes nothing. As shipped it keeps a leftover with several tracks or more than two channels; with
  the switch on it checks the copy against it before removing it (F955, under *Resuming* above).

## Amendment for F911 (2026-10-10)

A link import recovered after its audio extraction was interrupted keeps its complete download beside the
`recording.wav` the import was making, and that WAV can hold only part of the audio: FFmpeg stopped by SIGTERM, which
a shutdown, restart or logout sends, finishes its header over what it had written. Shrink treated every other
`recording.<ext>` as a leftover of the import. So once its encode succeeded, shrinking such a meeting would delete the
download — or, when the download was itself `recording.m4a`, replace it with the encode — and the only complete copy
would be gone. Today that is latent rather than live for a link import's own WAV: Shrink's first encode step
(`afconvert -c 1 --mix`) refuses a 16 kHz mono PCM input outright, which is what such a WAV is, so the encode fails
before anything is removed. The rule below does not rely on that. (Since F941, 2026-10-12, the encode no longer
refuses that input — `--mix` is left out for a recording whose header says it is mono — so this rule is now what
keeps the download.)

- **Each other `recording.<ext>` is measured** when the folder is: a WAV from its header (or, for one FFmpeg never
  finished, from the audio it holds), anything else with `AVAudioFile`.
- **Shrink refuses unless every one runs no more than half a second past the recording**
  (`InterruptedLinkImportExtraction.lengthTolerance`; the download and the WAV made from it were measured at most
  32 ms apart). A file that could not be measured is not shown to be covered, so it is refused too. An empty file
  holds nothing and is not.
- **Resume mode too.** A leftover that runs longer than the recording is not one Shrink made.

I chose refusing over removing only what is shown to be covered, because the file at risk is the only complete copy.
The cost: a meeting whose other file is a WebM download, which macOS cannot measure, is never shrunk, since showing
that its WAV holds all of it would need FFmpeg.

**Amended 2026-10-12 (F947).** A WebM that recovery converted itself is measured after all. When startup recovery
finishes the conversion of all of a link import's download (F453, F911), it writes `download-conversion.json` beside
it — the download's name and size, and the length of the WAV made from it — and Shrink takes that length as the
download's when `AVAudioFile` cannot open it. A record that names another file, or this one at another size, measures
nothing, so such a download is refused as before; so is a WebM beside a recording that recovery did not convert, such
as one in a folder an earlier build recovered.
