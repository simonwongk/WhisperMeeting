# Recovery correctness: F255 and F256

**Date:** 2026-09-16
**Status:** Approved design, pre-implementation
**Tickets:** F255 (high, recovery), F256 (medium, recovery) — filed by whisper-37, claimed by whisper-62
**Sub-project:** A of three. The seven-ticket recording/recovery set decomposes into A (F255, F256),
B (F257 → F253 → F254) and C (F258, F259); the user approved that grouping and ordering on
2026-09-16. A is independent of B and C and ships first.

## What this is

Two defects in `InterruptedRecordingRecovery` where recovery destroys or misrepresents a user's
recording. They share a file and a test surface but are otherwise unrelated, and either could ship
without the other.

Both are about the same principle: **recovery must never be less honest than doing nothing.** A
rebuild that strands the real recording, or reports silence as recovered, is worse than leaving the
raw tracks alone — the user would at least have known something was wrong.

## Not in scope

No sleep/wake handling (F253), no display-binding change (F254), no lifecycle move (F257), no
durability of markers or `fsync` (F258, F259). No change to how a recording is *captured*; this is
only about what happens to a folder afterwards.

---

## F255: a second instance rebuilds a live folder

### The defect

`meeting.wav` is written only by `AudioCaptureEngine.stop()`, and `startRecording` deliberately
creates the recording folder without indexing it (`AppModel.swift:1748`; the first `upsert` is at
`:1797`). While a capture runs, its folder therefore holds only two growing `.f32` tracks and no
finalized recording — **structurally indistinguishable from an interrupted one.**

`orphanedRecordings()` (`MeetingStore.swift:510-546`) has no liveness test: it excludes only folders
referenced by an indexed `recordingPath` and folders whose UUID is already a meeting id. So a second
instance launching mid-meeting reaches `InterruptedRecordingRecovery.recover(in:)`, which writes
`meeting-recovered.wav` into the live folder and upserts a "Recovered Meeting" under the same UUID.
When the first instance finishes and writes the complete `meeting.wav`, nothing points at it: the
full recording survives on disk, permanently stranded behind a truncated rebuild.

### The guard already exists and is dead

`LibraryWriterLock.shared(for:)` is called at `MeetingStore.swift:368` and stored in
`@Published private(set) var writerLease` (`:316`). `grep -rn "writerLease" Sources/` returns only
those two lines — nothing reads it. F190 built the mechanism; nothing consumes it.

### Design

Gate the rebuild on the lease. Refuse exactly one state:

| `StoreWriterLease` | Rebuild? | Reasoning |
|---|---|---|
| `.held(realm:)` | yes | We own the library |
| `.heldElsewhere(realm:)` | **no** | A live instance owns it; its folder is not ours to touch |
| `.unavailable(reason:)` | yes | No `flock` was possible — see fail-open below |
| `.unmanaged` | yes | No lease attempted (tests, fixtures) |

What the lease actually discriminates — stated precisely, because an earlier draft of this section
overclaimed it. It distinguishes **another instance is open** from **no other instance is open**. It
does *not* distinguish "recording" from "died recording". That is enough to close this defect, because
the defect requires a live second instance, and a live second instance never holds the lease. A
crashed first instance had its lease released by the kernel, so the relaunch that follows a crash does
hold it and does rebuild.

It is *not* enough to make every rebuild reachable. See the accepted trade-off below for the case it
gets wrong.

**`.unavailable` fails open, deliberately.** Refusing would permanently disable recovery for anyone
on a volume without `flock`, which is a worse defect than the one being fixed. It also preserves
F190's Invariant L in spirit: the lease stays advisory, and this gate only *defers* recovery, never
bricks a library.

**Placement.** The gate lives in `AppModel.performStartupRecovery`'s orphan loop, not in
`orphanedRecordings()`. That function is a read-and-report and must not start lying based on a lease;
the destructive action is in the loop, so the guard belongs there. (It has one production caller,
`AppModel.swift:1432` — the other two are tests. The argument stands on what the function *means*,
not on a caller count.)

