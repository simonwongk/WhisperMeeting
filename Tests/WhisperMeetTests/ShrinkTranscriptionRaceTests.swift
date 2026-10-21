import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F1028 — nothing on the transcription path consulted `shrinkRunningID`, so Transcribe (or Transcribe Again) started
// on a meeting while Shrink was encoding, checking and replacing its recording: the engine took `recording.wav`, which
// Shrink then deleted once it had committed `recording.m4a` (review 2 of Wave 8 lane A, finding 6, read from the code).
// Shrink already refuses a meeting being transcribed (`meetingBusy`); a transcription now waits in the queue, saying
// why, until Shrink of that meeting ends, and then runs on the recording the index names by then.

private final class Gate: @unchecked Sendable {
    let release = DispatchSemaphore(value: 0)
}

private final class Calls: @unchecked Sendable {
    private let lock = NSLock()
    private var urls: [URL] = []
    func add(_ url: URL) { lock.withLock { urls.append(url) } }
    var all: [URL] { lock.withLock { urls } }
}

private func voice(_ tones: [Double], seconds: Double) -> [Float] {
    (0..<Int(seconds * 48_000)).map { n in
        var v = 0.0
        for (i, f) in tones.enumerated() { v += 0.03 * sin(2 * .pi * f * Double(n) / 48_000) * (0.55 + 0.45 * sin(2 * .pi * Double(2 + i) * Double(n) / 48_000)) }
        return Float(v)
    }
}

@Test("A transcription asked for while Shrink is shrinking that meeting waits, says why, and then runs on the shrunk recording (F1028)")
@MainActor
func transcriptionWaitsForShrinkOfItsMeeting() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("F1028-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let folder = root.appendingPathComponent("Recordings/\(id.uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try fixturePolyWAV([voice([311, 457, 619, 911], seconds: 4), voice([353, 541, 823, 953], seconds: 4)])
        .write(to: folder.appendingPathComponent("recording.wav"))
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(),
                         defaults: try #require(UserDefaults(suiteName: testSuiteName())),
                         whisperExecutable: { URL(fileURLWithPath: "/usr/bin/true") }, qwenInstalled: { true })
    model.trashForShrink = try ShrinkTestTrash(in: root).seam   // F1040: never the real Trash
    model.selectedEngine = .whisperLarge
    model.store.upsert(MeetingRecord(id: id, title: "Client call", duration: 4,
                                     recordingPath: "Recordings/\(id.uuidString)/recording.wav", status: .recorded))
    model.availableBytesForShrink = { _ in .max }
    let calls = Calls()
    model.runTranscriptionEngineOverride = { _, url in
        calls.add(url)
        return TranscriptionResult(id: "stub", text: "Hi.", languageCode: "en", audioDuration: 4, confidence: nil,
                                   segments: [TranscriptSegment(speaker: nil, start: 0, end: 4, text: "Hi.")])
    }
    let gate = Gate()
    defer { gate.release.signal() }  // never leave the encode blocked, whatever fails first
    let real = model.encodeForShrink
    model.encodeForShrink = { input, output, working in
        gate.release.wait()
        try real(input, output, working)
    }

    await model.refreshStorage(ids: [id])
    model.requestShrink(ids: [id])
    let shrink = try #require(model.performShrink(confirmed: true))
    try await pollUntil("Shrink to start") { model.shrinkRunningID == id }

    model.beginTranscription(id: id)
    // `beginTranscription` pumps the queue synchronously: a job that started is active now, before any await, and one
    // that waits is still pending (review of round 2, finding 5: no sleep).
    let startedDuringShrink = model.hasActiveTranscription
    let waiting = model.queuedTranscriptionWaitMessage
    let queued = model.isQueuedForTranscription(id)

    gate.release.signal()
    await shrink.value
    try await pollUntil("the transcription to run after Shrink") { !calls.all.isEmpty && !model.hasActiveTranscription }

    #expect(!startedDuringShrink, "a transcription started during Shrink of its meeting")
    #expect(calls.all.count == 1, "the engine ran \(calls.all.count) times")
    #expect(queued, "the request was dropped instead of queued")
    #expect(waiting == "Waiting for Shrink to finish with this meeting.", "\(waiting)")
    #expect(model.alertMessage?.contains("Shrunk") == true, "\(model.alertMessage ?? "nil")")
    #expect(calls.all.map(\.lastPathComponent) == ["recording.m4a"], "\(calls.all)")
}
