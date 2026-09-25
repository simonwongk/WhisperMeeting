import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F512 — a second opinion, a segment re-run and a summary could not be stopped. A second opinion is a
// whole-meeting pass that can take tens of minutes, and while it ran every transcription and Quick
// Dictation waited on it; the only way out was to quit. Deleting the meeting stopped none of them.
// And a second opinion on a transcript with no timestamped lines returned without a word, leaving the
// sheet on "Preparing…" for good.

private func seg(_ text: String, _ start: Double, _ end: Double) -> TranscriptSegment {
    TranscriptSegment(speaker: nil, start: start, end: end, text: text)
}

/// What a long-running stub saw: whether it started, and whether it ran to the end instead of being
/// cancelled — the difference between "stopped" and "finished on its own before anyone looked".
private final class RunProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var _started = false
    private var _ranToCompletion = false
    var started: Bool { lock.withLock { _started } }
    var ranToCompletion: Bool { lock.withLock { _ranToCompletion } }
    func start() { lock.withLock { _started = true } }
    func complete() { lock.withLock { _ranToCompletion = true } }

    /// Sleeps in small steps for up to ~10 s. `Task.sleep` throws on cancellation, which is exactly
    /// how the real subprocess clients report it.
    func runUntilCancelled() async throws {
        start()
        for _ in 0..<5_000 { try await Task.sleep(nanoseconds: 2_000_000) }
        complete()
    }
}

/// The polled value is each caller's own subject; an exhausted budget fails as the wait it is.
@MainActor
private func waitUntil(_ what: String, _ condition: () -> Bool) async throws {
    var ticks = 0
    while !condition(), ticks < 6_000 {
        try await Task.sleep(nanoseconds: 5_000_000)
        ticks += 1
    }
    try #require(condition(), "timed out waiting for \(what)")
}

private struct StallingSummarizer: MeetingSummarizer {
    let probe: RunProbe
    func summarize(transcript: String, language: String?, style: SummaryStyle, template: MeetingTemplate) async throws -> MeetingSummary {
        try await probe.runUntilCancelled()
        return MeetingSummary(summary: "finished on its own", keyPoints: [], actionItems: [])
    }
}

private let original = [seg("The original first line.", 0, 1), seg("The original second line.", 1, 2)]

/// A completed meeting on a real 16-bit mono WAV, so a segment re-run can slice it.
@MainActor
private func makeModel(segments: [TranscriptSegment] = original) throws -> (AppModel, UUID) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("F512-\(UUID().uuidString)")
    let id = UUID()
    let directory = root.appendingPathComponent("Recordings/\(id.uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let sampleRate: UInt32 = 16_000
    let bytes = sampleRate * 2 * 2
    var wav = WAVWriter.header(sampleRate: sampleRate, dataByteCount: bytes)
    wav.append(Data(count: Int(bytes)))
    try wav.write(to: directory.appendingPathComponent("meeting.wav"))
    let defaults = try #require(UserDefaults(suiteName: "F512.\(UUID().uuidString)"))
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(), defaults: defaults,
                         whisperExecutable: { URL(fileURLWithPath: "/usr/bin/true") }, qwenInstalled: { true })
    model.store.upsert(MeetingRecord(
        id: id, title: "Synthetic", duration: 2, recordingPath: "Recordings/\(id.uuidString)/meeting.wav",
        status: .completed, transcriptText: TranscriptFormatter.timestamped(segments), segments: segments,
        transcriptionEngine: .whisperLarge
    ))
    return (model, id)
}

@MainActor
private func stallEngine(_ model: AppModel, _ probe: RunProbe) {
    model.runTranscriptionEngineOverride = { _, _ in
        try await probe.runUntilCancelled()
        return TranscriptionResult(id: "stub", text: "finished on its own", languageCode: "en", audioDuration: 1,
                                   confidence: nil, segments: [seg("finished on its own", 0, 1)])
    }
}

@MainActor
@Test("A running second opinion can be cancelled; it stops the engine and says nothing (F512)")
func secondOpinionCanBeCancelled() async throws {
    let (model, id) = try makeModel()
    let probe = RunProbe()
    stallEngine(model, probe)

    #expect(model.requestSecondOpinion(id: id))
    try await waitUntil("the other engine to start") { probe.started }
    model.cancelSecondOpinion()
    try await waitUntil("the auxiliary engine to be released") { !model.isRunningAuxiliaryEngine }

    #expect(!probe.ranToCompletion, "the engine was never told to stop")
    #expect(model.secondOpinionSpans == nil)
    #expect(!model.secondOpinionFailed, "a cancel is not a failure")
    #expect(model.alertMessage == nil, "a cancel is not an error: \(model.alertMessage ?? "")")
    #expect(model.secondOpinionRunningID == nil)
}