**There is a second `recover` call site, and it must stay UNGATED.**
`InterruptedRecordingRecovery.recover` is reached from two places: the injected seam at
`AppModel.swift:483` used by the orphan loop, and **`AppModel.swift:1820`**, inside `stopRecording`'s
error path. The second is this instance recovering *its own* folder after its own finalization
failed. Because nothing gates `startRecording` on the lease, the instance running that path may be
holding `.heldElsewhere` — so gating "every call to `recover`" would stop a non-lease-holding
instance from recovering the recording it just made. Gate the loop, not the function.

**Invariant this design makes safety-critical.** `LibraryWriterLock.shared(for:)` memoizes, and two
`flock` acquisitions on one file contend *within a single process* — `MeetingStore.swift` documents
this, and it is why the app never reports `.heldElsewhere` against itself today. After this change
that rule stops being cosmetic: any future second acquirer reaching for the public
`LibraryWriterLock.acquire` — the natural thing when wiring `DictationLogStore`, or a session marker
for F258 — would not merely mislabel a UI string, it would **disable recovery of the user's own
crashed recordings.** Never call `acquire` outside `shared(for:)`.

**Evaluate the predicate once, before the loop.** It is loop-invariant, and messages are joined with
a blank line (`AppModel.swift:1514`), so testing it per folder would emit N identical paragraphs.

**Shape.** A pure predicate over the four states, so every branch is unit-testable without a second
process:

```swift
static func mayRebuildInterruptedRecordings(_ lease: StoreWriterLease) -> Bool
```

**User-visible outcome.** A skipped folder appends one actionable line to the existing startup
message: another copy of WhisperMeet is open, so interrupted recordings were left untouched; quit it
and relaunch to finish recovering. The raw tracks are preserved, so nothing is lost by waiting.

### Accepted trade-off

The lease is library-wide, not per-folder, so while another instance is open a genuinely orphaned
folder is not rebuilt either. Recovery is **delayed, never lost** — the raw tracks are untouched.

An earlier draft justified this by saying the other instance "already recovered it at its own
launch". **That is false**, and the counterexample matters:

1. Instance A opens and sits idle, holding `.held`.
2. Instance B launches → `.heldElsewhere`. Nothing stops B recording: `refreshRecordingPreflight`
   checks `isDegraded`, not the lease, and `writerLease` is still read by nobody.
3. B crashes mid-recording. Its folder is a genuine orphan.
4. B relaunches while A is still open → `.heldElsewhere` → **B refuses to rebuild its own crashed
   recording.** A launched before the crash and has never seen that folder.

With F257 establishing that this app can run as a long-lived menu-bar session, "another copy is open"
is not a short window. The mitigations are the actionable message and the fact that the tracks
survive, so this stays an accepted trade-off rather than a blocker — but it is a real reachable gap
and must not be written up as covered. If it proves to bite, the cheapest precision is the one the
ticket originally proposed (skip only folders whose `.f32` mtime is fresh); gating `startRecording`
on the lease would prevent the state arising at all.

---

## F256: a swallowed read error becomes silence

### The defect

`RawFloatReader.read` (`InterruptedRecordingRecovery.swift:306-320`) pre-fills with zeros and reads
with `try?`:

```swift
guard let handle,
      let data = try? handle.read(upToCount: frameCount * MemoryLayout<Float>.size),
      !data.isEmpty else {
    return result   // all zeros
}
```

A genuine read failure mid-file is therefore **indistinguishable from end-of-file** — and EOF
zero-padding is intended behaviour for the shorter of the two tracks. Only one of the two is data
loss. `totalFrames` comes from the file *size* (`:93-95`, via `frameCount(at:)`), so the mix loop runs to the declared length
and writes silence for every remaining chunk, then returns normally with the ordinary "recovered
from source audio" notice.

The result is a WAV claiming the full duration whose tail is digital silence, presented as a
successful recovery. Because the notice is the normal one, the user has no reason to look at the
still-intact `.f32` tracks beside it, and a transcript of silence reads as a transcription failure
rather than a rebuild failure.

### Design

Truncate at the error and report the true length. Rejected alternatives: failing the whole recovery
(gives the user nothing even when 55 of 60 minutes were readable) and keeping full length with a
flagged silent span (preserves timeline alignment at the cost of a file containing audio that never
existed).

Four changes:

1. **`read` becomes throwing.** This is the whole fix for the conflation: an I/O error propagates, a
   short read still returns zero-padded samples. The EOF behaviour must not change — it is correct
   for the shorter track and the existing mix relies on it.
