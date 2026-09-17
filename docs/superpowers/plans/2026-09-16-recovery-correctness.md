# Recovery Correctness Implementation Plan (F255, F256)

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop recovery from stranding a finished meeting behind a rebuild of a live folder (F255), and stop a mid-file read error from being written as silence and reported as a success (F256).

**Architecture:** Two independent fixes in `InterruptedRecordingRecovery` and its one production caller. F255 adds a pure predicate over `StoreWriterLease` and consults it once before `AppModel.performStartupRecovery`'s orphan loop. F256 makes the raw-track read throwing, extracts the mix loop behind three injected closures so an I/O error can be simulated, and gives truncation a floor so a zero-length rebuild throws instead of indexing an empty meeting.

**Tech Stack:** Swift 6 (language mode 5), SwiftPM, Swift Testing (`@Test`/`#expect`), two targets — `WhisperCore` (Foundation-only) and `WhisperMeet` (app).

**Spec:** `docs/superpowers/specs/2026-09-16-recovery-correctness-design.md`

## Global Constraints

- **WhisperCore purity rule:** no AppKit/SwiftUI/ScreenCaptureKit import in `Sources/WhisperCore`. `MeetingRecord` lives in `Sources/WhisperMeet/MeetingStore.swift` and stays there.
- **Swift tools version is 6.1** (`Package.swift`). Do not raise it — CI's `macos-15` runner ships Swift 6.1.0 (F270).
- **Tests are Swift Testing**, not XCTest. `--filter` matches the Swift *function* name, not the `@Test("…")` display string, and a filter matching nothing still exits 0 — always confirm the test count.
- **Run the suite** with the framework flags, or via `Scripts/quality-check.sh`:
  ```bash
  FW=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
  LIB=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
  swift test --disable-sandbox --no-parallel \
    -Xswiftc -F -Xswiftc "$FW" -Xlinker -rpath -Xlinker "$FW" -Xlinker -rpath -Xlinker "$LIB"
  ```
- **A green local gate proves nothing about CI.** After any push, run `gh run list --limit 1`; a run finishing in under a minute tested nothing (F270).
- **Never use the user's recordings or transcripts in a fixture** — synthetic data only (AGENTS.md).
- **Ticket discipline:** F255 and F256 are already `in-progress`, owned by whisper-62. Mention the ticket ID in every commit. Run `python3 Scripts/generate-tickets-dashboard.py --check` before handing off.

---

## File Structure

| File | Responsibility | Change |
|---|---|---|
| `Sources/WhisperCore/InterruptedRecordingRecovery.swift` | Rebuild policy, raw-track IO, the mix, the manifest | Modify — predicate, throwing read, `mixTracks`, truncation floor |
| `Sources/WhisperMeet/AppModel.swift` | Startup recovery orchestration | Modify — gate before the orphan loop; short-prefix handling; set `recoveryWarning` |
| `Sources/WhisperMeet/MeetingStore.swift` | `MeetingRecord` | Modify — one optional field |
| `Sources/WhisperMeet/ContentView.swift` | Meeting detail | Modify — render the warning beside `alignmentWarning` |
| `Tests/WhisperCoreTests/RecoveryRebuildGateTests.swift` | F255 predicate | Create |
| `Tests/WhisperCoreTests/RecoveryTruncationTests.swift` | F256 mix + floor | Create |
| `Tests/WhisperMeetTests/OrphanRebuildLeaseGateTests.swift` | F255 wiring | Create |
| `Tests/WhisperMeetTests/RecoveryWarningPersistenceTests.swift` | F256 field + schema | Create |

---

### Task 1: The rebuild-permission predicate (F255)

**Files:**
- Modify: `Sources/WhisperCore/InterruptedRecordingRecovery.swift`
- Test: `Tests/WhisperCoreTests/RecoveryRebuildGateTests.swift` (create)

**Interfaces:**
- Consumes: `StoreWriterLease` from `Sources/WhisperCore/LibraryWriterLease.swift` — cases `.held(realm: String)`, `.heldElsewhere(realm: String)`, `.unavailable(reason: String)`, `.unmanaged`.
- Produces: `InterruptedRecordingRecovery.mayRebuildInterruptedRecordings(_ lease: StoreWriterLease) -> Bool`, used by Task 2.

- [x] **Step 1: Write the failing test**

Create `Tests/WhisperCoreTests/RecoveryRebuildGateTests.swift`:

```swift
import Foundation
import Testing
@testable import WhisperCore

// F255 — only the instance that owns the library may rebuild an interrupted recording.
//
// While a capture runs, its folder holds two growing `.f32` tracks and no finalized recording,
// which is structurally identical to an interrupted one. A second instance that rebuilds it writes
// `meeting-recovered.wav` into the live folder and indexes that, so when the first instance
// finishes and writes the complete `meeting.wav`, nothing points at it — the real recording is
// stranded. The lease already distinguishes the only case that matters: a live second instance
// never holds it, and a crashed first instance had its lease released by the kernel.

@Test("An instance that holds the lease may rebuild")
func heldLeaseMayRebuild() {
    #expect(InterruptedRecordingRecovery.mayRebuildInterruptedRecordings(.held(realm: "shared")))
}

@Test("An instance that does NOT hold the lease must not rebuild")
func leaseHeldElsewhereMustNotRebuild() {
    #expect(
        !InterruptedRecordingRecovery.mayRebuildInterruptedRecordings(.heldElsewhere(realm: "shared"))
    )
}

@Test("A library where no lease could be taken still rebuilds — fail open, deliberately")
func unavailableLeaseFailsOpen() {
    // Refusing here would permanently disable recovery on a volume without `flock`, which is a
    // worse defect than the one this gate closes. It also keeps F190's Invariant L intact in
    // spirit: the lease stays advisory, and this gate only defers recovery, never bricks a library.
    #expect(
        InterruptedRecordingRecovery.mayRebuildInterruptedRecordings(.unavailable(reason: "no flock"))
    )
}

@Test("An unmanaged lease still rebuilds, so fixtures and tests are unaffected")
func unmanagedLeaseMayRebuild() {
    #expect(InterruptedRecordingRecovery.mayRebuildInterruptedRecordings(.unmanaged))
}
```

- [x] **Step 2: Run it and watch it fail**

```bash
FW=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
LIB=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
swift test --disable-sandbox --no-parallel -Xswiftc -F -Xswiftc "$FW" \
  -Xlinker -rpath -Xlinker "$FW" -Xlinker -rpath -Xlinker "$LIB" \
  --filter "heldLeaseMayRebuild|leaseHeldElsewhereMustNotRebuild|unavailableLeaseFailsOpen|unmanagedLeaseMayRebuild"
```

Expected: build failure — `type 'InterruptedRecordingRecovery' has no member 'mayRebuildInterruptedRecordings'`.

- [x] **Step 3: Implement it**

In `Sources/WhisperCore/InterruptedRecordingRecovery.swift`, immediately after the two `private static let` filename constants at the top of the enum:

```swift
    /// Whether this instance may rebuild an interrupted recording folder (F255).
    ///
    /// Refuses exactly one state. While a capture is running its folder is structurally identical
    /// to an interrupted one — `meeting.wav` is written only by `AudioCaptureEngine.stop()` — so a
    /// second instance would rebuild a LIVE folder and strand the recording that is still being
    /// made.
    ///
    /// What the lease discriminates, stated precisely: *another instance is open* versus *no other
    /// instance is open*. Not "recording" versus "died recording". That is enough here, because the
    /// defect requires a live second instance, and a crashed first instance had its lease released
    /// by the kernel — so the relaunch after a crash does hold it and does rebuild.
    ///
    /// `.unavailable` fails open on purpose: refusing would permanently disable recovery on a
    /// volume without `flock`, which is worse than the defect. This keeps the lease advisory in
    /// F190's Invariant L sense — the gate defers recovery, it never bricks a library.
    ///
    /// **Invariant this makes safety-critical: never call `LibraryWriterLock.acquire` outside
    /// `shared(for:)`.** Two `flock` acquisitions on one file contend within a single process, and
    /// only `MeetingStore` acquires today, via the memoizing `shared(for:)`, which is why the app
    /// never reports `.heldElsewhere` against itself. A future second acquirer — wiring
    /// `DictationLogStore`, or a session marker for F258 — would not merely mislabel a UI string;
    /// it would disable recovery of the user's own crashed recordings.
    public static func mayRebuildInterruptedRecordings(_ lease: StoreWriterLease) -> Bool {
        switch lease {
        case .heldElsewhere: return false
        case .held, .unavailable, .unmanaged: return true
        }
    }
```

- [x] **Step 4: Run it and watch it pass**

Same command as Step 2. Expected: `✔ Test run with 4 tests`.

- [x] **Step 5: Commit**

```bash
git add Sources/WhisperCore/InterruptedRecordingRecovery.swift \
        Tests/WhisperCoreTests/RecoveryRebuildGateTests.swift
git commit -m "feat(recovery): a pure predicate for who may rebuild an interrupted folder (F255)"
```

---

### Task 2: Consult the gate in the orphan loop (F255)

**Files:**
- Modify: `Sources/WhisperMeet/AppModel.swift` — `performStartupRecovery`, the `do { ... }` block that begins `let recover = recoverInterruptedRecording`
- Test: `Tests/WhisperMeetTests/OrphanRebuildLeaseGateTests.swift` (create)

**Interfaces:**
- Consumes: `InterruptedRecordingRecovery.mayRebuildInterruptedRecordings(_:)` from Task 1; `store.writerLease` (`@Published private(set) var writerLease: StoreWriterLease`, `MeetingStore.swift:316`).
- Produces: nothing for later tasks.

**Do NOT gate `AppModel.swift:1820`.** `InterruptedRecordingRecovery.recover` has a second call site inside `stopRecording`'s error path. That is this instance recovering *its own* folder after its own finalization failed, and since nothing gates `startRecording` on the lease, that instance may be holding `.heldElsewhere`. Gating it would stop a non-lease-holding instance recovering the recording it just made. Gate the loop, not the function.

- [x] **Step 1: Write the failing test**

Create `Tests/WhisperMeetTests/OrphanRebuildLeaseGateTests.swift`:

