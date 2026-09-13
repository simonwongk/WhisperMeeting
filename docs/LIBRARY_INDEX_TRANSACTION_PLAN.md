# F190 Library-Index Transaction Implementation Plan

> **For agentic workers:** Execute task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.
> Every task ends green and committed before the next begins.

**Goal:** Make library-index writes transactional, generation-aware and single-writer, so a crash, a
full disk, or a second app instance can never silently discard a writer's changes — and so a bad
generation stays restorable.

**Architecture:** `meetings.json` and `meetings.backup.json` keep their names, meaning and bytes.
Two sidecars per store are added: an advisory ~600-byte ledger whose atomic rename is the commit
point, and a `<stem>.history/` directory of physically independent generation copies. Concurrency
safety is a compare-and-swap on content; the writer lease is taken once at launch and never on the
save path.

**Tech Stack:** Swift 6, Foundation only in `WhisperCore` (no AppKit/SwiftUI/os), swift-testing.

**Spec:** [`LIBRARY_INDEX_TRANSACTION_DESIGN.md`](LIBRARY_INDEX_TRANSACTION_DESIGN.md) — read it
first. This plan sequences that design; the design carries the exact algorithms, type signatures,
recovery table and test matrix. Section references below (§3, §9.4, …) point into it.

## Global Constraints

- `Sources/WhisperCore/` is Foundation-only, `Sendable`, no AppKit/SwiftUI/`os` imports (the
  **WhisperCore purity rule**, `AGENTS.md`). Design §2 verifies `open`/`flock`/`stat`/`chmod`/
  `getuid` all compile under `import Foundation` alone, so no new purity exception is needed.
  `CryptoKit` is barred — hence the hand-rolled `StoreFingerprint`.
- `MeetingStore` and `AppModel` are `@MainActor`. No save-path operation may block the main actor.
- Tests are swift-testing (`@Test("display name")`, `#expect`, `#require`) — never XCTest. Tests
  never write to `~/Library/Application Support/WhisperMeet/`; use
  `FileManager.default.temporaryDirectory` + UUID + `defer` cleanup, per `BackupJSONStoreTests.swift`.
- **Persisted-schema rules apply** (`AGENTS.md`): persisted fields are append-only and optional;
  compatibility is assessed in BOTH directions; an unreadable file is quarantined, never overwritten.
  Payload bytes must stay byte-identical to today — the root is an array, so there is nowhere to add
  a field without retyping the root, which is what cost the library on 2026-08-14.
- **Invariant L (design §1.2):** a ledger that is missing, unreadable, undecodable, or of unknown
  `formatVersion` is treated as *no ledger*, and the store behaves exactly as it did before F190.
  Four requirements depend on it; it is a tested invariant, not a comment.
- **F187 must not regress:** preserve-before-overwrite, read-only-while-degraded, honest health
  states, per-record salvage. **F211 must not regress:** the decode-skip identity memory
  (63.7 ms → 24.3 ms per save at the real index size).
- Test command on this Mac (Command Line Tools only — plain `swift test` cannot find swift-testing):

```bash
FW=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
LIB=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
swift test --disable-sandbox --no-parallel \
  -Xswiftc -F -Xswiftc "$FW" \
  -Xlinker -rpath -Xlinker "$FW" \
  -Xlinker -rpath -Xlinker "$LIB" --filter "<name>"
```

  Keep the flags byte-identical between runs so SwiftPM does not rebuild.
  `Scripts/quality-check.sh` already bakes these in for the full gate, and **new files must be
  `git add`-ed before the gate runs** or step [1/5] refuses.

---

## Task order, and why

The design (§10) is emphatic that the caller-side changes are **more dangerous than the store
change** and must land first, as their own commit, so a bisect can separate "the new protocol is
wrong" from "the delete path is wrong".

Task 1 is therefore standalone: it fixes a data-loss hazard that exists **today**, with no new
protocol, and is worth shipping even if the rest of F190 never lands.

| Task | Deliverable | Depends on |
|---|---|---|
| 1 | Caller-side: delete ordering + edit retention | — |
| 2 | `StoreFingerprint` | — |
| 3 | `StoreFileIO` fault-injection seam | — |
| 4 | `StoreLedger` + Invariant L | 2, 3 |
| 5 | `<stem>.history/` retention (real copies) | 2, 3 |
| 6 | Write algorithm + CAS (`save(expecting:)`) | 4, 5 |
| 7 | Recovery on load | 6 |
| 8 | Divergence → load-time health | 7 |
| 9 | `LibraryWriterLease` at launch | 3 |
| 10 | `MeetingStore` tokens + lease wiring | 6, 9 |
| 11 | Docs, `RECOVERY.md`, full gate | all |