2. **The mix loop breaks on a throw**, keeping the readable prefix. No new length bookkeeping is
   needed: `dataByteCount` and the returned `duration` already derive from `writtenFrames`, so the
   truncation falls out of code that is already there. To be explicit: the output is a single mixed
   stream, so it truncates at the first chunk where **either** reader throws, even if the other track
   would have read further. Keeping one channel past the point where the other became unreadable
   would mean shipping a mix that silently changes from two channels to one partway through.
3. **The truncation is carried up** on `RecoveredRecording` (a transient result type — no schema
   implication) and written into the recovery manifest beside the existing `alignment` value.
   `RecoveredRecording` has no explicit init, so the new field needs a `= nil` default or all four
   construction sites break, including `StartupRecoveryResilienceTests.swift:50`. The manifest's
   truncation key goes on `private struct RecoveredSourceManifest`, whose
   `writeRecoveryManifestIfNeeded` has a second caller at `:82` (the already-finalized path) with no
   truncation concept — safe because the manifest is write-only in `WhisperCore` and read by a
   tolerant subset struct in `AppModel`.
4. **The meeting remembers it.** A new optional `recoveryWarning: String?` on `MeetingRecord`,
   naming the truncation and the true duration. It stays `nil` for every recovery that read cleanly
   and for every meeting that was never recovered — its presence means "this audio is short by an
   unknown amount", and nothing else may start using it for unrelated notices. **Rendered at
   `ContentView.swift:2887-2899`**, the existing site for `alignmentWarning` and `languageWarning`,
   which is the same shape. Without a named surface this would close `partial`, not `fixed`.

### The truncation floor — "truncate" and "fail" are one policy, not two

A first draft of this design specified only the upper end and would have shipped a **worse** data-loss
path than the bug it fixes. Traced through the real code, a throw on the *first* chunk gives
`writtenFrames == 0` → `dataByteCount == 0` (`:131`) → a 44-byte WAV → `wavDuration` refuses it
(`:206-215` requires `dataByteCount > 0`), so `finalizedRecording` will not recognise the file the
rebuild just wrote. But `recover` still returns a `RecoveredRecording(duration: 0,
source: .rebuiltSourceTracks)`, and `AppModel`'s `duration <= 0` rescue at `:1477` is gated on
`source == .importedRecording`, so it does not fire. The loop upserts a meeting with duration 0
pointing at an empty WAV, carrying the **ordinary** "recovered from source audio" message. The
folder's UUID then sits in `indexedIDs`, so `orphanedRecordings()` (`MeetingStore.swift:527`)
excludes it **permanently**, and there is no in-app rebuild-from-source command. The intact `.f32`
tracks are stranded with no route back.

That is this spec's own principle failing on its own terms. So the policy has two ends:

- **`writtenFrames == 0` → throw.** The existing per-orphan catch (`AppModel.swift:1436-1444`) then
  leaves the folder untouched and reports it, which is exactly right: nothing readable was recovered,
  so the honest outcome is the one where the raw tracks stay claimable.
- **A short but non-empty prefix → recover it, but never with the ordinary message.** Below one tenth
  of `totalFrames` the meeting is upserted with `status: .failed` and an `errorMessage` naming the raw
  track files, so the user is told to look rather than left with a 10-second meeting over an hour of
  audio. At or above that, a normal recovery carrying `recoveryWarning`.

The one-tenth boundary is a judgement, not a measurement; it exists so that "technically recovered"
cannot masquerade as "recovered". **The absence of any in-app re-recovery surface is the deeper
problem and is out of scope here — filed as F267.**

**Why persisted rather than transient.** The startup alert is dismissible and never shown again. A
meeting whose audio is short by an unknown amount should still say so when the user opens it a month
later. `Optional` added field is the append-only pattern already used for `transcriptNormalized`,
`markers`, `pinned`, `notes`, `tags` and `healthReport`, and is safe in both directions under F188's
rules: an older build ignores the key, and this build decodes its absence as `nil`.

---

## Testing

**The hard part is F256.** A genuine I/O error cannot be produced with a real file, and revoking
permissions mid-read is flaky. So the mix loop is extracted into a seam — but it needs **three**
closures, not two. An earlier draft said two, which a literal reading would satisfy by returning all
the PCM: 345 MB for a 60-minute meeting, where the current code streams. The loop writes each chunk
as it goes, so the sink has to be injected too:

