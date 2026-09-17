import Foundation
import Testing
@testable import WhisperCore

@Test("A corrupted primary index recovers the previous valid copy")
func recoversPreviousJSONCopy() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("WhisperMeetBackupTests-\(UUID().uuidString)", isDirectory: true)
    let primaryURL = directory.appendingPathComponent("meetings.json")
    let backupURL = directory.appendingPathComponent("meetings.backup.json")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = BackupJSONStore<[SavedMeeting]>(
        primaryURL: primaryURL,
        backupURL: backupURL
    )

    try store.save([SavedMeeting(title: "First valid meeting")])
    try store.save([SavedMeeting(title: "Newest meeting")])
    try Data("not-json".utf8).write(to: primaryURL, options: .atomic)

    let loaded = try store.load()
    let recovered = try #require(loaded)
    #expect(recovered.health == .recoveredFromBackup)
    #expect(recovered.value == [SavedMeeting(title: "First valid meeting")])
    #expect(try JSONDecoder().decode([SavedMeeting].self, from: Data(contentsOf: backupURL)) == recovered.value)
}

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

// Skipped as root (F190, design §9.4). The scenario is "the directory refuses the quarantine copy",
// staged with `chmod 0o500` — and root ignores permission bits, so as root the copy SUCCEEDS, the
// save does not throw, and the test fails on a system that is behaving correctly. (The design
// described this as passing vacuously as root; it is the other way round, but the remedy is the
// same.) Once the seam lands, faulting the `quarantine` phase directly is the better instrument;
// this one is kept because it exercises the real POSIX refusal rather than an injected error.
@Test(
    "A save refuses to write when the undecodable bytes cannot be preserved",
    .enabled(if: getuid() != 0)
)
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

private struct SavedMeeting: Codable, Equatable {
    let title: String
}

/// Decodes an element or records that it could not be decoded, without failing the whole array.
struct FailableDecodable<Wrapped: Decodable>: Decodable {
    let value: Wrapped?

    init(from decoder: Decoder) throws {
        value = try? Wrapped(from: decoder)
    }
}

// F211 — `save()` may now skip the *decode* of a file whose exact bytes it has already decoded.
// These cases pin what a careless memory would break: any foreign write must still be seen, both
// when it is undecodable (preserve it) and when it is a valid generation (keep it as the backup).

@Test("A foreign corruption is still preserved even after this process has written the file (F211)")
func saveDoesNotLetItsWriteMemoryMaskAForeignCorruption() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("WhisperMeetBackupTests-\(UUID().uuidString)", isDirectory: true)
    let primaryURL = directory.appendingPathComponent("meetings.json")
    let backupURL = directory.appendingPathComponent("meetings.backup.json")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = BackupJSONStore<[SavedMeeting]>(primaryURL: primaryURL, backupURL: backupURL)

    // Two saves, so the store has written — and could have cached — both files.
    try store.save([SavedMeeting(title: "First")])
    try store.save([SavedMeeting(title: "Second")])

    // Someone else replaces the primary with bytes that do not decode. The F187 rule says those
    // bytes are preserved before anything overwrites them; a cache keyed on "I wrote this" and not
    // on the file's identity would skip the check and destroy them.
    let foreign = Data("foreign-corruption".utf8)
    try foreign.write(to: primaryURL, options: .atomic)

    try store.save([SavedMeeting(title: "Third")])

    let names = try FileManager.default.contentsOfDirectory(atPath: directory.path)
    let quarantined = names.filter { $0.contains(".unreadable-") }
    #expect(quarantined.count == 1)
    let preserved = try quarantined.map { try Data(contentsOf: directory.appendingPathComponent($0)) }
    #expect(preserved.contains(foreign))
}

@Test("A foreign valid generation becomes the backup, not this process's cached bytes (F211)")
func saveUsesTheForeignGenerationAsBackupNotItsCachedBytes() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("WhisperMeetBackupTests-\(UUID().uuidString)", isDirectory: true)
    let primaryURL = directory.appendingPathComponent("meetings.json")
    let backupURL = directory.appendingPathComponent("meetings.backup.json")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let store = BackupJSONStore<[SavedMeeting]>(primaryURL: primaryURL, backupURL: backupURL)

    try store.save([SavedMeeting(title: "Ours")])

    // A different writer lands a perfectly valid generation we have never seen. `save` keeps the
    // existing primary as the new backup, so that generation must survive into the backup — a stale
    // cache would silently write our own older bytes there and drop it.
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
    encoder.dateEncodingStrategy = .iso8601
    let foreignBytes = try encoder.encode([SavedMeeting(title: "Theirs")])
    try foreignBytes.write(to: primaryURL, options: .atomic)

    try store.save([SavedMeeting(title: "Next")])

    #expect(try Data(contentsOf: backupURL) == foreignBytes)
    let reloaded = try #require(try store.load())
    #expect(reloaded.value == [SavedMeeting(title: "Next")])
}