---

### Task 1: Caller-side — stop `delete` destroying audio before the index is safe

**Files:**
- Modify: `Sources/WhisperMeet/MeetingStore.swift` (`delete(id:)` ~:584-612, `flushPendingEdits()` ~:528-540)
- Test: `Tests/WhisperMeetTests/MeetingStoreDeleteOrderingTests.swift` (create)

**Interfaces:**
- Consumes: nothing new.
- Produces: no new public API. `delete(id:)` and `flushPendingEdits()` keep their signatures.

**Why this is a real bug today.** `AGENTS.md` already states the rule — *"`delete` removes audio
before it saves the index, so blocking persistence alone is not enough."* `delete(id:)` calls
`removeRecordingDirectory(directory)` and only then `persistMeetings()`. Any persist failure (a full
disk today; a refused save once F190 lands) leaves an index entry pointing at audio that is already
gone. Separately, `flushPendingEdits()` sets `pendingIndexFlush = nil` *before* `persistMeetings()`,
so a failed flush drops the user's edit with nothing left to re-attempt.

- [ ] **Step 1: Write the failing test for delete ordering**

```swift
@Test("A failed index save during delete leaves the recording on disk (F190)")
@MainActor
func deleteDoesNotDestroyAudioWhenTheIndexCannotBeSaved() async throws {
    // Build a store over a temp library with one meeting and its recording folder.
    // Make the index unsaveable (chmod 0o500 the library root after load), then delete.
    // Expect: the recording directory still exists, the meeting is still listed,
    // and storageErrorMessage is non-nil.
}
```

- [ ] **Step 2: Run it and watch it fail**

Expected: the recording directory is gone while the meeting remains listed.

- [ ] **Step 3: Reorder `delete(id:)` to persist before destroying**

