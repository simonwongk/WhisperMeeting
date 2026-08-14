# F187 Library-Index Safety Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make it impossible for an unreadable persisted store to lose user data — preserve the exact bytes before any write, and block every mutation until the user resolves recovery.

**Architecture:** One health state per persisted store, computed at load and carried on the store object. `BackupJSONStore` quarantines any file that exists but does not decode, before either write in `save()`, and refuses to write if quarantine fails. Any health other than `complete` blocks *all* mutation in `MeetingStore`/`DictationLogStore` — before in-memory and filesystem side effects, not merely before persistence — and suppresses automatic orphan recovery.

**Tech Stack:** Swift 6 toolchain in Swift 5 language mode, SwiftPM, swift-testing (`@Test`/`#expect`), macOS 15+.

**Scope:** This plan covers **F187 only**. F188 (frozen reader graphs, `LibraryIndexCodec`, format fence, library-instance guard) is a separate subsystem and gets its own plan — see [Scope boundary](#scope-boundary). F190–F192 follow after.

## Global Constraints

- `Sources/WhisperCore/` is pure `Foundation`-only `Sendable` logic. No AppKit/SwiftUI/`os` imports. Surface diagnostics through return values (the **WhisperCore purity rule** in `AGENTS.md`).
- `MeetingStore` and `AppModel` are `@MainActor`. All of `WhisperCore` is `Sendable`.
- Tests are swift-testing (`@Test("display name")`, `#expect`, `#require`) — never XCTest.
- Document invariants in code comments with the ticket id, e.g. `(F187)`, matching existing style.
- Never write to `~/Library/Application Support/WhisperMeet/` from a test. Tests use `FileManager.default.temporaryDirectory` with a UUID subdirectory and a `defer` cleanup, following `BackupJSONStoreTests.swift:7-12`.
- **Test command** (this Mac has Command Line Tools only; plain `swift test` cannot find swift-testing):

```bash
FW=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
LIB=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
swift test --disable-sandbox --no-parallel \
  -Xswiftc -F -Xswiftc "$FW" \
  -Xlinker -rpath -Xlinker "$FW" \
  -Xlinker -rpath -Xlinker "$LIB" --filter "<name>"
```

  Keep the flags byte-identical between runs so SwiftPM does not rebuild. `Scripts/quality-check.sh` already bakes these in for the full gate.
- **Do not launch `/Applications/WhisperMeet.app` at any point during this plan.** It is the pre-F177 binary and will wipe the library again. Task 10 replaces it.

---

## File Structure

| File | Responsibility |
|---|---|
| `Sources/WhisperCore/PersistedStoreHealth.swift` *(new)* | The health enum and its `allowsMutation` rule. Pure, shared by every store. |
| `Sources/WhisperCore/StoreQuarantine.swift` *(new)* | Copy-aside of undecodable bytes. Isolated so it can be tested without a store. |
| `Sources/WhisperCore/BackupJSONStore.swift` | Load/save with quarantine, health, and optional salvage. |
| `Sources/WhisperMeet/MeetingStore.swift` | Health state; mutation blocking; orphan suppression; vocabulary cap split. |
| `Sources/WhisperMeet/AppModel.swift` | Degraded startup surface; suppressed recovery; message wording. |
| `Sources/WhisperMeet/Dictation/DictationLogStore.swift` | Real load-error handling; write blocking. |
| `Tests/WhisperCoreTests/StoreQuarantineTests.swift` *(new)* | Quarantine unit behaviour. |
| `Tests/WhisperCoreTests/BackupJSONStoreTests.swift` | Rewritten preservation test + salvage + health. |
| `Tests/WhisperMeetTests/DegradedLibraryTests.swift` *(new)* | No mutation, no audio deletion, no rebuild while degraded. |
| `Tests/WhisperMeetTests/VocabularyCapTests.swift` *(new)* | Storage list survives the prompt cap. |
| `Tests/WhisperMeetTests/DictationLogFailureTests.swift` *(new)* | Unreadable log surfaces and blocks writes. |

---

### Task 1: Health state and quarantine primitive

**Files:**
- Create: `Sources/WhisperCore/PersistedStoreHealth.swift`
- Create: `Sources/WhisperCore/StoreQuarantine.swift`
- Test: `Tests/WhisperCoreTests/StoreQuarantineTests.swift`

**Interfaces:**
- Consumes: nothing.
- Produces: `PersistedStoreHealth` (`.complete`, `.recoveredFromBackup`, `.partiallySalvaged(parkedIdentifiers: [String])`, `.unreadable(quarantined: [String])`, `.suspectEmpty(recordingFolderCount: Int)`, `.unavailable(String)`) with `var allowsMutation: Bool`; `StoreQuarantine.preserve(fileAt:using:) throws -> String?` returning the quarantine file name, and `StoreQuarantineError.couldNotPreserve(String)`.

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import WhisperCore

private func makeTempDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("WhisperMeetQuarantineTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

@Test("Quarantine copies the exact bytes aside and leaves the original in place")
func quarantineCopiesRatherThanMoves() throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("meetings.json")
    let bytes = Data("broken-primary".utf8)
    try bytes.write(to: url)

    let name = try #require(StoreQuarantine.preserve(fileAt: url, using: .default))

    #expect(name.hasPrefix("meetings.unreadable-"))
    #expect(name.hasSuffix(".json"))
    // Copy, never move: load() must still see the original, or it returns nil and re-opens rebuild.
    #expect(FileManager.default.fileExists(atPath: url.path))
    #expect(try Data(contentsOf: url) == bytes)
    #expect(try Data(contentsOf: directory.appendingPathComponent(name)) == bytes)
}

@Test("Quarantining identical bytes twice does not accumulate duplicates")
func quarantineIsIdempotentForIdenticalBytes() throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("meetings.json")
    try Data("broken".utf8).write(to: url)

    _ = try StoreQuarantine.preserve(fileAt: url, using: .default)
    _ = try StoreQuarantine.preserve(fileAt: url, using: .default)

    let quarantined = try FileManager.default
        .contentsOfDirectory(atPath: directory.path)
        .filter { $0.contains(".unreadable-") }
    #expect(quarantined.count == 1)
}

@Test("Quarantining a file that does not exist is a no-op")
func quarantineSkipsMissingFile() throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let name = try StoreQuarantine.preserve(
        fileAt: directory.appendingPathComponent("absent.json"),
        using: .default
    )
    #expect(name == nil)
}

