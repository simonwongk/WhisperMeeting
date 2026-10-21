import Combine
import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F895 — once a link's audio has downloaded, `importFromURL` clears `mediaDownloadProgress` and then
// fetches the video's captions, which takes seconds. The link sheet shows "Checking the link…"
// whenever it is working with no download progress, so after "Downloading audio… 100%" it went back
// to "Checking the link…" — at the moment a user is likeliest to press Stop. The import now says what
// it is doing after the download (`linkImportStage`), and the sheet shows that.

/// What the stubs saw while the import ran.
private final class StageLog: @unchecked Sendable {
    var captionsRequested = false
    var stageDuringCaptions: AppModel.LinkImportStage?
    var progressDuringCaptions: MediaDownloadProgress?
    var stageDuringDownload: AppModel.LinkImportStage?
}

/// Every value `linkImportStage` took, in order.
private final class StagesSeen: @unchecked Sendable {
    var stages: [AppModel.LinkImportStage?] = []
}

@MainActor
private func makeModel(root: URL, log: StageLog, language: String?) -> AppModel {
    let model = AppModel(
        store: MeetingStore(rootDirectory: root),
        recorder: AudioCaptureEngine(),
        defaults: UserDefaults(suiteName: testSuiteName())!
    )
    model.linkImportEnabled = true
    model.runTranscriptionEngineOverride = { _, _ in throw CancellationError() }
    model.probeMediaURL = { _ in
        MediaProbe(title: "Quarterly review", durationSeconds: 600, uploader: "Acme", language: language)
    }
    model.downloadMedia = { [weak model] _, directory, _ in
        let current = model
        log.stageDuringDownload = await MainActor.run { current?.linkImportStage }
        let file = directory.appendingPathComponent("recording.wav")
        try WAVWriter.wavData(from: [Float](repeating: 0.1, count: 16_000), sampleRate: 16_000).write(to: file)
        return file
    }
    model.downloadCaptions = { [weak model] _, _, _ in
        log.captionsRequested = true
        let current = model
        let seen = await MainActor.run { (current?.linkImportStage, current?.mediaDownloadProgress) }
        log.stageDuringCaptions = seen.0
        log.progressDuringCaptions = seen.1
        return []
    }
    return model
}

private func makeRoot(_ label: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("F895-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

@MainActor
@Test("While a link import fetches captions it says so, and says nothing once it is done (F895)")
func linkImportSaysItIsFetchingCaptions() async throws {
    let root = try makeRoot("captions")
    defer { try? FileManager.default.removeItem(at: root) }
    let log = StageLog()
    let model = makeModel(root: root, log: log, language: "en")
    #expect(model.linkImportStage == nil)

    let outcome = await model.importFromURL("https://www.youtube.com/watch?v=abc123")

    try #require(log.captionsRequested, "the import never reached its caption fetch")
    #expect(log.stageDuringDownload == nil, "a stage was shown while the download's own bar was")
    #expect(log.progressDuringCaptions == nil, "the download's bar was still up during the caption fetch")
    #expect(log.stageDuringCaptions == .fetchingCaptions,
            "the sheet had nothing to say during the caption fetch but \"Checking the link…\"")
    #expect(outcome.meetingID != nil, "\(outcome)")
    #expect(model.linkImportStage == nil, "a finished import still reports \(String(describing: model.linkImportStage))")
}

@MainActor
@Test("A link import with no captions to fetch goes straight to adding the meeting (F895)")
func linkImportWithoutCaptionsSaysItIsAdding() async throws {
    // No language from the probe: captions are skipped, and the step after the download is adding the
    // meeting. Observed through the duration measurement's own suspension point.
    let root = try makeRoot("nocaptions")
    defer { try? FileManager.default.removeItem(at: root) }
    let log = StageLog()
    let model = makeModel(root: root, log: log, language: nil)
    let seen = StagesSeen()
    let observer = model.$linkImportStage.sink { seen.stages.append($0) }
    defer { observer.cancel() }

    let outcome = await model.importFromURL("https://www.youtube.com/watch?v=abc123")

    #expect(!log.captionsRequested)
    #expect(outcome.meetingID != nil, "\(outcome)")
    let expected: [AppModel.LinkImportStage?] = [nil, .addingMeeting, nil]
    #expect(seen.stages == expected)
}

@MainActor
@Test("A stopped link import leaves no stage behind (F895)")
func aStoppedLinkImportClearsItsStage() async throws {
    let root = try makeRoot("stop")
    defer { try? FileManager.default.removeItem(at: root) }
    let log = StageLog()
    let model = makeModel(root: root, log: log, language: "en")
    // Stop lands during the caption fetch, as in F453's test: the caption runner swallows it.
    model.downloadCaptions = { [weak model] _, _, _ in
        log.captionsRequested = true
        let current = model
        log.stageDuringCaptions = await MainActor.run { current?.linkImportStage }
        withUnsafeCurrentTask { $0?.cancel() }
        return []
    }
    let importTask = Task { @MainActor in await model.importFromURL("https://www.youtube.com/watch?v=abc123") }
    let outcome = await importTask.value

    try #require(log.captionsRequested, "the import never reached its caption fetch")
    #expect(log.stageDuringCaptions == .fetchingCaptions)
    #expect(outcome == .cancelled)
    #expect(model.linkImportStage == nil, "a stopped import still reports \(String(describing: model.linkImportStage))")
}

@Test("The link sheet shows the import's stage, and \"Checking the link…\" only before there is one (F895)")
func linkSheetShowsTheImportStage() throws {
    let source = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/ContentView.swift")
    let sheetStart = try #require(source.range(of: "private struct LinkImportSheet")?.lowerBound)
    let sheetEnd = try #require(source.range(of: "private struct AskMeetingsView")?.lowerBound)
    let sheet = String(source[sheetStart..<sheetEnd])
    // Offsets, so a failure names the missing piece instead of printing the whole sheet.
    func offset(_ text: String) -> Int? {
        sheet.range(of: text).map { sheet.distance(from: sheet.startIndex, to: $0.lowerBound) }
    }
    let stage = offset("if let stage = model.linkImportStage")
    let label = offset("ProgressView(stage.label)")
    let bar = offset("model.mediaDownloadProgress")
    let checking = offset("\"Checking the link…\"")
    #expect(stage != nil, "the sheet never reads the import's stage")
    #expect(label != nil, "the sheet never shows the stage's words")
    let order = [stage, label, bar, checking].compactMap { $0 }
    // The stage first: it is set only after the download has returned, so it wins over a late progress
    // update, and "Checking the link…" is left to the probe.
    #expect(order.count == 4 && order == order.sorted(),
            "stage \(String(describing: stage)), label \(String(describing: label)), bar \(String(describing: bar)), fallback \(String(describing: checking))")
    #expect(AppModel.LinkImportStage.fetchingCaptions.label == "Fetching captions…")
    #expect(AppModel.LinkImportStage.addingMeeting.label == "Adding the meeting…")
}
