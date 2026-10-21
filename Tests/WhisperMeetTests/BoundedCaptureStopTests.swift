import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F809 — nothing bounded `SCStream.stopCapture()`. A stop whose call never returned held "Finishing…"
// forever, and since F672 every quit too (⌘Q, Dock ▸ Quit, the menu bar's Quit, and a logout), which
// only Force Quit got out of. Suspected from reading; never observed. The bound is the one Stop
// already gives an in-flight restart (F292, F365), which tears down a stream with this same call;
// past it the capture is finalized from what was written, the deferred branch, never a discard.
//
// The bound is injected (`stopCaptureDeadlineForTesting`), so no test waits it out: the behaviour
// under test is what happens when it runs out, not the number it runs out at.

/// Holds something open until the test lets it go.
private actor Latch {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

private final class Slot<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value?
    var current: Value? {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

@Test("A stop whose stopCapture never returns saves what was written once the bound runs out (F809)")
func aHungStopCaptureFinalizesAfterTheBound() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("BoundedCaptureStop-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let neverStops = Latch()
    let bound = Latch()
    defer { Task { await neverStops.open(); await bound.open() } }
    let engine = AudioCaptureEngine(
        stoppingCapture: { await neverStops.wait() },
        finishingTracks: {}, preservingPartialTracks: nil,
        startingCapture: { _, _, _ in }, directory: directory
    )
    engine.stopCaptureDeadlineForTesting = { await bound.wait() }
    try engine.beginTestTrackSession(in: directory)
    try engine.writeTestFrames(system: 48_000 * 2, microphone: 48_000 * 2, systemStart: 0, microphoneStart: 0)

    let outcome = Slot<Result<RecordingArtifact, Error>>()
    Task {
        do { outcome.current = .success(try await engine.stop()) } catch { outcome.current = .failure(error) }
    }
    await bound.open()
    // The subject itself, polled against the wall clock: before F809 the stop never returns.
    let deadline = SuspendingClock.now + .seconds(30)
    while outcome.current == nil, SuspendingClock.now < deadline { try await Task.sleep(nanoseconds: 5_000_000) }
    let artifact = try #require(outcome.current, "the stop never returned: its stopCapture() still holds it").get()

    #expect(abs(artifact.duration - 2) < 0.05, "everything written is in the meeting: \(artifact.duration)")
    #expect(FileManager.default.fileExists(atPath: artifact.mixedRecordingURL.path), "finalized normally, not rebuilt")
    #expect(!artifact.captureStoppedEarly, "the capture did not die; Stop was pressed")
    #expect(!engine.hasLiveStreamForTesting, "the engine was reset, ready for the next recording")
}

@Test("A Cancel's stopCapture, the restart bound and the sample handler follow the stop's bound (F809)")
func theBoundIsSharedAndALetGoStreamIsIgnored() throws {
    let engine = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/AudioCaptureEngine.swift")
    // Cancel cannot be driven with a stream (no test may build an SCStream, F484), so its use of the
    // bound is pinned as source. Since F929 it takes the injected stop as `stop()` does, and
    // `aQuitDuringAHungCancelQuitsOnceTheCancelsBoundRunsOut` drives that; this pin still covers the
    // stream's branch.
    let cancel = try #require(engine.range(of: "func cancel() async {"))
    let afterCancel = try #require(engine.range(of: "func stream(", range: cancel.upperBound..<engine.endIndex))
    #expect(engine[cancel.upperBound..<afterCancel.lowerBound].contains("stopCaptureWithinBound("),
            "a Cancel whose stopCapture never returns would hold every quit just as a Stop's did")
    // A stream let go after the bound may still be delivering, so the handler drops any buffer that
    // is not the live stream's, or it would land in the next recording's writers. First, before
    // anything reads or writes.
    let handler = try #require(engine.range(of: "didOutputSampleBuffer sampleBuffer: CMSampleBuffer,"))
    let body = try #require(engine.range(of: "{", range: handler.upperBound..<engine.endIndex))
    let firstStatement = engine[body.upperBound...].drop(while: { $0.isWhitespace }).prefix(while: { $0 != "\n" })
    #expect(firstStatement == "guard stream === _stream else { return }", "\(firstStatement)")
    // One bound for both of Stop's waits on capture work it does not control.
    let model = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/AppModel.swift")
    #expect(model.contains("AudioCaptureEngine.captureSettleBound"), "the restart wait derives from the same bound")
}
