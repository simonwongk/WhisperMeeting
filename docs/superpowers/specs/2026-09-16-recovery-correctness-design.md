# Recovery correctness: F255 and F256

**Date:** 2026-09-16
**Status:** Approved design, pre-implementation
**Tickets:** F255 (high, recovery), F256 (medium, recovery) — filed by whisper-63, claimed by whisper-62
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

Why the lease is sufficient on its own, with no heartbeat: a live second instance never holds it, and
a **crashed** first instance had its lease released by the kernel — which is exactly the case where
rebuilding is correct. The mechanism discriminates "someone is recording" from "someone died
recording" for free.

**`.unavailable` fails open, deliberately.** Refusing would permanently disable recovery for anyone
on a volume without `flock`, which is a worse defect than the one being fixed. It also preserves
F190's Invariant L in spirit: the lease stays advisory, and this gate only *defers* recovery, never
bricks a library.

**Placement.** The gate lives in `AppModel.performStartupRecovery`'s orphan loop, not in
`orphanedRecordings()`. That function is a read-and-report with three callers and a documented
meaning; making it return `[]` based on a lease would make it lie. The destructive action is in the
loop, so the guard belongs there.

**Shape.** A pure predicate over the four states, so every branch is unit-testable without a second
process:

```swift
static func mayRebuildInterruptedRecordings(_ lease: StoreWriterLease) -> Bool
```

**User-visible outcome.** A skipped folder appends one actionable line to the existing startup
message: another copy of WhisperMeet is open, so interrupted recordings were left untouched; quit it
and relaunch to finish recovering. The raw tracks are preserved, so nothing is lost by waiting.

### Accepted trade-off

The lease is library-wide, not per-folder. While another instance is running, a genuinely orphaned
folder from an older crash is not rebuilt either — recovery is **delayed, never lost**, and that
instance already recovered it at its own launch. A per-folder sentinel held by the capture engine
would be precise but adds a second locking scheme; it is a follow-up only if the delay proves to
matter.

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
4. **The meeting remembers it.** A new optional `recoveryWarning: String?` on `MeetingRecord`,
   naming the truncation and the true duration. It stays `nil` for every recovery that read cleanly
   and for every meeting that was never recovered — its presence means "this audio is short by an
   unknown amount", and nothing else may start using it for unrelated notices.

**Why persisted rather than transient.** The startup alert is dismissible and never shown again. A
meeting whose audio is short by an unknown amount should still say so when the user opens it a month
later. `Optional` added field is the append-only pattern already used for `transcriptNormalized`,
`markers`, `pinned`, `notes`, `tags` and `healthReport`, and is safe in both directions under F188's
rules: an older build ignores the key, and this build decodes its absence as `nil`.

---

## Testing

**The hard part is F256.** A genuine I/O error cannot be produced with a real file, and revoking
permissions mid-read is flaky. So the mix loop is extracted into a function taking the two track
reads as closures:

```swift
(Int) throws -> [Float]
```

returning frames written plus an optional truncation frame. A test then supplies a closure that
throws at chunk 3 and asserts the output is exactly two chunks long with the true duration. This is
the same seam-extraction the F188/F193/F243 review pushed for on `decoding_indices`, and matches the
existing convention in `Scripts/tests/test_qwen_transcribe.py` and `PlanBatchesTests`.

| Test | Proves |
|---|---|
| Lease predicate over all four states | `.heldElsewhere` refuses; the other three proceed, including the fail-open |
| Orphan loop consults the predicate | The gate is wired, not merely written |
| Skipped folder is untouched | Raw tracks survive, and a `meeting.wav` appearing later is still indexable |
| Mix truncates at a throwing chunk | Readable prefix kept, true duration reported, no silent padding |
| Short read still zero-pads | The EOF path is unchanged — the regression this fix could most easily cause |
| Truncation reaches the meeting | `recoveryWarning` is set and survives a store reopen |
| Schema fixture, both directions | The new optional field decodes old→new and new→old |

## Risks

- **The EOF path is the regression risk.** Making `read` throwing puts the legitimate short-track
  zero-pad and the error path in the same function. If the distinction is got wrong, every two-track
  rebuild with unequal lengths breaks. Pinned by its own test.
- **`.unavailable` fails open,** so the F255 defect remains reachable on a volume without `flock`.
  Accepted, documented at the gate, and strictly better than disabling recovery there.
- **The lease is library-wide,** so recovery of an unrelated orphan is deferred while a second
  instance runs. Delayed, not lost.
- **A new persisted field** is a schema change, however safe the pattern. Covered by a
  both-directions fixture, per F188.

## Follow-ups this deliberately does not do

- A per-folder liveness sentinel (precision over the library-wide lease) — only if the delay matters.
- Anything in sub-projects B or C.
- `orphanedRecordings()` keeps its current semantics; the suspect-empty and read-only guards are
  untouched.
