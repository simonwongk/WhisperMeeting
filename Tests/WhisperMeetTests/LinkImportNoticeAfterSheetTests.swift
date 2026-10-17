import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F836 — a link import that finishes with no transcription engine installed set the window's
// `alertMessage` ("install a model…") while the Add from a Link sheet was still open, and the sheet
// closed a moment later. Whether the window's alert then presents behind a closing sheet is the
// on-screen question the ticket left open; it no longer matters, because the notice is held while a
// link sheet is open and raised when it closes, and raised at once when none is.

@MainActor
private func makeModelWithNoEngine() throws -> (AppModel, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("F836-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let model = AppModel(
        store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(),
        defaults: UserDefaults(suiteName: testSuiteName())!,
        whisperExecutable: { nil }, qwenInstalled: { false }
    )
    model.findWhisperExecutable = { nil }
    model.checkQwenInstalled = { false }
    model.linkImportEnabled = true
    model.probeMediaURL = { _ in MediaProbe(title: "Quarterly review", durationSeconds: 600) }
    model.downloadMedia = { _, directory, _ in
        let file = directory.appendingPathComponent("recording.wav")
        try WAVWriter.wavData(from: [Float](repeating: 0.05, count: 3_200), sampleRate: 16_000).write(to: file)
        return file
    }
    model.downloadCaptions = { _, _, _ in [] }
    return (model, root)
}

@MainActor
@Test("The no-engine notice from a link import waits for the link sheet to close (F836)")
func noEngineNoticeWaitsForTheLinkSheet() async throws {
    let (model, root) = try makeModelWithNoEngine()
    defer { try? FileManager.default.removeItem(at: root) }
    let expected = try #require(model.transcriptionUnavailableMessage, "fixture: no engine should be installed")

    model.linkImportSheetOpened()
    let outcome = await model.importFromURL("https://www.youtube.com/watch?v=abc123")
    try #require(outcome.meetingID != nil, "fixture: the import should succeed: \(outcome)")

    #expect(model.alertMessage == nil, "the notice was raised behind the open sheet")
    model.linkImportSheetClosed()
    #expect(model.alertMessage == expected)
    // Said once: a later sheet's close has nothing left to raise.
    model.alertMessage = nil
    model.linkImportSheetOpened()
    model.linkImportSheetClosed()
    #expect(model.alertMessage == nil)
}

@MainActor
@Test("With no link sheet open, the notice is raised at once, as before (F836 control)")
func noEngineNoticeIsImmediateWithoutASheet() async throws {
    let (model, root) = try makeModelWithNoEngine()
    defer { try? FileManager.default.removeItem(at: root) }
    let expected = try #require(model.transcriptionUnavailableMessage)

    let outcome = await model.importFromURL("https://www.youtube.com/watch?v=abc123")
    try #require(outcome.meetingID != nil)

    #expect(model.alertMessage == expected)
}

@Test("The link sheet tells the model when it opens and closes (F836)")
func linkSheetReportsItsLifetime() throws {
    let content = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/ContentView.swift")
    let start = try #require(content.range(of: "private struct LinkImportSheet: View {"))
    let sheet = content[start.lowerBound...].prefix(12_000)
    #expect(sheet.contains("model.linkImportSheetOpened()"))
    #expect(sheet.contains("model.linkImportSheetClosed()"))
}
