import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F539 — a link import that is refused or fails said so on the window's root `.alert`
// (`model.alertMessage`), and the Add-from-a-Link sheet is a sheet of that same window: macOS
// presents one sheet per window and an ancestor's alert does not go over it. The user pressed
// Download, the "Checking the link…" spinner stopped, the field came back, and nothing said why.
// A pasted address with no `https://`, a playlist, a live stream, a full disk, a downloader that
// died: all of them looked like the button doing nothing.
//
// The sheet now says it itself. `importFromURL` returns what happened (`LinkImportOutcome`) and
// raises nothing on the root alert, so every refusal reaches the one place that is on screen.
// These tests walk EVERY way `importFromURL` can decline (there are eleven), and for each one assert
// both halves: the outcome carries the sentence, and neither of the two things the root alert reads
// (`alertMessage`, `store.storageErrorMessage`) was touched.

private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var entered = false
    private var open = false
    func enter() { lock.withLock { entered = true } }
    var hasEntered: Bool { lock.withLock { entered } }
    func release() { lock.withLock { open = true } }
    var isOpen: Bool { lock.withLock { open } }
}

private struct ProbeBroke: LocalizedError { var errorDescription: String? { "the downloader could not look that up" } }

@MainActor
private func waitUntil(_ what: String, _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(30)
    while !condition(), Date() < deadline {
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    try #require(condition(), "timed out waiting for \(what)")
}

private let goodLink = "https://www.youtube.com/watch?v=abc123"

/// A petabyte: more than any Mac's volume has free, and nowhere near the `Int64` edge that F462
/// part 3 is about, so the free-space refusal is reached without that arithmetic.
private let aPetabyte: Int64 = 1_000_000_000_000_000

@MainActor
private func makeModel(brokenIndex: Bool = false) throws -> (AppModel, URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("F539-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    if brokenIndex {
        // Both copies unreadable: the store opens degraded, which is what refuses an import.
        try Data("broken-primary".utf8).write(to: root.appendingPathComponent("meetings.json"))
        try Data("broken-backup".utf8).write(to: root.appendingPathComponent("meetings.backup.json"))
    }
    let defaults = try #require(UserDefaults(suiteName: testSuiteName()))
    let model = AppModel(
        store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(), defaults: defaults,
        whisperExecutable: { URL(fileURLWithPath: "/usr/bin/true") }, qwenInstalled: { true }
    )
    model.linkImportEnabled = true
    // A finished import starts a transcription; keep it off the real engine.
    model.runTranscriptionEngineOverride = { _, _ in
        TranscriptionResult(id: "stub", text: "words", languageCode: "en", audioDuration: 1, confidence: nil,
                            segments: [TranscriptSegment(speaker: nil, start: 0, end: 1, text: "words")])
    }
    model.probeMediaURL = { _ in MediaProbe(title: "A talk", durationSeconds: 60, language: "en") }
    model.downloadMedia = { _, directory, _ in
        let file = directory.appendingPathComponent("recording.wav")
        try Data([0x52, 0x49, 0x46, 0x46]).write(to: file)
        return file
    }
    model.downloadCaptions = { _, _, _ in [] }
    return (model, root)
}

/// Neither of the two places the window's alert reads is set: that alert is behind the open sheet.
@MainActor
private func expectNothingRaisedBehindTheSheet(_ model: AppModel, _ branch: String) {
    #expect(model.alertMessage == nil, "\(branch): raised on the root alert, behind the sheet: \(model.alertMessage ?? "")")
    #expect(model.store.storageErrorMessage == nil, "\(branch): the store's error would land behind the sheet")
}

/// One attempt, asserting what it returned and that nothing was raised behind the sheet.
@MainActor
private func expectRefusal(
    _ model: AppModel, _ link: String, _ branch: String, says expected: String? = nil
) async -> String? {
    let outcome = await model.importFromURL(link)
    expectNothingRaisedBehindTheSheet(model, branch)
    guard case let .refused(message) = outcome else {
        Issue.record("\(branch): expected a refusal, got \(outcome)")
        return nil
    }
    if let expected { #expect(message == expected, "\(branch): said the wrong thing") }
    #expect(!message.isEmpty, "\(branch): a refusal with no sentence leaves the sheet as silent as before")
    return message
}

@MainActor
@Test("A link import that is switched off says so to the sheet (F539)")
func linkImportSwitchedOffIsSaidInTheSheet() async throws {
    let (model, root) = try makeModel()
    defer { try? FileManager.default.removeItem(at: root) }
    model.linkImportEnabled = false

    _ = await expectRefusal(model, goodLink, "switched off", says: AppModel.linkImportSwitchedOff)
}

@MainActor
@Test("A link that is not a web link, and a playlist, say so to the sheet (F539)")
func unusableLinksAreSaidInTheSheet() async throws {
    let (model, root) = try makeModel()
    defer { try? FileManager.default.removeItem(at: root) }

    // The shape the ticket names: a pasted address with no scheme.
    _ = await expectRefusal(model, "www.youtube.com/watch?v=abc123", "no scheme", says: AppModel.linkImportNotAWebLink)
    _ = await expectRefusal(
        model, "https://www.youtube.com/playlist?list=PL1", "playlist",
        says: MediaDownloadError.playlistNotSupported.localizedDescription
    )
}

@MainActor
@Test("A probe that fails, and a live stream, say so to the sheet (F539)")
func probeFailuresAreSaidInTheSheet() async throws {
    let (model, root) = try makeModel()
    defer { try? FileManager.default.removeItem(at: root) }

    model.probeMediaURL = { _ in throw ProbeBroke() }
    _ = await expectRefusal(model, goodLink, "probe failed", says: ProbeBroke().localizedDescription)

    model.probeMediaURL = { _ in MediaProbe(title: "Live", isLive: true) }
    _ = await expectRefusal(
        model, goodLink, "live stream", says: MediaDownloadError.liveInProgress.localizedDescription
    )
}

@MainActor
@Test("Too little free space says so to the sheet, naming how much was needed (F539)")
func notEnoughSpaceIsSaidInTheSheet() async throws {
    let (model, root) = try makeModel()
    defer { try? FileManager.default.removeItem(at: root) }
    // The check is skipped when the volume reports no free-space figure, so require one: otherwise
    // this would fail as a claim about the check when it is a fact about the host.
    model.refreshRecordingPreflight()
    try #require(model.recordingPreflight.availableStorageBytes != nil, "this volume reports no free-space figure")
    model.probeMediaURL = { _ in MediaProbe(title: "Huge", durationSeconds: 60, approximateBytes: aPetabyte) }

    let message = try #require(await expectRefusal(model, goodLink, "not enough space"))
    #expect(message.contains(ByteCountFormatter.string(fromByteCount: aPetabyte, countStyle: .file)),
            "the refusal names how much space the download needs: \(message)")
    #expect(model.store.meetings.isEmpty)
}

@MainActor
@Test("A download that fails says so to the sheet and leaves nothing behind (F539)")
func downloadFailureIsSaidInTheSheet() async throws {
    let (model, root) = try makeModel()
    defer { try? FileManager.default.removeItem(at: root) }
    model.downloadMedia = { _, _, _ in throw MediaDownloadError.missingOutput }

    _ = await expectRefusal(
        model, goodLink, "download failed", says: MediaDownloadError.missingOutput.localizedDescription
    )
    #expect(model.store.meetings.isEmpty)
    #expect(!model.isImporting, "the import latch is released, so the user can try again")
}

@MainActor
@Test("A read-only library, and one mid-restore, refuse a link and say so to the sheet (F539)")
func libraryRefusalsAreSaidInTheSheet() async throws {
    // Read-only.
    let (degraded, degradedRoot) = try makeModel(brokenIndex: true)
    defer { try? FileManager.default.removeItem(at: degradedRoot) }
    try #require(degraded.store.isDegraded)
    _ = await expectRefusal(degraded, goodLink, "read-only library", says: ReadOnlyLibraryNotice.actionRefused("Import"))

    // Mid-restore.
    let (restoring, restoringRoot) = try makeModel()
    defer { try? FileManager.default.removeItem(at: restoringRoot) }
    restoring.store.beginLibraryRestore()
    defer { restoring.store.endLibraryRestore() }
    _ = await expectRefusal(restoring, goodLink, "library restoring", says: AppModel.libraryRestoringMessage("Import"))
}

@MainActor
@Test("A link started while another import or a model install runs says so to the sheet (F539)")
func busyRefusalsAreSaidInTheSheet() async throws {
    // Another import in flight: the first one's download is held open.
    let (busy, busyRoot) = try makeModel()
    defer { try? FileManager.default.removeItem(at: busyRoot) }
    let download = Gate()
    busy.downloadMedia = { _, directory, _ in
        download.enter()
        while !download.isOpen { try await Task.sleep(nanoseconds: 2_000_000) }
        let file = directory.appendingPathComponent("recording.wav")
        try Data([0x52, 0x49, 0x46, 0x46]).write(to: file)
        return file
    }
    let first = Task { await busy.importFromURL(goodLink) }
    try await waitUntil("the first download to start") { download.hasEntered }
    _ = await expectRefusal(busy, "https://www.youtube.com/watch?v=second", "another import running", says: AppModel.linkImportBusy)
    download.release()
    let firstOutcome = await first.value
    #expect(firstOutcome.meetingID != nil, "the import that was already running was not disturbed: \(firstOutcome)")

    // A recognition-model install in flight.
    let (installing, installingRoot) = try makeModel()
    defer { try? FileManager.default.removeItem(at: installingRoot) }
    let install = Gate()
    installing.installerScriptURL = { _ in URL(fileURLWithPath: "/usr/bin/true") }
    installing.runInstallerJob = { _ in
        install.enter()
        while !install.isOpen { try await Task.sleep(nanoseconds: 2_000_000) }
    }
    installing.installLocalWhisper()
    try await waitUntil("the install to start") { install.hasEntered }
    _ = await expectRefusal(installing, goodLink, "a model install running", says: AppModel.linkImportInstallRunning)
    install.release()
    try await waitUntil("the install to end") { !installing.isInstallingRuntime }
}

@MainActor
@Test("A refusal is recoverable: the same sheet imports once the cause is gone (F539)")
func aRefusalLeavesTheImportReadyToTryAgain() async throws {
    let (model, root) = try makeModel()
    defer { try? FileManager.default.removeItem(at: root) }
    model.linkImportEnabled = false
    _ = await expectRefusal(model, goodLink, "switched off", says: AppModel.linkImportSwitchedOff)

    model.linkImportEnabled = true
    let outcome = await model.importFromURL(goodLink)
    let id = try #require(outcome.meetingID, "\(outcome)")
    #expect(model.store.meeting(id: id) != nil)
}

// The two outcomes that are not failures say nothing to the sheet and raise nothing either.
@MainActor
@Test("A long video asks for confirmation and a Stop says nothing: neither is a refusal (F539)")
func confirmationAndStopAreNotRefusals() async throws {
    let (model, root) = try makeModel()
    defer { try? FileManager.default.removeItem(at: root) }

    model.probeMediaURL = { _ in MediaProbe(title: "Long", durationSeconds: 3 * 3_600, language: "en") }
    #expect(await model.importFromURL(goodLink) == .needsConfirmation)
    #expect(model.pendingLongMediaConfirmation?.title == "Long")
    expectNothingRaisedBehindTheSheet(model, "needs confirmation")

    model.pendingLongMediaConfirmation = nil
    model.probeMediaURL = { _ in throw CancellationError() }
    #expect(await model.importFromURL(goodLink) == .cancelled)
    expectNothingRaisedBehindTheSheet(model, "stopped during the probe")

    model.probeMediaURL = { _ in MediaProbe(title: "A talk", durationSeconds: 60, language: "en") }
    model.downloadMedia = { _, _, _ in throw CancellationError() }
    #expect(await model.importFromURL(goodLink) == .cancelled)
    expectNothingRaisedBehindTheSheet(model, "stopped during the download")
    #expect(!model.isImporting)
}

// The sheet cannot be rendered here (F174's standing reason), so what it does with the result is
// checked in the source, comments stripped first (F285).
@Test("The Add-from-a-Link sheet shows a refusal inline instead of leaving it to the window's alert (F539)")
func linkImportSheetShowsItsOwnError() throws {
    let source = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/ContentView.swift")
    let start = try #require(source.range(of: "private struct LinkImportSheet"))
    let rest = source[start.upperBound...]
    let end = rest.range(of: "\nprivate struct ")?.lowerBound ?? rest.endIndex
    // One line per statement, so a reformat of the switch does not read as a regression.
    let sheet = String(rest[..<end]).split(whereSeparator: \.isWhitespace).joined(separator: " ")

    #expect(sheet.contains("@State private var refusal: String?"), "the sheet keeps what the import said")
    #expect(sheet.contains("case let .refused(message): refusal = message"), "a refusal is kept")
    #expect(sheet.contains("Label(refusal, systemImage:"), "and drawn inside the sheet, beside the field")
    #expect(sheet.contains(".onChange(of: link) { refusal = nil }"), "and withdrawn when the link is edited")
    #expect(sheet.contains("let outcome = await model.importFromURL("), "the result is the outcome, not a bare id")
    #expect(!sheet.contains("alertMessage"), "nothing here leans on the window's alert")
}
