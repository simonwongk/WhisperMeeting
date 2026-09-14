import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F220 — the two decisions behind the Improve-menu entry and the Export menu's labeled action. Both
// are genuinely red without the fix: `AppModel` has no `speakerAnalysisUnavailability(for:)` and no
// `speakerLabeledExportRequest(for:)`, so this file does not compile against the current tree.
//
// They live in AppModel rather than in the SwiftUI body because the `WhisperMeet` target has no
// view-render harness and never will: a rule written inline in a `.disabled(…)` or behind an `if`
// in a `Menu` is a rule no test can reach. Here the enable rule and the export payload are ordinary
// values, so the interesting claims — the entry says WHY it is greyed out, and a labeled export is
// offered only when there are labels to carry — are checked through the app-level call.

private func seg(_ text: String, _ start: Double, _ end: Double) -> TranscriptSegment {
    TranscriptSegment(speaker: nil, start: start, end: end, text: text)
}

private final class Gate: @unchecked Sendable {
    var started = false
    var release = false
}

private func writeSilentWav(seconds: Double, to url: URL) throws {
    let sampleRate: UInt32 = 16_000
    let dataBytes = UInt32(seconds * Double(sampleRate)) * 2
    var wav = WAVWriter.header(sampleRate: sampleRate, dataByteCount: dataBytes)
    wav.append(Data(count: Int(dataBytes)))
    try wav.write(to: url)
}

@MainActor
private struct EntryFixture {
    let model: AppModel
    let id: UUID
    let root: URL
    var meeting: MeetingRecord { model.store.meeting(id: id)! }
}