```swift
import Foundation
import Testing
@testable import WhisperMeet
@testable import WhisperCore

// F255 — a second live instance must not rebuild a folder the first one is still writing.
//
// Testing `.heldElsewhere` needs a specific recipe, because there is no seam: `writerLease` is
// `private(set)` with no setter, and a second `MeetingStore` on the same root gets the MEMOIZED
// handle and so reports `.held`. Acquire the lock FIRST, keep it alive, then construct the store.
// Do not "solve" this by widening `writerLease` to a settable var.

@Test("A live capture folder is not rebuilt while another instance holds the lease")
@MainActor
func liveFolderIsNotRebuiltByASecondInstance() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("WhisperMeetLeaseGate-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    // A folder that looks exactly like an interrupted capture: raw tracks, no finalized WAV.
    let id = UUID()
    let directory = root.appendingPathComponent("Recordings/\(id.uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let samples = [Float](repeating: 0.25, count: 48_000)
    try samples.withUnsafeBytes { try Data($0).write(to: directory.appendingPathComponent("system-audio.f32")) }

    // Another instance owns the library. `withExtendedLifetime` matters: the handle releases in
    // `deinit`, so letting it go out of scope would hand the lease straight back.
    let blocker = LibraryWriterLock.acquire(root: root)
    try withExtendedLifetime(blocker) {
        let store = MeetingStore(rootDirectory: root)
        #expect(store.writerLease == .heldElsewhere(realm: "shared"))
        #expect(!InterruptedRecordingRecovery.mayRebuildInterruptedRecordings(store.writerLease))
    }

    // The gate must leave the folder exactly as it found it: raw track intact, no rebuild.
    #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("system-audio.f32").path))
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("meeting-recovered.wav").path))
}

@Test("A meeting.wav that appears after a skipped rebuild is still recognised")
@MainActor
func aLaterFinishedRecordingIsStillUsable() throws {
    // The point of deferring rather than rebuilding: the real recording, once finalized by the
    // instance that owns it, must still be the one the library adopts.
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("WhisperMeetLeaseGateFinish-\(UUID().uuidString)", isDirectory: true)
    let directory = root.appendingPathComponent("Recordings/\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    // 44-byte header + one second of 16-bit mono at 48 kHz, written the way `stop()` finishes.
    var wav = Data()
    wav.append(contentsOf: Array("RIFF".utf8))
    wav.append(contentsOf: withUnsafeBytes(of: UInt32(36 + 96_000).littleEndian) { Array($0) })
    wav.append(contentsOf: Array("WAVEfmt ".utf8))
    wav.append(contentsOf: withUnsafeBytes(of: UInt32(16).littleEndian) { Array($0) })
    wav.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })
    wav.append(contentsOf: withUnsafeBytes(of: UInt16(1).littleEndian) { Array($0) })
    wav.append(contentsOf: withUnsafeBytes(of: UInt32(48_000).littleEndian) { Array($0) })
    wav.append(contentsOf: withUnsafeBytes(of: UInt32(96_000).littleEndian) { Array($0) })
    wav.append(contentsOf: withUnsafeBytes(of: UInt16(2).littleEndian) { Array($0) })
    wav.append(contentsOf: withUnsafeBytes(of: UInt16(16).littleEndian) { Array($0) })
    wav.append(contentsOf: Array("data".utf8))
    wav.append(contentsOf: withUnsafeBytes(of: UInt32(96_000).littleEndian) { Array($0) })
    wav.append(Data(repeating: 0, count: 96_000))
    try wav.write(to: directory.appendingPathComponent("meeting.wav"))

    let finished = try #require(InterruptedRecordingRecovery.finalizedRecording(in: directory))
    #expect(finished.source == .existingCapture)
    #expect(finished.duration == 1.0)
}
```

- [x] **Step 2: Run it and watch it fail**

```bash
swift test --disable-sandbox --no-parallel -Xswiftc -F -Xswiftc "$FW" \
  -Xlinker -rpath -Xlinker "$FW" -Xlinker -rpath -Xlinker "$LIB" \
  --filter "liveFolderIsNotRebuiltByASecondInstance|aLaterFinishedRecordingIsStillUsable"
```

Expected: `liveFolderIsNotRebuiltByASecondInstance` fails — without the gate nothing yet consults the lease, and the predicate call is the only thing asserting it. (If `LibraryWriterLock.acquire` is not visible, add `@testable import WhisperCore`, which the file already has.)

- [x] **Step 3: Wire the gate**

In `Sources/WhisperMeet/AppModel.swift`, inside `performStartupRecovery`, replace:

```swift
        do {
            let recover = recoverInterruptedRecording
            for orphan in try store.orphanedRecordings() {
```

with:

```swift
        do {
            let recover = recoverInterruptedRecording
            // F255: evaluated ONCE — the lease is loop-invariant, and testing it per folder would
            // append the same paragraph N times (messages are joined with a blank line below).
            //
            // While a capture is running, its folder holds only growing `.f32` tracks and no
            // finalized recording, so it is structurally identical to an interrupted one. Without
            // this, a second instance rebuilds the LIVE folder and indexes the partial result;
            // when the first instance finishes and writes `meeting.wav`, nothing points at it and
            // the real recording is stranded.
            //
            // Only the loop is gated. `recover` is also called from `stopRecording`'s error path
            // below, where this instance is recovering its OWN folder and may legitimately not
            // hold the lease — gating that would break it.
            let mayRebuild = InterruptedRecordingRecovery.mayRebuildInterruptedRecordings(
                store.writerLease
            )
            if !mayRebuild {
                messages.append(
                    "Another copy of WhisperMeet is open, so interrupted recordings were left untouched. Your audio is safe where it is. Quit the other copy and reopen WhisperMeet to finish recovering them."
                )
            }
            for orphan in try mayRebuild ? store.orphanedRecordings() : [] {
```

