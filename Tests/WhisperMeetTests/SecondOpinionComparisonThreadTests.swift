import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F542 — Second Opinion lined the two transcripts up on the main actor, in a scan of every line
// against every segment of the other engine. On a six-hour meeting that froze the window when the
// other engine finished. The comparison now runs off the main actor (and in one pass: the WhisperCore
// side is pinned by `comparisonFastPathMatchesTheReference`). Moving it off the main actor adds a
// suspension point where there was none, so a Cancel pressed while it runs must still mean "no
// comparison" — the F512 contract.

private func seg(_ text: String, _ start: Double, _ end: Double) -> TranscriptSegment {
    TranscriptSegment(speaker: nil, start: start, end: end, text: text)
}

/// Where the comparison ran, and whether it started. A class so the `@Sendable` seam can record.
private final class ComparisonProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var _ranOnMainThread: [Bool] = []
    var ranOnMainThread: [Bool] { lock.withLock { _ranOnMainThread } }
    var started: Bool { lock.withLock { !_ranOnMainThread.isEmpty } }
    func record(onMainThread: Bool) { lock.withLock { _ranOnMainThread.append(onMainThread) } }
}

@MainActor
private func makeModel() throws -> (AppModel, UUID, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("F542-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root.appendingPathComponent("Recordings"), withIntermediateDirectories: true)
    let defaults = try #require(UserDefaults(suiteName: "F542.\(UUID().uuidString)"))
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(), defaults: defaults)
    let id = UUID()
    let stored = [seg("hello world", 0, 1), seg("second segment", 1, 2)]
    model.store.upsert(MeetingRecord(
        id: id, title: "M", recordingPath: "Recordings/\(id.uuidString)/meeting.wav", status: .completed,
        transcriptText: TranscriptFormatter.timestamped(stored), segments: stored, transcriptionEngine: .whisperLarge
    ))
    model.runTranscriptionEngineOverride = { _, _ in
        TranscriptionResult(id: "x", text: "hello world second thing", languageCode: "en", audioDuration: 2,
                            confidence: nil, segments: [seg("hello world", 0, 1), seg("second thing", 1, 2)])
    }
    return (model, id, root)
}

/// Polls the caller's own subject against the wall clock; an exhausted budget fails as the wait.
@MainActor
private func waitUntil(_ what: String, _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(30)
    while !condition(), Date() < deadline {
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    try #require(condition(), "timed out waiting for \(what)")
}

@MainActor
@Test("Second Opinion lines the two transcripts up off the main actor (F542)")
func secondOpinionComparesOffTheMainActor() async throws {
    let (model, id, root) = try makeModel()
    defer { try? FileManager.default.removeItem(at: root) }
    let probe = ComparisonProbe()
    model.compareTranscripts = { primary, secondary in
        probe.record(onMainThread: Thread.isMainThread)
        return TranscriptComparison.compare(primary, secondary)
    }

    await model.computeSecondOpinion(id: id)

    #expect(probe.ranOnMainThread == [false], "the comparison runs once, and not on the main thread")
    #expect(model.secondOpinionSpans?.map(\.kind) == [.agree, .diverge], "and its result still reaches the sheet")
}

@MainActor
@Test("A second opinion cancelled while the comparison runs shows no comparison (F542)")
func secondOpinionCancelledDuringTheComparisonPublishesNothing() async throws {
    let (model, id, root) = try makeModel()
    defer { try? FileManager.default.removeItem(at: root) }
    let probe = ComparisonProbe()
    let release = DispatchSemaphore(value: 0)
    model.compareTranscripts = { primary, secondary in
        probe.record(onMainThread: Thread.isMainThread)
        // Held until the test has pressed Cancel. The timeout only stops a regression that runs
        // this on the main thread from hanging the suite; it is not what the test waits on.
        _ = release.wait(timeout: .now() + 30)
        return TranscriptComparison.compare(primary, secondary)
    }

    #expect(model.requestSecondOpinion(id: id))
    try await waitUntil("the comparison to start") { probe.started }
    model.cancelSecondOpinion()
    release.signal()
    try await waitUntil("the run to end") { !model.isRunningAuxiliaryEngine }

    #expect(model.secondOpinionSpans == nil, "Cancel means no comparison, however late it is pressed")
    #expect(model.secondOpinionFailed == false, "and it is not reported as a failure")
}
