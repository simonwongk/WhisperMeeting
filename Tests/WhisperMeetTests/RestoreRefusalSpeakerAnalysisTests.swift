import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F983, round 2 (the review of lane U, finding 7): speaker analysis holds `isRunningAuxiliaryEngine`,
// so it blocks a restore, but the refusal named only transcription, second opinion, passage re-run
// and summary. With only an analysis running it fell back to "the running transcription or
// summary"; beside a summary it named the summary alone, and cancelling that was refused again.

/// Holds the analysis open until the test lets it go; cancellation ends it, as the real client's does.
private final class HeldAnalysis: @unchecked Sendable {
    private let lock = NSLock()
    private var _started = false
    private var _released = false
    var started: Bool { lock.withLock { _started } }
    func letGo() { lock.withLock { _released = true } }
    func run() async throws {
        lock.withLock { _started = true }
        while !lock.withLock({ _released }) {
            try await Task.sleep(nanoseconds: 2_000_000)
        }
    }
}

@MainActor
private func waitUntil(_ condition: () -> Bool) async throws -> Bool {
    let deadline = Date().addingTimeInterval(30)
    while !condition() {
        if Date() > deadline { return false }
        try await Task.sleep(for: .milliseconds(5))
    }
    return true
}

private func seg(_ text: String, _ start: Double, _ end: Double) -> TranscriptSegment {
    TranscriptSegment(speaker: nil, start: start, end: end, text: text)
}

@MainActor
@Test("A restore refused over a running speaker analysis names it and its meeting (F983, round 2)")
func restoreRefusalNamesARunningSpeakerAnalysis() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("F983-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let directory = root.appendingPathComponent("Recordings/\(id.uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try WAVWriter.wavData(from: [Float](repeating: 0.05, count: 32_000), sampleRate: 16_000)
        .write(to: directory.appendingPathComponent("meeting.wav"))
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(),
                         defaults: UserDefaults(suiteName: testSuiteName())!)
    let segments = [seg("First line.", 0, 1), seg("Second line.", 1, 2)]
    model.store.upsert(MeetingRecord(
        id: id, title: "Board call", duration: 2, recordingPath: "Recordings/\(id.uuidString)/meeting.wav",
        status: .completed, transcriptText: TranscriptFormatter.timestamped(segments), segments: segments,
        transcriptionEngine: .whisperLarge
    ))
    model.isDiarizationModelInstalled = { true }
    let analysis = HeldAnalysis()
    model.runSpeakerDiarization = { _, _ in
        try await analysis.run()
        return SpeakerDiarizationResult(turns: [], speakerCount: 0, audioSeconds: 2)
    }
    model.requestSpeakerDiarization(for: id)
    try #require(try await waitUntil { analysis.started }, "the analysis never started")
    try #require(model.diarizationRunningID == id && model.isRunningAuxiliaryEngine)

    await model.requestLibraryRestore(from: root.appendingPathComponent("no-backup-needed"))

    #expect(model.pendingLibraryRestore == nil)
    #expect(model.alertMessage?.contains("the speaker analysis of “Board call”") == true,
            "the refusal does not name the running analysis: \(model.alertMessage ?? "no message")")

    analysis.letGo()
    try #require(try await waitUntil { model.diarizationRunningID == nil }, "the analysis never ended")
}
