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
  Trash, which I had recommended. **Changed by the user on 2026-10-17 (F1040): originals now go to the Trash**,
  each named "<meeting title> — <date> — original <file name>", so a check that missed a sound can be undone; a
  Trash that refuses a file leaves it in the meeting's folder, and Shrink says it could not finish.

I chose everything else: the codec and its settings, the file names, the refusal list, keeping the library format
unchanged, and the order of the steps. My reasons are below. The user can override any of them by reviewing this
document.

## What a meeting folder holds today

These figures come from the code. The capture format is fixed: 48 kHz (`AudioCaptureEngine.targetSampleRate`), and each track
is mono float32 (`FloatTrackWriter`'s output format). The arithmetic matches `RecordingSizeEstimator`.

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
  - **Step 0, for a recording with several audio tracks or more than two channels (F942, 2026-10-12) — held back.**
    As shipped, such a recording is refused (*Refusals*): `MeetingStoragePlan.shrinkMixesRecordings`, the switch, is
    off. F980 rewrote step 4's check of a mix and no probe of either review deletes an original through it, but a good
    copy of tracks that share their sound is still refused in some runs, so the switch stays off until that is fixed
    (see the F942 amendment). With the switch on, the recording is first mixed into a 16 kHz mono WAV, `.shrink-<uuid>.mix.wav`, by `RecordingMixer`, by a capture's rule: each track's
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
   - And, for a two-channel recording, that its channels do not cancel each other when they are mixed into one
     (F1001, 2026-10-15). The encode's mono mix sums the channels, so a mid/side recording (left A + B, right A − B),
     or left B with right A − B, lost B in the copy while both level checks above passed on A: the review of Wave 7
     lane S deleted both originals. **The user's decision, 2026-10-15: "Refuse any with cancellation"** — a stereo
     recording whose channels noticeably cancel when mixed to mono is kept full size, with a reason; no stereo
     copies. (Their first answer, "keep refusing as now", was given on a bound F1001's first round stated wrongly —
     that only a side voice about 6 dB quieter slipped through; both reviews then measured equal-level speech
     talking over each other, side voices 1–3 dB down, a side voice alone for about a second, a cancellation
     confined to part of the spectrum and a quiet cancelling stretch after a loud one all being deleted, and the
     user answered again on those numbers.)
     `RecordingMixer.channelPresence` reads the channels at 16 kHz, in 64 ms frames, half-overlapping, in stretches
     of sixteen (0.512 s). Per 15.6 Hz bin from 80 Hz to 7.8 kHz it sums the channels' cross-spectrum over the
     stretch; a bin cancels where the channels are in opposite polarity *consistently* (coherence at least 0.7,
     over at least three frames' worth of energy) — a voice inverted on one channel is opposite in every frame,
     two independent voices only for a moment. Two microphones apart hear a voice a little late on one side, a
     comb filter rather than a lost voice, so each stretch's delays up to 3 ms are found from its
     cross-correlation and each bin read at its best one. `RecordingMixPlan.firstChannelNotInCopy` refuses when,
     in any stretch above silence — judged against its own energy, so a loud stretch elsewhere hides nothing
     (review 2, F2-3) — any of the bands 80–250–500–1k–2k–4k–7.8k Hz holding a twentieth of the stretch has more
     than a tenth of its energy cancelling. Beside it — an additional refusal, not a replacement (round 4) — it
     keeps F1001's first-round link: in every five-second window in which a channel sounds (a tenth of its own
     level), more than a quarter of the channel's energy from 80 Hz to 4 kHz, in 256 ms frames, lying in bins
     the channels' mix does not hold refuses. The stretch rule's delay allowance cannot tell a steady tone
     inverted on one channel from the same tone half a period late — they are the same signal, and the mix
     cancels both — so alone it deleted a loud inverted tone or odd-harmonic buzz, a side voice under a talker
     on microphones 2.5–3 ms apart and a 0.1 s mid/side file, which the first round kept (review 1 of round 2:
     16 of its 213 probes); with both links, none of the 213 the first round kept is deleted
     (`gates/r4-06-attack-lines.txt`). It also checks the copy against the channels' mix (a bin held where the
     copy's projection reaches a quarter of the mix's energy; more than a twentieth of a window's mix missing
     refuses), and refuses whatever it cannot measure. Ordinary stereo shrank in every run made — a voice per
     channel, one silent channel, identical, panned or correlated channels, DC or hiss on a silent channel,
     independent noise, a voice beside itself 4 Hz higher, clipping, a phone's spacing with one or two talkers,
     8 to 96 kHz, float, files from 0.3 s, review 1's controls, review 1 of round 2's, ten ffmpeg-made files and,
     with the bench clips, speech — but for one of review 1's 22, a float WAV with one NaN sample, kept as
     unmeasurable as the level checks would. Adding the first round's link back cost one refusal in round 2's
     59 ordinary fixtures (`gates/r4-07-production.txt`): a single talker on echo-free microphones a metre
     apart (3 ms), which the first round already refused (0.34); with a room's echo it shrinks. Refused by the
     stretch rule although nothing a listener would call a second voice is lost: two talkers before microphones
     0.75 to 1.5 ms apart (five of six such fixtures, echoing or not), and a Haas widening of 10–20 ms; both
     lose sound to the mix's comb filter, and the user's rule keeps them. **Not caught** — deleted with the
     cancelled sound gone from the copy (review 1 of round 2's probes, re-run on round 4's code,
     `gates/r4-06-attack-lines.txt`, and round 4's own, `r4-08-mutant-base.txt`): a side voice talking over the
     middle one throughout from about 11 dB down as tones (10 dB down reads 0.11, caught), and as speech from
     between 8 and 12 dB down, depending on the voices; a side voice alone for 0.16 s or less (tones, and a 0.12 s
     spoken interjection); a cancelling sound confined to 4–7.8 kHz, from 6 dB under the rest as tones and 10 dB as speech; a steady tone
     inverted alone for 2 s between speech; an inverted tone burst of a second beside two talkers on spaced
     microphones; a side voice 6 dB down beside a talker on microphones 1 ms apart, or beside two spaced
     talkers; and a copy that leaves out a channel holding under a twentieth of the mix. Whole mid/side files
     of 0.05 s and shorter were kept as "Already compact" (nothing to gain), and from 0.08 s they are judged and
     kept.
   - **F1009 (2026-10-16), beside the stretch rule.** Most of those misses came from the delay allowance: a
     delay excused every bin less than a quarter-turn from it, and an inverted narrowband sound makes its own
     correlation peak at half its period. Two rules now sit beside it, each counting what the mix loses in a bin
     that is opposite (`-Re(L·conj R)`) and excusing it only by a *broadband* delay — a peak of the cross-spectrum
     weighted by phase alone (GCC-PHAT, each bin by the square root of its coherence, over bins with a tenth of the
     mean bin energy) that two bands reach by themselves: the **phase rule** over each stretch (a bin 0.99 coherent,
     excused within 30° of such a delay's phase; per bin the larger of it and the stretch rule) and the **brief
     rule** over windows of three frames every two (a bin 0.98 coherent, within 20° of opposite, excused within 75°
     of a delay of the stretches it overlaps or of its own). Every constant is pinned. Measured offline over 50
     positives and 311 controls (`gates/F1009-x16*.txt`, Wave 8 lane A) and through Shrink's own measure: now kept,
     a tone burst inverted beside two spaced talkers (953 Hz), a steady tone inverted alone between speech, a side
     voice 6 dB (and 10 dB) down beside a talker on microphones 1 ms apart or beside two spaced talkers, and solos
     of 0.08–0.16 s as tones, inside a stretch or across its edge, and spoken from 0.12 s. **Still not caught**:
     a narrowband sound whose frequency lies within 75° of a spaced talker's comb phase (the 500 Hz bursts beside
     talkers 0.6 and 1.3 ms apart; 400, 520, 1,200, 2,500 Hz too), a spoken solo of 0.08 s, and the quiet side voice
     and 4–7.8 kHz rows above. Refused now that was not: a pure tone delayed 1 ms on one channel under speech that
     is not (the mix loses the tone at a comb notch, about 8 dB, and nothing broadband shows the delay) — the user's
     rule keeps it. No ordinary control was newly refused; the margins closest to the bound are a phone's spacing
     with two talkers 0.25 ms apart (0.082) and one talker with an echo 1.5 ms apart (0.073).
   - And a two-channel file whose channel layout the encode's mix is not shown to keep both channels of is not
     shrunk (F1001, rounds 2 and 3). afconvert mixes by position — a WAV's mask, or a CAF's, an AIFF's or any
     container's layout, read with AVAudioFile as one channel label per channel — and leaves out of the copy a
     channel laid out as LFE, mid or side, an Ambisonic X/Y/Z, top back, unused or discrete (review 1 of round 2;
     review 2's R2-A, a CAF and an AIFF laid out centre + LFE, deleted with a voice 16 dB down missing). Measured
     over 1,156 ordered pairs of labels (`gates/r3-04-pairs.txt`), `MeetingStoragePlan.monoMix(ofChannelLabels:)`
     lets through no layout (a plain WAV, mask 0), and pairs of left/right, surround, rear, the centre pair,
     wide, vertical height, X/Y, binaural and headphones positions, centre or mono beside those, and matrix
     Lt/Rt — each of which keeps both channels, at two-thirds of an even mix's level at least (round 2 refused
     mask 0, back, side and centre-pair masks too, though nothing is lost: R2-C). It refuses a position it
     leaves out ("labels one of its two channels as a kind of channel … which the compression leaves out"), and,
     fail-closed, anything else ("in a way Shrink hasn't shown the compression keeps both of") — 147 measured
     pairs that do keep both, left beside left total say, among them. That a pair is let through does not mean
     every macOS can measure it: on macos-15 (CI run 38859340988) a WAV masked as the side pair, the centre pair
     or front left beside centre was kept, fail-closed, as "could not be read to check the compressed copy" —
     most likely the measure's AVAssetReader, the one reader on that path asked to convert a layout (two channels
     at 16 kHz with no layout given). macOS 27 reads all three; versions between are untried. Since F1013 the
     measure asks for a discrete layout at two channels too, as it did above two, so nothing is mapped; whether
     macos-15 then reads those three is what CI's "F1001 host:" lines show.
   - A two-channel `recording.<ext>` beside the recording — a link import's download beside the mono WAV ffmpeg
     extracted from it — is removed with it, so the copy is checked against it the same way first, and if that
     is not shown, nothing is removed (review 2, F2-1). A download AVFoundation cannot read (a WebM/Opus one) is
     decoded first with the installed ffmpeg into a 16 kHz WAV that keeps its channels (`.shrink-<token>.decoded.wav`,
     removed afterwards), and checked the same way: one channel has nothing to check, two are measured, and one that
     cannot be decoded — no ffmpeg, a decode that fails, more than one audio stream — holds more than two channels, or
     decodes shorter than its measured length is not shown, so nothing is removed (F1004). "Cannot read" includes a
     file AVFoundation opens but lists no audio track in (an MP3 in MP4) or a track of no channels (F1004 round 2).
     The same holds for a resume's leftover, which first checks the free space the decode needs (64 kB a second).
   - An MP4 holding Opus is read with AVAssetReader: AVAudioFile opens it, counts 0 frames, and raises when asked
     its position, which crashed Shrink (F1037). Such a file declares no length, so F911 measures it another way
     (recovery's record, or ffprobe) or keeps it, instead of taking its 0 s as holding nothing.
   - For a mixed recording (F942) the level checks above are replaced, because levels cannot show a track lost while
     another sounds over it, nor a track whose channels cancel when combined: the review deleted an original both ways
     (review of F942, R2 and M8). Instead the mixer keeps its own read beside the mix — every channel of every track,
     as it summed them, 16 kHz Float32 (F998) — `RecordingMixer.audit(lanes:trackChannels:frames:against:)` measures the copy
     against that read, in step with the copy, and `RecordingMixPlan.firstFinding` judges each **one-second** window
     by one rule (F980, 2026-10-14): *the original is deleted only when the audit finds every track's and every channel's
     sound in the copy; what it cannot find is a refusal.* This holds against a lost or fully cancelled track; it does not
     yet hold against a voice cancelled by an opposite-polarity copy of it on another track or channel (review of lane S,
     X1–X4) or a loss shorter than about half a second inside one window (W) — F998, which keeps mixing Shrink off. In each window: nothing measured is NaN or
     infinite, in the recording's own decode, the audit's read or the copy (D2); every channel the recording's own
     decode hears was read for the mix; every track that sounds keeps a quarter of its sound when its channels are
     combined, and the tracks a quarter when summed (a track or tracks in opposite polarity are refused); the copy
     keeps the mix's level within the band and follows its waveform at 0.6 of the mix's gain; a least-squares fit of
     the copy onto the tracks gives every track that sounds, and whose sound is at least a quarter its own, 0.6 of
     the gain where it is within 24 dB of the copy — and where such a track is quieter than that, the window is
     refused as too quiet to show (F978), not passed; the same channel by channel. "Sounds" is a tenth of the same
     track's or channel's level over the whole recording (D1: the review's quiet cancelling track was judged nowhere
     under a tenth of the recording's). Sound two tracks share (identical tracks; OBS's master beside its stems) is
     proven as the sum it is heard in, by the whole mix's fit. Every window is judged, the last partial one and a
     recording shorter than a window included.
     Before anything is summed, the read is aligned to the copy. The copy is an encode of the read's own sum, so its
     tracks cannot be out of step with one another: the mix — each channel at its track's weight — is aligned to the
     copy within ±16 frames of where it stood a window before, widening while it is not found, to 0.3 s in all (past
     that, refused as out of step), and that one alignment serves every track (F998). A sum that lost a track, or
     placed one 24 frames or a quarter second late, is refused against it, and a kept read short of the mix is
     refused rather than measured as far as it goes. What it cannot show is a fault in the mixer's own read that
     a second read would not repeat — a buffer dropped, a track taken to end early: the copy holds what that read
     held, so only the recording's own decode, compared channel by channel in five-second stretches, stands
     outside it (`channelNotRead`, which passes a channel down to a quarter of its level). F1071 weighs that
     before mixing Shrink is switched on.
     Until F998 the audit read the recording a second time. AVAssetReader does not read an ffmpeg-made file the same
     way twice — its reads drift along a file, each track on its own, about 0.4 frames a second without bound — so
     each track was aligned on its own and re-aligned against the copy less the other tracks' fitted contributions;
     and AVAssetWriter-made fixtures whose tracks share their sound were refused in some runs — the OBS layout and a
     dual-mono track beside a mono one about one run in three, identical tracks about one in eight — because that
     read lined such tracks up a frame or two apart from the mixer's. Against the kept read, 50 runs of those three
     layouts refused none (F998's log). A Shrink with no kept read — a resume's leftover, or a stand-in mixer in a
     test — still reads the recording again and aligns each track on its own.
     Measured with the second read, through the real mix and a 32 kbps encode at one-second windows (F980's log): a
     present track 24 dB under another fits at 0.95 to 1.03 and a dropped one within 0.30 of 0; at 30 dB a dropped
     one once fitted at 0.46, which is why 24 dB is the line. Ten Shrinks in a row of each ffmpeg two-track file, and
     of an ffmpeg-made OBS three-track layout, all succeeded, and a three-minute drifting file shrank. More than 16
     channels are not fitted one by one, and are refused up front.
     For a mix, the expected length is the mix's own, every track's end included; the mixer refuses a decode that
     stops more than 0.5 s short of where the audio tracks end — not the movie's length, which counts its picture
     (review of F942, R1).
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
     commit point is an atomic `replaceItemAt` and the index is unchanged. *(Since F1040 the replaced file is kept as
     `.shrink-<token>.replaced.<ext>` and moved to the Trash in step 7; if Shrink stops first, it is a stale
     `.shrink-*` file the next Shrink moves there.)*
7. **Delete** the originals, using an explicit list of names. Anything not on the list stays. *(Since F1040, the user's
   decision of 2026-10-17: "delete" here means **move to the Trash**, each file renamed "<meeting title> — <date> —
   original <file name>" first. A Trash that refuses a file — a volume with none, a network share — leaves it in the
   folder under its own name, and the summary says Shrink could not finish. Nothing is deleted in its place.)*
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

A leftover with several audio tracks or more than two channels (F955): a copy made before F942 holds only the first
track or channel, and the leftover then holds the last copy of the rest, which a resume used to delete; so as shipped
such a leftover is kept, and with the switch on it is removed only after the copy is checked against it with step 4's
check of a mix (F980). A leftover whose tracks are
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
  back: "This recording has 2 audio tracks; shrinking it isn't available yet, so its audio is kept as it is." (or
  "…6 channels; …"). With the switch on, such a recording is mixed into the copy (step 0), whatever its layout
  (F953), and the copy is checked against every track and channel before the original goes (step 4); a copy that check cannot prove is
  refused after the encode, with the reason ("…is too quiet beside the others at about 0:05 to show that the
  compressed copy holds it there…"). Refused before anything is encoded: audio tracks in different languages that are alternatives of each other
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
> tracks are **moved to the Trash**, where you can get them back until you empty the Trash; the space comes back when
> you do. Playback, transcription and summaries keep working. Rebuild Audio and re-running a single segment will no
> longer be available for this meeting.
>
> *(Until F1040, 2026-10-17, this said the originals were deleted permanently.)*

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

**Shrink's half is held back (F980).** The second review of F942 found Shrink's check of a mixed copy still
deleting originals whose sound was not in the copy (step 4), so the integrator decided on 2026-10-12, following the
user's "keep refusing for now": Shrink refuses every recording that needs mixing until its check is proven. F980
rewrote the check to the rule in step 4, and every probe of both reviews now keeps its original; its last runs on
2026-10-15 still refused good copies of tracks that share their sound in some runs, which was the integrator's
condition for leaving the switch off. The mixing Shrink described below is in place behind
`MeetingStoragePlan.shrinkMixesRecordings`, which is off, and its tests run with it on.

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
  a track that starts late stores nothing for the silence before it (review of F942). And the audio tracks' end is
  bounded too, since an edit list sets it: a mix runs at most the audio the tracks hold and as much silence again,
  or a minute (`RecordingMixPlan.longestMix`); past that it is refused, before anything is read, because an edit
  list placing a track an hour in made a 108 KB file into a 115 MB mix (second review, N16). What is mixed is
  handed on at most four seconds at a time. Then a
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
- **How it is checked.** Step 4's check of a mix, above (F980). What a 32 kbps copy cannot be shown to hold is
  refused, not passed: a track or channel more than 24 dB under the copy where it sounds (AAC spends the fewest bits
  there, and the fit cannot tell a present one from a dropped one at 30 dB), so a recording with a voice that quiet
  beside another, or a 5.1 movie whose surround channels carry only quiet ambience, keeps its original with the
  reason on screen. Shared sound (identical tracks, OBS's master beside its stems) is proven as the sum; a channel
  that shares more than three quarters of its sound with the others is proven only as part of that sum.
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

**Amended 2026-10-15 (F962).** A WebM in a folder recovered by a build before the record existed (between F453's
conversion and F947) is measured after all, once: when Shrink measures such a folder and finds a download that
`AVAudioFile` cannot open and no record, it asks the installed `ffprobe` for the container's duration
(`InterruptedLinkImportExtraction.measureDownload`) and writes the same record, so the next look reads the record
and no subprocess runs again. A download ffprobe cannot measure — none installed, not media, a container with no
duration, or one whose length ffprobe could only estimate from the bitrate (it warns that it did, and any line beside
the number measures nothing) — is refused as before, nothing is written, and it is not asked about again that
session. The refusal rules are unchanged: a length ffprobe reads that is longer than the recording keeps the download.
