import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F912 — a link import's recovery conversion that outlasts the launch's wait.
//
// `0da8039` (F453) capped how long the launch waits for the conversion of an interrupted link
// import's download at 30 s, and a longer one was killed and listed as "Unfinished import from
// <host>", whose remedy is importing the link again — a second download of something complete on
// disk. The launch still waits that long at most, but a conversion still going then is left to
// finish in the background: the launch notice says so, and the meeting is added when it ends — or,
// if it cannot be finished, the unfinished entry is. A quit before then stops it and leaves the
// folder for the next launch, as a cancellation does. The conversion's own expiry is its output
// (`InterruptedLinkImportExtraction.finish(outputStallTimeout:)`), tested in WhisperCoreTests.

/// A gate the stubbed conversion waits at, opened by the test; the wait also ends on its own after
/// `selfReleaseAfter`, so a launch that (wrongly) waits for the whole conversion cannot hang a test.
private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var open = false
    var isOpen: Bool { lock.withLock { open } }
    func openUp() { lock.withLock { open = true } }

    /// Waits for the gate; rethrows a cancellation at once.
    func wait(selfReleaseAfter seconds: TimeInterval = 3) async throws {
        let deadline = ProcessInfo.processInfo.systemUptime + seconds
        while !isOpen, ProcessInfo.processInfo.systemUptime < deadline {
            try Task.checkCancellation()
            try await Task.sleep(for: .milliseconds(20))
        }
        try Task.checkCancellation()
    }
}

/// `Recordings/<id>/` as the interrupted import left it: the sidecar, the complete download, and the
/// WAV ffmpeg never finished (placeholder sizes in its header).
private func makeInterruptedExtraction(in root: URL) throws -> (id: UUID, folder: URL) {
    let id = UUID()
    let folder = root.appendingPathComponent("Recordings/\(id.uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let source = MediaSource(
        kind: MediaSource.webKind, pageURL: "https://example.com/watch?v=abc123", host: "example.com",
        videoID: "abc123", uploader: "Example Channel", fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)
    )
    try JSONEncoder().encode(source).write(to: folder.appendingPathComponent(MediaSource.sidecarFilename))
    try Data("a complete downloaded file".utf8).write(to: folder.appendingPathComponent("recording.webm"))
    var partial = WAVWriter.wavData(from: [Float](repeating: 0.1, count: 8_000), sampleRate: 16_000)
    let placeholder = Data([0xFF, 0xFF, 0xFF, 0xFF])
    partial.replaceSubrange(4..<8, with: placeholder)
    let dataTag = try #require(partial.range(of: Data("data".utf8)))
    partial.replaceSubrange(dataTag.upperBound..<(dataTag.upperBound + 4), with: placeholder)
    try partial.write(to: folder.appendingPathComponent("recording.wav"))
    return (id, folder)
}

@MainActor
private func makeModel(root: URL) -> AppModel {
    let model = AppModel(
        store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(),
        defaults: UserDefaults(suiteName: testSuiteName())!
    )
    model.crashReportsSince = { _ in [] }
    // The launch waits this long for a conversion before leaving it to finish in the background.
    model.linkImportConversionWait = 0.2
    return model
}

@MainActor
private func waitForMeeting(_ id: UUID, in model: AppModel) async throws -> MeetingRecord {
    let deadline = SuspendingClock.now + .seconds(30)
    while model.store.meeting(id: id) == nil, SuspendingClock.now < deadline {
        try await Task.sleep(for: .milliseconds(20))
    }
    return try #require(model.store.meeting(id: id), "the meeting was not added within 30 s")
}

@MainActor
@Test("A conversion that outlasts the launch's wait finishes in the background, and its meeting is added when it ends (F912)")
func aConversionPastTheLaunchWaitFinishesInTheBackground() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("F912-background-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let (id, folder) = try makeInterruptedExtraction(in: root)
    let model = makeModel(root: root)
    let gate = Gate()
    let ended = Gate()
    model.finishInterruptedLinkImportExtraction = { download in
        defer { ended.openUp() }
        try await gate.wait(selfReleaseAfter: 120)
        let finished = download.deletingLastPathComponent().appendingPathComponent("recording.wav")
        try WAVWriter.wavData(from: [Float](repeating: 0.1, count: 8_000), sampleRate: 16_000).write(to: finished)
        return finished
    }

    await model.performStartupRecovery()

    try #require(!gate.isOpen, "fixture: the gate opened before the launch returned")
    // The conversion was still running when the launch returned: a launch that waited for it would
    // return only after the stub released itself, with the stub ended.
    #expect(!ended.isOpen, "the launch waited for the whole conversion")
    #expect(model.store.meeting(id: id) == nil, "the launch waited for the whole conversion")
    let alert = model.alertMessage ?? ""
    #expect(alert.contains(AppModel.linkImportStillConverting(host: "example.com")), "\(alert)")
    #expect(!alert.contains(AppModel.unfinishedLinkImportTitle(host: "example.com")), "listed as unfinished: \(alert)")
    #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("recording.webm").path))

    gate.openUp()
    let meeting = try await waitForMeeting(id, in: model)

    #expect(meeting.status == .recorded, "\(meeting.title): \(meeting.errorMessage ?? "")")
    #expect(meeting.recordingPath.hasSuffix("recording.wav"), "\(meeting.recordingPath)")
    #expect(abs(meeting.duration - 0.5) < 0.05, "duration \(meeting.duration)")
    #expect(meeting.source?.host == "example.com")
    #expect(meeting.recoverySource == RecoveredRecording.Source.importedRecording.rawValue)
    #expect(MeetingStore(rootDirectory: root).meeting(id: id) != nil, "the added meeting never reached the index")
    #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("recording.webm").path), "the download was removed")
    #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(InterruptedLinkImportExtraction.convertedDownloadFilename).path),
            "the conversion's length was not recorded for Shrink (F947)")
    let said = model.alertMessage ?? ""
    #expect(said.contains(meeting.title), "nothing said the meeting was added: \(said)")
}

