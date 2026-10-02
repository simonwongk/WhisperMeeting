import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

/// F206 — records the observable order around a short, post-meeting segment re-run without
/// touching a user's recording or loading a recognition model.
private final class SegmentRerunRewarmEvents: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [String] = []

    func append(_ value: String) {
        lock.withLock { values.append(value) }
    }

    var snapshot: [String] {
        lock.withLock { values }
    }
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

private func writeSegmentRerunFixtureWAV(to url: URL) throws {
    let sampleRate: UInt32 = 48_000
    let durationSeconds: UInt32 = 2
    let dataByteCount = sampleRate * durationSeconds * 2
    var wav = WAVWriter.header(sampleRate: sampleRate, dataByteCount: dataByteCount)
    wav.append(Data(count: Int(dataByteCount)))
    try wav.write(to: url)
}

@MainActor
@Test("Finishing a segment re-run rewarms dictation recognition (F206)")
func finishingSegmentRerunRewarmsDictationRecognition() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("SegmentRerunDictationRewarmTests-\(UUID().uuidString)")
    let id = UUID()
    let recordingDirectory = root.appendingPathComponent("Recordings/\(id.uuidString)")
    try FileManager.default.createDirectory(at: recordingDirectory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try writeSegmentRerunFixtureWAV(to: recordingDirectory.appendingPathComponent("meeting.wav"))

    let suite = "SegmentRerunDictationRewarmTests.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = AppModel(
        store: MeetingStore(rootDirectory: root),
        recorder: AudioCaptureEngine(),
        defaults: defaults
    )
    let segment = TranscriptSegment(speaker: nil, start: 0, end: 1, text: "original")
    model.store.upsert(MeetingRecord(
        id: id,
        title: "Synthetic",
        recordingPath: "Recordings/\(id.uuidString)/meeting.wav",
        status: .completed,
        // The text its lines render to. A bare "original" reads as a hand-edited transcript (it
        // lacks the line's timestamp), which F436 rightly refuses to re-run.
        transcriptText: TranscriptFormatter.timestamped([segment]),
        segments: [segment],
        transcriptionEngine: .whisperLarge
    ))

    let events = SegmentRerunRewarmEvents()
    model.releaseIdleDictationModels = { events.append("released") }
    model.configureIdleDictationRecognitionWarmUp { events.append("rewarmed") }
    model.runTranscriptionEngineOverride = { _, _ in
        events.append("engine")
        return TranscriptionResult(
            id: "test", text: "replacement", languageCode: "en",
            audioDuration: 1, confidence: nil,
            segments: [TranscriptSegment(speaker: nil, start: 0, end: 1, text: "replacement")]
        )
    }

    model.requestSegmentReTranscription(id: id, index: 0)
    try await waitUntil("the segment re-run to finish") { !model.isRunningAuxiliaryEngine }

    #expect(events.snapshot == ["released", "engine", "rewarmed"])
}
