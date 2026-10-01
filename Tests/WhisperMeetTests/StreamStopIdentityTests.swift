import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F484 — the delegate's stale-stream guard had no test.
//
// ScreenCaptureKit reports a dead stream through `stream(_:didStopWithError:)`, and that callback
// guards on the stream being the live one: after a restart (F275) the replaced stream can still
// report its own stop, late, and that report must not mark the healthy new capture dead — the
// health tick would restart it again (`AppModel` restarts on `captureDidDie`). Every test of a
// stream reporting its own death went through `handleStreamFailure`, which has no production caller
// and skips the guard, so deleting the guard failed nothing.
//
// These drive the delegate's own body, `recordStreamStop(from:error:)`. The live stream is a
// stand-in object, not an `SCStream`. One could be built: `SCStream`'s own `init` is unavailable but
// `SCContentFilter`'s is not, so `SCStream(filter: SCContentFilter(), …)` typechecks. But
// ScreenCaptureKit's headers do not say whether constructing a stream asks for the Screen Recording
// permission, and a test must never risk that prompt. So the stand-in exercises the guard, and
// `liveStreamIdentityIsTheStreamOutsideDebug` pins as source that outside DEBUG the identity is
// `_stream` itself.
//
// No clock. `recordStreamStop` hands its work to the serial `captureQueue` asynchronously, so each
// test calls `drainCaptureQueueForTesting()` (a `captureQueue.sync {}`) before it asserts. That
// orders the assertions after the queued block whatever `captureDidDie` and `hasStreamError` do to
// read their value. Without it, an accessor that does not wait on the queue fails the death test,
// and passes the ignore tests' expectations on it without checking anything.

private struct LateStop: Error {}

private func makeEngine() -> AudioCaptureEngine {
    AudioCaptureEngine(
        stoppingCapture: {},
        finishingTracks: {},
        preservingPartialTracks: {},
        startingCapture: { _, _, _ in },
        directory: FileManager.default.temporaryDirectory
            .appendingPathComponent("F484-\(UUID().uuidString)", isDirectory: true)
    )
}

@Test("A stop reported by a stream that is no longer the live one is ignored (F484)")
func staleStreamStopIsIgnored() {
    let engine = makeEngine()
    let replacedStream = NSObject()
    let liveStream = NSObject()
    engine.installLiveStreamStandInForTesting(liveStream)

    engine.recordStreamStop(from: replacedStream, error: LateStop())
    engine.drainCaptureQueueForTesting()

    #expect(!engine.captureDidDie, "a late stop from a replaced stream marked the live capture dead")
    #expect(!engine.hasStreamError, "a late stop from a replaced stream recorded an error on the live capture")
}

@Test("A stop reported when there is no live stream at all is ignored (F484)")
func stopWithNoLiveStreamIsIgnored() {
    let engine = makeEngine()

    engine.recordStreamStop(from: NSObject(), error: LateStop())
    engine.drainCaptureQueueForTesting()

    #expect(!engine.captureDidDie)
    #expect(!engine.hasStreamError)
}

@Test("The live stream's own stop records a death (F484)")
func liveStreamStopRecordsDeath() {
    let engine = makeEngine()
    let liveStream = NSObject()
    engine.installLiveStreamStandInForTesting(liveStream)

    engine.recordStreamStop(from: liveStream, error: LateStop())
    engine.drainCaptureQueueForTesting()

    #expect(engine.captureDidDie, "the live stream stopped and the engine did not notice")
    #expect(engine.hasStreamError)
}

@Test("The SCStream delegate callback forwards to the guarded body (F484)")
func delegateForwardsToRecordStreamStop() throws {
    // The three tests above call `recordStreamStop` directly, so they cannot see a delegate that
    // stops calling it — re-inlined without the guard, say. This is the crude check that can.
    let lines = try SourceAssertion.uncommentedLines("Sources/WhisperMeet/AudioCaptureEngine.swift")
    let declaration = try #require(
        lines.firstIndex { $0.text.contains("func stream(_ stream: SCStream, didStopWithError error: Error) {") },
        "the SCStreamDelegate stop callback was not found"
    )
    let body = lines[(declaration + 1)...]
        .map { $0.text.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }
    #expect(Array(body.prefix(2)) == ["recordStreamStop(from: stream, error: error)", "}"],
            "stream(_:didStopWithError:) must be exactly a forward to recordStreamStop(from:error:)")
}

@Test("Outside DEBUG, a stop is checked against the live SCStream itself (F484)")
func liveStreamIdentityIsTheStreamOutsideDebug() throws {
    // The three behavioural tests above either install a stand-in, which the DEBUG branch of
    // `_liveStreamIdentity` returns first, or have no live stream, where `return _stream` gives nil:
    // exactly what a getter mutated to `return nil` gives. None of them can tell that line from nil,
    // so `return nil` would make the shipped app ignore every real stream death with the whole
    // suite green. This pins the line as source.
    let source = SourceAssertion.stripComments(
        try String(
            contentsOf: SourceAssertion.url("Sources/WhisperMeet/AudioCaptureEngine.swift"),
            encoding: .utf8
        ),
        blankStringLiterals: true
    )
    let declarations = source.ranges(of: "var _liveStreamIdentity: AnyObject? {")
    try #require(declarations.count == 1, "expected one _liveStreamIdentity declaration, found \(declarations.count)")
    var depth = 1
    var cursor = declarations[0].upperBound
    while cursor < source.endIndex, depth > 0 {
        if source[cursor] == "{" { depth += 1 } else if source[cursor] == "}" { depth -= 1 }
        cursor = source.index(after: cursor)
    }
    try #require(depth == 0, "_liveStreamIdentity's getter never closes")
    let lines = source[declarations[0].upperBound..<source.index(before: cursor)]
        .split(separator: "\n")
        .map { $0.trimmingCharacters(in: .whitespaces) }
        .filter { !$0.isEmpty }

    // One `#if DEBUG … #endif` and no other directive, or this guard needs re-reading: an `#else`
    // or a second condition would put release code where the stripping below throws it away.
    let directives = lines.filter { $0.hasPrefix("#") }
    try #require(
        directives == ["#if DEBUG", "#endif"],
        "_liveStreamIdentity's compile-time branches changed (\(directives)); re-read this guard"
    )
    let opening = try #require(lines.firstIndex(of: "#if DEBUG"))
    let closing = try #require(lines.firstIndex(of: "#endif"))
    let releaseGetter = Array(lines[..<opening] + lines[(closing + 1)...])
    let expected: [String] = ["return _stream"]
    #expect(
        releaseGetter == expected,
        "outside DEBUG, _liveStreamIdentity must be exactly `return _stream`, or a real stream's stop is checked against something else"
    )
}