@MainActor
@Test("A running segment re-run can be cancelled, and leaves the transcript as it was (F512)")
func segmentReTranscriptionCanBeCancelled() async throws {
    let (model, id) = try makeModel()
    let probe = RunProbe()
    stallEngine(model, probe)

    model.requestSegmentReTranscription(id: id, index: 0)
    try await waitUntil("the engine to start") { probe.started }
    #expect(model.segmentReTranscriptionRunningID == id, "the progress row has nothing to show")
    model.cancelSegmentReTranscription()
    try await waitUntil("the auxiliary engine to be released") { !model.isRunningAuxiliaryEngine }

    #expect(!probe.ranToCompletion, "the engine was never told to stop")
    #expect(model.store.meeting(id: id)?.segments == original)
    #expect(model.alertMessage == nil, "a cancel is not an error: \(model.alertMessage ?? "")")
    #expect(model.segmentReTranscriptionRunningID == nil)
}

@MainActor
@Test("A second opinion on a transcript with no timestamped lines fails and says why, never 'Preparing…' (F512)")
func secondOpinionWithoutSegmentsSaysWhy() async throws {
    let (model, id) = try makeModel(segments: [])
    model.store.update(id: id) { $0.transcriptText = "Text the aligner could not place." }
    let probe = RunProbe()
    stallEngine(model, probe)

    #expect(model.requestSecondOpinion(id: id))
    try await waitUntil("the second opinion to end") { !model.isRunningAuxiliaryEngine }

    #expect(!probe.started, "the engine ran with nothing to compare against")
    // The sheet's "Preparing…" branch is exactly: not running, no spans, not failed.
    #expect(model.secondOpinionFailed)
    #expect(model.secondOpinionFailureReason == AppModel.secondOpinionNeedsTimestampsMessage)
}

@MainActor
@Test("A refused second opinion reports that it did not start, so the sheet does not open on nothing (F512)")
func refusedSecondOpinionReportsNotStarted() async throws {
    let (model, id) = try makeModel()
    model.configureDictationGuard { true }
    #expect(model.requestSecondOpinion(id: id) == false)
    #expect(model.alertMessage != nil)
    #expect(!model.isRunningAuxiliaryEngine)
}

@MainActor
@Test("A running summary can be cancelled; the meeting keeps no summary and the slot is freed (F512)")
func summaryCanBeCancelled() async throws {
    let (model, id) = try makeModel()
    let probe = RunProbe()
    model.summarizationEngine = .local
    model.isSummarizerModelInstalled = { true }
    model.makeSummarizer = { _, _ in StallingSummarizer(probe: probe) }

    model.summarize(id: id)
    try await waitUntil("the summarizer to start") { probe.started }
    #expect(model.activeSummarizationID == id)
    model.cancelSummarization(id: id)
    try await waitUntil("the summary slot to be freed") { model.activeSummarizationID == nil }

    #expect(!probe.ranToCompletion, "the summarizer was never told to stop")
    #expect(model.store.meeting(id: id)?.summary == nil)
    #expect(model.alertMessage == nil, "a cancel is not an error: \(model.alertMessage ?? "")")
}

@MainActor
@Test("Deleting a meeting stops its summary and its second opinion (F512)")
func deletingAMeetingStopsItsSummaryAndSecondOpinion() async throws {
    let (model, id) = try makeModel()
    let summaryProbe = RunProbe()
    let engineProbe = RunProbe()
    model.summarizationEngine = .local
    model.isSummarizerModelInstalled = { true }
    model.makeSummarizer = { _, _ in StallingSummarizer(probe: summaryProbe) }
    stallEngine(model, engineProbe)
    model.summarize(id: id)
    #expect(model.requestSecondOpinion(id: id))
    try await waitUntil("both to start") { summaryProbe.started && engineProbe.started }

    model.deleteMeetings(ids: [id])
    try await waitUntil("both slots to be freed") {
        model.activeSummarizationID == nil && !model.isRunningAuxiliaryEngine
    }

    #expect(!summaryProbe.ranToCompletion, "the summary of a deleted meeting ran on")
    #expect(!engineProbe.ranToCompletion, "the second opinion of a deleted meeting ran on")
    #expect(model.alertMessage == nil, "\(model.alertMessage ?? "")")
}