- [x] **Step 4: Run it and watch it pass**

Same command as Step 2. Expected: `✔ Test run with 2 tests`.

- [x] **Step 5: Run the whole suite, then commit**

```bash
swift test --disable-sandbox --no-parallel -Xswiftc -F -Xswiftc "$FW" \
  -Xlinker -rpath -Xlinker "$FW" -Xlinker -rpath -Xlinker "$LIB"
git add Sources/WhisperMeet/AppModel.swift Tests/WhisperMeetTests/OrphanRebuildLeaseGateTests.swift
git commit -m "fix(recovery): never rebuild a folder another live instance owns (F255)"
```

---

### Task 3: Extract the mix loop behind injected closures (F256)

**Files:**
- Modify: `Sources/WhisperCore/InterruptedRecordingRecovery.swift` — the `while writtenFrames < totalFrames` loop
- Test: `Tests/WhisperCoreTests/RecoveryTruncationTests.swift` (create)

**Interfaces:**
- Produces, used by Task 4:
  ```swift
  static func mixTracks(
      totalFrames: Int64,
      chunkSize: Int64,
      readSystem: (Int) throws -> [Float],
      readMicrophone: (Int) throws -> [Float],
      write: ([Int16]) throws -> Void
  ) rethrows -> (writtenFrames: Int64, truncation: (frame: Int64, error: any Error)?)
  ```
  **Three** closures, not two: the loop writes each chunk as it goes, so a two-closure version would have to return all the PCM — 345 MB for a 60-minute meeting, where the current code streams.

- [x] **Step 1: Write the failing test**

Create `Tests/WhisperCoreTests/RecoveryTruncationTests.swift`:

```swift
import Foundation
import Testing
@testable import WhisperCore

// F256 — a read error partway through a raw track must truncate, not become silence.
//
// `RawFloatReader.read` returned zero-filled samples for BOTH a genuine I/O error and end of file.
// EOF zero-padding is intended (one track is routinely shorter); an I/O error is data loss. Because
// `totalFrames` comes from the file SIZE, the loop ran to the declared length and wrote silence for
// every remaining chunk, then reported success. A real I/O error cannot be produced with a real
// file and permission tricks are flaky, so the loop takes its reads and its write as closures.

private struct ReadFailure: Error {}

@Test("A clean mix writes every frame and reports no truncation")
func cleanMixWritesEverything() throws {
    var written: [Int16] = []
    let result = try InterruptedRecordingRecovery.mixTracks(
        totalFrames: 300,
        chunkSize: 100,
        readSystem: { [Float](repeating: 0.5, count: $0) },
        readMicrophone: { [Float](repeating: 0.0, count: $0) },
        write: { written.append(contentsOf: $0) }
    )
    #expect(result.writtenFrames == 300)
    #expect(result.truncation == nil)
    #expect(written.count == 300)
}

@Test("A read error truncates at the failing chunk and keeps the readable prefix")
func readErrorTruncatesAtTheFailingChunk() throws {
    var written: [Int16] = []
    var call = 0
    let result = try InterruptedRecordingRecovery.mixTracks(
        totalFrames: 1_000,
        chunkSize: 100,
        readSystem: { count in
            call += 1
            if call == 3 { throw ReadFailure() }   // fails on the third chunk
            return [Float](repeating: 0.5, count: count)
        },
        readMicrophone: { [Float](repeating: 0.0, count: $0) },
        write: { written.append(contentsOf: $0) }
    )
    // Exactly two chunks survive — not 1,000 frames with 800 of silence.
    #expect(result.writtenFrames == 200)
    #expect(written.count == 200)
    #expect(result.truncation?.frame == 200)
    #expect(result.truncation?.error is ReadFailure)
}

@Test("Either track failing truncates the mix")
func microphoneFailureAlsoTruncates() throws {
    var call = 0
    let result = try InterruptedRecordingRecovery.mixTracks(
        totalFrames: 500,
        chunkSize: 100,
        readSystem: { [Float](repeating: 0.5, count: $0) },
        readMicrophone: { count in
            call += 1
            if call == 2 { throw ReadFailure() }
            return [Float](repeating: 0.1, count: count)
        },
        write: { _ in }
    )
    // The output is one mixed stream, so it stops where EITHER side became unreadable. Keeping one
    // channel past that point would silently change the mix from two channels to one partway
    // through.
    #expect(result.writtenFrames == 100)
    #expect(result.truncation?.frame == 100)
}

@Test("A failure on the very first chunk writes nothing at all")
func firstChunkFailureWritesNothing() throws {
    var written: [Int16] = []
    let result = try InterruptedRecordingRecovery.mixTracks(
        totalFrames: 500,
        chunkSize: 100,
        readSystem: { _ in throw ReadFailure() },
        readMicrophone: { [Float](repeating: 0.0, count: $0) },
        write: { written.append(contentsOf: $0) }
    )
    #expect(result.writtenFrames == 0)
    #expect(written.isEmpty)
    #expect(result.truncation?.frame == 0)
}
```