@Test("Only a complete store permits mutation")
func onlyCompleteHealthAllowsMutation() {
    #expect(PersistedStoreHealth.complete.allowsMutation)
    #expect(!PersistedStoreHealth.recoveredFromBackup.allowsMutation)
    #expect(!PersistedStoreHealth.partiallySalvaged(parkedIdentifiers: ["a"]).allowsMutation)
    #expect(!PersistedStoreHealth.unreadable(quarantined: ["x.json"]).allowsMutation)
    #expect(!PersistedStoreHealth.suspectEmpty(recordingFolderCount: 10).allowsMutation)
    #expect(!PersistedStoreHealth.unavailable("disk").allowsMutation)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run the test command with `--filter "Quarantine"` then `--filter "complete store permits"`.
Expected: FAIL — `cannot find 'StoreQuarantine' in scope`, `cannot find 'PersistedStoreHealth' in scope`.

- [ ] **Step 3: Write the implementation**

`Sources/WhisperCore/PersistedStoreHealth.swift`:

```swift
import Foundation

/// How much of a persisted store actually loaded (F187). Anything other than `.complete` means the
/// in-memory value is NOT a faithful picture of what the user had, so no mutation may be applied —
/// see `allowsMutation`. A persistence-only guard is not enough: `MeetingStore.delete` removes the
/// recording directory before it saves the index, so a blocked save would still lose audio.
public enum PersistedStoreHealth: Sendable, Equatable {
    /// The primary copy decoded in full.
    case complete
    /// The primary failed but the backup decoded — deliberately one generation stale.
    case recoveredFromBackup
    /// Some records decoded; `parkedIdentifiers` names those that did not and were left behind.
    case partiallySalvaged(parkedIdentifiers: [String])
    /// Neither copy decoded. `quarantined` lists the preserved file names.
    case unreadable(quarantined: [String])
    /// A syntactically valid but empty index found alongside existing recording folders.
    case suspectEmpty(recordingFolderCount: Int)
    /// The store could not be read at all (I/O, permissions).
    case unavailable(String)

    /// Mutation is permitted only when the loaded value is known complete.
    public var allowsMutation: Bool {
        self == .complete
    }
}
```

`Sources/WhisperCore/StoreQuarantine.swift`:

```swift
import Foundation

public enum StoreQuarantineError: LocalizedError, Sendable, Equatable {
    case couldNotPreserve(String)

    public var errorDescription: String? {
        switch self {
        case let .couldNotPreserve(name):
            return "\(name) could not be read and could not be copied aside, so it was left untouched and nothing was written."
        }
    }
}

/// Copies bytes that exist but do not decode to a timestamped sibling, so a later write can never be
/// the only thing standing between the user and their data (F187).
public enum StoreQuarantine {
    /// Copies `url` aside as `<stem>.unreadable-<ISO8601>.<ext>` and returns the new file's name.
    /// Returns nil when `url` does not exist.
    ///
    /// Copies, never moves: a move would leave `load()` seeing no file at all, which returns nil and
    /// re-opens the rebuild path this ticket closes. Idempotent per (file, byte content) so a launch
    /// loop cannot fill the folder with duplicates.
    public static func preserve(fileAt url: URL, using fileManager: FileManager) throws -> String? {
        guard fileManager.fileExists(atPath: url.path) else { return nil }
        guard let bytes = try? Data(contentsOf: url) else {
            throw StoreQuarantineError.couldNotPreserve(url.lastPathComponent)
        }
        let directory = url.deletingLastPathComponent()
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension
        let marker = "\(stem).unreadable-"

        let siblings = (try? fileManager.contentsOfDirectory(atPath: directory.path)) ?? []
        for sibling in siblings where sibling.hasPrefix(marker) {
            let existing = directory.appendingPathComponent(sibling)
            if let existingBytes = try? Data(contentsOf: existing), existingBytes == bytes {
                return sibling
            }
        }

        let stamp = ISO8601DateFormatter.quarantineStamp.string(from: Date())
        let name = ext.isEmpty ? "\(marker)\(stamp)" : "\(marker)\(stamp).\(ext)"
        do {
            try bytes.write(to: directory.appendingPathComponent(name), options: .atomic)
        } catch {
            throw StoreQuarantineError.couldNotPreserve(url.lastPathComponent)
        }
        return name
    }
}

private extension ISO8601DateFormatter {
    /// Colons are legal in HFS+/APFS names but confusing in paths, so use a filename-safe stamp.
    static let quarantineStamp: ISO8601DateFormatter = {
        let formatter = ISO8601DateFormatter()
        formatter.formatOptions = [.withYear, .withMonth, .withDay, .withTime]
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        return formatter
    }()
}
```

- [ ] **Step 4: Run the tests to verify they pass**

Run with `--filter "Quarantine"` and `--filter "complete store permits"`. Expected: PASS, 4 tests.

- [ ] **Step 5: Commit**

```bash
git add Sources/WhisperCore/PersistedStoreHealth.swift Sources/WhisperCore/StoreQuarantine.swift Tests/WhisperCoreTests/StoreQuarantineTests.swift
git commit -m "feat(core): store health state and copy-aside quarantine for undecodable bytes (F187)"
```

---

### Task 2: `save()` preserves before it overwrites

This is the fix that would have prevented the incident.

**Files:**
- Modify: `Sources/WhisperCore/BackupJSONStore.swift:60-79`
- Test: `Tests/WhisperCoreTests/BackupJSONStoreTests.swift:29-54` (rewrite)

**Interfaces:**
- Consumes: `StoreQuarantine.preserve(fileAt:using:)`, `StoreQuarantineError`.
- Produces: `BackupJSONStore.save(_:)` that quarantines undecodable copies before writing and rethrows `StoreQuarantineError.couldNotPreserve` rather than writing.

- [ ] **Step 1: Write the failing test** — replace the body of `preservesUnreadableJSONCopies` (lines 29-54) with:

```swift
@Test("A save after an unreadable load preserves the original bytes instead of overwriting them")
func saveAfterUnreadableLoadPreservesOriginalBytes() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("WhisperMeetBackupTests-\(UUID().uuidString)", isDirectory: true)
    let primaryURL = directory.appendingPathComponent("meetings.json")
    let backupURL = directory.appendingPathComponent("meetings.backup.json")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = BackupJSONStore<[SavedMeeting]>(primaryURL: primaryURL, backupURL: backupURL)
    let primaryBytes = Data("broken-primary".utf8)
    let backupBytes = Data("broken-backup".utf8)
    try primaryBytes.write(to: primaryURL)
    try backupBytes.write(to: backupURL)

    #expect(throws: (any Error).self) { try store.load() }

    // The incident: startup recovery upserted a stub, which called save(), which overwrote BOTH copies.
    try store.save([SavedMeeting(title: "Recovered Meeting")])

    let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    let quarantined = names.filter { $0.contains(".unreadable-") }
    #expect(quarantined.count == 2)
    let preserved = try quarantined.map { try Data(contentsOf: directory.appendingPathComponent($0)) }
    #expect(preserved.contains(primaryBytes))
    #expect(preserved.contains(backupBytes))
}

@Test("A save refuses to write when the undecodable bytes cannot be preserved")
func saveRefusesWhenQuarantineFails() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("WhisperMeetBackupTests-\(UUID().uuidString)", isDirectory: true)
    let primaryURL = directory.appendingPathComponent("meetings.json")
    let backupURL = directory.appendingPathComponent("meetings.backup.json")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer {
        try? FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
        try? FileManager.default.removeItem(at: directory)
    }
    let store = BackupJSONStore<[SavedMeeting]>(primaryURL: primaryURL, backupURL: backupURL)
    let primaryBytes = Data("broken-primary".utf8)
    try primaryBytes.write(to: primaryURL)
    // Read-only directory: the quarantine copy cannot be created.
    try FileManager.default.setAttributes([.posixPermissions: 0o500], ofItemAtPath: directory.path)

    #expect(throws: StoreQuarantineError.couldNotPreserve("meetings.json")) {
        try store.save([SavedMeeting(title: "Recovered Meeting")])
    }
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: directory.path)
    #expect(try Data(contentsOf: primaryURL) == primaryBytes)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run with `--filter "preserves the original bytes"`.
Expected: FAIL — no `.unreadable-` files exist (`quarantined.count` is 0, not 2), because `save()` overwrote both copies.

- [ ] **Step 3: Write the implementation** — replace `save(_:)` in `BackupJSONStore.swift`:

```swift
    public func save(_ value: Value) throws {
        try fileManager.createDirectory(
            at: primaryURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let newData = try encoder.encode(value)
        let existingPrimary = readableData(at: primaryURL)
        let existingBackup = readableData(at: backupURL)

        // Preserve anything that exists but does not decode BEFORE either write can replace it (F187).
        // "Undecodable" is not "worthless": conflating them is what destroyed the library on 2026-08-14.
        // If the bytes cannot be preserved, refuse to write at all — surfacing an error beats losing data.
        if existingPrimary == nil {
            _ = try StoreQuarantine.preserve(fileAt: primaryURL, using: fileManager)
        }
        if existingBackup == nil {
            _ = try StoreQuarantine.preserve(fileAt: backupURL, using: fileManager)
        }

        let backupData = existingPrimary ?? existingBackup ?? newData
        try backupData.write(to: backupURL, options: .atomic)
        try newData.write(to: primaryURL, options: .atomic)
    }
```

- [ ] **Step 4: Run the tests to verify they pass**

Run with `--filter "BackupJSONStore"` and also `--filter "corrupted primary index"` to confirm the existing recovery test still passes. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/WhisperCore/BackupJSONStore.swift Tests/WhisperCoreTests/BackupJSONStoreTests.swift
git commit -m "fix(core): preserve undecodable index bytes before any write (F187)

The prior test asserted preservation but never called save() — it only proved
load() is side-effect-free, and passed while save() overwrote both copies."
```

---

### Task 3: Honest load errors and tolerant per-record decoding

**Files:**
- Modify: `Sources/WhisperCore/BackupJSONStore.swift:3-58`
- Test: `Tests/WhisperCoreTests/BackupJSONStoreTests.swift` (append)

**Interfaces:**
- Consumes: `PersistedStoreHealth`, `StoreQuarantine`.
- Produces: `BackupJSONStore.LoadResult { value: Value, health: PersistedStoreHealth }` (replacing `source`); `BackupJSONStoreError.noReadableCopy(primary: String, backup: String, quarantined: [String])`; `init(primaryURL:backupURL:fileManager:salvage:)` taking `((Data) -> SalvagedValue<Value>?)?`; `public struct SalvagedValue<Value> { let value: Value; let parkedIdentifiers: [String] }`.

- [ ] **Step 1: Write the failing test**

```swift
@Test("An unreadable load reports the quarantine file names it actually created")
func unreadableLoadNamesItsQuarantine() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("WhisperMeetBackupTests-\(UUID().uuidString)", isDirectory: true)
    let primaryURL = directory.appendingPathComponent("meetings.json")
    let backupURL = directory.appendingPathComponent("meetings.backup.json")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = BackupJSONStore<[SavedMeeting]>(primaryURL: primaryURL, backupURL: backupURL)
    try Data("broken-primary".utf8).write(to: primaryURL)
    try Data("broken-backup".utf8).write(to: backupURL)

    var captured: BackupJSONStoreError?
    do {
        _ = try store.load()
    } catch let error as BackupJSONStoreError {
        captured = error
    }
    let error = try #require(captured)
    guard case let .noReadableCopy(_, _, quarantined) = error else {
        Issue.record("expected noReadableCopy")
        return
    }
    #expect(quarantined.count == 2)
    for name in quarantined {
        #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path))
    }
    let message = try #require(error.errorDescription)
    #expect(message.contains(quarantined[0]))
    #expect(!message.contains("were preserved for manual recovery"))
}

@Test("Salvage keeps the readable records and parks the one that is not")
func salvageKeepsReadableRecords() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("WhisperMeetBackupTests-\(UUID().uuidString)", isDirectory: true)
    let primaryURL = directory.appendingPathComponent("meetings.json")
    let backupURL = directory.appendingPathComponent("meetings.backup.json")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    // Second record's `title` is a number, so only that element fails.
    let mixed = Data(#"[{"title":"good"},{"title":42},{"title":"also good"}]"#.utf8)
    try mixed.write(to: primaryURL)

    let store = BackupJSONStore<[SavedMeeting]>(
        primaryURL: primaryURL,
        backupURL: backupURL,
        salvage: { data in
            let elements = (try? JSONDecoder().decode([FailableDecodable<SavedMeeting>].self, from: data)) ?? []
            var kept: [SavedMeeting] = []
            var parked: [String] = []
            for (index, element) in elements.enumerated() {
                if let value = element.value { kept.append(value) } else { parked.append("index \(index)") }
            }
            return kept.isEmpty ? nil : SalvagedValue(value: kept, parkedIdentifiers: parked)
        }
    )

    let result = try #require(try store.load())
    #expect(result.value == [SavedMeeting(title: "good"), SavedMeeting(title: "also good")])
    #expect(result.health == .partiallySalvaged(parkedIdentifiers: ["index 1"]))
}
```

Add the shared helper at the bottom of the test file, next to `SavedMeeting`:

```swift
/// Decodes an element or records that it could not be decoded, without failing the whole array.
struct FailableDecodable<Wrapped: Decodable>: Decodable {
    let value: Wrapped?

    init(from decoder: Decoder) throws {
        value = try? Wrapped(from: decoder)
    }
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run with `--filter "quarantine file names"` and `--filter "Salvage keeps"`.
Expected: FAIL — `noReadableCopy` has no `quarantined` parameter; `salvage:` and `SalvagedValue` do not exist.

- [ ] **Step 3: Write the implementation** — replace lines 3-58 of `BackupJSONStore.swift`:

```swift
import Foundation

public enum BackupJSONStoreError: LocalizedError, Sendable, Equatable {
    case noReadableCopy(primary: String, backup: String, quarantined: [String])

    public var errorDescription: String? {
        switch self {
        case let .noReadableCopy(primary, backup, quarantined):
            // Claim only the preservation that actually happened (F187). The prior wording promised
            // preservation unconditionally while nothing preserved anything.
            guard !quarantined.isEmpty else {
                return "Neither \(primary) nor its backup \(backup) could be read, and neither could be copied aside. Nothing was changed on disk."
            }
            return "Neither \(primary) nor its backup \(backup) could be read. The exact bytes were copied aside as \(quarantined.joined(separator: " and ")) and nothing was overwritten."
        }
    }
}

/// A value rebuilt from a partly-unreadable file, plus the records that had to be left behind.
public struct SalvagedValue<Value>: Sendable where Value: Sendable {
    public let value: Value
    public let parkedIdentifiers: [String]

    public init(value: Value, parkedIdentifiers: [String]) {
        self.value = value
        self.parkedIdentifiers = parkedIdentifiers
    }
}

public struct BackupJSONStore<Value: Codable & Sendable> {
    public struct LoadResult {
        public let value: Value
        public let health: PersistedStoreHealth
    }

    private let primaryURL: URL
    private let backupURL: URL
    private let fileManager: FileManager
    /// Optional element-wise recovery so one bad record costs one record, not the whole library (F187).
    private let salvage: (@Sendable (Data) -> SalvagedValue<Value>?)?

    public init(
        primaryURL: URL,
        backupURL: URL,
        fileManager: FileManager = .default,
        salvage: (@Sendable (Data) -> SalvagedValue<Value>?)? = nil
    ) {
        self.primaryURL = primaryURL
        self.backupURL = backupURL
        self.fileManager = fileManager
        self.salvage = salvage
    }

    public func load() throws -> LoadResult? {
        let primaryExists = fileManager.fileExists(atPath: primaryURL.path)
        let backupExists = fileManager.fileExists(atPath: backupURL.path)

        if primaryExists,
           let data = try? Data(contentsOf: primaryURL),
           let value = try? decoder.decode(Value.self, from: data) {
            return LoadResult(value: value, health: .complete)
        }
        if backupExists,
           let data = try? Data(contentsOf: backupURL),
           let value = try? decoder.decode(Value.self, from: data) {
            return LoadResult(value: value, health: .recoveredFromBackup)
        }
        guard primaryExists || backupExists else { return nil }

        // Preserve first, then try to rescue individual records from the preserved bytes.
        var quarantined: [String] = []
        if let name = try StoreQuarantine.preserve(fileAt: primaryURL, using: fileManager) {
            quarantined.append(name)
        }
        if let name = try StoreQuarantine.preserve(fileAt: backupURL, using: fileManager) {
            quarantined.append(name)
        }

        if let salvage {
            for url in [primaryURL, backupURL] {
                guard let data = try? Data(contentsOf: url), let rescued = salvage(data) else { continue }
                return LoadResult(
                    value: rescued.value,
                    health: .partiallySalvaged(parkedIdentifiers: rescued.parkedIdentifiers)
                )
            }
        }

        throw BackupJSONStoreError.noReadableCopy(
            primary: primaryURL.lastPathComponent,
            backup: backupURL.lastPathComponent,
            quarantined: quarantined
        )
    }
```

Keep `save(_:)` from Task 2, and `readableData`/`encoder`/`decoder` unchanged.

- [ ] **Step 4: Run the tests to verify they pass**

Run with `--filter "BackupJSONStore"`. The pre-existing `recoversPreviousJSONCopy` test references `recovered.source == .backup`; update that one line to `recovered.health == .recoveredFromBackup`. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/WhisperCore/BackupJSONStore.swift Tests/WhisperCoreTests/BackupJSONStoreTests.swift
git commit -m "feat(core): name the real quarantine in load errors; salvage readable records (F187)"
```

---

### Task 4: `MeetingStore` blocks every mutation while degraded

The review's decisive finding: `delete` removes audio at line 375 and persists at line 382, so a persistence-only guard still destroys recordings.

**Files:**
- Modify: `Sources/WhisperMeet/MeetingStore.swift:155-213, 273-345, 361-411, 437-478`
- Test: `Tests/WhisperMeetTests/DegradedLibraryTests.swift` *(new)*

**Interfaces:**
- Consumes: `PersistedStoreHealth`, `BackupJSONStore.LoadResult`.
- Produces: `MeetingStore.health: PersistedStoreHealth`, `MeetingStore.isDegraded: Bool`, `MeetingStore.recoveryMessage: String?`.

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import WhisperMeet
@testable import WhisperCore

@MainActor
private func makeDegradedStore() throws -> (MeetingStore, URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("WhisperMeetDegraded-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("broken-primary".utf8).write(to: root.appendingPathComponent("meetings.json"))
    try Data("broken-backup".utf8).write(to: root.appendingPathComponent("meetings.backup.json"))
    return (MeetingStore(rootDirectory: root), root)
}

@Test("An unreadable index leaves the store degraded rather than empty-and-writable")
@MainActor
func unreadableIndexIsDegraded() throws {
    let (store, root) = try makeDegradedStore()
    defer { try? FileManager.default.removeItem(at: root) }
    #expect(store.isDegraded)
    #expect(!store.health.allowsMutation)
}

@Test("Deleting while degraded removes no audio and no record")
@MainActor
func degradedDeleteRemovesNothing() throws {
    let (store, root) = try makeDegradedStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let directory = root.appendingPathComponent("Recordings/\(id.uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("audio".utf8).write(to: directory.appendingPathComponent("meeting.wav"))
    var removalAttempted = false
    store.removeRecordingDirectory = { _ in removalAttempted = true }

    store.delete(id: id)

    #expect(!removalAttempted)
    #expect(FileManager.default.fileExists(atPath: directory.appendingPathComponent("meeting.wav").path))
    #expect(store.storageErrorMessage != nil)
}

@Test("No mutation while degraded reaches disk or memory")
@MainActor
func degradedMutationsAreRefused() throws {
    let (store, root) = try makeDegradedStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let before = store.persistCount

    store.upsert(MeetingRecord(title: "New"))
    store.setTags(id: UUID(), ["x"])
    store.addVocabulary(["term"])

    #expect(store.meetings.isEmpty)
    #expect(store.vocabulary.isEmpty)
    #expect(store.persistCount == before)
}

@Test("A degraded index reports no orphans, so startup cannot rebuild over it")
@MainActor
func degradedIndexReportsNoOrphans() throws {
    let (store, root) = try makeDegradedStore()
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appendingPathComponent("Recordings/\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    #expect(try store.orphanedRecordings().isEmpty)
}
```

- [ ] **Step 2: Run the tests to verify they fail**

Run with `--filter "degraded"`.
Expected: FAIL — `isDegraded`/`health` do not exist; once stubbed, `degradedDeleteRemovesNothing` fails because `delete` removes the directory before persisting.

- [ ] **Step 3: Write the implementation**

Add to `MeetingStore` near `storageErrorMessage` (line 162):

```swift
    /// How much of the meeting index actually loaded (F187). Anything but `.complete` blocks EVERY
    /// mutation — not just persistence — because `delete` removes audio before it saves the index.
    @Published private(set) var health: PersistedStoreHealth = .complete
    var isDegraded: Bool { !health.allowsMutation }
```

Add the shared guard:

```swift
    /// Refuses a mutation while the library is not known-complete, and says why (F187). Callers must
    /// invoke this BEFORE any in-memory or filesystem side effect.
    private func refuseWhileDegraded() -> Bool {
        guard isDegraded else { return false }
        storageErrorMessage = "WhisperMeet could not fully read its meeting library, so it is open in read-only mode and nothing has been changed. Resolve recovery before editing, deleting, or recording."
        return true
    }
```

Insert `guard !refuseWhileDegraded() else { return }` as the **first line** of: `upsert`, `update`, `editTranscript`, `editNotes`, `setTags`, `togglePin`, `delete`, `addVocabulary`, `removeVocabulary`, `addReplacementRule`, `removeReplacementRule`.

In `delete(id:)` the guard must precede the existing `guard let meeting = meeting(id: id)` at line 362, so no directory is removed.

In `orphanedRecordings()` add after line 238:

```swift
        // An index that did not fully load is indistinguishable from "no meetings", which is exactly
        // how every recording folder came to look orphaned on 2026-08-14 (F187).
        guard !isDegraded else { return [] }
```

Rewrite `loadMeetings()`:

```swift
    private func loadMeetings() {
        do {
            guard let result = try meetingFiles.load() else { return }
            meetings = MeetingOrdering.sorted(result.value)
            health = result.health
            if case .recoveredFromBackup = result.health {
                startupRecoveryMessages.append(
                    "The meeting index was damaged, so WhisperMeet loaded the previous readable backup, which may be one save behind. Nothing was written and no recording folders were deleted — confirm the library looks right before editing."
                )
            }
            if case let .partiallySalvaged(parked) = result.health {
                startupRecoveryMessages.append(
                    "\(parked.count) meeting record(s) could not be read and were left in the preserved copy. The rest of the library loaded. Nothing was written."
                )
            }
            // A valid but empty index sitting next to recording folders is suspicious, not normal.
            if meetings.isEmpty, health == .complete {
                let count = recordingFolderCount()
                if count > 0 { health = .suspectEmpty(recordingFolderCount: count) }
            }
        } catch let error as BackupJSONStoreError {
            guard case let .noReadableCopy(_, _, quarantined) = error else { return }
            health = .unreadable(quarantined: quarantined)
            startupRecoveryMessages.append(error.localizedDescription)
        } catch {
            health = .unavailable(error.localizedDescription)
            startupRecoveryMessages.append(error.localizedDescription)
        }
    }

    private func recordingFolderCount() -> Int {
        let recordings = rootDirectory.appendingPathComponent("Recordings", isDirectory: true)
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: recordings,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls.filter { UUID(uuidString: $0.lastPathComponent) != nil }.count
    }
```

Note the removed `try meetingFiles.save(meetings)` from the old backup branch: recovering from a stale backup no longer re-persists silently.

- [ ] **Step 4: Run the tests to verify they pass**

Run with `--filter "degraded"` then the full `WhisperMeetTests` suite to catch call sites that assumed `source`. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/WhisperMeet/MeetingStore.swift Tests/WhisperMeetTests/DegradedLibraryTests.swift
git commit -m "fix(meetings): block every mutation while the index is not known-complete (F187)

delete() removes the recording directory before it saves the index, so a
persistence-only guard would still destroy audio. The guard runs first."
```

---

### Task 5: Startup surfaces recovery instead of rebuilding

**Files:**
- Modify: `Sources/WhisperMeet/AppModel.swift:649-745`
- Test: `Tests/WhisperMeetTests/DegradedLibraryTests.swift` (append)

**Interfaces:**
- Consumes: `MeetingStore.isDegraded`, `MeetingStore.health`.
- Produces: no new public API; `performStartupRecovery` becomes a no-op for orphan rebuild while degraded.

- [ ] **Step 1: Write the failing test**

```swift
@Test("Startup recovery creates no records when the index is degraded")
@MainActor
func startupRecoverySuppressedWhileDegraded() async throws {
    let (store, root) = try makeDegradedStore()
    defer { try? FileManager.default.removeItem(at: root) }
    for _ in 0..<3 {
        let directory = root.appendingPathComponent("Recordings/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    let defaults = try #require(UserDefaults(suiteName: "DegradedLibraryTests-\(UUID().uuidString)"))
    let model = AppModel(store: store, recorder: AudioCaptureEngine(), defaults: defaults)

    await model.performStartupRecovery()

    #expect(store.meetings.isEmpty)
    #expect(store.persistCount == 0)
    let alert = try #require(model.alertMessage)
    #expect(alert.contains("read-only"))
    #expect(!alert.contains("added it back to meeting history"))
}
```

This mirrors the established seam — see `Tests/WhisperMeetTests/CancelConfirmationTests.swift:10`, which builds
`AppModel(store:recorder:defaults:)` with a throwaway `UserDefaults` suite. Constructing
`AudioCaptureEngine()` does not touch hardware; only `start` does.

- [ ] **Step 2: Run the test to verify it fails**

Run with `--filter "Startup recovery creates no records"`.
Expected: FAIL — three blank stubs are created and `persistCount == 3`.

- [ ] **Step 3: Write the implementation** — insert immediately after line 658 (`var messages = store.startupRecoveryMessages`):

```swift
        // A library that did not fully load must never be "recovered" into a lesser one (F187). Every
        // recording folder looks orphaned when the in-memory index is empty, which is how ten meetings
        // became blank stubs on 2026-08-14. Show the state and stop; the user decides what happens next.
        if store.isDegraded {
            messages.append(
                "WhisperMeet is open in read-only mode because it could not fully read your meeting library. Your recordings are untouched and the unreadable index was copied aside. Nothing will be changed until you choose how to recover."
            )
            alertMessage = messages.joined(separator: "\n\n")
            return
        }
```

Then fix the doubled wording at line 731:

```swift
                // `title` already begins with "Recovered Meeting", so do not prefix it again (F187).
                messages.append("\(title) was added back to meeting history.")
```

- [ ] **Step 4: Run the test to verify it passes**

Run with `--filter "Startup recovery creates no records"`, then `--filter "OrphanRecovery"` and `--filter "StartupRecovery"` for regressions. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/WhisperMeet/AppModel.swift Tests/WhisperMeetTests/DegradedLibraryTests.swift
git commit -m "fix(meetings): a degraded library reports recovery instead of rebuilding stubs (F187)"
```

---

### Task 6: `DictationLogStore` stops failing silently

**Files:**
- Modify: `Sources/WhisperMeet/Dictation/DictationLogStore.swift:9-31`
- Test: `Tests/WhisperMeetTests/DictationLogFailureTests.swift` *(new)*

**Interfaces:**
- Consumes: `PersistedStoreHealth`, `BackupJSONStoreError`.
- Produces: `DictationLogStore.health: PersistedStoreHealth`, `DictationLogStore.loadErrorMessage: String?`.

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import WhisperMeet
@testable import WhisperCore

@Test("An unreadable dictation log is surfaced and never overwritten by the next dictation")
@MainActor
func unreadableDictationLogIsNotOverwritten() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("WhisperMeetDictationLog-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let primary = root.appendingPathComponent("dictation-log.json")
    let bytes = Data("broken-log".utf8)
    try bytes.write(to: primary)

    let store = DictationLogStore(directory: root)
    #expect(store.loadErrorMessage != nil)
    #expect(!store.health.allowsMutation)

    store.record(text: "hello", outcome: .pasted)

    // The original bytes survive, preserved rather than replaced by a one-entry log.
    let quarantined = try FileManager.default.contentsOfDirectory(atPath: root.path)
        .filter { $0.contains(".unreadable-") }
    #expect(quarantined.count == 1)
    #expect(try Data(contentsOf: root.appendingPathComponent(quarantined[0])) == bytes)
    #expect(store.log.entries.isEmpty)
}
```

Signatures verified against source: `DictationLogStore.init(directory:)` (`:12`),
`record(text:outcome:)` (`:23`) with `DictationLogEntry.Outcome.pasted`, and
`DictationLog.entries` (`DictationLog.swift:35`).

- [ ] **Step 2: Run the test to verify it fails**

Run with `--filter "unreadable dictation log"`.
Expected: FAIL — `loadErrorMessage`/`health` do not exist, and the log is silently replaced.

- [ ] **Step 3: Write the implementation** — replace the load and mutation paths:

```swift
    /// Load health for the dictation history (F187). The previous `try?` discarded the failure with no
    /// alert, no startup message and no storage error, so the next dictation destroyed the history.
    @Published private(set) var health: PersistedStoreHealth = .complete
    @Published private(set) var loadErrorMessage: String?

    // in init, replacing `if let loaded = try? store.load() { log = loaded.value }`
        do {
            if let loaded = try store.load() {
                log = loaded.value
                health = loaded.health
                if !loaded.health.allowsMutation {
                    loadErrorMessage = "Your dictation history could not be fully read, so it is shown read-only and nothing will be written over it."
                }
            }
        } catch {
            health = .unavailable(error.localizedDescription)
            loadErrorMessage = error.localizedDescription
        }
```

Guard both mutators:

```swift
    func record(...) {
        guard health.allowsMutation else { return }
        ...
    }

    func clear() {
        guard health.allowsMutation else { return }
        ...
    }
```

Replace the two `try? store.save(log)` calls with `do/catch` that sets `loadErrorMessage` from the thrown error, so a failed quarantine is visible rather than swallowed.

- [ ] **Step 4: Run the test to verify it passes**

Run with `--filter "dictation"`. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/WhisperMeet/Dictation/DictationLogStore.swift Tests/WhisperMeetTests/DictationLogFailureTests.swift
git commit -m "fix(dictation): surface an unreadable log instead of silently replacing it (F187)"
```

---

### Task 7: Vocabulary storage stops being narrowed by the prompt budget

**Files:**
- Modify: `Sources/WhisperMeet/MeetingStore.swift:386-394, 419-435, 480-493`
- Test: `Tests/WhisperMeetTests/VocabularyCapTests.swift` *(new)*

**Interfaces:**
- Consumes: nothing new.
- Produces: `MeetingStore.promptVocabulary: [String]` (the capped list for prompt construction); `vocabulary` becomes the full stored list.

- [ ] **Step 1: Write the failing test**

```swift
import Foundation
import Testing
@testable import WhisperMeet

@Test("Terms beyond the prompt budget stay in storage and only the prompt is capped")
@MainActor
func vocabularyStorageSurvivesThePromptCap() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("WhisperMeetVocabulary-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let store = MeetingStore(rootDirectory: root)
    let terms = (0..<150).map { "term-number-\($0)" }
    store.addVocabulary(terms)

    #expect(store.vocabulary.count == 150)
    #expect(store.promptVocabulary.count <= 100)
    #expect(store.promptVocabulary.joined(separator: ", ").count <= 1_000)

    // Reload from disk: nothing was truncated on the way out or the way back in.
    let reopened = MeetingStore(rootDirectory: root)
    #expect(reopened.vocabulary.count == 150)
}
```

- [ ] **Step 2: Run the test to verify it fails**

Run with `--filter "prompt budget"`.
Expected: FAIL — `store.vocabulary.count` is capped at 100, and `promptVocabulary` does not exist.

- [ ] **Step 3: Write the implementation**

`vocabulary` already exists at `MeetingStore.swift:158` — do not redeclare it; only its comment and the
code that narrows it change. Add the computed prompt view next to it:

```swift
    /// The full stored term list (F187). Never narrowed by the prompt budget — doing that at load and
    /// on every addition made the truncation permanent on the next write.
    @Published var vocabulary: [String] = []

    /// The subset handed to an engine's `initial_prompt`, capped to the prompt budget at the point of
    /// use rather than in storage.
    var promptVocabulary: [String] { Self.promptSafeTerms(vocabulary) }
```

In `addVocabulary`, replace `vocabulary = Self.promptSafeTerms(vocabulary + terms)` with a storage-only normalization (trim, drop empties, dedupe, sort) and a generous storage ceiling:

```swift
    func addVocabulary(_ terms: [String]) {
        guard !refuseWhileDegraded() else { return }
        vocabulary = Self.storedTerms(vocabulary + terms)
        persistVocabulary()
    }

    /// Storage-side normalization only: trim, drop empties, dedupe, sort. The 1,000-character prompt
    /// budget belongs to `promptVocabulary`, not to what the user's file is allowed to contain.
    private static func storedTerms(_ values: [String]) -> [String] {
        Array(Set(values.map(normalizeTerm).filter { !$0.isEmpty }))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .prefix(maxStoredVocabularyTerms)
            .map { $0 }
    }

    private static let maxStoredVocabularyTerms = 5_000
```

In `loadVocabulary`, replace `vocabulary = Self.promptSafeTerms(result.value)` with
`vocabulary = Self.storedTerms(result.value)` and set `health` as in Task 4.

Keep `promptSafeTerms` and switch exactly the two **prompt** consumers to `promptVocabulary`:

- `AppModel.swift:470` — `keyterms: store.vocabulary` in `.accuracyFirst(...)` (the Whisper prompt)
- `AppModel.swift:1663` — `let vocabulary = store.vocabulary` feeding `proposeTranscriptCorrections`

Leave the two **non-prompt** consumers on the full list, because they are local matching and should see
every term:

- `AppModel.swift:1598` — `GlossaryCorrector.corrections(vocabulary: store.vocabulary, ...)`
- `AppModel.swift:1823` — the diagnostics bundle

- [ ] **Step 4: Run the test to verify it passes**

Run with `--filter "prompt budget"`, then `--filter "Vocabulary"` for regressions. Expected: PASS.

- [ ] **Step 5: Commit**

```bash
git add Sources/WhisperMeet/MeetingStore.swift Tests/WhisperMeetTests/VocabularyCapTests.swift
git commit -m "fix(vocabulary): cap the prompt, not the stored term list (F187)"
```

---

### Task 8: Documentation

**Files:**
- Modify: `docs/PRODUCT_SPEC.md:41-43`, `AGENTS.md` (§ Build commands, new § Persistence rules), `docs/RECOVERY.md`

- [ ] **Step 1: Amend the product invariant** — replace the "Keep a previous-readable backup…" bullet:

```markdown
- Keep a previous-readable backup of meeting and vocabulary indexes. If an index copy cannot be read,
  copy its exact bytes aside before writing anything, and never overwrite bytes that failed to parse.
  When no copy is readable, open the library read-only, block every mutation, and offer recovery from
  usable recording folders only as an explicit, user-reviewed action — never automatically, and never
  deleting audio.
```

The preserve clause was always there and was never implemented; only the automatic reconstruction changes.

- [ ] **Step 2: Correct the AGENTS.md build commands** — replace `open .build/WhisperMeet.app` with:

```bash
Scripts/install-app.sh          # build + guarded install to /Applications (the bundle you run)
open /Applications/WhisperMeet.app
```

Add a note: `Scripts/build-app.sh` only packages into `.build/`; never run that bundle while an installed copy exists, because two bundles at different commits can hold incompatible library schemas.

- [ ] **Step 3: Add the AGENTS.md persistence rules** — a new section after § WhisperCore purity rule:

```markdown
## Persisted-schema rules

`meetings.json`, `vocabulary.json`, `replacement-rules.json` and `dictation-log.json` are a wire
format shared by every build a user might launch. See
`docs/LIBRARY_INDEX_WIPE_POSTMORTEM_2026-08-14.md`.

- Persisted fields are **append-only and optional**. Never retype an existing field: F177 changed
  `actionItems` from `[String]` to `[ActionItem]` and cost a user's entire library.
- Assess compatibility in **both** directions. "Old data still decodes" is half a review — ask whether
  the previously shipped build can read what this one writes.
- Every `Codable` change to a persisted type ships fixtures in both directions (F188).
- An unreadable file is quarantined, never overwritten.
- A failed load never rebuilds a library, and never permits mutation — `delete` removes audio before it
  saves the index, so blocking persistence alone is not enough.
- Enums reachable from a persisted type decode unknown raw values leniently or fail closed. Prefer a
  plain `String` as `MediaSource.kind` does.
```

- [ ] **Step 4: Update `docs/RECOVERY.md`** — extend the file list with `replacement-rules.json` and `dictation-log.json` (and their `.backup.json` copies), and add a Failure behavior row:

```markdown
| Neither index copy can be read | The exact bytes are copied aside as `<name>.unreadable-<timestamp>.json`, the library opens read-only, and no mutation, recording, import, transcription or deletion is permitted until recovery is resolved. | Every recording folder, and both original index files. |
```

- [ ] **Step 5: Commit**

```bash
git add docs/PRODUCT_SPEC.md AGENTS.md docs/RECOVERY.md
git commit -m "docs: persisted-schema rules, corrected build commands, read-only recovery (F187)"
```

---

### Task 9: Full gate

- [ ] **Step 1: Run the complete suite**

```bash
Scripts/quality-check.sh
```

Expected: all five steps pass. If step [4] reports unrelated pre-existing failures, record them in the commit message rather than fixing them here.

- [ ] **Step 2: Fix any regression, re-run, then commit**

```bash
git commit -am "test: green gate for the F187 library-safety work"
```

---

### Task 10: Install, then restore

**Do not reorder.** The pre-F177 bundle must be gone before the restored library exists.

- [ ] **Step 1: Confirm nothing is running, then install**

```bash
pgrep -x WhisperMeet || echo "not running"
Scripts/install-app.sh
```

- [ ] **Step 2: Verify the installed bundle is the fixed one**

```bash
nm -a /Applications/WhisperMeet.app/Contents/MacOS/WhisperMeet | grep -c ActionItem
```

Expected: a non-zero count. `0` means the old bundle is still installed — stop and investigate.

- [ ] **Step 3: Verify the recovery snapshot before reading from it**

```bash
cd ~/Documents/WhisperMeet-index-recovery-2026-08-14 && shasum -a 256 -c SHA256SUMS.txt
```

Expected: every line `OK`.

- [ ] **Step 4: Write and run the restore**

Save as `<scratchpad>/restore-library.py` — **not** committed. Excluding the link-imported records falls
out of the path check: their `recording.wav` files were deleted, so their paths no longer resolve.

```python
#!/usr/bin/env python3
"""One-off restore of the meeting index after the 2026-08-14 wipe (F187). Read-only on audio."""
import datetime, json, os, shutil, subprocess, sys

LIB = os.path.expanduser("~/Library/Application Support/WhisperMeet")
SNAP = os.path.expanduser("~/Documents/WhisperMeet-index-recovery-2026-08-14")
SOURCE = os.path.join(SNAP, "meetings.before-retranscribe.json")
REQUIRED = ["id", "title", "createdAt", "duration", "recordingPath", "status", "transcriptText"]

if subprocess.run(["pgrep", "-x", "WhisperMeet"], capture_output=True).returncode == 0:
    sys.exit("WhisperMeet is running. Quit it and try again.")
if subprocess.run(["shasum", "-a", "256", "-c", "SHA256SUMS.txt"], cwd=SNAP).returncode != 0:
    sys.exit("Snapshot failed hash verification. Stopping.")

stamp = datetime.datetime.now().strftime("%Y%m%dT%H%M%S")
live_primary = os.path.join(LIB, "meetings.json")
live_backup = os.path.join(LIB, "meetings.backup.json")
for path in (live_primary, live_backup):
    if os.path.exists(path):
        shutil.copy2(path, f"{path}.pre-restore-{stamp}")

live = {m["id"]: m for m in json.load(open(live_primary))}
restored = []
for record in json.load(open(SOURCE)):
    path = record.get("recordingPath") or ""
    if not path or not os.path.exists(os.path.join(LIB, path)):
        print(f"skip (audio gone): {record['id']}")
        continue
    record.setdefault("segments", [])
    if record.get("segments") is None:
        record["segments"] = []
    missing = [k for k in REQUIRED if record.get(k) is None]
    if missing:
        sys.exit(f"record {record['id']} is missing {missing}; refusing to write a hard-fail index")
    restored.append(record)
    live.pop(record["id"], None)

# Anything still in `live` is newer than the snapshot: keep it, and repair the false stub metadata.
for record in live.values():
    tracks = os.path.join(LIB, os.path.dirname(record.get("recordingPath", "")), "source-tracks.json")
    if os.path.exists(tracks):
        when = datetime.datetime.fromtimestamp(os.path.getmtime(tracks))
        record["title"] = f"Meeting {when.strftime('%b %-d, %Y at %H:%M')}"
    record["errorMessage"] = None          # it ended normally; it was never interrupted
    record["status"] = "recorded"          # ready to transcribe
    record.setdefault("segments", [])
    restored.append(record)

restored.sort(key=lambda m: m["createdAt"])
payload = json.dumps(restored, indent=2, ensure_ascii=False, sort_keys=True)
for path in (live_backup, live_primary):
    with open(path, "w", encoding="utf-8") as handle:
        handle.write(payload)

with_text = sum(1 for m in restored if (m.get("transcriptText") or "").strip())
print(f"restored {len(restored)} meetings, {with_text} with transcripts")
```

Run it, and confirm the printed counts are `10` and `8`.

- [ ] **Step 5: Verify in the app, not in the tests**

```bash
open /Applications/WhisperMeet.app
```

Confirm 10 meetings, 8 with transcript text, tags intact, one summary present, and no recovery alert. Passing tests are not evidence that the library reads.

---

## Scope boundary

**Not in this plan** — F188 gets its own, because it is a different subsystem with its own file set:

- `LibraryIndexCodec` seam and canonical encoder settings
- frozen reader graphs per storage wire revision, the three compatibility checks, the supported writer floor
- synthetic representative fixtures and hand-authored canonical goldens
- the format/version fence and exclusive library-instance guard
- the checked-in inventory of persisted roots and nested types
- **lenient decoding for the undefended enums** (`RecordingHealthStatus`, `RecordingHealthWarning`,
  `MeetingTranscriptionEngine` all throw `dataCorrupted` on an unknown raw value; only `MeetingStatus`
  is defended) and lossless unknown-field passthrough — both are compatibility policy, and F188's
  "round-trip losslessly or fail closed" rule decides them together

**Deliberately deferred to F190, not forgotten:** the review listed *divergent copies* among the states
to treat as degraded. `PersistedStoreHealth` has no `divergent` case because divergence cannot be
detected today — the backup is *supposed* to be one generation behind, so "the copies differ" is the
normal condition. Telling a stale backup from a foreign write needs the generation identity that F190
introduces. Adding a case now would either fire constantly or assert something unproven.

Until F188 ships, a stray pre-F177 bundle can still wipe a restored library. The mitigations are that Task 10 replaces the only known copy, and the verified snapshot makes a third wipe recoverable.

F190 (transactional, generation-aware, single-writer writes), F191 (backup/restore completeness), F192 (privacy and reproducibility) follow.
