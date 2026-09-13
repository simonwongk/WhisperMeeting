<!-- Design document for F190. The implementation plan that executes it is
     docs/LIBRARY_INDEX_TRANSACTION_PLAN.md. Its predecessor is docs/LIBRARY_INDEX_SAFETY_PLAN.md
     (F187, shipped), and the incident that started this work is
     docs/LIBRARY_INDEX_WIPE_POSTMORTEM_2026-08-14.md. -->

> **Status:** design agreed, not yet implemented. Nothing in `Sources/` implements this document yet.
>
> **How this design was produced (2026-09-12).** Four independent protocol designs were written from
> different angles — a write-ahead journal, numbered generations behind an atomically swapped
> pointer, a sidecar manifest beside today's two files, and a deliberately minimal design — and each
> was then attacked by three adversaries (a data-loss adversary, an F187/F211 regression adversary,
> and an implementation adversary). **All four failed review**, scoring 3.3–5.3/10 on data safety and
> 2.7–3.3/10 on simplicity, with 11–13 fatal flaws each. This document is the synthesis that resolves
> them; §12 records what was rejected and why. The mechanical claims in §11 were measured on this
> machine rather than assumed — most importantly that hard links cannot provide immutable history,
> which invalidated the core of two of the four candidates.

# F190 — Ledger-Committed Rotation with Content-Addressed History

**Make library-index writes transactional, generation-aware, and single-writer.**

Supersedes: the four candidate designs (journal / generations / manifest / minimal) and the un-shipped F190 writer-lock prototype.
Depends on: F187 (shipped), F211 (shipped).
Does **not** subsume: F188, F191, F192 — see *What this does not solve*.

---

## 0. Summary and the three decisions that shape everything

The store keeps `meetings.json` and `meetings.backup.json` exactly as they are — same names, same meaning, same bytes — and adds two sidecar artifacts per store: a ~600-byte **ledger** and a **content-addressed history directory**. The commit point is the ledger's atomic rename. Concurrency safety is a **compare-and-swap on content**, not a lock. The lock is acquired once at launch, never on the save path, and never makes anything read-only.

Three decisions were forced by the adversarial review and are load-bearing everywhere below. Each was verified on this machine (§11).

1. **History entries are physically independent copies, never hardlinks.** `link(2)` makes the retained generation an alias of the live file, so `cp good.json meetings.json`, a shell redirect, `rsync --inplace`, an editor's in-place save, or a non-atomic `Data.write(to:)` all rewrite the archive through the live name. Measured: `cp` through a hardlink destroyed the archived copy; `cp` onto a `FileManager.copyItem` clone did not. `link(2)` also bumps `st_ctime`, which is in F211's identity tuple, so any hardlink of the primary silently voids F211's decode-skip on every subsequent save. **We use `FileManager.copyItem`** (0.371 ms for 2.1 MB on APFS via `clonefile`, distinct inode; a real byte copy elsewhere).

2. **Health is still decided only in `init`.** A save-time conflict does **not** degrade `PersistedStoreHealth`. `AppModel.startRecording` pre-flights `!store.isDegraded` and then relies on that answer for the whole recording (`AppModel.swift:1001`); a mid-session degrade makes `stopRecording`'s `store.upsert` silently return while `orphanedRecordings()` returns `[]`, losing a finished meeting with no error. A save-time conflict instead sets a **separate, non-health channel** (`writeConflict` + `unsavedChanges`). Load-time divergence does degrade health, in `init`, exactly like every other F187 state.

3. **`save()` returns normally if and only if the value is durable at `primaryURL`.** Every outcome meaning "your bytes are not on disk" is a `throw`. This is what makes `@discardableResult` safe at the four call sites that today do `try store.save(x); errorMessage = nil`.

---

## 1. On-disk layout

Per store, derived from `primaryURL`. `stem = primaryURL.deletingPathExtension().lastPathComponent`. Shown for the meeting index; identical shape for `vocabulary`, `replacement-rules`, `dictation-log`.

```
~/Library/Application Support/WhisperMeet/
  .writer.lock                              NEW, one per LIBRARY. 0 bytes. flock(2) target only;
                                            contents are never read as a decision input.
  .writer-501.lock                          NEW, per-uid fallback. Created only when .writer.lock
                                            cannot be opened. Never unlinks the shared one.

  meetings.json                             UNCHANGED name, meaning and bytes. Current generation.
  meetings.backup.json                      UNCHANGED name, meaning and bytes. Previous generation.
  meetings.unreadable-<stamp>.json          F187 quarantine, unchanged.
  meetings.ledger.json                      NEW ~600 B. The commit record. ADVISORY (§1.2).
  meetings.json.stage-<nonce>               NEW, transient. Staging for the new body. Swept.
  meetings.backup.json.rotate-<nonce>       NEW, transient. Staging for the backup clone. Swept.
  meetings.history/                         NEW directory. Retained generations, real copies.
      g-000000042-7f3a1c9b2d4e6f80.json     committed generation 42, fingerprint in the name
      g-000000041-4b0e77a2c1935ee4.json
      g-000000040-2b91ee04aa17c3d9.json
      conflict-000000042-7f3a-9c11ab….json  a refused save's body, preserved (never auto-pruned)

  vocabulary.json / .backup.json / vocabulary.ledger.json / vocabulary.history/
  replacement-rules.json / … / replacement-rules.ledger.json / replacement-rules.history/
  dictation-log.json / … / dictation-log.ledger.json / dictation-log.history/
  Recordings/…
```

**Payload files are byte-identical to today.** `meetings.json` is a bare `[MeetingRecord]` array encoded with `[.prettyPrinted, .sortedKeys]` and `.iso8601`. No envelope, no generation field. The root is an array, so there is nowhere to add a field without retyping the root — the exact move that cost the library on 2026-08-14, and forbidden by the persisted-schema rules in `AGENTS.md:378`. All F190 metadata lives outside the payload.

### 1.1 Name-collision audit

`StoreQuarantine.preserve` lists siblings and matches the prefix `"<stem>.unreadable-"` (`StoreQuarantine.swift:31-39`), filtering by prefix *before* reading. None of `meetings.ledger.json`, `meetings.history`, `meetings.json.stage-*`, `meetings.backup.json.rotate-*`, `.writer.lock` match it, and `meetings.history` is a directory that is therefore never passed to `Data(contentsOf:)`. `g-` and `conflict-` names live one level down and are invisible to that scan.

`MeetingStore.orphanedRecordings()` (`:426`) and `finalizedRecordingFolderCount()` (`:843`) scan `Recordings/` only; `AppModel.hasOrphanedQwenInstallArtifacts` (`:2251`) scans the runtime directory. No new file at the library root is visible to any of them.

### 1.2 The ledger is advisory, and that rule is load-bearing

> **Invariant L:** a ledger that is missing, unreadable, undecodable, or carries an unknown `formatVersion` is treated as *no ledger*, and the store behaves exactly as it did before F190.

Four separate requirements depend on Invariant L and fail together if it is ever relaxed:

* A restore that brings back `meetings.json` without its ledger must read `.complete`, not damaged.
* `docs/RECOVERY.md` tells the user to hand-copy index files; a hand-copy must never brick the library.
* Deleting `meetings.ledger.json` is the documented manual exit from a divergence read-only state.
* An old bundle that writes the two legacy files and knows nothing about the ledger must not be destructive.

Invariant L must be an explicitly tested invariant (§9.4), not a comment.

The ledger is also never the only record of a generation: **history file names carry the fingerprint**, so a generation is self-identifying without any ledger record. A lost ledger update therefore degrades to a directory scan; it can never lose a generation.

---

## 2. New WhisperCore types

All Foundation-only and `Sendable`. Verified: `open`, `flock`, `stat`, `chmod`, `getuid`, `close`, `errno`, `O_RDWR`/`O_CREAT`/`O_CLOEXEC`, `LOCK_EX`/`LOCK_NB` all compile under `import Foundation` alone on macOS, so **no new purity exception is needed** (`AGENTS.md:394`). `CryptoKit` is *not* used: it is a framework import and barred from WhisperCore.

### 2.1 `Sources/WhisperCore/StoreFingerprint.swift`

```swift
/// A 64-bit content fingerprint for a store payload (F190).
///
/// Accident detection, NOT tamper resistance: it answers "are these the same bytes I recorded"
/// against a torn write, a foreign overwrite, a half-restored file or a stale sidecar. It makes no
/// claim against an adversary. Every comparison in this module pairs it with `byteCount`.
///
/// Four independent lanes so the multiply chain is not serial: measured 0.403 ms for 2.1 MB
/// (5.2 GB/s) against 2.59 ms for the same mixer in one lane. CryptoKit is a framework import and
/// is barred from WhisperCore; a pure-Swift SHA-256 would cost an order of magnitude more for a
/// property this design does not need.
public enum StoreFingerprint {
    /// 16 lowercase hex characters.
    public static func of(_ data: Data) -> String
}
```

Exact algorithm (both any future reimplementation and this one must produce identical output):

```
mix(h, w):  x = h ^ w;  x = x &* 0xFF51AFD7ED558CCD;  return ((x << 31) | (x >> 33)) &+ 0x165667B19E3779F9

a = 0x9E3779B97F4A7C15 ^ UInt64(data.count)
b = 0xBF58476D1CE4E5B9
c = 0x94D049BB133111EB
e = 0x2545F4914F6CDD1D

i = 0
while i + 32 <= n:
    a = mix(a, loadUnaligned(i,      UInt64))     // little-endian, as loaded
    b = mix(b, loadUnaligned(i + 8,  UInt64))
    c = mix(c, loadUnaligned(i + 16, UInt64))
    e = mix(e, loadUnaligned(i + 24, UInt64))
    i += 32
while i < n:
    a = (a ^ UInt64(byte[i])) &* 0x100000001B3;  i += 1

h = a ^ (b &* 0xC2B2AE3D27D4EB4F) ^ ((c << 17) | (c >> 47)) ^ (e &+ 0x9E3779B97F4A7C15)
h ^= h >> 33;  h = h &* 0xFF51AFD7ED558CCD
h ^= h >> 29;  h = h &* 0xC4CEB9FE1A85EC53
h ^= h >> 32
return String(format: "%016llx", h)
```

