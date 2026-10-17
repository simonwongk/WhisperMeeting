import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F453 part 2, through startup recovery: the folder a link import leaves when the app dies while
// ffmpeg is extracting its audio holds the complete download and a `recording.wav` with ffmpeg's
// placeholder header (ImportCandidateChoiceTests says why). The outcomes at the next launch, each
// pinned here through `performStartupRecovery`:
//
// - nothing is writing it any more (a power loss, or the extraction was killed): recovery chooses
//   the complete download, never the partial WAV. A download macOS cannot open — YouTube's usual
//   Opus in WebM, which is what the fixture's undecodable bytes stand for — is converted then into
//   the WAV the import was making (review of F453); if that cannot be finished, the entry keeps the
//   download and its link and never suggests deleting it, since deleting it removes the folder;
// - ffmpeg is still writing it, because it outlived the app: the folder is left alone, with a
//   sentence that says what will happen to it. Adopting it would point the meeting at the download
//   yt-dlp deletes the moment ffmpeg finishes.

private final class SampleCounter: @unchecked Sendable {
    var calls = 0
}

/// What the stubbed conversion was asked to do.
private final class ConversionLog: @unchecked Sendable {
    var downloads: [String] = []
}

/// `Recordings/<id>/` as the interrupted import left it.
private func makeInterruptedExtraction(in root: URL) throws -> (id: UUID, folder: URL) {
    let id = UUID()
    let folder = root.appendingPathComponent("Recordings/\(id.uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let source = MediaSource(
        kind: MediaSource.webKind,
        pageURL: "https://example.com/watch?v=abc123",
        host: "example.com",
        videoID: "abc123",
        uploader: "Example Channel",
        fetchedAt: Date(timeIntervalSince1970: 1_700_000_000)
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
        store: MeetingStore(rootDirectory: root),
        recorder: AudioCaptureEngine(),
        defaults: UserDefaults(suiteName: testSuiteName())!
    )
    model.crashReportsSince = { _ in [] }
    return model
}

@MainActor
@Test("A download macOS cannot open is converted into the WAV the import was making (F453)")
func anUnplayableDownloadIsFinishedIntoItsWAV() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("F453-extraction-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let (id, folder) = try makeInterruptedExtraction(in: root)
    let model = makeModel(root: root)
    // The conversion as the real one ends: a finished WAV renamed over the half-written one.
    let log = ConversionLog()
    model.finishInterruptedLinkImportExtraction = { download in
        log.downloads.append(download.lastPathComponent)
        let finished = download.deletingLastPathComponent().appendingPathComponent("recording.wav")
        try WAVWriter.wavData(from: [Float](repeating: 0.1, count: 8_000), sampleRate: 16_000).write(to: finished)
        return finished
    }

    await model.performStartupRecovery()

    #expect(log.downloads == ["recording.webm"], "the conversion was asked about \(log.downloads)")
    let meeting = try #require(model.store.meeting(id: id), "the interrupted import was not indexed")
    #expect(meeting.status == .recorded, "\(meeting.title): \(meeting.errorMessage ?? "")")
    #expect(meeting.recordingPath.hasSuffix("recording.wav"), "indexed against \(meeting.recordingPath)")
    #expect(abs(meeting.duration - 0.5) < 0.05, "duration \(meeting.duration)")
    #expect(meeting.source?.host == "example.com")
    #expect(meeting.recoverySource == RecoveredRecording.Source.importedRecording.rawValue)
    #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent("recording.webm").path),
            "the complete download was removed")
}

