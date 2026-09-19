import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F334 — `stop()` and `restartAfterFailure()` are both `nonisolated async` on an `@unchecked
// Sendable` class, so under SE-0338 they run on the cooperative pool rather than on AppModel's
// MainActor and can genuinely run in parallel. That happens whenever
// `waitForCaptureRestartToSettle()` reaches its 10 s bound: Stop gives up waiting and resets the
// engine while the restart is still going.
//
// The generation counter exists to make the restart give up in that case. It could not, because the
// check and the publish were separate statements: a `reset()` landing between them left `stream`
// non-nil and `pendingRestartPadding` set on an engine that had been reset — and `start()` is
// `guard stream == nil`, so the NEXT meeting recorded nothing at all.

private final class Flag: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false
    func set() { lock.lock(); value = true; lock.unlock() }
    var isSet: Bool { lock.lock(); defer { lock.unlock() }; return value }
}

private func makeEngine() -> AudioCaptureEngine {
    AudioCaptureEngine(
        stoppingCapture: {},
        finishingTracks: {},
        preservingPartialTracks: {},
        startingCapture: { _, _, _ in },
        restartingCapture: { _ in },
        directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("F334-\(UUID().uuidString)", isDirectory: true)
    )
}

@Test("A reset cannot land inside the restart's publish step (F334)")
func resetCannotLandInsideThePublish() throws {
    let engine = makeEngine()
    let generation = engine.sessionGenerationForTesting
    let resetLanded = Flag()

    engine.onRestartPublishWindowForTesting = { [engine] in
        // Stop's bounded wait has run out, so another thread resets the engine right here.
        DispatchQueue.global().async {
            engine.resetForTesting()
            resetLanded.set()
        }
        // Long enough for that reset to finish if anything let it: it must not, because the publish
        // owns the engine's session state for the whole of this window.
        Thread.sleep(forTimeInterval: 0.2)
        #expect(!resetLanded.isSet, "a reset landed between the session check and the publish")
    }

    try engine.publishRestartForTesting(generation: generation, paddingFrames: 4_800)

    // Whatever the interleaving, the engine must not end up holding a restarted session's state on
    // a reset engine — that is the state in which the next `start()` silently records nothing.
    while !resetLanded.isSet { Thread.sleep(forTimeInterval: 0.01) }
    #expect(!engine.hasLiveStreamForTesting)
    #expect(engine.pendingRestartPaddingForTesting == 0)
}

@Test("A restart whose session was already reset publishes nothing (F334)")
func staleRestartPublishesNothing() throws {
    let engine = makeEngine()
    let generation = engine.sessionGenerationForTesting
    engine.resetForTesting()

    #expect(throws: CancellationError.self) {
        try engine.publishRestartForTesting(generation: generation, paddingFrames: 4_800)
    }
    #expect(engine.pendingRestartPaddingForTesting == 0, "silence owed by a session nobody owns")
    #expect(!engine.hasLiveStreamForTesting)
}