### 2.2 `Sources/WhisperCore/StoreGeneration.swift`

```swift
/// A store's position in its own write history (F190).
///
/// `fingerprint` + `byteCount` are the identity; `sequence` only orders and names. A writer that
/// resets or forges the number cannot thereby claim to have read bytes it never read, because every
/// compare-and-swap in this module compares content, never numbers.
public struct GenerationToken: Codable, Sendable, Equatable {
    public let sequence: UInt64
    public let fingerprint: String        // StoreFingerprint.of(payload)
    public let byteCount: Int
    public let writer: String             // 8 lowercase hex; one nonce per process
    /// False when these bytes were adopted from a file no ledger described — a pre-F190 library, an
    /// old bundle's write, a hand-restore. Adopted generations are fully writable.
    public let verified: Bool

    public func hasSameBody(as other: GenerationToken) -> Bool
    public func matches(fingerprint: String, byteCount: Int) -> Bool
}

/// The commit record. Written last; its atomic rename IS the commit (F190).
public struct StoreLedger: Codable, Sendable, Equatable {
    public static let currentFormatVersion = 1

    public struct Record: Codable, Sendable, Equatable {
        public var sequence: UInt64
        public var fingerprint: String
        public var byteCount: Int
        public var writer: String
        public var wroteAtEpochSeconds: Int
        public var parentFingerprint: String?   // nil for an adopted or bootstrap generation
        public var recordCount: Int?            // top-level element count; nil when unknown
        public var historyName: String?         // file name under <stem>.history/, nil once pruned
    }

    public var formatVersion: Int               // 1
    public var current: Record
    public var previous: Record?
    public var history: [Record]                // newest first, includes `current`, bounded
    /// False when this writer could not create or use <stem>.history/. A load NEVER declares
    /// divergence while this is false — without history there is no evidence to be sure with.
    public var historyAvailable: Bool
    public var writerRealm: String              // "shared" | "uid-<n>" | "none"
}
```

Fields added after v1 must be **optional and append-only**, per `AGENTS.md:378`. A reader that finds `formatVersion > currentFormatVersion` treats the ledger as absent (Invariant L) **and refuses to overwrite it** — a cheap forward fence on the metadata only.

### 2.3 `Sources/WhisperCore/StoreFileIO.swift` — the fault-injection seam

The existing `fileManager` parameter cannot do this job: it is used only for `createDirectory` and `fileExists`, while every byte read/write bypasses it and F211's identity check calls raw `stat()` (`BackupJSONStore.swift:58-68`). It is an ownership seam, not an IO seam. Subclassing `FileManager` is worse: routing contents through `contents(atPath:)`/`createFile` loses `Data.write(options: .atomic)`'s temp-then-rename, which F187's preserve rule, F211's inode identity and this design's install step all stand on.

```swift
public struct StoreFileIdentity: Sendable, Equatable {
    public let device: Int32
    public let inode: UInt64
    public let size: Int64
    public let modifiedSeconds: Int, modifiedNanoseconds: Int
    public let changedSeconds: Int,  changedNanoseconds: Int
    public init?(path: String)        // stat(2); nil when absent
}

/// Every distinct filesystem effect in the write protocol, so a test can fail exactly one (F190).
/// The phase is passed BY THE PRODUCTION CODE, never inferred from a URL suffix: `rename` serves
/// both `install` and `rotateBackup`, `writeAtomically` serves both `stage` and `commit`, and
/// suffix-matching cannot tell them apart.
public enum StoreWritePhase: String, Sendable, CaseIterable, Codable {
    case prepareDirectory
    case readPrimary, readBackup, readLedger, listHistory, readHistoryEntry
    case quarantine
    case preserveConflictBranch
    case stage
    case createHistoryDirectory, retain
    case rotateBackup
    case install
    case commit
    case prune
}

/// Defaults are the real Foundation/POSIX calls; a test substitutes a faulted copy.
public struct StoreFileIO: Sendable {
    public var read:                @Sendable (URL, StoreWritePhase) throws -> Data
    /// Data.write(options: .atomic) — temp + rename. Never FileManager.createFile.
    public var writeAtomically:     @Sendable (Data, URL, StoreWritePhase) throws -> Void
    /// FileManager.copyItem — clonefile(2) on APFS (O(1), separate inode), byte copy elsewhere.
    /// Throws NSFileWriteFileExistsError (516) when the destination exists; callers treat that as
    /// success for content-addressed names.
    public var copyItem:            @Sendable (URL, URL, StoreWritePhase) throws -> Void
    public var rename:              @Sendable (URL, URL, StoreWritePhase) throws -> Void   // rename(2)
    public var remove:              @Sendable (URL, StoreWritePhase) throws -> Void
    public var createDirectory:     @Sendable (URL, StoreWritePhase) throws -> Void
    public var contentsOfDirectory: @Sendable (URL, StoreWritePhase) throws -> [String]
    /// nil when absent; true/false for directory-ness. Lets the caller detect a plain FILE squatting
    /// the <stem>.history name without createDirectory throwing.
    public var isDirectory:         @Sendable (URL) -> Bool?
    /// MUST go through the seam. A faulted write plus a real stat() desyncs the F211 memory and
    /// silently turns its decode-skip into a proof it never earned.
    public var identity:            @Sendable (URL) -> StoreFileIdentity?
    public var fingerprint:         @Sendable (Data) -> String
    public var openLease:           @Sendable (URL) -> LibraryWriterLeaseHandle

    public static let live: StoreFileIO
}

public enum StoreIOError: Error, Sendable, Equatable {
    case destinationExists(String)
    case posix(operation: String, path: String, code: Int32)
}
```

### 2.4 `Sources/WhisperCore/LibraryWriterLease.swift`

```swift
public enum StoreWriterLease: Sendable, Equatable {
    case held(realm: String)               // "shared" or "uid-501"
    case heldElsewhere(realm: String)      // another live process has it
    case unavailable(reason: String)       // unopenable lock, ENOTSUP volume, EMFILE…
    case unmanaged                         // no lease was attempted (tests, fixtures)
}

public final class LibraryWriterLeaseHandle: @unchecked Sendable {
    public let lease: StoreWriterLease
    public func release()                  // idempotent; also called from deinit
}

public enum LibraryWriterLock {
    /// Non-blocking. NEVER waits, NEVER unlinks an existing lock file, NEVER throws.
    public static func acquire(root: URL, io: StoreFileIO = .live) -> LibraryWriterLeaseHandle
    /// Process-wide, memoized per resolvingSymlinksInPath().standardizedFileURL.path so MeetingStore
    /// and DictationLogStore share one lease instead of fighting each other for it.
    public static func shared(for root: URL) -> LibraryWriterLeaseHandle
}
```

Acquisition ladder, in order:

1. `open(root/.writer.lock, O_RDWR|O_CREAT|O_CLOEXEC, 0o644)` then `flock(fd, LOCK_EX|LOCK_NB)`.
   `O_CLOEXEC` is **mandatory**: the app spawns whisper/Qwen helper subprocesses, and without it a child inherits the descriptor and keeps the library locked after the parent dies.
2. `EWOULDBLOCK` (35) → `.heldElsewhere("shared")`.
3. `EACCES`/`EPERM` on open → retry `open(…, O_RDONLY)`; `flock(LOCK_EX)` on a read-only descriptor is legal (verified). This rung covers a `0o444`/foreign-owned-but-readable lock. Measured: a `0o000` file returns `EACCES` for **both** `O_RDWR` and `O_RDONLY`, so that case falls through.
4. Still denied and the library root is writable by us → create and lease `root/.writer-<getuid()>.lock`; record `realm: "uid-501"`.
5. Otherwise `.unavailable(reason:)`.

**No lease outcome ever sets `PersistedStoreHealth`, and no lease outcome ever refuses a write.** The lease makes conflicts rare; the CAS makes them safe. Unlinking a lock we cannot open would silently break serialization against a holder that *can* open it (`flock` attaches to the open file description, so the healer would lock a fresh inode while the holder keeps the old one) — so we never unlink. Refusing to write forever is the other bad answer, and the CAS makes it unnecessary.

### 2.5 `PersistedStoreHealth` — exactly one new case

```swift
/// Two decodable copies belonging to different write lineages, with the other branch still on disk
/// (F190). Nothing is known to be lost; what is unknown is which copy is the user's truth, so
/// nothing may be written until they choose. Both branches are named and both are retained.
case divergentGenerations(current: String, rival: String, retained: [String])
```

`allowsMutation` is untouched (`self == .complete`), so the new case is read-only with no extra code. `severity` is re-ranked, preserving the relative order of every existing case so `isWorse` and `degrade(to:)` behave identically:

| case | old | new |
|---|---|---|
| `.complete` | 0 | 0 |
| `.recoveredFromBackup` | 1 | 1 |
| `.partiallySalvaged` | 2 | 2 |
| `.suspectEmpty` | 3 | 3 |
| **`.divergentGenerations`** | — | **4** |
| `.unreadable` | 4 | 5 |
| `.unavailable` | 5 | 6 |