Remove the entry from `meetings`, persist, and only remove the recording directory once the index no
longer references it. If the persist throws, restore the in-memory entry and surface
`storageErrorMessage` without touching the directory. Keep the existing `mutationIsAllowed()` guard
first — it must still precede every side effect (F187) — and keep the `isWithinLibrary` /
library-root guards exactly as they are (F148 #6).

Orphaned audio with no index entry is the strictly better failure: `MeetingStore.orphanedRecordings()`
already finds and re-adopts it, whereas an index entry pointing at deleted audio is unrecoverable.

- [ ] **Step 4: Run it and watch it pass**

- [ ] **Step 5: Write the failing test for edit retention**

```swift
@Test("A failed flush keeps the pending edit so a later flush retries it (F190)")
@MainActor
func failedFlushKeepsThePendingEdit() async throws {
    // Schedule a debounced edit, make the index unsaveable, flush.
    // Expect: storageErrorMessage set AND the edit still pending; make the index
    // writable, flush again, and the edit lands.
}
```

- [ ] **Step 6: Run it and watch it fail** — the edit is lost after the first flush.

- [ ] **Step 7: Make `flushPendingEdits()` clear its pending state only on success**

- [ ] **Step 8: Run the full gate and commit**

```bash
git add -A && ./Scripts/quality-check.sh
git commit -m "fix(storage): persist the index before deleting audio, keep a failed edit pending (F190)"
```

---

### Task 2: `StoreFingerprint`

**Files:**
- Create: `Sources/WhisperCore/StoreFingerprint.swift`
- Test: `Tests/WhisperCoreTests/StoreFingerprintTests.swift`

**Interfaces:**
- Produces: `StoreFingerprint` (`Sendable`, `Equatable`, `Codable`), `init(_ data: Data)`,
  `var hexString: String`, and pairing with `byteCount` at every comparison site.

Exact type, doc comment and the four-lane mixer are in design §2.1. It is **accident detection, not
tamper resistance** — that claim belongs in the doc comment, because a reader who assumes otherwise
will build a security property on it. Measured 0.403 ms for 2.1 MB (4 lanes) vs 2.59 ms (1 lane).

- [ ] **Step 1: Write failing tests** — identical bytes give identical fingerprints; a single flipped
      byte changes it; empty data is stable; the hex string round-trips through `Codable`.
- [ ] **Step 2: Run and watch them fail.**
- [ ] **Step 3: Implement per design §2.1.**
- [ ] **Step 4: Run and watch them pass.**
- [ ] **Step 5: Commit** — `feat(storage): content fingerprint for store payloads (F190)`.

---

### Task 3: `StoreFileIO` — the fault-injection seam

**Files:**
- Create: `Sources/WhisperCore/StoreFileIO.swift`
- Test: `Tests/WhisperCoreTests/StoreFileIOTests.swift`

**Interfaces:**
- Produces: `StoreFileIO` — a `Sendable` struct of injected closures with a `.live` POSIX
  implementation, per design §9. Every filesystem operation the write path performs goes through it.

The ticket's verification clause ("fault-injection tests cover every write phase") is only
satisfiable if a test can fail operation *N* specifically. Design §9.4 lists the phases that must be
individually failable; the seam must be able to express every row of that matrix, which is exactly
the objection one critique raised against a coarser seam.

- [ ] **Step 1: Write a failing test** that fails the 3rd write and asserts the error surfaces.
- [ ] **Step 2: Run and watch it fail.**
- [ ] **Step 3: Implement the seam and route `BackupJSONStore`'s existing writes through `.live`.**
- [ ] **Step 4: Run the whole existing store suite** — it must stay green, proving `.live` is a
      faithful replacement. This is the real test of this task.
- [ ] **Step 5: Commit** — `refactor(storage): route store writes through an injectable IO seam (F190)`.

---

### Task 4: `StoreLedger` and Invariant L

**Files:**
- Create: `Sources/WhisperCore/StoreLedger.swift`
- Test: `Tests/WhisperCoreTests/StoreLedgerTests.swift`

**Interfaces:**
- Produces: `StoreLedger` (`Codable`, `Sendable`) with `formatVersion`, generation number, parent
  identity, fingerprint and byte count; `read(at:)` returning an optional; `write(_:to:io:)`.

Per design §1.2 and §2. **Invariant L is the point of this task**: missing, unreadable, undecodable,
or unknown-`formatVersion` all mean *no ledger*, and the store then behaves exactly as pre-F190.

- [ ] **Step 1: Write failing tests, one per Invariant-L input** — absent file; zero bytes; invalid
      JSON; valid JSON with `formatVersion: 9999`; valid JSON of the wrong shape. Each must yield
      "no ledger" and a store that still loads and saves normally.
- [ ] **Step 2: Run and watch them fail.**
- [ ] **Step 3: Implement per design §2.**
- [ ] **Step 4: Run and watch them pass.**
- [ ] **Step 5: Commit** — `feat(storage): advisory store ledger (F190)`.

---

### Task 5: Retained history as physically independent copies

**Files:**
- Create: `Sources/WhisperCore/StoreHistory.swift`
- Test: `Tests/WhisperCoreTests/StoreHistoryTests.swift`

**Interfaces:**
- Produces: `StoreHistory` with `record(_:generation:fingerprint:io:)`, `retained()` →
  `[RetainedGeneration]`, `prune(byteBudget:anchors:)`, `value(ofGeneration:)`.

**The load-bearing rule, verified on this machine (design §11): never `link(2)`.** A hard link makes
the retained generation an alias of the live file, so `cp good.json meetings.json`, a shell redirect,
`rsync --inplace` or a non-atomic `Data.write(to:)` rewrite the archive through the live name. `link`
also bumps the source's `st_ctime`, which is in F211's identity tuple, silently voiding the
decode-skip on every later save. Use `FileManager.copyItem` (APFS `clonefile`, 0.371 ms for 2.1 MB,
distinct inode).

**Retention must not be count-only.** A critique showed `AppModel.performStartupRecovery` calls
`upsert` once per orphan, so a burst of saves blows through a "keep the newest 5" window — destroying
history in exactly the incident shape this ticket exists for. Use the design's byte budget plus
hour/day/week anchors and the high-water pin (§7).

- [ ] **Step 1: Write the failing regression test for the hardlink hazard**

```swift
@Test("A retained generation survives an in-place overwrite of the live index (F190)")
func retainedGenerationIsIndependentOfTheLiveFile() throws {
    // record a generation, then overwrite the live primary IN PLACE (non-atomic write),
    // then assert the retained copy still decodes to the original value.
}
```

- [ ] **Step 2: Run and watch it fail** if implemented with `link(2)`; this test is why the design
      forbids it.
- [ ] **Step 3: Implement with `copyItem` and the §7 retention policy.**
- [ ] **Step 4: Write and run the burst test** — 50 rapid saves must not evict the anchors.
- [ ] **Step 5: Commit** — `feat(storage): content-addressed retained generations (F190)`.

---

### Task 6: The write algorithm and the compare-and-swap

**Files:**
- Modify: `Sources/WhisperCore/BackupJSONStore.swift`
- Test: `Tests/WhisperCoreTests/BackupJSONStoreTransactionTests.swift`

**Interfaces:**
- Produces: `save(_:expecting:) throws -> SaveOutcome`, `GenerationToken`, `SaveOutcome`.
  `save(_:)` remains, meaning `expecting: nil` — documented as last-writer-wins (design §13 names
  this an accepted hole).

Follow design §3 exactly, including the rule that **`save()` returns normally if and only if the
value is durable at `primaryURL`** — every other outcome throws. The four existing call sites do
`try store.save(x); errorMessage = nil`, so anything weaker silently reports success.

- [ ] **Step 1: Write failing tests for each §3 postcondition**, and specifically the two F211 safety
      tests that must still pass unchanged (foreign corruption preserved; foreign valid generation
      becomes the backup).
- [ ] **Step 2: Run and watch them fail.**
- [ ] **Step 3: Implement §3.**
- [ ] **Step 4: Run the whole store suite plus the F211 performance harness**
      (`F211_MEASURE=1 … --filter savePathCostBeforeAndAfter`) and confirm the per-save cost has not
      regressed past today's ~24 ms.
- [ ] **Step 5: Commit** — `feat(storage): ledger-committed rotation with a content CAS (F190)`.

---

### Task 7: Recovery on load

**Files:** Modify `Sources/WhisperCore/BackupJSONStore.swift`; test
`Tests/WhisperCoreTests/BackupJSONStoreRecoveryTests.swift`.

Implement the recovery table in design §4 — **one test per row**, which is the ticket's
"fault-injection tests cover every write phase and recovery on next launch". Use the Task 3 seam to
kill the write at each phase, then re-open the store and assert the row's stated outcome.

**`load()` must never become a writer without preserve-before-overwrite.** Two critiques found
designs whose recovery renamed an undecodable primary over a good backup. Today's
`backupData = existingPrimary ?? existingBackup ?? newData` makes that structurally impossible;
recovery must keep that property.

- [ ] **Step 1: Write one failing test per recovery-table row.**
- [ ] **Step 2: Run and watch them fail.**
- [ ] **Step 3: Implement §4.**
- [ ] **Step 4: Run and watch them pass.**
- [ ] **Step 5: Commit** — `feat(storage): transaction recovery on load (F190)`.

---

### Task 8: Divergence detection

**Files:** Modify `Sources/WhisperCore/PersistedStoreHealth.swift` and `BackupJSONStore.swift`;
test `Tests/WhisperCoreTests/BackupJSONStoreDivergenceTests.swift`.

Per design §5. **Divergence is decided at load, in `init`, never at save time.** A save-time health
transition is forbidden: `AppModel.startRecording` pre-flights `!store.isDegraded` and relies on that
answer for the whole recording, so a mid-session degrade makes `stopRecording`'s `upsert` silently
return and loses a finished meeting. A save-time conflict uses the separate `writeConflict` /
`unsavedChanges` channel instead (§10.1).

Also required by §5: the manual exit. Deleting `meetings.ledger.json` must restore a normal load —
this is the documented escape hatch and follows from Invariant L.

- [ ] **Step 1: Write failing tests** — divergent valid copies surface a no-write state; a
      hand-restored file without a ledger loads `.complete`; deleting the ledger clears divergence.
- [ ] **Step 2: Run and watch them fail.**
- [ ] **Step 3: Implement §5.**
- [ ] **Step 4: Run and watch them pass.**
- [ ] **Step 5: Commit** — `feat(storage): detect divergent index generations at load (F190)`.

---

### Task 9: `LibraryWriterLease`

**Files:** Create `Sources/WhisperCore/LibraryWriterLease.swift`; test
`Tests/WhisperCoreTests/LibraryWriterLeaseTests.swift`.

Per design §2 and §10.1. **Taken once at launch with `flock(LOCK_EX|LOCK_NB)`, zero retries, never
on the save path** — measured at 14–30 µs, so it cannot stall the main actor. Not holding the lease
never makes anything read-only; it publishes an advisory only.

Two verified hazards to encode as tests: `flock` **self-conflicts across two `open()` calls in the
same process** (fd1 locks, fd2 gets `EWOULDBLOCK`), so the lease must be a single shared handle; and
an unopenable shared lock file falls back to a per-uid lock rather than unlinking the shared one
(unlinking silently breaks serialization against a holder that *can* open it).

- [ ] **Step 1: Write failing tests** — acquire/release; a second handle in-process does not
      self-deadlock; an unopenable shared lock falls back per-uid; failure to lease never degrades
      health.
- [ ] **Step 2: Run and watch them fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run and watch them pass.**
- [ ] **Step 5: Commit** — `feat(storage): single-writer lease taken once at launch (F190)`.

---

### Task 10: `MeetingStore` wiring

**Files:** Modify `Sources/WhisperMeet/MeetingStore.swift`,
`Sources/WhisperMeet/Dictation/DictationLogStore.swift`; tests alongside.

Per design §10. Thread `GenerationToken`s from each `load()` into every `save(expecting:)` and
refresh them from each `SaveOutcome` — **without this the CAS never fires and the ticket is not
satisfied**. Publish the lease advisory. Add the `writeConflict` / `unsavedChanges` channel.

`DictationLogStore` assigns `health` only in `init` and documents that as a three-part invariant;
do not make it runtime-mutable.

- [ ] **Step 1: Write failing tests** — a stale token is refused and the body preserved as
      `conflict-…`; a successful save refreshes the token; a refused save leaves `unsavedChanges`.
- [ ] **Step 2: Run and watch them fail.**
- [ ] **Step 3: Implement.**
- [ ] **Step 4: Run and watch them pass, plus the whole suite.**
- [ ] **Step 5: Commit** — `feat(storage): thread generation tokens through the meeting store (F190)`.

---

### Task 11: Docs and the full gate

**Files:** `docs/RECOVERY.md`, `AGENTS.md` (persisted-schema rules), `docs/CHANGELOG.md`,
`docs/TICKET_LOG.md`, `README.md`.

- [ ] **Step 1: Extend `docs/RECOVERY.md`** with the new files (`*.ledger.json`, `<stem>.history/`,
      `.writer.lock`), the manual exit from divergence (delete the ledger), and how to restore a
      retained generation by hand.
- [ ] **Step 2: Record the privacy trade** (design §13): retained generations keep the content of
      deleted meetings for a bounded window, so "delete" does not immediately erase every copy. File
      the *shred on delete* follow-up against F192.
- [ ] **Step 3: Run the complete gate**, confirm the test count rose and nothing dropped.
- [ ] **Step 4: Close F190 in `docs/TICKET_LOG.md`** with real command output, and file the follow-ups
      named in design §13 against F188 / F191 / F192.
- [ ] **Step 5: Commit and push.**

---

## What this plan does not deliver

Carried verbatim from design §13 so it is not lost between documents:

- **F188** — the format/version fence and single-instance enforcement. F190 does **not** stop a
  downgraded bundle writing a payload a newer bundle cannot read; the 2026-08-14 wipe file would
  still be a structurally perfect lineal child. What changes is that the pre-wipe generations
  survive in `<stem>.history/` and are restorable in one call.
- **F191** — `BackupCoordinator`'s torn read is mitigated, not closed; the real fix is hashing during
  the copy. There is still no in-app restore-from-backup flow.
- **F192** — the mechanism ships, the picker UI does not. Plus the retention privacy trade above.
- **Semantic detection** — nothing here distinguishes a valid-but-wrong generation from a valid one.
  F190's guarantee is recoverability, not detection.
- **Power-loss durability** — no `fsync`/`F_FULLFSYNC` on the save path; on macOS plain `fsync` only
  reaches the drive's volatile cache, and `F_FULLFSYNC` would cost tens of milliseconds on the main
  actor. Recovery handles the resulting states non-destructively instead (§4).
- **Field-level merge** — conflict resolution is "keep mine" or "take theirs", with both branches on
  disk. A three-way merge needs per-record storage (postmortem open decision #2).