- [x] **Step 2: Run it and watch it fail**

```bash
swift test --disable-sandbox --no-parallel -Xswiftc -F -Xswiftc "$FW" \
  -Xlinker -rpath -Xlinker "$FW" -Xlinker -rpath -Xlinker "$LIB" \
  --filter "cleanMixWritesEverything|readErrorTruncatesAtTheFailingChunk|microphoneFailureAlsoTruncates|firstChunkFailureWritesNothing"
```

Expected: build failure — no member `mixTracks`.

- [x] **Step 3: Implement `mixTracks`**

Add to `InterruptedRecordingRecovery`, above `recover(in:sampleRate:)`:

```swift
    /// Mixes the two raw tracks into 16-bit PCM, stopping at the first unreadable chunk (F256).
    ///
    /// Reads and the write are injected so a genuine I/O error can be simulated — it cannot be
    /// produced with a real file, and revoking permissions mid-read is flaky. The write is a
    /// closure too, not just the reads: the loop streams each chunk out as it goes, and returning
    /// the PCM instead would mean holding 345 MB in memory for a 60-minute meeting.
    ///
    /// Truncation is RETURNED rather than rethrown, so the caller can still finalize the readable
    /// prefix; the underlying error travels with it for the message.
    static func mixTracks(
        totalFrames: Int64,
        chunkSize: Int64,
        readSystem: (Int) throws -> [Float],
        readMicrophone: (Int) throws -> [Float],
        write: ([Int16]) throws -> Void
    ) rethrows -> (writtenFrames: Int64, truncation: (frame: Int64, error: any Error)?) {
        var writtenFrames: Int64 = 0
        while writtenFrames < totalFrames {
            let count = Int(min(chunkSize, totalFrames - writtenFrames))
            let systemSamples: [Float]
            let microphoneSamples: [Float]
            do {
                systemSamples = try readSystem(count)
                microphoneSamples = try readMicrophone(count)
            } catch {
                // One mixed stream, so it stops where EITHER track became unreadable.
                return (writtenFrames, (writtenFrames, error))
            }
            var pcm = [Int16](repeating: 0, count: count)
            for index in pcm.indices {
                let systemSample = systemSamples[index]
                let microphoneSample = microphoneSamples[index]
                let bothActive = abs(systemSample) > 0.01 && abs(microphoneSample) > 0.01
                let mixed = bothActive
                    ? (systemSample + microphoneSample) * 0.5
                    : (systemSample + microphoneSample) * 0.95
                pcm[index] = Int16(max(-1, min(1, mixed)) * Float(Int16.max))
            }
            try write(pcm)
            writtenFrames += Int64(count)
        }
        return (writtenFrames, nil)
    }
```

- [x] **Step 4: Run it and watch it pass**

Same command as Step 2. Expected: `✔ Test run with 4 tests`.

- [x] **Step 5: Commit**

```bash
git add Sources/WhisperCore/InterruptedRecordingRecovery.swift \
        Tests/WhisperCoreTests/RecoveryTruncationTests.swift
git commit -m "refactor(recovery): extract the mix loop so an I/O error can be tested (F256)"
```

---

### Task 4: Throwing reads, the truncation floor, and truncation on the result (F256)

**Files:**
- Modify: `Sources/WhisperCore/InterruptedRecordingRecovery.swift` — `RawFloatReader.read`, `recover(in:sampleRate:)`, `RecoveredRecording`
- Test: `Tests/WhisperCoreTests/RecoveryTruncationTests.swift` (append)

**Interfaces:**
- Consumes: `mixTracks` from Task 3.
- Produces, used by Task 5: `RecoveredRecording.truncatedAtSeconds: TimeInterval?` — `nil` unless the rebuild stopped early.

`RecoveredRecording` has no explicit `init`, so the new property **must** carry `= nil` or all four construction sites break, including `Tests/WhisperMeetTests/StartupRecoveryResilienceTests.swift`.

- [x] **Step 1: Write the failing test**

Append to `Tests/WhisperCoreTests/RecoveryTruncationTests.swift`:

```swift
@Test("A rebuild that can read nothing throws instead of indexing an empty meeting")
func zeroReadableFramesThrows() throws {
    // The floor. Without it: `writtenFrames == 0` gives a 44-byte WAV that `wavDuration` refuses,
    // yet `recover` still returns a result, `AppModel`'s `duration <= 0` rescue is gated on
    // `.importedRecording` and does not fire, and a duration-0 meeting is indexed with the ORDINARY
    // "recovered" message. Its UUID then sits in `indexedIDs`, so `orphanedRecordings()` excludes
    // the folder permanently and the intact `.f32` tracks are stranded with no route back —
    // strictly worse than the bug this ticket fixes.
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("RecoveryFloor-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    // A track whose declared size promises frames the file cannot supply: `frameCount` reads the
    // SIZE, so `totalFrames` is non-zero while the first read fails.
    let path = directory.appendingPathComponent("system-audio.f32")
    try Data(repeating: 0, count: 4_000).write(to: path)
    try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: path.path)
    defer { try? FileManager.default.setAttributes([.posixPermissions: 0o644], ofItemAtPath: path.path) }

    #expect(throws: (any Error).self) {
        _ = try InterruptedRecordingRecovery.recover(in: directory)
    }
    // Nothing was indexed and nothing was left behind pretending to be a recording.
    #expect(!FileManager.default.fileExists(atPath: directory.appendingPathComponent("meeting-recovered.wav").path))
}
```

