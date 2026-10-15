import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F944 — before F705 an import of a Finder alias copied the alias itself (`copyItem` copies a bookmark
// file as a file), so the library holds a ~1 KB `recording.<ext>` of bookmark bytes and a 0:00 meeting
// with no audio of its own, and nothing told the user why. Verify Library now names such a meeting
// (`IntegrityFinding.recordingIsAlias`), read-only: nothing resolves the bookmark or rebuilds the
// meeting — a meeting is never built from bookmark bytes without the user choosing it — and the words
// say what to do. Synthetic files in a temp library only.

private func makeTempLibrary() throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("F944-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(
        at: root.appendingPathComponent("Recordings", isDirectory: true), withIntermediateDirectories: true
    )
    return root
}

private func makeMeetingDirectory(_ id: UUID, in root: URL) throws -> URL {
    let dir = root.appendingPathComponent("Recordings", isDirectory: true)
        .appendingPathComponent(id.uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// A Finder alias at `alias` pointing at `target`, written the way Finder writes one (F705's fixture).
private func makeAlias(at alias: URL, to target: URL) throws {
    let bookmark = try target.bookmarkData(
        options: .suitableForBookmarkFile, includingResourceValuesForKeys: nil, relativeTo: nil
    )
    try URL.writeBookmarkData(bookmark, to: alias)
}

@MainActor
@Test("Verify Library names a meeting whose recording is a Finder alias's bytes, as an import before F705 left it, and says what to do (F944)")
func verifyLibraryNamesAnAliasRecording() async throws {
    let root = try makeTempLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    // The original the alias points at, somewhere outside the library; it is never touched.
    let originals = FileManager.default.temporaryDirectory.appendingPathComponent("F944-originals-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: originals, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: originals) }
    let original = originals.appendingPathComponent("take-3.m4a")
    try Data(repeating: 0x5A, count: 2_048).write(to: original)
    let originalBytes = try Data(contentsOf: original)

    let aliasID = UUID()
    let aliasRecording = try makeMeetingDirectory(aliasID, in: root).appendingPathComponent("recording.m4a")
    try makeAlias(at: aliasRecording, to: original)
    let values = try aliasRecording.resourceValues(forKeys: [.isAliasFileKey, .isRegularFileKey])
    try #require(values.isAliasFile == true && values.isRegularFile == true, "fixture: not an alias file")
    let aliasBytes = try Data(contentsOf: aliasRecording)

    let healthyID = UUID()
    let healthyRecording = try makeMeetingDirectory(healthyID, in: root).appendingPathComponent("recording.wav")
    try WAVWriter.wavData(from: [Float](repeating: 0.05, count: 16_000), sampleRate: 16_000).write(to: healthyRecording)

    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(),
                         defaults: UserDefaults(suiteName: testSuiteName())!)
    model.store.upsert(MeetingRecord(id: aliasID, title: "Board call", duration: 0,
                                     recordingPath: "Recordings/\(aliasID.uuidString)/recording.m4a", status: .recorded))
    model.store.upsert(MeetingRecord(id: healthyID, title: "Healthy", duration: 1,
                                     recordingPath: "Recordings/\(healthyID.uuidString)/recording.wav", status: .recorded))

    let results = model.verifyLibraryIntegrity()
    let flagged = results.first { $0.meeting.id == aliasID }
    #expect(flagged?.findings.contains(.recordingIsAlias) == true, "\(results.map { ($0.meeting.title, $0.findings) })")
    #expect(!results.contains { $0.meeting.id == healthyID }, "a real recording was named")

    // The button's words: the title, that it is an alias, and what to do.
    model.verifyLibrary()
    let alert = model.alertMessage ?? ""
    #expect(alert.contains("Board call"), "\(alert)")
    #expect(alert.localizedCaseInsensitiveContains("alias"), "\(alert)")
    #expect(alert.localizedCaseInsensitiveContains("import"), "\(alert)")
    #expect(alert.contains("found problems with 1 recording"), "\(alert)")

    // Read-only: the alias's bytes and the original are as they were, and the meeting is unchanged.
    #expect(try Data(contentsOf: aliasRecording) == aliasBytes)
    #expect(try Data(contentsOf: original) == originalBytes)
    #expect(model.store.meeting(id: aliasID)?.recordingPath == "Recordings/\(aliasID.uuidString)/recording.m4a")
}
