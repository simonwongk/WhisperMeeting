import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F185 — queue every ready meeting in one action. After a bulk import, pressing Transcribe once per
// meeting is tedious; this must still go through the normal per-meeting path so the queue applies.

/// Pinned installed, so a request reaches the queue on any host — including a runner with no Whisper,
/// where it would otherwise stop at the install gate and pass or fail for the wrong reason (F441).
@MainActor
private func makeModel() throws -> (AppModel, URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("BatchTranscribeTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let defaults = UserDefaults(suiteName: "F185.\(UUID().uuidString)")!
    let model = AppModel(
        store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(), defaults: defaults,
        whisperExecutable: { URL(fileURLWithPath: "/usr/bin/true") }, qwenInstalled: { true }
    )
    model.selectedEngine = .whisperLarge
    return (model, root)
}

/// A transcription held open until released, so the queue can be read while one job runs and the
/// rest wait. Cancelling ends it with an error, as a real subprocess client does.
private final class HeldRun: @unchecked Sendable {
    private let lock = NSLock()
    private var _released = false
    private var _starts = 0
    var starts: Int { lock.withLock { _starts } }
    func release() { lock.withLock { _released = true } }

    struct NeverReleased: Error {}

    func run() async throws {
        lock.withLock { _starts += 1 }
        for _ in 0..<6_000 {
            if lock.withLock({ _released }) { return }
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        throw NeverReleased()
    }
}

@MainActor
private func waitUntil(_ what: String, _ condition: () -> Bool) async throws {
    var ticks = 0
    while !condition(), ticks < 6_000 {
        try await Task.sleep(nanoseconds: 5_000_000)
        ticks += 1
    }
    try #require(condition(), "timed out waiting for \(what)")
}

@MainActor
@Test("Only meetings with audio and no transcript count as ready to transcribe (F185)")
func readyMeetingsExcludeCompletedAndAudioless() throws {
    let (model, root) = try makeModel()
    defer { try? FileManager.default.removeItem(at: root) }

    let ready = UUID(), done = UUID(), noAudio = UUID()
    model.store.upsert(MeetingRecord(id: ready, title: "A", recordingPath: "Recordings/a/recording.wav", status: .recorded))
    model.store.upsert(MeetingRecord(id: done, title: "B", recordingPath: "Recordings/b/recording.wav", status: .completed))
    model.store.upsert(MeetingRecord(id: noAudio, title: "C", recordingPath: "", status: .recorded))

    let ids = model.readyToTranscribeMeetings.map(\.id)
    #expect(ids == [ready])
}

// F441: this asserted only `beginTranscriptionForAllReady() == 3`, which the function returns as
// `ready.count` whatever each `beginTranscription` did — so removing the per-meeting call left it
// green while "Transcribe N Ready Meetings" queued nothing. It now reads the queue itself: one job
// running, held open, and the other two waiting behind it; then every one of the three finishing.
@MainActor
@Test("Queueing all ready meetings enqueues each one, not just the first (F185)")
func queuesEveryReadyMeeting() async throws {
    let (model, root) = try makeModel()
    defer { try? FileManager.default.removeItem(at: root) }
    let held = HeldRun()
    defer { held.release() }
    model.runTranscriptionEngineOverride = { _, _ in
        try await held.run()
        return TranscriptionResult(
            id: "stub", text: "hello", languageCode: "en", audioDuration: 1, confidence: nil,
            segments: [TranscriptSegment(speaker: nil, start: 0, end: 1, text: "hello")]
        )
    }

    var ids: [UUID] = []
    for index in 0..<3 {
        let id = UUID()
        ids.append(id)
        model.store.upsert(MeetingRecord(
            id: id, title: "M\(index)", recordingPath: "Recordings/\(index)/recording.wav", status: .recorded
        ))
    }
    try #require(model.readyToTranscribeMeetings.count == 3)

    let attempted = model.beginTranscriptionForAllReady()
    #expect(attempted == 3)

    // One job is running and held open; the other two are waiting behind it. Together they are all
    // three ready meetings — none dropped, none queued twice.
    try await waitUntil("the first transcription to start") { held.starts == 1 }
    let active = try #require(model.transcription.activeID, "nothing is running: the batch queued nothing")
    let waiting = ids.filter { model.isQueuedForTranscription($0) }
    #expect(waiting.count == 2, "expected two meetings waiting behind the running one, found \(waiting.count)")
    #expect(Set(waiting + [active]) == Set(ids), "the running and waiting meetings are not the three ready ones")

    // Releasing the first lets each queued meeting run in turn and finish.
    held.release()
    try await waitUntil("the queue to drain") { !model.hasActiveTranscription && !model.hasQueuedTranscriptions }
    for id in ids {
        #expect(model.store.meeting(id: id)?.status == .completed, "a ready meeting was never transcribed")
    }
    #expect(held.starts == 3)
}
