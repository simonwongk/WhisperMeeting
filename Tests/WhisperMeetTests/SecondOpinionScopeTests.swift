import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

private func seg(_ text: String, _ start: Double, _ end: Double) -> TranscriptSegment {
    TranscriptSegment(speaker: nil, start: start, end: end, text: text)
}

/// Polls `condition` up to 6,000 times with a 5 ms sleep between polls, then requires it, so a
/// regression that never reaches the awaited state fails here by name instead of hanging the suite
/// (F681, in F639's shape: bounded by sleeps, never by a count of `Task.yield()`s). That is at least
/// 30 s; a suppressed state measured 41-44 s, because each sleep overruns its 5 ms.
@MainActor
private func waitUntil(_ what: String, _ condition: () -> Bool) async throws {
    var ticks = 0
    while !condition(), ticks < 6_000 {
        try await Task.sleep(nanoseconds: 5_000_000)
        ticks += 1
    }
    try #require(condition(), "timed out waiting for \(what)")
}

// F88 UX fix — the "running" state must be scoped to the meeting actually being processed, so only that
// meeting's button shows a spinner (not every meeting's, via a global flag).
@MainActor
@Test("Second opinion running state is scoped to the specific meeting (F88 UX)")
func secondOpinionRunningStateIsScopedToMeeting() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("SecondOpScope-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root.appendingPathComponent("Recordings"), withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let defaults = UserDefaults(suiteName: "F88scope.\(UUID().uuidString)")!
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(), defaults: defaults)

    let id1 = UUID(), id2 = UUID()
    for id in [id1, id2] {
        model.store.upsert(MeetingRecord(
            id: id, title: "M", recordingPath: "Recordings/\(id.uuidString)/meeting.wav",
            status: .completed, transcriptText: "hi", segments: [seg("hi", 0, 1)], transcriptionEngine: .whisperLarge
        ))
    }
    model.runTranscriptionEngineOverride = { _, _ in
        TranscriptionResult(id: "x", text: "hi", languageCode: "en", audioDuration: 1, confidence: nil, segments: [seg("hi", 0, 1)])
    }

    model.requestSecondOpinion(id: id1)
    #expect(model.secondOpinionRunningID == id1)   // only meeting 1 is "running"
    #expect(model.secondOpinionRunningID != id2)   // meeting 2 is NOT shown as running

    try await waitUntil("the second-opinion run to finish") { !model.isRunningAuxiliaryEngine }
    #expect(model.secondOpinionRunningID == nil)   // cleared when done
}