- [x] **Step 2: Run it and watch it fail**

```bash
swift test --disable-sandbox --no-parallel -Xswiftc -F -Xswiftc "$FW" \
  -Xlinker -rpath -Xlinker "$FW" -Xlinker -rpath -Xlinker "$LIB" \
  --filter "zeroReadableFramesThrows"
```

Expected: FAIL — `recover` currently returns a `RecoveredRecording` with duration 0 rather than throwing.

- [x] **Step 3: Make the read throwing, add the field, add the floor**

**3a.** In `RawFloatReader`, change `read` to throw. A short read still zero-pads — that is correct for the shorter track and must not change; only a genuine error propagates:

```swift
    func read(frameCount: Int) throws -> [Float] {
        var result = [Float](repeating: 0, count: frameCount)
        guard let handle else { return result }
        // A throw here is an I/O error; `nil`/empty is end of file, which zero-pads. Conflating the
        // two is what wrote silence into a rebuild and called it a success (F256).
        guard let data = try handle.read(upToCount: frameCount * MemoryLayout<Float>.size),
              !data.isEmpty else {
            return result
        }
        data.withUnsafeBytes { bytes in
            let source = bytes.bindMemory(to: Float.self)
            for index in 0..<min(source.count, result.count) {
                result[index] = source[index]
            }
        }
        return result
    }
```

**3b.** Add to `RecoveredRecording`, after `public let source: Source`:

```swift
    /// Where the rebuild stopped, when a raw track became unreadable partway through (F256).
    /// `nil` for every recovery that read cleanly — its presence means the audio is short.
    public let truncatedAtSeconds: TimeInterval?

    /// What the raw tracks promised, from their file size. Carried so a caller can judge how much
    /// of the meeting survived: with only `duration` and `truncatedAtSeconds` — which are equal
    /// after a truncation, both deriving from `writtenFrames` — the ratio cannot be computed.
    public let expectedDurationSeconds: TimeInterval?

    /// A rebuild that kept less than a tenth of what the tracks promised (F256). Such a meeting is
    /// upserted `.failed` naming the raw tracks, rather than presented as an ordinary recovery, so
    /// "technically recovered" cannot masquerade as recovered. The boundary is a judgement, not a
    /// measurement.
    public var isSeverelyTruncated: Bool {
        guard let expected = expectedDurationSeconds, expected > 0, truncatedAtSeconds != nil else {
            return false
        }
        return duration < expected / 10
    }
```

and give it a default so the memberwise init stays source-compatible with all four call sites:

```swift
    public init(
        recordingURL: URL,
        duration: TimeInterval,
        source: Source,
        truncatedAtSeconds: TimeInterval? = nil,
        expectedDurationSeconds: TimeInterval? = nil
    ) {
        self.recordingURL = recordingURL
        self.duration = duration
        self.source = source
        self.truncatedAtSeconds = truncatedAtSeconds
        self.expectedDurationSeconds = expectedDurationSeconds
    }
```

**3c.** In `recover(in:sampleRate:)`, replace the `while writtenFrames < totalFrames { ... }` loop with a `mixTracks` call, add the floor, and carry the truncation:

```swift
        let systemReader = try RawFloatReader(url: systemFrames > 0 ? systemURL : nil)
        let microphoneReader = try RawFloatReader(url: microphoneFrames > 0 ? microphoneURL : nil)
        let mix = try mixTracks(
            totalFrames: totalFrames,
            chunkSize: 8_192,
            readSystem: { try systemReader.read(frameCount: $0) },
            readMicrophone: { try microphoneReader.read(frameCount: $0) },
            write: { pcm in
                try pcm.withUnsafeBytes { try ThrowingFileHandleIO.write(Data($0), to: output) }
            }
        )
        let writtenFrames = mix.writtenFrames
        // The floor (F256). Nothing readable means nothing to recover, and indexing a duration-0
        // meeting would remove the folder from `orphanedRecordings()` forever while its raw tracks
        // are still intact. Throwing hands it to the caller's per-orphan catch, which leaves the
        // folder untouched and reports it — the only honest outcome.
        if writtenFrames == 0, let truncation = mix.truncation {
            try? FileManager.default.removeItem(at: outputURL)
            throw truncation.error
        }
```

**3d.** Record the truncation in the manifest too, so the folder itself explains its own state
without the index. In `RecoveredSourceManifest` add `let truncatedAtSeconds: TimeInterval?`, and
change `writeRecoveryManifestIfNeeded` to take `truncatedAtSeconds: TimeInterval? = nil` and pass it
through. The defaulted parameter matters: the function has a second caller at the already-finalized
path near the top of `recover`, which has no truncation concept. Safe to add a key because the
manifest is write-only in `WhisperCore` and read by a tolerant subset struct in `AppModel`.

