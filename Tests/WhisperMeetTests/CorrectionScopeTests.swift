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
    let defaults = UserDefaults(suiteName: "F173.\(UUID().uuidString)")!
    return AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(), defaults: defaults)
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
    while gate.release == nil { await Task.yield() }

    #expect(model.proposingCorrectionsID == a) // scoped to A…
    #expect(model.proposingCorrectionsID != b) // …never attributed to B
    #expect(model.isProposingCorrections == true)

    gate.release?.resume()
    _ = await run.value
    #expect(model.proposingCorrectionsID == nil)
    #expect(model.isProposingCorrections == false)
}
