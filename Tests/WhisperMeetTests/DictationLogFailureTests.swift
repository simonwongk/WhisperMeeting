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