// MARK: - F197: salvage must present the best copy, not the first one that works

@Test("Salvage picks the copy that rescues the most records, not the first (F197)")
func salvagePicksTheRichestCopy() throws {
    // `load()` iterated `[primaryURL, backupURL]` and returned the first successful salvage. So a
    // primary that rescues two records beat a backup that would rescue nine, and the user was shown
    // two. Nothing was lost — both files are quarantined and the library goes read-only — but the
    // poorer result is what they were told about and what they had to work from.
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("F197-\(UUID().uuidString)", isDirectory: true)
    let primaryURL = directory.appendingPathComponent("meetings.json")
    let backupURL = directory.appendingPathComponent("meetings.backup.json")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    // Primary rescues 1 of 3; backup rescues 3 of 4. Both are unreadable as a whole, so both reach
    // the element-wise salvage.
    try Data(#"[{"title":"one"},{"title":1},{"title":2}]"#.utf8).write(to: primaryURL)
    try Data(#"[{"title":"a"},{"title":"b"},{"title":"c"},{"title":9}]"#.utf8).write(to: backupURL)

    let store = BackupJSONStore<[SavedMeeting]>(
        primaryURL: primaryURL,
        backupURL: backupURL,
        salvage: elementWiseSalvage
    )

    let result = try #require(try store.load())
    #expect(result.value.map(\.title) == ["a", "b", "c"], "kept the poorer primary salvage")
    #expect(result.health == .partiallySalvaged(parkedIdentifiers: ["index 3"]))
}

@Test("A tie keeps the primary, so the choice is stable rather than arbitrary (F197)")
func salvageTieKeepsThePrimary() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("F197-tie-\(UUID().uuidString)", isDirectory: true)
    let primaryURL = directory.appendingPathComponent("meetings.json")
    let backupURL = directory.appendingPathComponent("meetings.backup.json")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    try Data(#"[{"title":"primary"},{"title":1}]"#.utf8).write(to: primaryURL)
    try Data(#"[{"title":"backup"},{"title":1}]"#.utf8).write(to: backupURL)

    let store = BackupJSONStore<[SavedMeeting]>(
        primaryURL: primaryURL,
        backupURL: backupURL,
        salvage: elementWiseSalvage
    )

    // Equal counts: prefer the primary, because it is the live generation and the one a later save
    // would be replacing. "Most records, primary on a tie" is a rule; "whichever came first" was an
    // accident of loop order that happened to agree with it.
    let result = try #require(try store.load())
    #expect(result.value.map(\.title) == ["primary"])
}

@Test("A backup that salvages nothing does not displace a primary that salvages something (F197)")
func anEmptyBackupSalvageIsNotPreferred() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("F197-empty-\(UUID().uuidString)", isDirectory: true)
    let primaryURL = directory.appendingPathComponent("meetings.json")
    let backupURL = directory.appendingPathComponent("meetings.backup.json")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    try Data(#"[{"title":"kept"},{"title":1}]"#.utf8).write(to: primaryURL)
    try Data(#"[{"title":1},{"title":2}]"#.utf8).write(to: backupURL)

    let store = BackupJSONStore<[SavedMeeting]>(
        primaryURL: primaryURL,
        backupURL: backupURL,
        salvage: elementWiseSalvage
    )

    let result = try #require(try store.load())
    #expect(result.value.map(\.title) == ["kept"])
}

/// The shape `MeetingStore.salvageMeetings` has: keep what decodes, park what does not, nil when
/// nothing decoded at all.
private let elementWiseSalvage: @Sendable (Data) -> SalvagedValue<[SavedMeeting]>? = { data in
    let elements = (try? JSONDecoder().decode([FailableDecodable<SavedMeeting>].self, from: data)) ?? []
    var kept: [SavedMeeting] = []
    var parked: [String] = []
    for (index, element) in elements.enumerated() {
        if let value = element.value { kept.append(value) } else { parked.append("index \(index)") }
    }
    return kept.isEmpty ? nil : SalvagedValue(value: kept, parkedIdentifiers: parked)
}
