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
    #expect(recovered.source == .backup)
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

private struct SavedMeeting: Codable, Equatable {
    let title: String
}