@MainActor
@Test("A background conversion that cannot be finished lists the unfinished import when it ends, with its download kept (F912)")
func aBackgroundConversionThatFailsListsTheUnfinishedImport() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("F912-fails-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let (id, folder) = try makeInterruptedExtraction(in: root)
    let model = makeModel(root: root)
    let gate = Gate()
    let ended = Gate()
    let stalled = MediaDownloadError.extractionStalled(60)
    model.finishInterruptedLinkImportExtraction = { _ in
        defer { ended.openUp() }
        try await gate.wait(selfReleaseAfter: 120)
        throw stalled
    }

    await model.performStartupRecovery()
    try #require(!ended.isOpen, "the launch waited for the whole conversion")
    try #require(model.store.meeting(id: id) == nil, "the launch waited for the whole conversion")
    gate.openUp()
    let meeting = try await waitForMeeting(id, in: model)

    #expect(meeting.status == .failed)
    #expect(meeting.title == AppModel.unfinishedLinkImportTitle(host: "example.com"))
    #expect(meeting.errorMessage == AppModel.unfinishedLinkImportMessage(reason: stalled.localizedDescription))
    #expect(meeting.errorMessage?.localizedCaseInsensitiveContains("delete") == false, "\(meeting.errorMessage ?? "")")
    #expect(meeting.recordingPath.hasSuffix("recording.webm"), "\(meeting.recordingPath)")
    for name in ["recording.webm", "recording.wav", MediaSource.sidecarFilename] {
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path), "\(name) was removed")
    }
}

@MainActor
@Test("Quitting while a conversion finishes in the background stops it and leaves the folder for the next launch (F912)")
func quittingDuringABackgroundConversionLeavesTheFolder() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("F912-quit-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let (id, folder) = try makeInterruptedExtraction(in: root)
    let model = makeModel(root: root)
    let gate = Gate()
    let ended = Gate()
    // A stub that is not cancelled runs for longer than any wait below, so this test cannot pass by
    // the stub ending on its own.
    model.finishInterruptedLinkImportExtraction = { download in
        defer { ended.openUp() }
        try await gate.wait(selfReleaseAfter: 120)
        let finished = download.deletingLastPathComponent().appendingPathComponent("recording.wav")
        try WAVWriter.wavData(from: [Float](repeating: 0.1, count: 8_000), sampleRate: 16_000).write(to: finished)
        return finished
    }

    let launched = ProcessInfo.processInfo.systemUptime
    await model.performStartupRecovery()
    try #require(!ended.isOpen, "the launch waited for the whole conversion")
    try #require(ProcessInfo.processInfo.systemUptime - launched < 20, "the launch waited for the whole conversion")
    try #require(model.store.meeting(id: id) == nil, "the launch waited for the whole conversion")
    try #require(!model.deferredLinkImportConversions.isEmpty, "fixture: no conversion was left running in the background")

    model.cancelWorkForQuit()

    // The stub observed the cancellation and ended without finishing, and the background work ended.
    let deadline = SuspendingClock.now + .seconds(30)
    while !(ended.isOpen && model.deferredLinkImportConversions.isEmpty), SuspendingClock.now < deadline {
        try await Task.sleep(for: .milliseconds(20))
    }
    try #require(ended.isOpen, "the conversion was not stopped by the quit")
    try #require(model.deferredLinkImportConversions.isEmpty, "the background work did not end after the quit")
    #expect(!gate.isOpen)
    #expect(model.store.meeting(id: id) == nil, "a cancelled conversion indexed a meeting")
    #expect(MeetingStore(rootDirectory: root).meeting(id: id) == nil)
    for name in ["recording.webm", "recording.wav", MediaSource.sidecarFilename] {
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path), "\(name) was removed")
    }
    // The next launch finds the folder as it was and converts it.
    let next = makeModel(root: root)
    next.finishInterruptedLinkImportExtraction = { download in
        let finished = download.deletingLastPathComponent().appendingPathComponent("recording.wav")
        try WAVWriter.wavData(from: [Float](repeating: 0.1, count: 8_000), sampleRate: 16_000).write(to: finished)
        return finished
    }
    await next.performStartupRecovery()
    #expect(next.store.meeting(id: id)?.status == .recorded, "\(String(describing: next.store.meeting(id: id)))")
}