Rationale for rank 4: in divergence everything decodes and nothing is *known* lost, but an unknown amount of one writer's work is unaccounted for — worse than "the index is empty but every folder is intact" (`suspectEmpty`), better than "nothing decoded at all" (`unreadable`). The exhaustive switch breaks the build until the rank is given, which is the intended design. No test asserts a literal severity integer (the only `severity` reference in `Tests/` is `TranscriptQualityTests.swift:87`, an unrelated type), so the renumbering is safe.

### 2.6 `BackupJSONStoreError` — two new cases

```swift
/// Refused: the primary on disk is a generation this store did not derive from. NOTHING was
/// written; the refused value was preserved as `preservedAs` and is listed by
/// `retainedGenerations()`. Neither update is lost.
case generationConflict(primary: String, expected: GenerationToken, found: GenerationToken, preservedAs: String)

/// Refused, and the refused value could NOT be preserved to disk. It survives only in memory.
/// Fails closed, exactly like `StoreQuarantineError.couldNotPreserve`.
case generationConflictNotPreserved(primary: String, expected: GenerationToken, found: GenerationToken, reason: String)
```

Both carry honest `errorDescription` text: claim only the preservation that actually happened (the F187 rule, `BackupJSONStore.swift:9-14`).

### 2.7 `BackupJSONStore` — public surface

```swift
public struct BackupJSONStore<Value: Codable & Sendable> {

    public struct LoadResult {
        public let value: Value
        public let health: PersistedStoreHealth
        /// The generation these bytes are. Thread it back into `save(expecting:)`.
        public let token: GenerationToken?
        /// What the load observed and could not silently fix. Diagnostics through return values.
        public let repairs: [StoreRepair]
        public let writerLease: StoreWriterLease
        /// Conflict branches on disk awaiting a decision.
        public let conflictBranches: [RetainedGeneration]
    }

    public enum StoreRepair: Sendable, Equatable {
        case adoptedUnrecordedPrimary(fingerprint: String)      // our own crash between install and commit
        case adoptedForeignRotation(fingerprint: String)        // an old bundle / hand-restore wrote the pair
        case ledgerAheadOfBody(expected: String)                // power-loss reordering
        case ledgerUnreadable
        case ledgerNewerFormat(Int)
        case historyUnavailable(reason: String)
        case backupAheadOfLedger
        case sweptStagingFile(String)
        case missingHistoryEntry(String)
    }

    public struct SaveOutcome: Sendable, Equatable {
        public let token: GenerationToken
        public let parent: GenerationToken?
        public let phases: [StoreWritePhase]        // what actually committed, in order
        public let retainedName: String?
        public let prunedNames: [String]
        /// True when the BODY is durable but the ledger commit did not land. NOT an error.
        public let ledgerLagged: Bool
        public let adoptedUnrecordedPrimary: Bool
        public let adoptedForeignRotation: Bool
        public let quarantined: [String]
        public let conflictBranchBacklog: Int
    }

    public init(
        primaryURL: URL,
        backupURL: URL,
        fileManager: FileManager = .default,
        salvage: (@Sendable (Data) -> SalvagedValue<Value>?)? = nil,
        io: StoreFileIO = .live,
        writer: String = StoreWriterNonce.forThisProcess,
        lease: StoreWriterLease = .unmanaged,
        retention: RetentionPolicy = .init(),
        /// Top-level element count, for the retention high-water pin and the recovery list. The
        /// value is already in memory, so this is free — never a JSONSerialization re-parse.
        recordCount: (@Sendable (Value) -> Int?)? = nil
    )

    public func load() throws -> LoadResult?

    /// Returns normally IF AND ONLY IF `value` is durable at `primaryURL`.
    /// `expecting: nil` means unchecked (today's last-writer-wins) and is the compatibility default;
    /// every production caller MUST thread the token from `load()`/the previous `SaveOutcome`.
    @discardableResult
    public func save(
        _ value: Value,
        expecting: GenerationToken? = nil,
        now: Int = Int(Date().timeIntervalSince1970)
    ) throws -> SaveOutcome

    // Recovery — reads only, except `restore`.
    public func retainedGenerations() throws -> [RetainedGeneration]
    public func value(ofGeneration fingerprint: String) throws -> Value
    @discardableResult
    public func restore(generation fingerprint: String,
                        now: Int = Int(Date().timeIntervalSince1970)) throws -> SaveOutcome
}

public struct RetainedGeneration: Sendable, Equatable {
    public let fileName: String
    public let sequence: UInt64
    public let fingerprint: String
    public let byteCount: Int
    public let writer: String
    public let wroteAtEpochSeconds: Int
    public let recordCount: Int?
    public let isConflictBranch: Bool
    public let isCurrentBody: Bool
    public let isPinnedHighWater: Bool
}
```

`StoreQuarantine.preserve(fileAt:using:io:)` gains a defaulted `io:` parameter and keeps `using fileManager:`, so `StoreQuarantineTests.swift:20/37/38/50` compile unchanged.

Every new `init` parameter is defaulted and declared **after** `salvage:`, so all 9 existing `BackupJSONStore(...)` constructions (`BackupJSONStoreTests.swift:13/37/67/88/125/169/198`, `BackupJSONStoreSavePerformanceTests.swift:70`, `MeetingStore.swift:261/267/271`, `DictationLogStore.swift:20`) compile untouched.

---

## 3. The write algorithm

Ten steps. `save()` stays **synchronous, `await`-free, sleep-free, and free of any blocking wait** — there is no lock acquisition on this path at all (§5).

Nonce: `<nonce>` is 8 hex characters, fresh per call.

---

**`prepareDirectory`** — `io.createDirectory(primaryURL.deletingLastPathComponent())` with intermediates. Byte-identical to today's first line (`BackupJSONStore.swift:176`); a no-op when the directory exists. Then best-effort sweep of *our own* stale temps only: siblings matching `<stem>.json.stage-` and `<stem>.backup.json.rotate-`. Foundation cleans up its own `.atomic` temps.

> `<stem>.history/` is deliberately **not** created here. `saveRefusesWhenQuarantineFails` (`BackupJSONStoreTests.swift:56-77`) runs against a `0o500` directory and must still fail at the quarantine with exactly `StoreQuarantineError.couldNotPreserve("meetings.json")`; a directory create before the quarantine would throw `EACCES` first.

**`encode`** (no IO) — `let newData = try encoder.encode(value)`; `let newFingerprint = io.fingerprint(newData)`. Placed here so an encoding failure changes nothing on disk, matching today's line 180. Encoder settings unchanged, so output bytes are identical to today's.

**`classify`** (read-only) —

* Primary: `io.identity(primaryURL)`; if present, `io.read(primaryURL, .readPrimary)` — **always read**. Skip only the `Codable` decode when `memory.isProvenDecodable(primaryURL)`. Compute `primaryFingerprint`.
  *Why always read:* the primary's fingerprint is the input to the compare-and-swap. A CAS decided from a cached fingerprint would promote F211's memory from an optimization (worst case: one skipped decode, bytes still from disk) into the sole authority on whether to clobber another writer. Measured cost of the read: 1.19 ms warm, plus 0.403 ms to fingerprint.
* Backup: `io.identity(backupURL)`. If `memory.isProvenDecodable(backupURL)` → mark decodable with **no read**. This is a genuine extension of F211 and it is safe because the backup's *bytes* are never used any more (the rotation is a clone of the primary, §3 `rotateBackup`); only the *proof* is needed, and the identity tuple is exactly that proof. With a stale identity hit the behaviour is identical to today's, which also skips the quarantine in that case. Otherwise read + decode.
* Ledger: `io.read(ledgerURL, .readLedger)`, capture `ledgerIdentity = io.identity(ledgerURL)`, decode. Any failure or `formatVersion > 1` ⇒ `ledger = nil` (Invariant L) plus a `StoreRepair`.
* History: `io.contentsOfDirectory(historyURL, .listHistory)` when it exists and is a directory. `io.isDirectory(historyURL) == false` (a plain file squats the name) ⇒ `historyAvailable = false`, `StoreRepair.historyUnavailable`; **never throw**.

**`quarantine`** — F187, verbatim and unchanged. Any *data* copy that exists and does not decode is copied aside by `StoreQuarantine.preserve` before anything can replace it; a preserve failure throws and **nothing is written**. The ledger is derived metadata and is never quarantined — it is discarded and rebuilt.

**`compareAndSwap`** (read-only, except the conflict branch) — first matching rule wins:

| # | Condition | Outcome |
|---|---|---|
| 1 | `expecting == nil` | proceed, mode `.unchecked` (compat default) |
| 2 | primary missing | proceed, bootstrap, `parent = nil` |
| 3 | primary undecodable (already quarantined) | proceed, `parent = nil` — the F187 ladder |
| 4 | `expecting!.matches(primaryFingerprint, primaryByteCount)` | proceed, `parent = expecting` — **the common case** |
| 5 | `ledger == nil` | proceed, **adopt** the primary as parent, `verified: false` |
| 6 | `ledger!.current.fingerprint == primaryFingerprint` | **CONFLICT** — another F190 writer committed |
| 7 | a history file named `g-*-<primaryFingerprint>.json` exists | proceed, **adopt** — an F190 body installed but not yet recorded (our own crash, or a sibling's lagging commit) |
| 8 | `backupFingerprint == ledger!.current.fingerprint` | proceed, **adopt** — the legacy two-file rotation signature |
| 9 | otherwise | **CONFLICT** |

Rule order matters. Rule 6 fires before rules 7/8 so a genuine F190 sibling that *did* commit is caught rather than adopted. Rule 8 is the old-bundle / hand-restore signature: a non-F190 writer rotated our current generation into the backup and installed its own, which proves the foreign primary descends from us.

On **CONFLICT**: create `<stem>.history/` if needed, then write `newData` to `<stem>.history/conflict-<sequence>-<writer>-<newFingerprint>.json` via `io.writeAtomically(…, .preserveConflictBranch)`. **This fails closed.** If it cannot be written, throw `.generationConflictNotPreserved`; otherwise throw `.generationConflict(preservedAs:)`. Either way nothing else on disk changed, so the winner's generation is untouched and the loser's body is either on disk under a name `retainedGenerations()` lists, or the error says plainly that it is not.

`sequence = (parent?.sequence ?? ledger?.current.sequence ?? 0) + 1`.

**`stage`** — `io.writeAtomically(newData, stagingURL, .stage)` where `stagingURL = <dir>/<stem>.json.stage-<nonce>`. Same directory ⇒ same volume ⇒ the later `rename` is atomic. This is the **only** 2.1 MB write in the whole save (today there are two).

**`retain`** — `io.createDirectory(historyURL, .createHistoryDirectory)` (lazy), then `io.copyItem(stagingURL, historyURL/g-<sequence padded to 9>-<newFingerprint>.json, .retain)`. `destinationExists` ⇒ success (the name is content-addressed, so the bytes are identical). **Never fatal**: any failure sets `historyAvailable = false` in the ledger this save will write, records `StoreRepair.historyUnavailable`, and the save continues.

> This is also the transaction's **intent record**. It exists before the primary changes, so a crash between `install` and `commit` leaves a primary whose fingerprint is provably an F190 writer's body (rule 7). One artifact, two jobs — no separate journal or intent file, which is a second thing to keep consistent.

**`rotateBackup`** — reproduces today's `backupData = existingPrimary ?? existingBackup ?? newData` exactly, with clones instead of byte writes:

| outgoing primary | existing backup | action |
|---|---|---|
| decodable | any | `io.copyItem(primaryURL, backupURL+".rotate-<nonce>")` then `io.rename(tmp, backupURL)` |
| undecodable / missing | decodable | leave the backup exactly as it is |
| undecodable / missing | undecodable / missing | `io.copyItem(stagingURL, backupURL+".rotate-<nonce>")` then `io.rename(tmp, backupURL)` |

**Fatal on failure**, matching today: a failed backup write aborts the save before the primary changes, so the previous generation always survives a failed save. `memory.forget(backupURL)` before, `memory.remember(backupURL, byteCount:)` after.

**`install`** — `memory.forget(primaryURL)`; `io.rename(stagingURL, primaryURL, .install)`; `memory.remember(primaryURL, byteCount: newData.count)`.

> ▸ **DURABILITY POINT A.** The user's value is now the primary, atomically, and is readable by every bundle that has ever shipped. Nothing after this point can lose it.
> Nothing touches the primary's inode after this — in particular there is no `link(2)` — so its `ctime` stays put and F211's memory stays warm for the next save. That is a specific fix: `link(2)` was measured to bump `ctime`, which would have made every subsequent save miss the memory and pay a full decode.

**`commit`** — build the new `StoreLedger` (`current` = this generation, `previous` = the outgoing one, `history` = the retained records newest-first, `historyAvailable`, `writerRealm`). Re-take `io.identity(ledgerURL)` and compare with the identity captured in `classify`:

* changed ⇒ someone else rewrote the ledger since we read it. **Do not overwrite.** `ledgerLagged = true`.
* `formatVersion` was newer ⇒ **do not overwrite.** `ledgerLagged = true`.
* otherwise ⇒ `io.writeAtomically(ledgerBytes, ledgerURL, .commit)`; a failure sets `ledgerLagged = true`.

**Never fatal.** The body is already installed; throwing here would show "changes could not be saved" for changes that are on disk, and could provoke a caller rollback of durable data. A lagged ledger costs one generation of lineage certainty and nothing else, because the history entry already identifies the generation by content.

> ▸ **DURABILITY POINT B.** The lineage is recorded. `retainedGenerations()`, divergence detection and the parent chain are all exact from here.

**`prune`** — apply `RetentionPolicy` (§7) and `io.remove(…, .prune)` only the `g-` entries it drops. Never a `conflict-` entry. Best-effort; never throws.

### 3.1 Durability and fsync

There is **no `fsync`/`F_FULLFSYNC`**, deliberately. Today's code has none either, so adding one would be a new per-save cost on the main actor (`F_FULLFSYNC` on 2.1 MB is tens of milliseconds — the entire budget), and `Data.write(options: .atomic)`'s temp+rename already makes every file wholly-old or wholly-new against a *process* crash, which is the fault class the seam can inject and the class that actually caused 2026-08-14. Power-loss reordering is **handled in recovery rather than prevented**: both "ledger behind body" and "ledger ahead of body" are enumerated, recoverable states (§4). This is an accepted limit, named in §12.

---

## 4. Recovery table

One row per interruption point. Starting state: ledger `L0 = {current: C(seq n, fp c), previous: P}`; primary = C; backup = P; history holds C, P and older. The new generation is N (seq n+1, fp x). "Next launch" means a fresh `BackupJSONStore.load()`.

> **`load()` writes nothing, ever, except F187's additive quarantine.** It classifies and reports; it never deletes a staging file, never rewrites a ledger, never repairs. Every repair happens inside the next `save()`, under the normal algorithm, as a new generation. This preserves the postmortem's rule that a failed load never rebuilds a library.

| Interrupted after | On disk | What the next launch sees | Health | Load writes |
|---|---|---|---|---|
| `prepareDirectory` | nothing changed; our stale temps may be swept | primary = C matches `L0.current` | `.complete` | none |
| `encode` | nothing | as above | `.complete` | none |
| `classify` | nothing | as above | `.complete` | none |
| `quarantine` | a `<stem>.unreadable-<stamp>.json` copy may exist; no data file touched | as above, plus an evidence file. `StoreQuarantine` is idempotent per (file, bytes), so a launch loop cannot duplicate it | `.complete` (or the F187 ladder if the primary was already bad) | quarantine only (F187) |
| `compareAndSwap`, conflict path | `conflict-…json` exists; primary, backup, ledger all untouched | primary = C; the refused body is listed in `conflictBranches` | `.complete` | none |
| `stage` | orphan `<stem>.json.stage-<nonce>` | primary = C; the orphan is not `meetings.json` so load ignores it | `.complete` + `.sweptStagingFile` at the next save | none |
| `retain` | `history/g-<n+1>-x.json` exists; primary still C | primary matches `L0.current` ⇒ clean. A history entry whose fingerprint matches no live body is an **uncommitted generation**: retained as evidence, never presented as current | `.complete` | none |
| `rotateBackup` | backup = C (was P); primary = C; history has N | primary matches `L0.current`. `backup ≠ L0.previous` is tolerated — `previous` is advisory — and P is still in history | `.complete` + `.backupAheadOfLedger` | none |
| **`install`** | **primary = N**, backup = C, ledger still `L0` | primary is off-lineage **but `history/g-<n+1>-x.json` exists with exactly fp x** ⇒ rule 7 ⇒ **adopt N as current**. The save survived the crash | `.complete` + `.adoptedUnrecordedPrimary(x)` | none |
| `commit` | ledger = `L1 {current: N, previous: C}`; bodies consistent | fully consistent | `.complete` | none |
| `prune` | history partially pruned | a ledger record whose `historyName` is gone is reported, never fatal | `.complete` + `.missingHistoryEntry` | none |
| inside any `.atomic` write | Foundation writes a sibling temp then renames ⇒ the file is wholly old or wholly new | as the row above it | — | — |
| **power loss, ledger ahead of body** | `ledger.current` names a fingerprint on no body and in no history file | fall back to what is present: the primary decodes and *is* a known ledger record ⇒ adopt it | `.complete` + `.ledgerAheadOfBody` | none |
| power loss, both bodies lost | neither decodes | unchanged F187 ladder: quarantine both, then `salvage` over both, then `noReadableCopy`. Plus the retained generations are offered | `.unreadable` / `.partiallySalvaged` | quarantine only |
| process killed holding the lease | `flock` is released by the kernel on the last `close`, including `SIGKILL` | no stale lock is possible; the 0-byte lock file persists and is reused | — | — |
| `retain` never ran (history unavailable) and then `install` crashed | primary = N, no evidence anywhere | `ledger.historyAvailable == false` ⇒ **divergence is never declared** (§5 rule 2) ⇒ adopt the primary | `.complete` + `.adoptedUnrecordedPrimary` | none |

Two properties fall out and should be asserted directly:

* **The primary is never absent.** Every install is a `rename` over an existing or absent name; there is no window in which `meetings.json` does not exist. (This is why the "rename the primary away into the backup" design was rejected.)
* **No interruption point makes both live copies unreadable.** The `rotateBackup` step never writes an undecodable body over a decodable backup, and the primary is only ever replaced by a `rename` of a fully-written staging file.

---

## 5. Divergence

Divergence must fire on positive evidence of two lineages and must *not* fire on a crash, an old bundle's write, or a documented hand-restore. A false read-only library is itself a harm — F187's `.suspectEmpty` over-fire already proved that, turning "deleted my last meeting, then crashed while recording" into a locked library with no in-app way out. **The bias is explicitly toward adopting.**

### 5.1 Load-time divergence (the only thing that sets health)

Declare `.divergentGenerations` only when **all five** hold:

1. The ledger decodes with a known `formatVersion`.
2. `ledger.historyAvailable == true` **and** `<stem>.history/` is readable.
3. The primary **decodes** and its fingerprint matches **no** ledger record (`current`, `previous`, any `history[]` entry) and **no** file in `<stem>.history/`.
4. `backupFingerprint != ledger.current.fingerprint` (otherwise it is the legacy-rotation signature ⇒ adopt).
5. `ledger.current`'s bytes are still retrievable — present in the backup or in `<stem>.history/` — so there genuinely is a second branch to choose between.

Any failure ⇒ adopt the primary with a `StoreRepair` note and `.complete`. Explicitly **not** divergence: a missing/undecodable/newer-format ledger; a stale manifest matching neither file; a different `writer`/`writerRealm`; a stale or hand-replaced backup while the primary is on-lineage; an unrecorded primary whose fingerprint is in history; history unavailable.

On divergence, `load()` quarantines both **data** files via `StoreQuarantine` (copies, never moves; names reported honestly), returns the **primary's** value so the user can still see and export their library, and reports `.divergentGenerations`. It does **not** throw — a throw would leave `MeetingStore.meetings` empty and render as zero meetings plus a read-only banner, visually indistinguishable from the wipe this work exists to prevent.

`MeetingStore.degrade(after:)` still fails closed for everything it does not recognise; the divergence path does not reach it because divergence is a returned health, not an error.

### 5.2 Save-time conflict (never touches health)

`BackupJSONStoreError.generationConflict` is thrown from `compareAndSwap` and is surfaced by `MeetingStore` through a **separate channel**:

```swift
@Published private(set) var writeConflict: WriteConflictReport?
@Published private(set) var unsavedChanges: Bool
```

It does **not** call `degrade(to:)`, does **not** change `health`, and does **not** change `isDegraded`. Therefore:

* `AppModel.startRecording`'s pre-flight (`AppModel.swift:1001`) keeps its meaning for the whole recording, and `stopRecording`'s `upsert` can never silently drop a finished meeting.
* `MeetingStore.recordingDirectory(for:)`, `orphanedRecordings()`, `libraryAcceptsChanges` and every other `isDegraded` reader keep the launch-time assumption they were written under.
* `DictationLogStore`'s documented three-part invariant ("`health` is assigned **only in `init`**") is preserved exactly.

The user sees an honest alert with two explicit choices:

* **Reload the library** — discard the in-memory value, re-`load()`, relaunch the token. The refused body is still on disk as a conflict branch.
* **Keep mine** — an explicit override: `save(expecting: nil)`. Last-writer-wins, but *chosen*, and the other writer's generation is safe in `<stem>.history/` and in the backup.

Both are lossless at the file level; the choice is which becomes current. Whole-value semantics make a generic field-level merge impossible — see §12.

---

## 6. Migration

No flag day. Nothing is converted. Four cases.

**1. First launch of an F190 build on today's two-file library.** `load()` finds the two files and no ledger. Invariant L ⇒ pre-F190 behaviour: the primary decodes ⇒ `.complete`, exactly as today. The result carries `token = GenerationToken(sequence: 0, fingerprint: fp(primary), byteCount:, writer:, verified: false)`. **Nothing is written at load** — pinned by `VocabularyCapTests.swift:107-146`.

**2. First save.** Rule 5 (no ledger) ⇒ adopt. `retain` clones the *new* body into `history/g-000000001-<fp>.json`; `rotateBackup` clones the pre-F190 primary into `meetings.backup.json` (today's exact semantics); `install`; `commit` writes the first ledger with `current` = generation 1, `previous` = the adopted generation 0. From here on the library is generation-aware. `meetings.json` and `meetings.backup.json` keep their exact names, meanings and bytes throughout.

**3. An old bundle writes the old two-file format.** It rewrites both files with `Data.write(options: .atomic)` — temp + rename — which replaces the *names*, not our inodes, and it never touches `meetings.ledger.json` or `meetings.history/`. So:

* **Our retained generations survive entirely.** This is the property that would have prevented 2026-08-14: the wipe destroyed both rotating copies and there was no third. History entries are independent clones (verified: a `cp` onto the live primary did not touch the clone), so no writer of any kind can reach them through a live name.
* Our next load sees rule 8's signature (`backup == ledger.current`) ⇒ **adopt**, `.complete`, `StoreRepair.adoptedForeignRotation`. No false lock-out, no alarm. The old bundle's write stands; the next save re-establishes verification.
* If the old bundle saved repeatedly (the stub loop), rotating our generation out of both files, the fingerprint matches nothing ⇒ divergence rule 3 holds; rules 1, 2, 4, 5 are checked; if they all hold, `.divergentGenerations` read-only with both branches named and the real library restorable from `<stem>.history/`. If any fails, adopt with a note — and the real library is *still* in `<stem>.history/`.

F190 does **not** stop an old bundle from writing a payload a newer bundle cannot read. That is F188's format fence. F190 converts that failure from unrecoverable to recoverable.

**4. Permanent downgrade.** A pre-F190 bundle reads `meetings.json` fine and treats the ledger and history directory as inert files it never opens. Storage grows by the retained generations and nothing else. Re-upgrading lands in case 3.

### 6.1 Hand-restore (`docs/RECOVERY.md`)

Replacing `meetings.json` by hand while the app is closed lands in rule 5 or 8 (adopt) or, for a pair replaced from an unrelated library, in divergence. **No new step is required of the user**, and the documented procedure keeps working. `RECOVERY.md` gains:

* `meetings.history/` as the first place to look for a previous version, with the note that file names carry the generation number and that `recordCount` is visible in the app's recovery list.
* The manual divergence exit: quit WhisperMeet, copy the chosen `meetings.history/g-….json` over `meetings.json`, delete `meetings.ledger.json`. The library is then pre-F190 and loads clean. **This exit works only because the ledger is advisory** (Invariant L).
* A warning that `cp` onto `meetings.json` is safe for the history entries (they are independent copies) — which is true by construction here and would have been false with hardlinks.

### 6.2 `BackupCoordinator`

`backedUpEntries` (`BackupCoordinator.swift:46`) is today `["Recordings", "meetings.json", "vocabulary.json"]` — it already omits `meetings.backup.json`, `replacement-rules.json` and `dictation-log.json`, so a restore already produces a half set. It becomes:

```swift
static let backedUpEntries =
    ["Recordings"] +
    ["meetings", "vocabulary", "replacement-rules", "dictation-log"].flatMap {
        ["\($0).json", "\($0).backup.json", "\($0).ledger.json"]
    }
```

`<stem>.history/` is **deliberately excluded**: those are up to ~6 × 2.1 MB per store of local crash insurance, `copyItem` across volumes expands clones into real bytes, and `descriptors` SHA-256s every file it plans (`:207-210`). The backup generations serve the same role off-library. A restore that brings back a ledger without history sets `historyAvailable = false` on the next load and therefore can never read as divergent (rule 2) — it adopts. `.writer.lock` and the `.stage-`/`.rotate-` temps are excluded.

`BackupCoordinatorTests` asserts exact copied/skipped counts (`#expect(g1.copied == 2)`) and must be updated; that is the intended cost of fixing an already-incomplete manifest.

Torn-read mitigation in this ticket (the full fix is F191): `AppModel.backUpLibrary` (`:715`) calls `store.flushPendingEdits()` before starting and guards on `!store.unsavedChanges`; `BackupCoordinator` re-hashes and re-copies a `verificationFailed` file **once** before throwing.

---

## 7. Retained history

### 7.1 Mechanism

`<stem>.history/g-<sequence padded to 9>-<fingerprint>.json`, created by `io.copyItem` from the **staging file**, before the primary is installed. Content-addressed, so the name alone identifies the bytes without any ledger record — which is what makes a lagged or lost ledger update harmless.

On APFS `copyItem` issues `clonefile(2)`: measured **0.371 ms for 2.1 MB**, a distinct inode, and copy-on-write so neither name can affect the other. On a volume without clone support it degrades to a real byte copy — slower, never broken. This is why `link(2)` is not used anywhere: besides aliasing the live file, `link` can fail outright with `EPERM`/`ENOTSUP` on exFAT/SMB, which would have made a retention step a terminal save failure.

Retention failure is **never fatal** (§3 `retain`).

### 7.2 Policy — counted in content and time, never in saves

```swift
public struct RetentionPolicy: Sendable, Equatable {
    public var recentCount: Int = 3
    /// Keep the newest generation older than each of these ages, in seconds.
    public var ageAnchors: [Int] = [3_600, 86_400, 604_800]     // an hour, a day, a week
    public var pinHighWaterRecordCount: Bool = true
    public var byteBudget: Int = 256 * 1024 * 1024
    public var maxConflictBranches: Int = 20
    public static let dictationLog = RetentionPolicy(recentCount: 2, ageAnchors: [86_400])
}
```

A `g-` entry is pruned only when **no** rule keeps it:

1. It is among the newest `recentCount`.
2. It is the newest generation older than anchor A, for some A in `ageAnchors` (one slot per anchor).
3. `pinHighWaterRecordCount` and it has the greatest known `recordCount` of all retained generations, and no *newer* retained generation has `recordCount >= ` it. Exactly one such pin exists.
4. Its `(fingerprint, byteCount)` equals the live primary's or the backup's — never delete the bytes that are live.

Then a byte budget: if the retained set exceeds `byteBudget`, drop oldest-first, but never anything kept by rules 1, 3 or 4.

`conflict-` files are **never automatically pruned** — they are unique user data that exists nowhere else. When their count reaches `maxConflictBranches` a new conflict is still preserved and `SaveOutcome.conflictBranchBacklog` reports the count so the app can ask the user to resolve them.

> **Why not "the newest K saves".** The 2026-08-14 loop wrote **ten** generations inside one launch (`AppModel.performStartupRecovery` calls `store.upsert` once per orphan folder, and `upsert` persists). `AppModel.recoverInterruptedTranscriptions` does the same per `.processing` meeting, and ordinary debounced transcript editing does it in under a minute. A 5-deep save window would have been emptied before the user saw the window. Under this policy those ten stub saves all have `recordCount == 0`, so rule 3 pins the 17-meeting generation indefinitely and rules 1–2 keep the hourly/daily/weekly anchors.

`recordCount` comes from the injected `recordCount:` closure — the value is already in memory (`{ $0.count }` for the three array stores), so it costs nothing. It is never a `JSONSerialization` re-parse of the payload.

### 7.3 Reading and restoring

`retainedGenerations()` reads the history directory, parses the names, joins the ledger records for `wroteAtEpochSeconds`/`recordCount`, and reports each entry newest-first. An entry whose bytes no longer match its name's fingerprint is reported with `recordCount: nil` and is refused by `restore` — it is never silently omitted, and never silently served.

`restore(generation:)` verifies the fingerprint, decodes, and commits the bytes as a **new** generation through the ordinary algorithm. History is therefore append-only: a restore is itself undoable, and the bad generation stays on disk as evidence until it ages out.

This is what closes the ticket's last clause. A semantically bad generation — `[]`, or ten blank stubs — is *syntactically perfect*: it decodes, it commits, and `.complete` is an honest report of what was read. Nothing in a write protocol can detect it. What this design guarantees is that committing it cannot destroy the last real generations, and that the recovery list shows *"42 · 3 minutes ago · **0 meetings**"* above *"41 · yesterday · 17 meetings"* — exactly the discrimination the 2026-08-14 recovery failed to make.

---

## 8. Performance

Measured on this machine at 2.1 MB, which is the real meeting-index size (F211's baseline: 63.7 ms → 24.3 ms per save).

| Component | measured |
|---|---|
| `JSONEncoder` `[.prettyPrinted, .sortedKeys]`, 2.1 MB | **11.29 ms** |
| `Data(contentsOf:)`, warm | **1.19 ms** |
| `Data.write(options: .atomic)`, 2.1 MB | **3.22 ms** |
| `FileManager.copyItem` (clone), 2.1 MB | **0.371 ms** |
| `StoreFingerprint.of`, 2.1 MB, 4 lanes | **0.403 ms** |
| `JSONDecoder`, 2.1 MB | 3.24 ms |

| | today (post-F211) | F190 | Δ |
|---|---|---|---|
| encode | 11.3 ms | 11.3 ms | — |
| read primary | 1.19 ms | 1.19 ms | — |
| fingerprint primary + new body | — | 0.81 ms | **+0.81** |
| read backup | 1.19 ms | **0** (identity proof; its bytes are never used) | **−1.19** |
| write backup | 3.22 ms | **0.37 ms** (clone + rename) | **−2.85** |
| write primary | 3.22 ms | 3.22 ms (staging) + rename ≈ 0 | — |
| history retain | — | 0.37 ms (clone) | **+0.37** |
| ledger read + write (~600 B each) | — | ≈ 0.05 ms | +0.05 |
| lease | — | **0** (acquired once at launch) | — |
| prune / sweep | — | ≈ 0.05 ms | +0.05 |
| **total** | **≈ 20.1 ms** | **≈ 16.9 ms** | **≈ −16 %** |

Bytes through the page cache per save go from **4 × index size to 1 × index size plus ~1 KB**. The two removed terms scale with the library; the three added ones are either O(1) (the clones, on APFS) or scale at 5.2 GB/s (the fingerprint). At 100 meetings (~12.4 MB) the advantage widens.

Non-APFS volumes: both clones become real byte copies, putting the save at roughly today's cost plus one extra copy for history. Retention is the part that degrades, it is never fatal, and `SaveOutcome`/`LoadResult` report `historyUnavailable` honestly.

Latency-sensitive call sites all get faster or stay level: the six saves inside `withAnimation` (`ContentView.swift:103/1989/2083/2138/2160/2308`), the view-lifecycle flushes (`:2231/:2968/:3599`, `normalizeTranscriptIfNeeded` at `:2982/:2989`), and `AppModel.swift:1856`'s one-save-per-`.processing`-meeting startup loop.

**Verification**, following the established precedent rather than asserting a threshold: extend `BackupJSONStoreSavePerformanceTests.swift` with a third arm under `F190_MEASURE=1`, `.enabled(if:)`, printing medians to stderr at 17 and 100 meetings for (a) today's two-write path, (b) the F190 path. The `F211_MEASURE` case stays as it is so the numbers remain directly comparable. A hard threshold would be a flaky test on someone else's hardware.

---

## 9. Fault-injection seam and the test matrix

### 9.1 The double

Repo idiom: `final class` + `NSLock` + scripted enum (`DictationRefinerTests.swift:5-27`, `DictationTestSupport.swift:61-85`). It wraps `.live`, so real bytes land in a real temp directory and only the *error* is injected — which is what lets each case then assert the real on-disk state on the "next launch".

```swift
private final class ScriptedStoreIO: @unchecked Sendable {
    init(failing phase: StoreWritePhase? = nil,
         occurrence: Int = 1,
         with error: Error = CocoaError(.fileWriteUnknown))
    var io: StoreFileIO { get }                       // counts per phase; throws or delegates to .live
    var completedPhases: [StoreWritePhase] { get }
    /// Called just BEFORE the effect, to open a deterministic concurrency window without a sleep.
    var barrier: (@Sendable (StoreWritePhase) -> Void)?
}
```

### 9.2 Every write phase × recovery on next launch

```swift
@Test("Every write phase fails cleanly and the next launch recovers (F190)")
func everyWritePhaseRecovers() throws {
    for phase in StoreWritePhase.allCases {
        // …seed two generations, then save a third through a ScriptedStoreIO failing `phase`.
        // Assert: the error (or that the phase is absent from SaveOutcome.phases for the
        // never-fatal ones), then construct a FRESH BackupJSONStore over the same directory with
        // io: .live and assert the row of §4's table — token, health, repairs — plus the two
        // invariants: the primary exists, and at least one decodable body is present.
    }
}
```

A `.allCases` loop means a phase added later without a recovery row fails the suite rather than going untested. Payloads must be **distinct at every step** so the fingerprint discriminators cannot collapse (a no-op save, e.g. a double `togglePin`, is covered by its own case).

### 9.3 Concurrency, in one process, with no sleeps

`flock(2)` locks attach to the open file description, so two `LibraryWriterLock.acquire(root:)` handles **in one process** genuinely contend — verified here (`first=0, second=-1, errno=35`). That keeps the concurrency test meaningful in-process; `fcntl(F_SETLK)` is per-process and would have made it vacuous, forcing a second process (and macOS ships no `/usr/bin/flock` to drive one from a shell helper).

* **Lost update:** two stores over one directory, both loaded at generation *n*. A commits; B's `save(expecting: tokenN)` throws `.generationConflict`. Assert: A's generation is the live primary; B's body exists byte-exactly at the reported `preservedAs` path; `retainedGenerations()` lists both; **neither update is lost**.
* **Deterministic window:** `barrier` blocks A at `.install` while B runs, instead of a timing `Task.sleep`.
* **Conflict fails closed:** inject a `.preserveConflictBranch` failure and assert `.generationConflictNotPreserved` with a message that does not claim preservation.
* No `Process.waitUntilExit()` anywhere (F169 — it wedges the cooperative pool). The suite stays `--no-parallel`.

### 9.4 The other cases

* **Invariant L:** `load()` returns `.complete` with a ledger that is truncated, empty, `formatVersion: 99`, or names generations that do not exist. Four cases, one per shape. This is the invariant everything in §6 rests on and it must be tested, not commented.
* **Unopenable lock, for real:** `chmod 0o000` on `.writer.lock`, behind `guard getuid() != 0` (today's read-only-directory test at `BackupJSONStoreTests.swift:63-77` lacks that guard and passes vacuously as root — worth fixing in the same commit). Assert the save still **succeeds**, `lease == .held(realm: "uid-…")` or `.unavailable`, the lock file was **not unlinked**, and `health` is unchanged.
* **`0o444` lock:** assert the `O_RDONLY` rung is exercised and returns `.held(realm: "shared")`.
* **A plain file at `<stem>.history`:** assert the save succeeds, `historyAvailable == false`, and the library is never read-only.
* **Old-bundle writer:** a `/bin/sh` helper written into a temp directory (the repo's precedent, `WarmWhisperDictationEngineTests.swift:37-40`) writes the legacy two files with no ledger. Assert the retained generation is **byte-identical before and after**, the next load adopts and is `.complete`, and no divergence fires.
* **Hardlink regression guard:** after a save, `cp` an unrelated file onto `meetings.json` and assert every `<stem>.history/g-*.json` still holds its recorded bytes. This is the test that pins the single most-cited fatal flaw in the rejected designs.
* **F211 guard:** after a save, assert `io.identity(primaryURL)` is unchanged from what `memory.remember` recorded, so nothing in the protocol disturbs the primary's `ctime` after install.
* **Divergence:** construct all five conditions and assert `.divergentGenerations`; then break each one in turn and assert `.complete` + the right `StoreRepair`. Five negative cases, one positive.

### 9.5 Existing tests, walked

| test | result |
|---|---|
| `recoversPreviousJSONCopy` (`:15`) | save 1 seeds both files; save 2 rotates gen 1 into the backup; an atomic corruption of the primary leaves it undecodable so divergence rule 3 (primary decodes) fails; F187 ladder ⇒ `.recoveredFromBackup`, value = gen 1, and `Data(contentsOf: backupURL)` decodes to it. **Passes unchanged.** |
| `saveAfterUnreadableLoadPreservesOriginalBytes` (`:37`) | both undecodable ⇒ both quarantined at `quarantine`; `rotateBackup` takes the third row (seed from staging); 2 quarantine files with the exact bytes. **Passes unchanged.** |
| `saveRefusesWhenQuarantineFails` (`:56`) | `prepareDirectory` is a no-op on the existing `0o500` dir; `encode` succeeds; `classify` reads; `quarantine` throws exactly `StoreQuarantineError.couldNotPreserve("meetings.json")` before any write, and the primary bytes are unchanged. **Passes unchanged** — which is why `<stem>.history/` is created lazily and not in `prepareDirectory`. |
| `unreadableLoadNamesItsQuarantine` (`:88`) | unchanged path. **Passes unchanged.** |
| `salvageKeepsReadableRecords` (`:125`) | unchanged path. **Passes unchanged.** |
| `saveDoesNotLetItsWriteMemoryMaskAForeignCorruption` (`:161`) | the foreign atomic write moves the inode ⇒ memory miss ⇒ read + decode fails ⇒ quarantined; the backup is proven and is not quarantined ⇒ `quarantined.count == 1`. **Passes unchanged.** |
| `saveUsesTheForeignGenerationAsBackupNotItsCachedBytes` (`:190`) | after save 1, `backup == ledger.current`, so the foreign valid primary hits CAS rule 8 ⇒ adopt (not conflict); `rotateBackup` clones the foreign primary into the backup byte-exactly; reload returns "Next". **Passes unchanged.** |
| `SuspectEmptyIndexTests.swift:157` byte-exact `Data("[]".utf8)` | a refused mutation still writes absolutely nothing, and the ledger is a sibling file. **Passes unchanged.** |
| the ~40 hand-written two-file fixtures (`DegradedLibraryTests:11-12/57`, `VocabularyCapTests:53-56/84-85/116-125/137-146`, `MeetingSalvageTests:29-37`, `SuspectEmptyIndexTests`, `NotesSidecarTests:264-265`, `DictationLogFailureTests:15`, `MediaSourceSchemaTests:27`) | every one writes a library with no ledger ⇒ migration case 1 ⇒ pre-F190 behaviour. **Pass unchanged.** |
| every `persistCount` assertion (`DegradedLibraryTests:120/127/138/152/163/170/240`, `NotesEditCoalescingTests:20-29`, `TranscriptEditCoalescingTests:23-35`, `SuspectEmptyIndexTests:152-155`, `VocabularyCapTests:66-71`) | `persistCount += 1` stays at `MeetingStore.swift:684`, before the save, and keeps meaning "attempted". **Pass unchanged.** |
| `BackupCoordinatorTests` exact copied/skipped counts | **must be updated** (§6.2). |

---

## 10. Caller-side changes

These are **more dangerous than the store change** and must land as their own commit, with their own tests, **before** the store change, so a bisect can separate "the new protocol is wrong" from "the delete path is wrong".

### 10.1 `MeetingStore`

**Lease, at init, once.** After the existing `createDirectory(rootDirectory)` (so the lock's `open` cannot fail with `ENOENT` on a first launch) and before the three loads:

```swift
private let leaseHandle: LibraryWriterLeaseHandle
@Published private(set) var writerLease: StoreWriterLease
```

Published as a **non-blocking advisory** ("Another copy of WhisperMeet has this library open. Your edits are protected: a conflicting save is refused and preserved, never silently discarded."). It **never** sets `health`.

**Tokens.** `private var meetingsToken: GenerationToken?`, `vocabularyToken`, `rulesToken`. Seeded from each `load()`, refreshed from each successful `SaveOutcome`, and threaded into every `save(expecting:)`. Without this the CAS never fires and the ticket is not satisfied.

**Seams.** Inject `recordCount: { $0.count }` into all three stores and `lease: leaseHandle.lease`.

**Persist methods return `Bool`:**

```swift
@discardableResult private func persistMeetings() -> Bool {
    persistCount += 1                              // UNCHANGED position and meaning: "attempted"
    do {
        let outcome = try meetingFiles.save(meetings, expecting: meetingsToken)
        meetingsToken = outcome.token
        persistCommitCount += 1                    // NEW counter; existing assertions untouched
        unsavedChanges = false
        writeConflict = nil
        storageErrorMessage = nil
        return true
    } catch let error as BackupJSONStoreError {
        unsavedChanges = true
        if case .generationConflict = error { writeConflict = WriteConflictReport(error) }
        if case .generationConflictNotPreserved = error { writeConflict = WriteConflictReport(error) }
        storageErrorMessage = "Meeting changes could not be saved. The recording files and last readable index copy remain on this Mac. \(error.localizedDescription)"
        return false
    } catch {
        unsavedChanges = true
        storageErrorMessage = "Meeting changes could not be saved. The recording files and last readable index copy remain on this Mac. \(error.localizedDescription)"
        return false
    }
}
```

The same shape for `persistVocabulary()` and `persistReplacementRules()` — **all three**, not only meetings. Their failure paths today have no dirty flag, no retry and no quit-time flush.

**The three `storageErrorMessage` clobbers are fixed** (`:598`, `:605`, `:610`). Today the most destructive save failure in the app produces no user-visible message at all, and without this none of F190's states can reach the user:

```swift
// :598 and :605 — append to, never replace, a save failure
// :610 — was: storageErrorMessage = nil
if saved { storageErrorMessage = nil }
```

**`delete(id:)` keeps today's order — deliberately.**

```swift
guard mutationIsAllowed() else { return }          // still the first statement (F187)
guard let meeting = meeting(id: id) else { return }
…                                                  // path-escape branch unchanged, message appended
do { try removeRecordingDirectory(directory) } catch { … return }   // unchanged
meetings.removeAll { $0.id == id }
let saved = persistMeetings()
if saved { storageErrorMessage = nil }             // ← the only change on this line
```

> **Why not persist-then-delete.** Three of the twelve critiques independently found that inverting the order resurrects deleted meetings: a failed `removeRecordingDirectory` leaves an unindexed folder, `orphanedRecordings()` reports it, and `AppModel.swift:832` upserts it back as a "Recovered Meeting" stub **with its audio** — a possibly sensitive recording the user explicitly deleted, reappearing. Today's order fails toward a *dangling index entry* (a meeting listed whose audio is gone), which the app already tolerates and the user can delete again. The dangling entry is strictly the better failure.
> The original reason to invert was that a lock-busy save would be a new terminal failure after the audio was destroyed. **That reason is gone:** there is no lock acquisition on the save path at all, and a CAS conflict preserves the body to disk and sets `unsavedChanges` with the message standing. Keeping the order removes an entire class of regression risk from the most destructive path in the app.

**`flushPendingEdits()` stops dropping the edit, with a one-shot retry:**

```swift
func flushPendingEdits() {
    guard mutationIsAllowed() else { return }
    flushPendingNotesSidecars()
    if pendingIndexFlush == nil {
        if unsavedChanges { _ = persistMeetings() }       // NEW: the dirty-flag re-attempt
        return
    }
    let task = pendingIndexFlush
    task?.cancel()
    if persistMeetings() {
        pendingIndexFlush = nil                            // cleared ONLY on success
    } else {
        pendingIndexFlush = nil
        unsavedChanges = true                              // ONE-SHOT: no re-arm, no loop
    }
}
```

> **No unbounded re-arm.** `if !persistMeetings() { scheduleDebouncedPersist() }` would re-encode 2.1 MB on the main actor every `transcriptWriteDebounce` forever on a full volume, and it can never clear a CAS conflict (the same stale token is refused identically). The retry instead happens at (a) the head of the next mutator via `unsavedChanges`, (b) the explicit **Try Again** button, (c) `AppModel.flushPendingWrites()` at `willTerminate`/`willResignActive`. The value is never silently dropped: it is still in `meetings`, `unsavedChanges` is visible, and a CAS-refused body is already on disk as a conflict branch.

**New published state and API:**

```swift
@Published private(set) var unsavedChanges: Bool = false
@Published private(set) var writeConflict: WriteConflictReport?
private(set) var persistCommitCount = 0

func retryPendingPersist()                                  // the "Try Again" button
func resolveWriteConflict(_ choice: WriteConflictResolution) // .reloadFromDisk | .keepMine
func retainedIndexGenerations() -> [RetainedGeneration]
func restoreIndexGeneration(_ fingerprint: String)          // see below
```

`ContentView`'s single alert (`:129-150`) gains a **Try Again** button while `unsavedChanges`, and a two-button conflict sheet while `writeConflict != nil`.

**The one sanctioned exception to `mutationIsAllowed()`.** `restoreIndexGeneration(_:)` is the only method permitted to write while `isDegraded`, because a read-only state with no exit is itself the F187 failure. It (a) requires an explicit user choice, (b) re-verifies the fingerprint before decoding, (c) goes through the ordinary write algorithm so both live files are quarantined and the restore becomes its own generation, and (d) does **not** upgrade `health` in-process — `degrade(to:)` stays monotone and the app asks the user to relaunch, after which the load is clean. Write this exception down in the method's doc comment with that reasoning, next to `mutationIsAllowed()`'s "MUST be the first statement of every mutator".

### 10.2 `DictationLogStore`

Its own doc comment (`:60-75`) says: *"Split the property into load- and save-error channels before loosening any of them."* This ticket touches part 1 of that invariant's neighbourhood, so:

```swift
@Published private(set) var loadErrorMessage: String?     // set only in init, as today
@Published private(set) var saveErrorMessage: String?     // NEW
@Published private(set) var unsavedChanges: Bool = false
private var token: GenerationToken?
```

`persist()` switches on the outcome rather than treating a non-throwing return as success — which is correct because of §0 decision 3: `save()` returns normally **iff** the value is durable. `health` is still assigned **only in `init`**; a save-time conflict sets `saveErrorMessage` + `unsavedChanges`, never `health`. All three parts of the documented invariant survive intact.

`DictationLogStore` gains `retryPendingPersist()`, called from `AppModel.flushPendingWrites()` (`:1850`) alongside `store.flushPendingEdits()` — today the dictation log has **no** quit-flush path at all. It passes `retention: .dictationLog`.

### 10.3 `AppModel`

* `flushPendingWrites()` also calls `logStore.retryPendingPersist()`.
* `backUpLibrary()` calls `store.flushPendingEdits()` first and guards on `!store.unsavedChanges`.
* No change to any `isDegraded` / `libraryAcceptsChanges` guard — that is the point of §0 decision 2.

---

## 11. Facts verified on this machine

Run under `import Foundation` only, on the boot APFS volume, 2026-09-12.

| claim | result |
|---|---|
| `FileManager.copyItem`, 2.1 MB | **0.371 ms**, **distinct inode** |
| `cp other.json a.json` where `clone.json` was a `copyItem` of `a.json` | **clone survived intact** |
| `link(2)` then `cp other.json h.json` | **hardlinked copy destroyed** |
| `link(2)` effect on the source's `st_ctime` | **changed** (F211's identity tuple includes ctime) |
| `Data(contentsOf:)`, 2.1 MB, warm | 1.19 ms |
| `Data.write(options: .atomic)`, 2.1 MB | 3.22 ms |
| 4-lane fingerprint, 2.1 MB | **0.403 ms (5.2 GB/s)**; 1-lane: 2.59 ms |
| `JSONEncoder` `[.prettyPrinted, .sortedKeys]` / `JSONDecoder`, 2.1 MB | 11.29 ms / 3.24 ms |
| two `open()` + `flock(LOCK_EX\|LOCK_NB)` in **one** process | first `0`, second `-1`, `errno 35` (EWOULDBLOCK) |
| `flock(LOCK_EX)` on an `O_RDONLY` descriptor | `0` (succeeds) |
| `open` on a `0o000` file | `EACCES` for **both** `O_RDWR` and `O_RDONLY` |
| `FileManager.copyItem` onto an existing destination | throws `NSError` 516 (`NSFileWriteFileExistsError`) |
| `open`/`flock`/`stat`/`chmod`/`getuid` under `import Foundation` alone | compiles — **no new purity exception** |

---

## 12. Rejected alternatives, and why

**A write-ahead journal holding the new body (the "journal" design).** A third 2.1 MB write per save (+3–5 ms, +5–20 ms with `fsync`), a second artifact to keep consistent with the commit record, and a commit that asserts a generation whose bytes were deliberately never synced. Replaced by: *the content-addressed history entry is the intent record*, written before the primary is installed, at clone cost. One artifact, two jobs.

**`link(2)` EEXIST as a cross-process compare-and-swap.** Elegant, but it makes a hard link a mandatory terminal step: on exFAT/SMB or a managed network home `link` returns `EPERM`/`ENOTSUP` and **every save fails forever**. Replaced by a content CAS, which needs no filesystem capability at all.

**Hardlinking the live files into history, or making `meetings.backup.json` a hardlink of a history entry (the "generations" and "minimal" designs).** Measured fatal: `cp`, a shell redirect, `rsync --inplace`, an in-place editor save, or a non-atomic `Data.write(to:)` onto the live name rewrites the archive through the shared inode — including the app's own documented recovery gesture. Also `link(2)` bumps `ctime`, voiding F211's memory on every save. Replaced by independent `copyItem` clones.

**Rotating by `rename(primary → backup)`.** Free and atomic, but it creates a window in which `meetings.json` does not exist (an older bundle reading there loads `.recoveredFromBackup` and opens read-only; `BackupCoordinator` can snapshot a set without it), and it *unlinks* the backup — so an undecodable primary can displace a decodable backup, which is exactly the rule `BackupJSONStore.swift:194` exists to prevent. Replaced by clone + rename, which is also O(1) on APFS.

**Making the lock the correctness mechanism, blocking or otherwise.** Serialization alone cannot prevent a lost update: two instances each holding the whole array in memory will overwrite each other in *some* order, and a mutex only chooses which. Only a compare-and-swap on content knows that the loser derived from a generation that is no longer current. This is also why the F190 prototype's per-save lock was correctly not shipped.

**A read-only second instance (`notTheWriter` as a health state).** `allowsMutation == false` routes straight into F187's gates: `recordingDirectory(for:)` throws, `orphanedRecordings()` returns `[]`, and the user is shown *"WhisperMeet could not fully read your meeting library… the unreadable index was copied aside"* — which is false, and the postmortem's lesson 5 is that an error message is a promise. On a false positive (a stale lease on a network volume, a uid mismatch) that is real harm. Enforcing one instance belongs to F188; F190 delivers the weaker but honest guarantee that a second writer cannot *silently* discard the first's changes.

**Degrading health on a save-time conflict.** `AppModel.startRecording` pre-flights `!store.isDegraded` and then relies on that answer for the whole recording; a mid-session degrade makes `stopRecording`'s `upsert` silently return while `orphanedRecordings()` returns `[]` — a finished meeting on disk that no surface will ever show. Replaced by a separate non-health channel.

**Inverting `delete(id:)` to persist-then-delete.** See §10.1: it resurrects deleted recordings as stubs through `orphanedRecordings()` → `AppModel.swift:832`, and its motivating failure (a lock-busy save after the audio is gone) no longer exists.

**Unbounded re-arm of a failed debounced flush.** A permanently failing volume turns into a forever loop of 2.1 MB main-actor encodes, and it cannot clear a CAS conflict anyway. Replaced by a one-shot dirty flag with three explicit retry points.

**Subclassing `FileManager` for the IO seam.** `FileManager` has no API the current code uses for file *contents*; routing through `contents(atPath:)`/`createFile(atPath:contents:)` loses `.atomic`'s temp-then-rename, which F187's preserve rule, F211's inode identity and this design's install step all depend on. It also cannot intercept the raw `stat()`, and `FileManager` is not `Sendable`.

**Inferring the fault-injection phase from URL suffixes.** `rename` serves both `install` and `rotateBackup`; `writeAtomically` serves both `stage` and `commit`. Suffix matching cannot tell them apart, so the phase is passed explicitly by the production code.

**Generation metadata inside the payload.** The roots are arrays; there is nowhere to add a field without retyping the root, which is the exact change that cost a user's library (F177 → 2026-08-14) and is forbidden by `AGENTS.md:378`.

**SHA-256 for the fingerprint.** CryptoKit is a framework import barred from WhisperCore; a vendored pure-Swift SHA-256 costs an order of magnitude more and would become a correctness-critical hand-rolled crypto primitive whose production and test implementations differ. The threat model is accident, not forgery, and this is written down in the type's doc comment.

**`fsync` / `F_FULLFSYNC` per save.** Tens of milliseconds on the main actor for 2.1 MB — the entire latency budget — to defend a fault class (power loss with rename reordering) that recovery already handles as two enumerated, non-destructive states. Named as an accepted limit below.

---

## 13. What this does **not** solve

**F188 — format fence and single-instance enforcement.**
F190 does not stop a downgraded bundle from writing a payload a newer bundle cannot read; the 2026-08-14 wipe file would still be *structurally* a perfect lineal child and would be adopted with only a `StoreRepair` note. What changes is that the pre-wipe generations survive in `<stem>.history/` and are restorable in one call instead of being gone. Prevention needs a format/version fence and a library-instance guard, both F188. F190 also does not make a second instance read-only.

**F191 — `BackupCoordinator`'s torn read and restore.**
The plan-hash (`:169`) → copy (`:94`) → verify (`:95`) window is mitigated here (flush + guard + one retry) but not closed; the real fix is hashing during the copy. There is also still no in-app restore-from-backup flow. `<stem>.history/` is deliberately outside backups.

**F192 — the recovery surface, and retention privacy.**
F190 ships the *mechanism* (`retainedGenerations()`, `value(ofGeneration:)`, `restore(generation:)`, `MeetingStore.restoreIndexGeneration`) plus the documented manual procedure in `RECOVERY.md`. It does not ship the picker UI that shows *"42 · 0 meetings · 3 min ago"* beside *"41 · 17 meetings · yesterday"*, which is what makes the mechanism usable by a non-technical user. **Privacy trade, named explicitly:** retained generations keep the content of deleted meetings — transcripts, notes, summaries — for a bounded window (the newest 3 saves, the hour/day/week anchors, and the high-water pin). "Delete" therefore does not immediately erase every copy. The bound is the `byteBudget` and the anchors; a *shred on delete* / *forget history* command belongs to F192 and should be filed with this design.

**Semantic detection.** Nothing in this write protocol can tell a valid-but-wrong generation from a valid one. Only `MeetingStore`'s `.suspectEmpty` check does any semantic work, and it is unchanged. F190's guarantee is recoverability, not detection — say so plainly in the ticket.

**Field-level merge.** `save()` persists a whole value; there is no generic way to merge two `[MeetingRecord]` arrays. Conflict resolution is therefore "keep mine" or "take theirs", with **both** branches on disk. A real three-way merge would need per-record storage (the postmortem's open decision #2) and is not this ticket.

**Power-loss durability.** No `fsync` anywhere. A power cut can leave the ledger ahead of the body; recovery handles it (§4) by falling back to what is actually present and reporting `.ledgerAheadOfBody`. The threat this design is built for is process death and competing bundles.

**`expecting: nil` is a real hole.** A future caller that constructs a `BackupJSONStore` and saves without loading gets today's last-writer-wins silently. `MeetingStore` and `DictationLogStore` always load in `init`, so it does not bite today. A stricter API would return the store *from* the load; that churns 13 call sites and is deliberately out of scope. Note it in the `expecting:` doc comment.

**Non-APFS volumes.** Retention degrades from an O(1) clone to a real byte copy, and the save cost lands near today's rather than below it. `historyAvailable` reports it honestly, retention is never fatal, and no correctness property depends on clone support.