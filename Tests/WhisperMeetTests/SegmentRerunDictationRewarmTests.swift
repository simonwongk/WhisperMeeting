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
        transcriptText: "original",
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
    while model.isRunningAuxiliaryEngine { await Task.yield() }

    #expect(events.snapshot == ["released", "engine", "rewarmed"])
}
