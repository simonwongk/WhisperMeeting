import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F173 — the correction busy state is scoped to the meeting being corrected, mirroring F156's
// second-opinion scoping: meeting B must never be shown as busy for meeting A's run.

@MainActor
private func makeModel() throws -> AppModel {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("CorrectionScopeTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let defaults = UserDefaults(suiteName: testSuiteName())!
    return AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(), defaults: defaults)
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

@MainActor
@Test("A correction run is attributed to the requested meeting only, and clears when done (F173)")
func correctionBusyStateIsScopedToTheMeeting() async throws {
    let model = try makeModel()
    model.isCorrectionModelInstalled = { true }

    final class Gate: @unchecked Sendable {
        var release: CheckedContinuation<Void, Never>?
    }
    let gate = Gate()
    model.proposeTranscriptCorrections = { _, _, _ in
        await withCheckedContinuation { gate.release = $0 }
        return []
    }

    let segments = [TranscriptSegment(speaker: nil, start: 0, end: 1, text: "hello world")]
    let a = UUID()
    let b = UUID()
    model.store.addVocabulary(["Kubernetes"])
    for id in [a, b] {
        model.store.upsert(MeetingRecord(
            id: id, title: "M", status: .completed,
            transcriptText: TranscriptFormatter.timestamped(segments), segments: segments
        ))
    }

    let run = Task { await model.proposeLocalCorrections(for: a) }
    try await waitUntil("the correction run to reach its model") { gate.release != nil }

    #expect(model.proposingCorrectionsID == a) // scoped to A…
    #expect(model.proposingCorrectionsID != b) // …never attributed to B
    #expect(model.isProposingCorrections == true)

    gate.release?.resume()
    _ = await run.value
    #expect(model.proposingCorrectionsID == nil)
    #expect(model.isProposingCorrections == false)
}
