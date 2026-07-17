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

@Test("Unreadable primary and backup files are preserved for manual recovery")
func preservesUnreadableJSONCopies() throws {
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
    let primaryBytes = Data("broken-primary".utf8)
    let backupBytes = Data("broken-backup".utf8)
    try primaryBytes.write(to: primaryURL)
    try backupBytes.write(to: backupURL)

    #expect(throws: BackupJSONStoreError.noReadableCopy(
        primary: "meetings.json",
        backup: "meetings.backup.json"
    )) {
        try store.load()
    }
    #expect(try Data(contentsOf: primaryURL) == primaryBytes)
    #expect(try Data(contentsOf: backupURL) == backupBytes)
}

private struct SavedMeeting: Codable, Equatable {
    let title: String
}