then leave the header rewrite as it is, and return:

```swift
        return RecoveredRecording(
            recordingURL: outputURL,
            duration: Double(writtenFrames) / sampleRate,
            source: .rebuiltSourceTracks,
            truncatedAtSeconds: mix.truncation.map { Double($0.frame) / sampleRate },
            expectedDurationSeconds: Double(totalFrames) / sampleRate
        )
```

- [x] **Step 4: Run the new test, then the whole suite**

```bash
swift test --disable-sandbox --no-parallel -Xswiftc -F -Xswiftc "$FW" \
  -Xlinker -rpath -Xlinker "$FW" -Xlinker -rpath -Xlinker "$LIB" --filter "zeroReadableFramesThrows"
swift test --disable-sandbox --no-parallel -Xswiftc -F -Xswiftc "$FW" \
  -Xlinker -rpath -Xlinker "$FW" -Xlinker -rpath -Xlinker "$LIB"
```

Expected: the new test passes; the full suite still passes. If `StartupRecoveryResilienceTests` fails to build, the `= nil` default in 3b is missing.

- [x] **Step 5: Commit**

```bash
git add Sources/WhisperCore/InterruptedRecordingRecovery.swift \
        Tests/WhisperCoreTests/RecoveryTruncationTests.swift
git commit -m "fix(recovery): truncate at a read error, and refuse to index an empty rebuild (F256)"
```

---

### Task 5: Persist the truncation on the meeting (F256)

**Files:**
- Modify: `Sources/WhisperMeet/MeetingStore.swift` — `MeetingRecord`
- Modify: `Sources/WhisperMeet/AppModel.swift` — the recovered-meeting `upsert` in `performStartupRecovery`
- Test: `Tests/WhisperMeetTests/RecoveryWarningPersistenceTests.swift` (create)

**Interfaces:**
- Consumes: `RecoveredRecording.truncatedAtSeconds` from Task 4.
- Produces: `MeetingRecord.recoveryWarning: String?`, rendered by Task 6.

- [x] **Step 1: Write the failing test**

Create `Tests/WhisperMeetTests/RecoveryWarningPersistenceTests.swift`:

```swift
import Foundation
import Testing
@testable import WhisperMeet
@testable import WhisperCore

// F256 — a truncated recovery must still say so after the startup alert is dismissed.
//
// Optional added field, the append-only pattern already used for `markers`, `pinned`, `notes`,
// `tags` and `healthReport`: an older build ignores the key, and this build decodes its absence as
// nil. Precisely, it DECODES in both directions — an older build that saves the record drops the
// key, which is true of every optional field here.

@Test("A recovery warning survives a store reopen")
@MainActor
func recoveryWarningPersists() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("RecoveryWarning-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let id = UUID()
    let store = MeetingStore(rootDirectory: root)
    store.upsert(MeetingRecord(
        id: id,
        title: "Recovered Meeting",
        status: .recorded,
        recoveryWarning: "Rebuilt audio stops at 12:30 because the source track could not be read past that point."
    ))
    let reopened = MeetingStore(rootDirectory: root)
    #expect(reopened.meeting(id: id)?.recoveryWarning?.contains("12:30") == true)
}

@Test("A record written without the field decodes with nil")
func olderRecordDecodesWithNilWarning() throws {
    // Forward direction: an index written before this field existed must still load.
    let fixture = #"""
    {"id":"3E3269A2-4E5B-4B0A-9A2E-444444444444","title":"Old","createdAt":700000000,
     "duration":0,"recordingPath":"","status":"recorded","transcriptText":"","segments":[]}
    """#
    let record = try JSONDecoder().decode(MeetingRecord.self, from: Data(fixture.utf8))
    #expect(record.recoveryWarning == nil)
    #expect(record.title == "Old")
}

@Test("A clean recovery carries no warning")
@MainActor
func cleanRecoveryHasNoWarning() throws {
    // Its presence must mean exactly one thing: this audio is short by an unknown amount.
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("RecoveryNoWarning-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let id = UUID()
    let store = MeetingStore(rootDirectory: root)
    store.upsert(MeetingRecord(id: id, title: "Fine", status: .completed))
    #expect(store.meeting(id: id)?.recoveryWarning == nil)
}
```

- [x] **Step 2: Run it and watch it fail**

```bash
swift test --disable-sandbox --no-parallel -Xswiftc -F -Xswiftc "$FW" \
  -Xlinker -rpath -Xlinker "$FW" -Xlinker -rpath -Xlinker "$LIB" \
  --filter "recoveryWarningPersists|olderRecordDecodesWithNilWarning|cleanRecoveryHasNoWarning"
```

Expected: build failure — `MeetingRecord` has no `recoveryWarning`.

- [x] **Step 3: Add the field and set it**

**3a.** In `Sources/WhisperMeet/MeetingStore.swift`, in `MeetingRecord` beside `alignmentWarning`:

```swift
    /// Set when a rebuild from raw tracks stopped early because a source track became unreadable
    /// (F256). Optional so indexes written before this field still decode. `nil` means the audio is
    /// whole — nothing else may use this for unrelated notices.
    var recoveryWarning: String?
```

