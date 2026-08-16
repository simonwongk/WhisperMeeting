# Library-index wipe — post-mortem and fix design (2026-08-14)

**Tickets:** F187 (store safety), F188 (schema compatibility + bundle identity), F190 (transactional
writes), F191 (backup/restore), F192 (incident-record privacy)

**Scope note.** This record is deliberately free of meeting metadata, record identifiers and local
filesystem paths. Counts, commit hashes and mechanism are kept here; the specifics live in a private
evidence manifest held outside the repository with SHA-256 hashes and restricted permissions (F192).

On 2026-08-14 at 11:52 the installed app was launched and reported that neither `meetings.json` nor
its backup could be read, claiming both files "were preserved for manual recovery". Ten meetings were
then replaced by blank stubs. The preservation claim was false — nothing in the code preserved
anything.

All recording audio survived (10 folders). No transcript text survived in the library. The same event
had already occurred once before, three days earlier, and was closed on the wrong cause.

## Root cause

A **version downgrade** met three latent defects. None alone loses data.

### Trigger: an asymmetric Codable change

Commit `94de11b` retyped `MeetingSummary.actionItems` from `[String]` to `[ActionItem]`.
`ActionItem.init(from:)` accepts the legacy bare-string form, so a **newer reader accepts older
data**; the synthesized `encode(to:)` only ever emits an object, so an **older reader rejects newer
data** with `typeMismatch`. The change was reviewed as backward-compatible. It is — and it is
forward-fatal. Only one of the two directions was considered.

Two bundles existed with different schemas: the installed app built from `4bd5cb2` (pre-`94de11b`,
`nm` reports **0** `ActionItem` symbols) and a development bundle built from `1434006` (**356**
symbols). Exactly one meeting in the library carried a summary, with six object-shaped action items.
A summary with an *empty* `actionItems` array would not have been fatal.

Confirmed four ways: `git diff 4bd5cb2..1434006` shows this is the *only* non-additive persisted-schema
change in the `MeetingRecord` graph; `strings` on the installed binary finds `actionItems`/`keyPoints`
but none of the new nested keys; the `nm` symbol counts above; and both schemas compiled into
standalone decoders reproduce `typeMismatch … Path: [N].summary.actionItems[0]` against the real
surviving bytes, while removing only that one summary's action items makes the same file decode
cleanly under the real `4bd5cb2` schema.

### Why both rotating copies were fatal — the precise write timeline

This needs care, because a single upgraded save does **not** arm the wipe.

`save()` writes the *previous primary* into the backup, then the new value into the primary. Starting
from an all-old-schema library, one save by a new-schema build therefore leaves the **backup still in
the old schema**. An old reader would fail on the primary, succeed on the backup, report "the index
was damaged, restored the previous readable backup", and re-save in its own schema. The
one-generation-behind backup is, by accident, exactly one save of downgrade protection.

Arming the wipe requires either **two or more successive new-schema saves** (rotating the last
old-schema generation out) or **a single write of both files at once**. The latter is what happened:
the recovery performed after the earlier wipe wrote both copies from a recovered snapshot, removing
the last old-schema generation. From that moment the library was unreadable to the installed build,
and the wipe was waiting for whenever that bundle was next opened — six days later. The development
session in between re-encoded the index but changed nothing that mattered.

### Defect 1 — `save()` destroyed the only surviving bytes

`BackupJSONStore.save()` computed `existingPrimary ?? existingBackup ?? newData`, where
`readableData` returns `nil` unless the bytes *decode*. "Undecodable" was conflated with "worthless",
so the new value was written over the backup **and** the primary. `.atomic` replaces via temp+rename,
unlinking both originals.

### Defect 2 — a failed load presented as an empty library

`MeetingStore.loadMeetings()` swallowed the throw into `startupRecoveryMessages` and left
`meetings = []`. Nothing distinguished "unreadable" from "no meetings".

### Defect 3 — the empty library triggered a destructive rebuild

`AppModel.performStartupRecovery` called `store.orphanedRecordings()`, whose guard derives both its
guard sets from the in-memory index and is therefore a no-op when that index is empty. All ten
recording folders qualified as orphans and each was upserted as a blank stub, every upsert calling
`persistMeetings()` → `save()`.