@MainActor
@Test("Deleting a meeting stops its segment re-run (F512)")
func deletingAMeetingStopsItsSegmentReTranscription() async throws {
    let (model, id) = try makeModel()
    let probe = RunProbe()
    stallEngine(model, probe)
    model.requestSegmentReTranscription(id: id, index: 0)
    try await waitUntil("the engine to start") { probe.started }

    model.deleteMeetings(ids: [id])
    try await waitUntil("the auxiliary engine to be released") { !model.isRunningAuxiliaryEngine }
    #expect(!probe.ranToCompletion, "the re-run of a deleted meeting ran on")
}

@MainActor
@Test("Deleting a meeting stops its speaker analysis (F512)")
func deletingAMeetingStopsItsSpeakerAnalysis() async throws {
    let (model, id) = try makeModel()
    model.isDiarizationModelInstalled = { true }
    let probe = RunProbe()
    model.runSpeakerDiarization = { _, _ in
        try await probe.runUntilCancelled()
        return SpeakerDiarizationResult(turns: [], speakerCount: 0, audioSeconds: 2)
    }
    model.requestSpeakerDiarization(for: id)
    try await waitUntil("the analysis to start") { probe.started }

    model.deleteMeetings(ids: [id])
    try await waitUntil("the analysis to end") { model.diarizationRunningID == nil }
    #expect(!probe.ranToCompletion, "the analysis of a deleted meeting ran on")
    #expect(!model.isRunningAuxiliaryEngine)
}

@MainActor
@Test("Deleting a different meeting leaves a running second opinion alone (F512)")
func deletingAnotherMeetingLeavesTheRunAlone() async throws {
    let (model, id) = try makeModel()
    let other = UUID()
    model.store.upsert(MeetingRecord(id: other, title: "Other", status: .recorded))
    let probe = RunProbe()
    stallEngine(model, probe)
    #expect(model.requestSecondOpinion(id: id))
    try await waitUntil("the other engine to start") { probe.started }

    model.deleteMeetings(ids: [other])
    #expect(model.secondOpinionRunningID == id)
    #expect(model.isRunningAuxiliaryEngine)

    model.cancelSecondOpinion()
    try await waitUntil("the auxiliary engine to be released") { !model.isRunningAuxiliaryEngine }
}

// The Cancel controls live in views this target cannot render, and a suite that drives
// `cancelSecondOpinion()` directly cannot see the button being dropped (F306). So the source is
// asserted, comments stripped (F285) — and each control is asserted to sit NEXT TO the progress it
// stops, because a control nested somewhere else is the shape that made F306's button deletable.
@Test("Each run's Cancel sits beside its progress, and the menu says why Second Opinion is unavailable (F512)")
func cancelControlsAreWiredBesideTheirProgress() throws {
    let view = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/ContentView.swift")
    /// Whether any occurrence of `control` lies within a few lines of the progress text it stops.
    func beside(_ progress: String, _ control: String) -> Bool {
        guard let anchor = view.range(of: progress) else { return false }
        var searchStart = view.startIndex
        while let found = view.range(of: control, range: searchStart..<view.endIndex) {
            if abs(view.distance(from: anchor.lowerBound, to: found.lowerBound)) < 500 { return true }
            searchStart = found.upperBound
        }
        return false
    }

    #expect(beside("Summarizing on this Mac…", "model.cancelSummarization(id: meetingID)"))
    #expect(beside("Second opinion in progress…", "model.cancelSecondOpinion()"))
    #expect(beside("Re-transcribing a segment…", "model.cancelSegmentReTranscription()"))
    #expect(beside("You can keep using the app.", "onCancel()"))
    // Bound to Bools first, so a failure names the missing line instead of printing the whole file.
    let sheetCancelsTheRun = view.contains("onCancel: { model.cancelSecondOpinion() }")
    #expect(sheetCancelsTheRun)
    // The sheet opens only for a run that started; a refusal is the alert alone.
    let sheetOpensOnlyOnStart = view.contains("if model.requestSecondOpinion(id: meetingID) {")
    #expect(sheetOpensOnlyOnStart)
    let menuSaysWhy = view.contains("Text(AppModel.secondOpinionNeedsTimestampsMessage)")
    #expect(menuSaysWhy)
}
