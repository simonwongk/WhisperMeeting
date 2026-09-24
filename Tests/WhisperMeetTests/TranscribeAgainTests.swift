import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F515 — a completed meeting had no way to be transcribed again, although F420's lost timestamps come
// back only that way and three notices tell the user to "transcribe again". And a re-run that does
// not finish must not make a meeting that HAS a transcript look untranscribed: cancelling set
// `.recorded`, failing set `.failed`, and an interrupted run was recovered as `.recorded`.

private func seg(_ text: String, _ start: Double, _ end: Double) -> TranscriptSegment {
    TranscriptSegment(speaker: nil, start: start, end: end, text: text)
}

private let oldLines = [seg("Old first line.", 0, 2), seg("Old second line.", 2, 4)]

@MainActor
private func completedMeeting(
    engine: @escaping (MeetingTranscriptionSelection, URL) async throws -> TranscriptionResult
) throws -> (AppModel, UUID) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("TranscribeAgain-\(UUID().uuidString)")
    let id = UUID()
    try FileManager.default.createDirectory(
        at: root.appendingPathComponent("Recordings/\(id.uuidString)"), withIntermediateDirectories: true
    )
    let defaults = UserDefaults(suiteName: "F515.\(UUID().uuidString)")!
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(), defaults: defaults)
    model.store.upsert(MeetingRecord(
        id: id, title: "Day 4 2", recordingPath: "Recordings/\(id.uuidString)/meeting.wav",
        status: .completed, transcriptText: TranscriptFormatter.timestamped(oldLines),
        languageCode: "en", segments: oldLines, transcriptNormalized: true
    ))
    model.findWhisperExecutable = { URL(fileURLWithPath: "/usr/bin/true") }
    model.runTranscriptionEngineOverride = engine
    return (model, id)
}

/// The run's outcome is the subject, so waiting for the queue to drain is the assertion's own
/// precondition and is required, never assumed (AGENTS.md: a timeout must fail as a timeout).
@MainActor
private func waitForTheRunToEnd(_ model: AppModel) async throws {
    var ticks = 0
    while model.hasActiveTranscription, ticks < 200_000 { await Task.yield(); ticks += 1 }
    try #require(!model.hasActiveTranscription, "the transcription never finished")
}

@MainActor
@Test("A completed meeting can be transcribed again, and the new transcript replaces the old (F515)")
func aCompletedMeetingIsTranscribedAgain() async throws {
    let newLines = [seg("New first line.", 0, 2), seg("New second line.", 2, 4)]
    let (model, id) = try completedMeeting { _, _ in
        TranscriptionResult(id: "x", text: "New first line. New second line.", languageCode: "en",
                            audioDuration: 4, confidence: nil, segments: newLines)
    }
    #expect(model.transcribeAgainBlockedReason(for: id) == nil)

    model.transcribeAgain(id: id)
    try await waitForTheRunToEnd(model)

    let meeting = try #require(model.store.meeting(id: id))
    #expect(meeting.status == .completed)
    #expect(meeting.segments == newLines)
}

@MainActor
@Test("A cancelled re-run keeps the transcript it would have replaced, and stays completed (F515)")
func aCancelledReRunKeepsTheTranscript() async throws {
    let (model, id) = try completedMeeting { _, _ in throw CancellationError() }
    model.transcribeAgain(id: id)
    try await waitForTheRunToEnd(model)

    let meeting = try #require(model.store.meeting(id: id))
    #expect(meeting.status == .completed)
    #expect(meeting.segments == oldLines)
    #expect(meeting.transcriptText == TranscriptFormatter.timestamped(oldLines))
}

private struct EngineBroke: LocalizedError { var errorDescription: String? { "engine broke" } }

@MainActor
@Test("A failed re-run keeps the transcript too, and says why it failed (F515)")
func aFailedReRunKeepsTheTranscript() async throws {
    let (model, id) = try completedMeeting { _, _ in throw EngineBroke() }
    model.transcribeAgain(id: id)
    try await waitForTheRunToEnd(model)

    let meeting = try #require(model.store.meeting(id: id))
    #expect(meeting.status == .completed)
    #expect(meeting.segments == oldLines)
    #expect(model.alertMessage?.contains("previous transcript is unchanged") == true)
}

@MainActor
@Test("A re-run interrupted by quitting is recovered as completed; a first run still as recorded (F515)")
func anInterruptedReRunIsRecoveredAsCompleted() throws {
    let (model, id) = try completedMeeting { _, _ in throw CancellationError() }
    model.store.update(id: id) { $0.status = .processing }
    let firstRun = UUID()
    model.store.upsert(MeetingRecord(id: firstRun, title: "New", status: .processing))

    model.recoverInterruptedTranscriptions()

    #expect(model.store.meeting(id: id)?.status == .completed)
    #expect(model.store.meeting(id: id)?.segments == oldLines)
    #expect(model.store.meeting(id: firstRun)?.status == .recorded)
}

@MainActor
@Test("Transcribe Again is refused while the meeting is already being transcribed (F515)")
func transcribeAgainIsBlockedWhileProcessing() throws {
    let (model, id) = try completedMeeting { _, _ in throw CancellationError() }
    model.store.update(id: id) { $0.status = .processing }
    #expect(model.transcribeAgainBlockedReason(for: id) != nil)
}

@Test("Transcribe Again is in the Improve menu and beside the alignment notice, behind a confirmation (F515)")
func transcribeAgainIsWired() throws {
    let source = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/ContentView.swift")
    #expect(source.contains(#"Label("Transcribe Again…", systemImage: "arrow.clockwise")"#))
    #expect(source.contains(#"Button("Transcribe Again…") { confirmTranscribeAgain = true }"#))
    #expect(source.contains("model.transcribeAgain(id: meetingID)"))
    #expect(source.contains(".disabled(model.transcribeAgainBlockedReason(for: meetingID) != nil)"))
}