The end state is a fingerprint of exactly that loop: **10 records in the primary, 9 in the backup** —
write #1 found both copies undecodable and put the 1-stub array in both; writes #2–#10 found a
decodable primary, so the backup received the previous generation. N and N−1, N = folder count.
Reproduced end-to-end in a sandbox against the real store code, producing the alert text verbatim.

One link is permanently unprovable: the exact bytes at 11:52:20.4. Both inodes were replaced by
`.atomic` writes 0.6 s later; there is no snapshot and no Time Machine destination. Everything on both
sides of that 0.6-second hole is pinned by the unified log, which shows the installed bundle as the
only app launch in the window.

### Blast radius

Four `BackupJSONStore` instances share the destroy-both-copies behaviour: meetings, vocabulary,
replacement rules, dictation history. Only meetings fired. Vocabulary survived because its value type
is `[String]` — no schema surface to break, and only until any term becomes a struct. Replacement
rules survived because the file did not exist yet. Dictation history survived because its schema had
not been touched in three weeks. Survival was release timing, not design.

Two further data-loss paths were found, neither dependent on a downgrade:

- **Dictation history fails silently.** `DictationLogStore` loads with `try?`, so an unreadable log
  leaves an empty value with no alert, no startup message and no storage error. The next dictation or
  clear writes through the same `save()` and annihilates the history.
- **Vocabulary truncates.** The stored list is narrowed through a prompt budget (100 terms / 1000
  characters) at load time *and again* on every addition, so the truncation becomes permanent on the
  next write. The live file sits at 986 of 1000 characters.

Also undefended: `RecordingHealthStatus`, `RecordingHealthWarning` and `MeetingTranscriptionEngine`
throw `dataCorrupted` on an unknown raw value in **both** builds. Only `MeetingStatus` has a lenient
decoder. Notably `MediaSource.kind` is deliberately a `String` with a comment explaining this exact
hazard — the lesson was already known in `4bd5cb2`'s successor work while `94de11b` shipped against it.

### The prior occurrence, and why it recurred

The earlier wipe produced an identical stub file three days before. It was attributed to Python `NaN`
in the index. That diagnosis is refuted on mechanism: `JSONEncoder` throws `EncodingError.invalidValue`
on a non-finite `Double` rather than emitting a bare `NaN` token, so a `NaN` makes `save()` fail **with
both files intact** — the opposite of the observed outcome. The pre-wipe copies also contain zero
`NaN`/`Infinity` tokens and *are* fatal to the older reader.

Unified-log retention begins after that event, so the binary that launched it cannot be identified and
that link stays inferred. What is certain: the recovery closed on the wrong cause, wrote both copies
in the new schema (arming the second firing), and was verified by launching the *development* bundle —
the one build that could read it. Verifying a restore with the only reader that works is why the
installed build stayed fatal.

### The documented workflow contributed

`AGENTS.md` § Build commands listed the packaging script and `open .build/WhisperMeet.app`, never
mentioning the installed copy. Following the guide as written produces the two-bundle, two-schema
condition this incident required.

## What is recoverable

Full-fidelity copies survived outside the library in an agent scratch directory subject to periodic
cleanup. They have been copied to a private, hash-verified snapshot outside the repository (9 files,
SHA-256 manifest verified, restricted permissions) per F192.

Of the ten recording folders, **nine** appear in the newest complete snapshot: eight with full
transcript text and segments, one title-only (it never had a transcript), and one carrying the summary
whose action items triggered the failure. Titles, tags, health reports and segment timings come back
with them. The tenth postdates every snapshot; its title is reconstructible from a recording-folder
manifest mtime, a rule that correctly predicts the recorded title of all eight sibling meetings, and it
must be re-transcribed.

All audio is byte-complete and matches the stored durations, and the separated microphone/system tracks
survive, so any re-run can use cleaner isolated input than the original mixed WAV. One title is
independently corroborated by a hash-identical source file outside the library.

Eight link-imported records in the same snapshot are **not** restored: their audio was deleted before
the incident and they are not wanted.

The app's own library-backup feature had **never been used** — no managed backup folder exists and no
destination bookmark is stored. The one designed recovery mechanism was idle.

## Fix design

Revised after review. The first version of this design was rejected on four counts, all upheld:
a persist-only latch is insufficient, compatibility testing was one-directional, the packaging change
was unworkable, and the record leaked metadata.

### F187 — store safety