@MainActor
private func makeEntryFixture(
    status: MeetingStatus = .completed,
    segments: [TranscriptSegment] = [seg("one", 0, 2), seg("two", 2, 4)],
    recordingFileName: String = "meeting.wav",
    source: MediaSource? = nil,
    installed: Bool = true,
    degraded: Bool = false
) throws -> EntryFixture {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("DiarizationEntry-\(UUID().uuidString)", isDirectory: true)
    let id = UUID()
    let directory = root.appendingPathComponent("Recordings/\(id.uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try writeSilentWav(seconds: 4, to: directory.appendingPathComponent(recordingFileName))

    let seed = MeetingStore(rootDirectory: root)
    seed.upsert(MeetingRecord(
        id: id, title: "M", duration: 4,
        recordingPath: "Recordings/\(id.uuidString)/\(recordingFileName)",
        status: status,
        transcriptText: TranscriptFormatter.timestamped(segments),
        segments: segments,
        source: source
    ))
    try #require(!seed.isDegraded, "the seed store must be writable, or nothing was persisted")
    if degraded {
        // The field's real read-only state: records present, mutation refused (DegradedLibraryTests).
        try Data("truncated-primary".utf8).write(to: root.appendingPathComponent("meetings.json"))
    }

    let defaults = UserDefaults(suiteName: "F220entry.\(UUID().uuidString)")!
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(), defaults: defaults)
    model.isDiarizationModelInstalled = { installed }
    // The menu reads the published flag rather than re-probing 21 model files on every render, so the
    // fixture publishes through the same call the installer and launch use.
    model.refreshRuntime()
    if degraded { try #require(model.store.isDegraded, "the reopened store must be read-only") }
    return EntryFixture(model: model, id: id, root: root)
}

private func twoClusterResult() -> SpeakerDiarizationResult {
    SpeakerDiarizationResult(
        turns: [
            SpeakerTurn(startSeconds: 0, endSeconds: 2, clusterID: 0, kind: .speech),
            SpeakerTurn(startSeconds: 2, endSeconds: 4, clusterID: 1, kind: .speech)
        ],
        speakerCount: 2,
        audioSeconds: 4
    )
}

@MainActor
private func spin(_ label: String, until condition: @MainActor () -> Bool) async {
    var ticks = 0
    while !condition(), ticks < 200_000 {
        await Task.yield()
        ticks += 1
    }
    #expect(condition(), "timed out waiting for \(label)")
}

@MainActor
@Test("The analyze entry is offered for a completed, timed, natively recorded meeting (F220)")
func speakerAnalysisEntryIsOfferedWhenEverythingIsReady() throws {
    let fixture = try makeEntryFixture()
    #expect(fixture.model.speakerAnalysisUnavailability(for: fixture.meeting) == nil)
}

@MainActor
@Test("A missing model greys the analyze entry and says where to install it (F220)")
func speakerAnalysisEntryNamesTheMissingModel() throws {
    let fixture = try makeEntryFixture(installed: false)
    #expect(fixture.model.speakerAnalysisUnavailability(for: fixture.meeting) == .modelNotInstalled)
}

@MainActor
@Test("A transcript with no timestamps greys the analyze entry as having nothing to label (F220)")
func speakerAnalysisEntryNamesAnUntimedTranscript() throws {
    // The Qwen alignment-failure shape: complete text, no timings to reconcile turns against.
    let fixture = try makeEntryFixture(
        segments: [TranscriptSegment(speaker: nil, start: nil, end: nil, text: "one two")]
    )
    #expect(fixture.model.speakerAnalysisUnavailability(for: fixture.meeting) == .noTimestamps)
}

@MainActor
@Test("An imported or unfinished recording greys the analyze entry as unsupported (F220)")
func speakerAnalysisEntryNamesAnUnsupportedRecording() throws {
    let imported = try makeEntryFixture(
        recordingFileName: "downloaded.m4a",
        source: MediaSource(kind: MediaSource.youTubeKind, pageURL: "https://example.com/v",
                            host: "example.com", fetchedAt: Date())
    )
    #expect(imported.model.speakerAnalysisUnavailability(for: imported.meeting) == .unsupportedRecording)

    let unfinished = try makeEntryFixture(status: .recorded)
    #expect(unfinished.model.speakerAnalysisUnavailability(for: unfinished.meeting) == .unsupportedRecording)
}

@MainActor
@Test("A read-only library greys the analyze entry rather than spending minutes on a refused write (F220)")
func speakerAnalysisEntryNamesAReadOnlyLibrary() throws {
    let fixture = try makeEntryFixture(degraded: true)
    #expect(fixture.model.speakerAnalysisUnavailability(for: fixture.meeting) == .libraryReadOnly)
}

@MainActor
@Test("A running analysis greys the entry as already running, not as a missing model (F220)")
func speakerAnalysisEntryNamesTheRunningAnalysis() async throws {
    let fixture = try makeEntryFixture()
    let gate = Gate()
    fixture.model.runSpeakerDiarization = { _, _ in
        gate.started = true
        while !gate.release { await Task.yield() }
        return twoClusterResult()
    }
    fixture.model.requestSpeakerDiarization(for: fixture.id)
    await spin("the seam to start") { gate.started }

    #expect(fixture.model.speakerAnalysisUnavailability(for: fixture.meeting) == .analyzing)

    gate.release = true
    await spin("the analysis to finish") { fixture.model.diarizationRunningID == nil }
    #expect(fixture.model.speakerAnalysisUnavailability(for: fixture.meeting) == nil)
}

@MainActor
@Test("A running transcription greys the entry as busy (F220)")
func speakerAnalysisEntryNamesABusyMac() async throws {
    let fixture = try makeEntryFixture()
    let other = UUID()
    fixture.model.store.upsert(MeetingRecord(id: other, title: "B", status: .recorded))
    fixture.model.findWhisperExecutable = { URL(fileURLWithPath: "/usr/bin/true") }
    fixture.model.runTranscriptionEngineOverride = { _, _ in
        TranscriptionResult(id: "x", text: "hi", languageCode: "en", audioDuration: 1, confidence: nil, segments: [])
    }
    fixture.model.beginTranscription(id: other)
    try #require(fixture.model.hasActiveTranscription, "the transcription queue must be active")

    #expect(fixture.model.speakerAnalysisUnavailability(for: fixture.meeting) == .busy)
}

@MainActor
@Test("The labeled export appears only once an analysis exists, and the ordinary exports stay clean (F220)")
func labeledExportIsOfferedOnlyOnceAnOverlayExists() async throws {
    let fixture = try makeEntryFixture()
    // Nothing analyzed yet: there is no labeled export to offer, so the menu shows no action for it.
    #expect(fixture.model.speakerLabeledExportRequest(for: fixture.id) == nil)

    fixture.model.runSpeakerDiarization = { _, _ in twoClusterResult() }
    fixture.model.requestSpeakerDiarization(for: fixture.id)
    await spin("the analysis to finish") { fixture.model.diarizationRunningID == nil }
    fixture.model.renameSpeaker(clusterID: 0, to: "Nadia", in: fixture.id)

    let request = try #require(fixture.model.speakerLabeledExportRequest(for: fixture.id))
    #expect(request.speakerRows.count == fixture.meeting.segments.count)
    #expect(request.speakerLabels == [0: "Nadia"])

    let labeled = TranscriptExporter.render(.labeledMarkdown, request)
    #expect(labeled.contains("Nadia"))
    #expect(labeled.contains("Speaker 2"))
    // The same request through the nine ordinary formats carries nothing — the export menu hands
    // them this payload too once it is built from one place.
    for format in TranscriptExportFormat.standardFormats {
        let rendered = TranscriptExporter.render(format, request)
        #expect(!rendered.contains("Nadia"), "\(format) leaked an alias")
        #expect(!rendered.contains("Speaker 2"), "\(format) leaked a cluster label")
    }
}

@MainActor
@Test("No labeled export is offered when only one voice could be told apart (F220)")
func labeledExportIsWithheldForASingleCluster() async throws {
    let fixture = try makeEntryFixture()
    fixture.model.runSpeakerDiarization = { _, _ in
        SpeakerDiarizationResult(
            turns: [
                SpeakerTurn(startSeconds: 0, endSeconds: 2, clusterID: 0, kind: .speech),
                SpeakerTurn(startSeconds: 2, endSeconds: 4, clusterID: 0, kind: .speech)
            ],
            speakerCount: 1,
            audioSeconds: 4
        )
    }
    fixture.model.requestSpeakerDiarization(for: fixture.id)
    await spin("the analysis to finish") { fixture.model.diarizationRunningID == nil }

    // Labelling every row "Speaker 1" is worthless for a monologue and misleading for a failed
    // separation, so there is nothing to export — the same rule that suppresses the row labels.
    #expect(fixture.model.speakerOverlay(for: fixture.id)?.isSingleCluster == true)
    #expect(fixture.model.speakerLabeledExportRequest(for: fixture.id) == nil)
}