```swift
static func mixTracks(
    totalFrames: Int64,
    chunkSize: Int64,
    readSystem: (Int) throws -> [Float],
    readMicrophone: (Int) throws -> [Float],
    write: ([Int16]) throws -> Void
) -> (writtenFrames: Int64, truncation: (frame: Int64, error: any Error)?)
```

The header rewrite (`output.seek(toOffset: 0)`) stays in `recover`, which owns the file handle. The
truncation is **returned rather than rethrown** so `recover` can still finalize the readable prefix —
and the underlying error travels with it, because `recoveryWarning` quotes its
`localizedDescription`.

A test then supplies a `readSystem` that throws at chunk 3 and asserts the output is exactly two
chunks long with the true duration. Same seam-extraction the F188/F193/F243 review pushed for on
`decoding_indices`, and the same convention as `PlanBatchesTests` in
`Scripts/tests/test_qwen_transcribe.py:85` (a Python test class — noting the language because a
Swift-scoped grep will not find it).

**Testing `.heldElsewhere` needs a specific recipe,** because there is no obvious seam:
`MeetingStore.writerLease` is `private(set)` with no setter, and a second `MeetingStore` on the same
root gets the *memoized* handle and so reports `.held`. The working order is: acquire
`LibraryWriterLock.acquire(root:)` **first**, keep it alive with `withExtendedLifetime` (the handle
releases in `deinit`), *then* construct the `MeetingStore`. Written down here so nobody "solves" it
by widening `writerLease` to a settable var.

| Test | Proves |
|---|---|
| Lease predicate over all four states | `.heldElsewhere` refuses; the other three proceed, including the fail-open |
| Orphan loop consults the predicate | The gate is wired, not merely written |
| Skipped folder is untouched | Raw tracks survive, and a `meeting.wav` appearing later is still indexable |
| Mix truncates at a throwing chunk | Readable prefix kept, true duration reported, no silent padding |
| Short read still zero-pads | The EOF path is unchanged — the regression this fix could most easily cause |
| Truncation reaches the meeting | `recoveryWarning` is set and survives a store reopen |
| **A throw on the FIRST chunk throws out of `recover`** | No empty meeting is indexed, the folder stays an orphan, the raw tracks stay claimable |
| **A very short prefix is marked `.failed`** | "Technically recovered" cannot masquerade as recovered |
| Schema fixture, both directions | The new optional field decodes old→new and new→old (precedent: `MediaSourceSchemaTests.swift`) |

## Risks

- **The EOF path is the regression risk.** Making `read` throwing puts the legitimate short-track
  zero-pad and the error path in the same function. If the distinction is got wrong, every two-track
  rebuild with unequal lengths breaks. Pinned by its own test.
- **`.unavailable` fails open,** so the F255 defect remains reachable on a volume without `flock`.
  Accepted, documented at the gate, and strictly better than disabling recovery there.
- **The lease is library-wide,** so recovery of an unrelated orphan is deferred while a second
  instance runs. Delayed, not lost.
- **A new persisted field** is a schema change, however safe the pattern. Covered by a
  both-directions fixture, per F188. Precisely: it **decodes** in both directions. An older build
  that reads a record carrying `recoveryWarning` drops the key on its next save — true of every
  existing optional field here, so not a new defect, but "safe in both directions" overstates it.
- **F255's entire user-visible remedy is an `alertMessage` line, and F257 — scheduled after it —
  records that alerts and startup recovery are window-scoped**, so a menu-bar session gets none of
  them. That is exactly the long-lived "another copy is open" scenario F255 is about, so the message
  is least reliable in the case that needs it most. Not a blocker for A; it does mean F255's remedy
  gets more reliable when B lands.

## Follow-ups this deliberately does not do

- A per-folder liveness sentinel (precision over the library-wide lease) — only if the delay matters,
  or gating `startRecording` on the lease so the harmful state cannot arise.
- **F267: no in-app surface re-runs recovery on a folder already indexed.** Once a UUID is in the
  index, `orphanedRecordings()` excludes it forever, so any partial recovery is final from the app's
  point of view. This design works around it (throw on empty, flag short) rather than fixing it.
- Anything in sub-projects B or C.
- `orphanedRecordings()` keeps its current semantics; the suspect-empty and read-only guards are
  untouched.