**Preserve before writing.** Any file that exists but does not decode is quarantined before any write
can replace it. Quarantine **copies, never moves**: a move would leave `load()` seeing no file, which
returns `nil` and re-opens the rebuild path this ticket closes. It is idempotent per (file, byte
content), so a launch loop cannot accumulate duplicates. If quarantine fails, the write fails —
surfacing an error beats destroying bytes. The error message may claim only the preservation that
actually happened, and names the quarantine location.

**A true degraded-library state, not a persistence latch.** Every persisted store carries an explicit
health state — `complete`, backup-recovered, partial-salvage, unreadable, unavailable/divergent — and
anything other than `complete` blocks *all* mutation, not just persistence. This is the review's most
important correction: `MeetingStore.delete` removes the recording directory **before** it saves the
index, so a latch that only refuses to persist would still let a delete destroy audio. Recording,
import, transcription, editing, deletion and automatic orphan recovery are all suppressed **before
their in-memory and filesystem side effects**, until the user explicitly resolves recovery.

**Treat as degraded, not normal:** partial salvage, recovery from a stale backup, divergent copies, and
a syntactically valid but suspiciously empty index found alongside recording folders. Otherwise missing
record IDs read as orphans and startup recreates blank records — the original failure in a new costume.

**Tolerant per-record decoding** keeps the good records when one is undecodable, and carries parked IDs
through salvage so a dropped record cannot reappear as a blank stub.

**Dictation history** stops swallowing load errors and blocks writes over unreadable bytes.
**Vocabulary** separates storage normalization from the prompt cap — at load *and* at every addition.

### F188 — schema compatibility and bundle identity

**Compatibility is bidirectional or it is nothing.** The rejected design checked only that current
readers accept old payloads — the safe direction, which would not have caught `94de11b`.

*Frozen reader graphs* (resolved). One reader graph per **storage wire revision**, copied and
minimized from the exact shipped source and annotated with its commit. Each must preserve the
*historical decoding behaviour* — nesting, optionality, enum handling, date strategy and key names —
not merely the top-level type. A compiled old app is brittle and a recorded decode trace proves only
one execution; frozen readers exercise the real wire contract in ordinary tests.

Three checks:

1. the current reader decodes each synthetic historical fixture;
2. each still-supported frozen reader decodes canonical bytes emitted by the current writer;
3. current writer output matches checked-in canonical golden bytes for representative records.

Two qualifications. Fixtures cover **representative graphs**, not one happy-path record: every
`ActionItem` state, nested health data, enums, dates, optional fields, non-ASCII text and mixed
historical shapes. And check 2 applies only to readers within an explicit **supported writer floor** —
for a deliberately retired reader the test asserts the compatibility fence and isolation, never an
accidental decode failure.

Encoding and decoding move behind one small `LibraryIndexCodec` seam so production and contract tests
share the exact canonical encoder settings. Exact-byte goldens become appropriate once that encoding is
deliberately canonical, and **must not be generated from the implementation under test** — a golden
dumped from the current encoder only asserts that the code equals itself.

Unknown fields and unknown raw enum values must round-trip losslessly or fail closed. A checked-in
inventory of persisted roots and nested types keeps the surface honest. Fixtures are synthetic and
sanitized, pinned to commits.

**No conditional bare-string encoding for `ActionItem`** (resolved — the earlier proposal is dropped).
Encoding a text-only item back to a string is not a cure: it holds only while *every* item is
text-only, and enrichment is the entire point of the feature — `quote` and `timestamp` are derived
automatically, and `done`/`owner`/`due` arrive from ordinary UI edits. One rich item breaks the old
reader again, while mixed string/object arrays obscure the format contract and manufacture false
confidence. The canonical format encodes `ActionItem` as an object, consistently; old string-form data
is preserved through the current reader's migration; and retired binaries are kept from writing the
library by the format/version fence and instance isolation rather than by a shim. Were supporting
`4bd5cb2` *as a writer* ever an explicit product promise, the answer would be a bounded dual-format
migration with a documented sunset — a larger commitment that would still need write fencing to stop an
old save stripping richer data.

**Packaging stays separate from installation.** The rejected proposal — packaging installs by default,
and the development bundle is deleted — was wrong three ways: the installer *calls* the packaging
script and would re-enter itself, it *reads* the development bundle as its install source, and the
quality gate calls the same script and would silently replace the installed app. The guarded installer
already has repeated running-process checks, staging, signature verification and rollback. Packaging
stays pure and side-effect-free; the installer remains the only installer.

