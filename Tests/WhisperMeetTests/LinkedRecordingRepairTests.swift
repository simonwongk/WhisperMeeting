import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F704 — before F494, importing a link wrote `Recordings/<id>/recording.<ext>` as a symbolic link to the
// user's file (`copyItem` copies a link as a link). Such a meeting plays only while the original stays
// where it is, and backups skip it. Verify Library now reports it, and the meeting's page offers to
// copy the original in while it still exists. Fixtures are temp files; never a user's recording.

@MainActor
private func makeLinkedLibrary(_ label: String) throws -> (root: URL, model: AppModel, id: UUID, link: URL, original: URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("F704-\(label)-\(UUID().uuidString)", isDirectory: true)
    let library = root.appendingPathComponent("Library", isDirectory: true)
    let elsewhere = root.appendingPathComponent("Elsewhere", isDirectory: true)
    try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
    let original = elsewhere.appendingPathComponent("Board call.wav")
    try WAVWriter.wavData(from: [Float](repeating: 0.2, count: 16_000 * 2), sampleRate: 16_000).write(to: original)
    let id = UUID()
    let folder = library.appendingPathComponent("Recordings/\(id.uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let link = folder.appendingPathComponent("recording.wav")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
    let store = MeetingStore(rootDirectory: library)
    store.upsert(MeetingRecord(
        id: id, title: "Imported as a link", duration: 2,
        recordingPath: "Recordings/\(id.uuidString)/recording.wav", status: .recorded
    ))
    let model = AppModel(store: store, recorder: AudioCaptureEngine(), defaults: UserDefaults(suiteName: testSuiteName())!)
    return (root, model, id, link, original)
}

private func entryType(_ url: URL) -> FileAttributeType? {
    (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType
}

@Test("Verify Library reports a recording that is a symbolic link, and nothing false about its audio (F704)")
@MainActor
func verifyLibraryReportsALinkedRecording() throws {
    let (root, model, id, _, _) = try makeLinkedLibrary("report")
    defer { try? FileManager.default.removeItem(at: root) }

    let results = model.verifyLibraryIntegrity()

    let result = try #require(results.first { $0.meeting.id == id }, "a linked recording was reported as clean")
    #expect(result.findings == [.recordingIsSymbolicLink], "\(result.findings)")
    let expected: [String] = ["Copy Linked Recording Into Library"]
    #expect(AppModel.integrityMessages(results).contains { $0.contains(expected[0]) })
}

@Test("Copying the linked recording in replaces the link with the original's bytes and leaves the original alone (F704)")
@MainActor
func copyingTheLinkedRecordingInMakesItTheMeetingsOwn() async throws {
    let (root, model, id, link, original) = try makeLinkedLibrary("repair")
    defer { try? FileManager.default.removeItem(at: root) }
    let originalBytes = try Data(contentsOf: original)
    try #require(model.linkedRecordingOriginal(id: id)?.standardizedFileURL == original.resolvingSymlinksInPath().standardizedFileURL)

    let copied = await model.copyLinkedRecordingIntoLibrary(id: id)

    #expect(copied, "\(model.alertMessage ?? "nil")")
    #expect(entryType(link) == .typeRegular, "the recording is still a link")
    #expect(try Data(contentsOf: link) == originalBytes)
    #expect(try Data(contentsOf: original) == originalBytes, "the original changed")
    #expect(entryType(original) == .typeRegular)
    #expect(model.linkedRecordingOriginal(id: id) == nil, "the offer is still shown")
    #expect(model.verifyLibraryIntegrity().isEmpty, "\(model.verifyLibraryIntegrity().map(\.findings))")
    let leftovers = try FileManager.default.contentsOfDirectory(atPath: link.deletingLastPathComponent().path)
    #expect(leftovers == ["recording.wav"], "\(leftovers)")
}

@Test("A link whose original has gone is reported, offers no copy, and is left as it is (F704)")
@MainActor
func aDanglingLinkIsReportedAndLeftAlone() async throws {
    let (root, model, id, link, original) = try makeLinkedLibrary("dangling")
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.removeItem(at: original)

    let findings = try #require(model.verifyLibraryIntegrity().first { $0.meeting.id == id }).findings
    #expect(findings.contains(.recordingIsSymbolicLink))
    #expect(findings.contains(.recordingMissing))
    #expect(model.linkedRecordingOriginal(id: id) == nil)

    #expect(!(await model.copyLinkedRecordingIntoLibrary(id: id)))
    #expect(entryType(link) == .typeSymbolicLink, "the link was touched")
}

@Test("The meeting page offers the copy beside its other recording controls (F704)")
func theMeetingPageOffersTheCopy() throws {
    // No view harness here (F174), so the control is pinned as comment-stripped source (F285).
    let source = SourceAssertion.stripComments(
        try String(contentsOf: SourceAssertion.url("Sources/WhisperMeet/ContentView.swift"), encoding: .utf8)
    )
    let compact = source.filter { !$0.isWhitespace }
    #expect(compact.contains("ifmodel.linkedRecordingOriginal(id:meetingID)!=nil{Button(\"CopyLinkedRecordingIntoLibrary\"){Task{awaitmodel.copyLinkedRecordingIntoLibrary(id:meetingID)}}"))
}