@MainActor
@Test("A download whose conversion cannot be finished is kept, and its entry never suggests deleting it (F453)")
func anUnfinishableDownloadIsKeptAndNotOfferedForDeletion() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("F453-unfinished-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let (id, folder) = try makeInterruptedExtraction(in: root)
    let model = makeModel(root: root)
    model.finishInterruptedLinkImportExtraction = { _ in throw MediaDownloadError.ffmpegMissing }

    await model.performStartupRecovery()

    let meeting = try #require(model.store.meeting(id: id), "the interrupted import was not kept as an entry")
    #expect(meeting.status == .failed)
    #expect(meeting.title == AppModel.unfinishedLinkImportTitle(host: "example.com"))
    #expect(meeting.errorMessage == AppModel.unfinishedLinkImportMessage(
        reason: MediaDownloadError.ffmpegMissing.localizedDescription
    ))
    // Deleting the entry deletes the folder, and the folder holds the only complete download.
    #expect(meeting.errorMessage?.localizedCaseInsensitiveContains("delete") == false, "\(meeting.errorMessage ?? "")")
    #expect(model.alertMessage?.localizedCaseInsensitiveContains("delete") == false, "\(model.alertMessage ?? "")")
    #expect(meeting.recordingPath.hasSuffix("recording.webm"), "indexed against \(meeting.recordingPath)")
    #expect(meeting.source?.pageURL == "https://example.com/watch?v=abc123", "the link to import again was lost")
    #expect(meeting.recoverySource == RecoveredRecording.Source.importedRecording.rawValue)
    for name in ["recording.webm", MediaSource.sidecarFilename] {
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path), "\(name) was removed")
    }
}

@MainActor
@Test("An interrupted file import is never converted: it has no download to finish (F453)")
func anInterruptedFileImportIsNotConverted() async throws {
    // A file import's `recording.<ext>` is the user's own file, copied — there was no conversion in
    // progress to finish — so it keeps the existing Unverified Import path (RecoveryProvenanceTests).
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("F453-fileimport-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let folder = root.appendingPathComponent("Recordings/\(id.uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try Data("not audio, but not empty either".utf8).write(to: folder.appendingPathComponent("recording.webm"))
    let model = makeModel(root: root)
    let log = ConversionLog()
    model.finishInterruptedLinkImportExtraction = { download in
        log.downloads.append(download.lastPathComponent)
        throw MediaDownloadError.extractionFailed
    }

    await model.performStartupRecovery()

    #expect(log.downloads.isEmpty, "a file import was sent to the link-import conversion")
    let meeting = try #require(model.store.meeting(id: id))
    #expect(meeting.status == .failed)
    #expect(meeting.title != AppModel.unfinishedLinkImportTitle(host: "example.com"))
}

@MainActor
@Test("An import still being extracted by a writer that outlived the app is left alone, and says so (F453)")
func anExtractionStillRunningIsLeftAlone() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("F453-extracting-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let (_, folder) = try makeInterruptedExtraction(in: root)
    let model = makeModel(root: root)
    // ffmpeg appending to the WAV between recovery's two samples, without a clock to race.
    let counter = SampleCounter()
    model.sampleRecordingFolderLiveness = { _ in
        counter.calls += 1
        return RecordingFolderLiveness.Sample(trackBytes: ["recording.wav": Int64(counter.calls) * 65_536])
    }
    let log = ConversionLog()
    model.finishInterruptedLinkImportExtraction = { download in
        log.downloads.append(download.lastPathComponent)
        throw MediaDownloadError.extractionFailed
    }

    await model.performStartupRecovery()

    try #require(counter.calls >= 2, "recovery never sampled the folder twice")
    #expect(model.store.meetings.isEmpty, "a folder still being written was indexed")
    #expect(log.downloads.isEmpty, "a second conversion was started beside the one still writing")
    for name in ["recording.webm", "recording.wav", MediaSource.sidecarFilename] {
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path), "\(name) was touched")
    }
    let alert = model.alertMessage ?? ""
    #expect(alert.contains(AppModel.linkImportStillBeingWritten), "\(alert)")
    #expect(!alert.contains(AppModel.recordingStillInProgress),
            "an import was described as a recording that will be added when it stops: \(alert)")
}