and add a matching parameter to the explicit `init`, defaulted, beside the other optionals:

```swift
        recoveryWarning: String? = nil,
```

with `self.recoveryWarning = recoveryWarning` in the body.

**3b.** In `Sources/WhisperMeet/AppModel.swift`, in the recovered-meeting `upsert`, add the warning and mark a very short prefix as failed. Replace the final `store.upsert(MeetingRecord(...))` in the orphan loop with:

```swift
                // F256: a rebuild that stopped early is never presented as an ordinary recovery.
                // Below a tenth of what the tracks promised, "technically recovered" would
                // masquerade as recovered, so it lands as `.failed` naming the raw tracks instead.
                let warning = recovered.truncatedAtSeconds.map {
                    "The rebuilt audio stops at \(TranscriptFormatter.clock($0)) because a source track could not be read past that point. The original microphone and system tracks are still in this meeting's folder."
                }
                if recovered.isSeverelyTruncated {
                    let failedTitle = "Partly Recovered Meeting \(orphan.createdAt.formatted(date: .abbreviated, time: .shortened))"
                    let message = "Only \(TranscriptFormatter.clock(duration)) of this recording could be rebuilt before a source track became unreadable. The original microphone and system tracks are still in this meeting's folder and have not been changed."
                    store.upsert(MeetingRecord(
                        id: orphan.id,
                        title: failedTitle,
                        createdAt: orphan.createdAt,
                        duration: duration,
                        recordingPath: store.relativeRecordingPath(for: recovered.recordingURL),
                        status: .failed,
                        errorMessage: message,
                        recoveryWarning: warning
                    ))
                    messages.append("\(failedTitle) needs attention. \(message)")
                    continue
                }
                store.upsert(MeetingRecord(
                    id: orphan.id,
                    title: title,
                    createdAt: orphan.createdAt,
                    duration: duration,
                    recordingPath: store.relativeRecordingPath(for: recovered.recordingURL),
                    errorMessage: recovered.wasRebuiltFromRawTracks
                        ? "Recovered from source audio after an interruption. The raw microphone and system tracks were preserved; their exact start alignment was unavailable."
                        : "Recovered after an interruption. The original recording and source tracks were preserved.",
                    recoveryWarning: warning
                ))
```

- [x] **Step 4: Run the new tests, then the whole suite**

Same filter as Step 2, then the full run. Expected: 3 new tests pass, suite green.

- [x] **Step 5: Commit**

```bash
git add Sources/WhisperMeet/MeetingStore.swift Sources/WhisperMeet/AppModel.swift \
        Tests/WhisperMeetTests/RecoveryWarningPersistenceTests.swift
git commit -m "feat(recovery): a truncated rebuild says so on the meeting itself (F256)"
```

---

### Task 6: Render the warning (F256)

**Files:**
- Modify: `Sources/WhisperMeet/ContentView.swift` — the meeting detail. **Corrected during implementation:** NOT beside `alignmentWarning` at `:2887-2899`, which is inside `transcriptSection` and renders only for `.completed`; beside the capture-health advisory in `body`, which renders at every status.

**Interfaces:**
- Consumes: `MeetingRecord.recoveryWarning` from Task 5.

Without a render site this closes `partial`, not `fixed` — AGENTS.md's definition of done needs a user-triggerable path.

- [x] **Step 1: Add the banner**

Immediately after the `if let warning = meeting.alignmentWarning { ... }` block:

```swift
            // F256: the rebuild stopped early, so the audio is short by a known amount. Beside the
            // alignment and language warnings because it is the same kind of statement — something
            // about this transcript's source is not what the user would assume.
            if let warning = meeting.recoveryWarning {
                Label(warning, systemImage: "waveform.badge.exclamationmark")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .bannerSurface(.orange)
                    .accessibilityElement(children: .combine)
            }
```

- [x] **Step 2: Build with warnings as errors**

```bash
swift build -c release -Xswiftc -warnings-as-errors
```

Expected: `Build complete!`. (`swift build -c release` does not compile tests, so test-only warnings will not appear here — CI's `swift test` is what surfaces those.)

- [x] **Step 3: Run the full gate**

```bash
git add -A Sources Tests
Scripts/quality-check.sh
```

Expected: `Quality check passed`, with the test count five higher than the pre-plan baseline of 904 plus the tests added in Tasks 1-5.

- [x] **Step 4: Commit**

```bash
git commit -m "feat(recovery): show the truncation warning on the meeting (F256)"
```

- [x] **Step 5: Close the tickets and check the board**

Move F255 and F256 from `docs/TICKETS.md` to `docs/TICKET_LOG.md` with the evidence, then:

```bash
python3 Scripts/generate-tickets-dashboard.py
python3 Scripts/generate-tickets-dashboard.py --check
```

Record in F256's closure that **F267** (nothing can re-run recovery on an indexed folder) is the reason the floor exists, and that the one-tenth boundary is a judgement, not a measurement.

- [x] **Step 6: After pushing, confirm CI**

```bash
gh run list --limit 1
```

A run under a minute tested nothing (F270). Do not report the work as verified until a run completes green.