Since packaging discipline cannot prevent copied, archived or already-running older binaries, the
protection must live in the library: real build/schema identity plus an exclusive library-instance
guard, so an older or concurrent reader refuses the library instead of rebuilding it.

### F190 / F191 / F192

Split out as separate tickets: transactional, generation-aware, single-writer index writes (the current
two-file rotation has no generation identity, journal, divergence detection or cross-process lock); a
complete backup/restore story (the manifest omits the rolling backup copy, replacement rules, dictation
history and quarantine data, overlapping backups can collide, and whole-file hashing loads entire
recordings into memory); and the privacy/reproducibility work governing this record.

### Documentation

`PRODUCT_SPEC.md` currently requires: "If neither index copy is readable, preserve both files and
reconstruct history from usable recording folders without deleting audio." The implementation did the
reconstruct half and **never** did the preserve half. So the spec was not wrong — it was
half-implemented, and F187 finally delivers the clause that was there all along. The narrower edit is
to keep "preserve both files" (now true) and change reconstruction from automatic to an explicit,
user-reviewed candidate-recovery action behind a persistent recovery surface.

`AGENTS.md` gains the process rules: persisted fields are append-only and optional, never retyped;
compatibility is assessed in **both** directions; any Codable change to a persisted type ships a
fixture in both directions; an unreadable file is quarantined, never overwritten; a failed load never
rebuilds a library. Its build commands are corrected to name the installed bundle as the thing you run.
`RECOVERY.md` gains quarantine behaviour, the degraded state, and the two stores it omits.

## Restore procedure

Order is load-bearing: **contain → fix → install → restore**, and a pre-fix bundle is never launched
against the restored library. Restoring before the installed bundle is replaced invites a third wipe —
which is precisely what the earlier recovery did.

Per F191 the restore is a reviewable runbook rather than a scratch script: refuse to run while the app
is running, snapshot and hash current state first, write both copies from the verified snapshot,
exclude the link-imported records, retitle the newest recording from its folder manifest and clear its
false interruption message, then verify by launching the newly installed bundle. The restored JSON must
emit `"segments": []` rather than `null` and carry every non-optional key, or both schemas hard-fail.

Final library: **10 meetings, 8 with transcripts.**

**Live hazard until F188 ships:** preferences still select an action-item-focused summary style, so
generating any summary re-arms the same field.

## Decisions taken

- **Frozen historical readers**: test-only vendored reader graphs per storage wire revision, with the
  three checks and the supported-writer-floor qualification above. Not compiled binaries, not traces.
- **`ActionItem` symmetry**: dropped. Canonical object encoding, migration on read, fencing instead of
  a shim.
- **Library/schema fence**: required. This reverses an earlier preference for single-binary discipline
  over a version stamp; that discipline proved unworkable, so the ground for declining it is gone.

## Open decisions

1. **After a partial salvage, may the app write at all?** Proposal: write-blocked until the user
   explicitly accepts the loss. UX call, not technical.
2. **Should the index stop being the single point of truth?** Nothing on disk can reconstruct a title,
   transcript, note, tag or summary. A per-recording sidecar written alongside every index save would
   make this class of incident survivable by construction.

## Lessons

1. **Compatibility has two directions.** "Old data still decodes" is half a review.
2. **Undecodable is not worthless.** A store may never overwrite bytes it failed to parse.
3. **Absence of data and inability to read data are different states.** Collapsing them turned a read
   error into a rebuild.
4. **Blocking persistence is not blocking mutation.** Deletion removed audio before it touched the
   index; a persistence latch would not have saved it.
5. **An error message is a promise.** "Both files were preserved" was shipped, tested, and false.
6. **A test name is not an assertion.** The test that should have caught this never exercised the
   destroying path.
7. **A shim that holds only in the trivial case is a false cure.** Encoding text-only action items as
   strings would have "fixed" compatibility exactly until the first enriched item — and enrichment is
   the feature. Worse than no fix, because it reads like one.
8. **Never verify a restore with the only reader that works.** That is what hid the fault for six days.
9. **A wrong diagnosis costs the next incident.**
10. **The docs are part of the system.** A guide that says to run the development bundle, while an
   installed copy exists, is a defect.