@MainActor
@Test("A conversion stopped at the launch's time limit is listed with its download kept, never offered for deletion (F453)")
func aConversionPastTheLaunchLimitIsListedAndKept() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("F453-limit-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let (id, folder) = try makeInterruptedExtraction(in: root)
    let model = makeModel(root: root)
    let limit = AppModel.linkImportConversionTimeLimit
    model.finishInterruptedLinkImportExtraction = { _ in throw MediaDownloadError.extractionTimedOut(limit) }

    await model.performStartupRecovery()

    let meeting = try #require(model.store.meeting(id: id), "the interrupted import was not kept as an entry")
    #expect(meeting.status == .failed)
    #expect(meeting.title == AppModel.unfinishedLinkImportTitle(host: "example.com"))
    #expect(meeting.errorMessage == AppModel.unfinishedLinkImportMessage(
        reason: MediaDownloadError.extractionTimedOut(limit).localizedDescription
    ))
    #expect(meeting.errorMessage?.localizedCaseInsensitiveContains("delete") == false, "\(meeting.errorMessage ?? "")")
    #expect(model.alertMessage?.localizedCaseInsensitiveContains("delete") == false, "\(model.alertMessage ?? "")")
    #expect(meeting.recordingPath.hasSuffix("recording.webm"), "indexed against \(meeting.recordingPath)")
    // The WAV ffmpeg never finished stays too: nothing can measure the download (review of F894).
    for name in ["recording.webm", "recording.wav", MediaSource.sidecarFilename] {
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path), "\(name) was removed")
    }
}

@Test("Startup recovery's real conversion expires on its output, not on the launch's wait (F453, F912)")
func theLaunchConversionIsGivenItsTimeLimit() throws {
    // The seam's default cannot run in a test process — it refuses ffmpeg there (F442) — so its
    // wiring is pinned as source. The launch waits `linkImportConversionWait` and then leaves the
    // conversion to finish in the background (F912), so the conversion itself must not be killed at
    // the launch's limit any more, and must still have an expiry of its own: a stuck ffmpeg prints
    // progress and writes nothing, so the bound is on its output.
    let source = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/AppModel.swift")
    let declaration = try #require(source.range(of: "var finishInterruptedLinkImportExtraction"))
    let closureEnd = try #require(source.range(of: "\n    }\n", range: declaration.upperBound..<source.endIndex))
    let seam = source[declaration.lowerBound..<closureEnd.upperBound]
    #expect(seam.contains("outputStallTimeout: AppModel.linkImportConversionStallLimit"), "\(seam)")
    #expect(!seam.contains("timeLimit: AppModel.linkImportConversionTimeLimit"), "the launch's limit kills the conversion again: \(seam)")
    // F989: and an absolute expiry for a conversion whose output keeps growing, derived from the
    // download it converts — never the launch's 30 s.
    let compactSeam = seam.filter { !$0.isWhitespace }
    #expect(compactSeam.contains("timeLimit:InterruptedLinkImportExtraction.conversionTimeLimit(downloadSeconds:DecodedAudio.declaredDuration(of:download),downloadBytes:downloadBytes)"),
            "a conversion whose output keeps growing runs until quit: \(seam)")
    #expect(AppModel.linkImportConversionTimeLimit > 0 && AppModel.linkImportConversionTimeLimit.isFinite)
    #expect(AppModel.linkImportConversionStallLimit > 0 && AppModel.linkImportConversionStallLimit.isFinite)
    // The wait the app runs with is the documented limit; tests shorten the instance's.
    let wait = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/AppModel.swift")
        .range(of: "var linkImportConversionWait: TimeInterval = AppModel.linkImportConversionTimeLimit")
    #expect(wait != nil, "the launch's wait no longer defaults to linkImportConversionTimeLimit")
}

@Test("The no-lock sweep's age is ten times the stall limit the app gives a conversion, so a slow live run is never taken for abandoned (F976)")
func theAbandonedTempAgeIsDerivedFromTheStallLimit() {
    // `abandonedTemporaryFileAge` (WhisperCore) is safe only because a conversion that writes nothing
    // for `linkImportConversionStallLimit` (the app's) is killed by its own watch (F912): a temp that
    // has not grown for ten of those has no bounded run writing it. Raise the stall limit and the age
    // must follow, or the sweep on a volume without flock could take a live, slow conversion's temp.
    #expect(InterruptedLinkImportExtraction.abandonedTemporaryFileAge
            == 10 * AppModel.linkImportConversionStallLimit)
}
