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
    await model.refreshLinkedRecordingOffer(id: id)
    try #require(model.linkedRecordingOffers[id]?.standardizedFileURL == original.resolvingSymlinksInPath().standardizedFileURL)

    let copied = await model.copyLinkedRecordingIntoLibrary(id: id)

    #expect(copied, "\(model.alertMessage ?? "nil")")
    #expect(entryType(link) == .typeRegular, "the recording is still a link")
    #expect(try Data(contentsOf: link) == originalBytes)
    #expect(try Data(contentsOf: original) == originalBytes, "the original changed")
    #expect(entryType(original) == .typeRegular)
    #expect(model.linkedRecordingOffers[id] == nil, "the offer is still shown")
    await model.refreshLinkedRecordingOffer(id: id)
    #expect(model.linkedRecordingOffers[id] == nil, "a regular file is offered a copy")
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
    await model.refreshLinkedRecordingOffer(id: id)
    #expect(model.linkedRecordingOffers[id] == nil)

    #expect(!(await model.copyLinkedRecordingIntoLibrary(id: id)))
    #expect(entryType(link) == .typeSymbolicLink, "the link was touched")
    // Round 2: the report must not send the user to a button this meeting does not show.
    let messages = AppModel.integrityMessages(model.verifyLibraryIntegrity()).joined(separator: "\n")
    #expect(messages.contains("link to a file somewhere else"), "\(messages)")
    #expect(!messages.contains("Copy Linked Recording Into Library"), "a hidden button was named: \(messages)")
}

@Test("A second Copy while the first is running is turned away quietly, so the success is what the user reads (F704)")
@MainActor
func aDoubleClickDoesNotReportAFailureOverASuccess() async throws {
    let (root, model, id, link, original) = try makeLinkedLibrary("double")
    defer { try? FileManager.default.removeItem(at: root) }
    let originalBytes = try Data(contentsOf: original)

    async let first = model.copyLinkedRecordingIntoLibrary(id: id)
    async let second = model.copyLinkedRecordingIntoLibrary(id: id)
    let firstOutcome = await first
    let secondOutcome = await second
    let outcomes: [Bool] = [firstOutcome, secondOutcome]

    #expect(outcomes.filter { $0 }.count == 1, "\(outcomes)")
    #expect(model.alertMessage?.contains("now has its own copy of its recording") == true, "\(model.alertMessage ?? "nil")")
    #expect(entryType(link) == .typeRegular)
    #expect(try Data(contentsOf: link) == originalBytes)
}

@Test("The swap re-checks that the recording is still a link, and leaves anything else at that name alone (F704)")
func theSwapRefusesWhenTheRecordingIsNoLongerALink() throws {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("F704-recheck-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let original = folder.appendingPathComponent("original.wav")
    try Data("the original".utf8).write(to: original)
    // What a check made earlier found as a link is, by the swap, somebody's regular file.
    let recording = folder.appendingPathComponent("recording.wav")
    try Data("written meanwhile".utf8).write(to: recording)

    #expect(throws: (any Error).self) { try AppModel.replaceLink(recording, withCopyOf: original) }

    #expect(try Data(contentsOf: recording) == Data("written meanwhile".utf8), "a file that is not a link was replaced")
    #expect(try Data(contentsOf: original) == Data("the original".utf8))
    let names = try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted()
    #expect(names == ["original.wav", "recording.wav"], "the partial copy was left: \(names)")
}

@Test("The meeting page offers the copy beside its other recording controls (F704)")
func theMeetingPageOffersTheCopy() throws {
    // No view harness here (F174), so the control is pinned as comment-stripped source (F285).
    let source = SourceAssertion.stripComments(
        try String(contentsOf: SourceAssertion.url("Sources/WhisperMeet/ContentView.swift"), encoding: .utf8)
    )
    let compact = source.filter { !$0.isWhitespace }
    #expect(compact.contains("ifmodel.linkedRecordingOffers[meetingID]!=nil{Button(\"CopyLinkedRecordingIntoLibrary\"){Task{awaitmodel.copyLinkedRecordingIntoLibrary(id:meetingID)}}"))
    #expect(compact.contains(".disabled(model.copyingLinkedRecordingIDs.contains(meetingID))"))
    // Round 2: the page reads the cached answer, checked off the main actor when the meeting is shown,
    // and never asks the filesystem itself.
    #expect(compact.contains(".task(id:meetingID){awaitmodel.refreshLinkedRecordingOffer(id:meetingID)}"))
    #expect(!compact.contains("linkedOriginal("), "the view stats the original itself")
}

@Test("The link's original is checked off the main actor, and the page reads the answer (F704)")
@MainActor
func theLinkedOriginalIsCheckedOffTheMainActor() async throws {
    let (root, model, id, _, original) = try makeLinkedLibrary("offmain")
    defer { try? FileManager.default.removeItem(at: root) }
    final class Seen: @unchecked Sendable { var onMain: Bool?; let lock = NSLock() }
    let seen = Seen()
    let real = model.linkedRecordingProbe
    model.linkedRecordingProbe = { link in
        seen.lock.withLock { seen.onMain = Thread.isMainThread }
        return real(link)
    }

    await model.refreshLinkedRecordingOffer(id: id)

    let ranOnMain = try #require(seen.lock.withLock { seen.onMain }, "the probe never ran")
    #expect(!ranOnMain, "the original was stat'ed on the main thread")
    #expect(model.linkedRecordingOffers[id]?.standardizedFileURL == original.resolvingSymlinksInPath().standardizedFileURL)
}

@Test("The swap's size check passes a whole copy and refuses a short one, leaving the link (F704)")
func theSizeCheckPassesAWholeCopyAndRefusesAShortOne() throws {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("F704-size-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let original = folder.appendingPathComponent("original.wav")
    let bytes = Data(repeating: 7, count: 10_000)
    try bytes.write(to: original)
    let link = folder.appendingPathComponent("recording.wav")
    try FileManager.default.createSymbolicLink(at: link, withDestinationURL: original)
    let bothNames: [String] = ["original.wav", "recording.wav"]

    // A copy that came out short: refused, the link kept, nothing left behind.
    #expect(throws: (any Error).self) {
        try AppModel.replaceLink(link, withCopyOf: original) { _, destination in
            try Data(repeating: 7, count: 9_000).write(to: destination)
        }
    }
    #expect(entryType(link) == .typeSymbolicLink, "a short copy replaced the link")
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == bothNames)

    // A well-formed copy passes the same check and takes the link's place.
    try AppModel.replaceLink(link, withCopyOf: original)
    #expect(entryType(link) == .typeRegular)
    #expect(try Data(contentsOf: link) == bytes)
    #expect(try Data(contentsOf: original) == bytes, "the original changed")
    #expect(try FileManager.default.contentsOfDirectory(atPath: folder.path).sorted() == bothNames)
}
