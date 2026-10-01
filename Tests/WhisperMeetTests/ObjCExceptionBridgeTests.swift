import AVFoundation
import Foundation
import ObjCExceptionBridge
import Testing
@testable import WhisperMeet

// F374 — the bridge, and where it is used.
//
// The first tests below drive the mechanism itself: a raised `NSException` becomes a Swift-visible
// error and the process survives. Before the bridge, a test that raised took the test runner down
// with it. F403 recorded exactly that: `aRaisingProbeIsCaughtByTheBridge` (in
// `DictationCaptureLossTests`) aborted `swiftpm-testing-helper` while the probe still ran outside
// the bridge. That test now raises through `MicDictationRecorder.start()` itself, and
// `nonPCMBufferFormatRaiseIsCaught` (F385) has AVFoundation raise for real. What no headless test
// can reach is pinned by the two source assertions at the end: that the rest of `start()`'s
// hardware calls, and `AudioCaptureEngine`'s buffer construction, are inside the bridge.
//
// The option chosen, and the two rejected. (1) "accept and document" is the status quo plus a
// sentence and closes nothing. (2) "re-probe immediately before `engine.start()`" narrows the
// window and, by F356's own lesson, must not be mistaken for closing it — a value read before a
// side-effecting call is stale when the call validates it, however few lines apart they are.
// (3) is the only one that closes the class, and the build-system risk the ticket flagged was
// measured rather than argued: an Objective-C target builds under Command Line Tools on this
// machine, with no Xcode installed.

@Test("A raised NSException becomes a Swift error and the process survives (F374)")
func aRaisedExceptionBecomesAnError() {
    var error: NSError?
    let completed = WMRunCatchingObjCExceptions({
        NSException(
            name: .invalidArgumentException,
            // Verbatim from the 2026-09-21 abort. The reason is the line that matters and the one
            // the `.ips` crash report did not carry.
            reason: "required condition is false: format.sampleRate == hwFormat.sampleRate",
            userInfo: nil
        ).raise()
    }, &error)

    #expect(!completed)
    let raised = try? #require(error)
    #expect(raised?.domain == WMObjCExceptionErrorDomain)
    #expect(raised?.localizedDescription == "required condition is false: format.sampleRate == hwFormat.sampleRate")
    #expect(raised?.userInfo[WMObjCExceptionNameKey] as? String == NSExceptionName.invalidArgumentException.rawValue)
}

@Test("A block that does not raise reports success and leaves the error alone (F374)")
func aNormalBlockIsNotDisturbed() {
    var error: NSError? = NSError(domain: "pre-existing", code: 99)
    var ran = false
    let completed = WMRunCatchingObjCExceptions({ ran = true }, &error)
    #expect(completed)
    #expect(ran, "the block must actually run — a bridge that swallowed it would pass every other check")
    #expect(error?.domain == "pre-existing", "an untouched out-parameter, not a cleared one")
}

@Test("An exception with no reason still yields a named error (F374)")
func anExceptionWithoutAReasonStillNamesItself() {
    var error: NSError?
    let completed = WMRunCatchingObjCExceptions({
        NSException(name: NSExceptionName("WMTestException"), reason: nil, userInfo: nil).raise()
    }, &error)
    #expect(!completed)
    // `reason` is nullable and AVFoundation does not always set it. Falling through to the name
    // keeps `localizedDescription` non-empty, which is what `ErrorPresentation.sentence` tests.
    #expect(error?.localizedDescription == "WMTestException")
}

@Test("The recorder's raise case reads as a sentence, not as a reason string (F374, F366)")
func theRaiseCaseHasUserFacingCopy() {
    let error = MicDictationRecorder.RecorderError.captureEngineRaised(
        reason: "required condition is false: format.sampleRate == hwFormat.sampleRate"
    )
    let shown = (error as any Error).localizedDescription
    #expect(!shown.contains("required condition"), "the raised reason is diagnostic, not copy: \(shown)")
    #expect(shown.localizedCaseInsensitiveContains("audio device changed"))
}

// MARK: - F385: AudioCaptureEngine's own raising call

@Test("AVAudioPCMBuffer raises for a non-PCM format, exactly as AVAudioBuffer.h documents, and the bridge catches it (F385)")
func nonPCMBufferFormatRaiseIsCaught() throws {
    // Grounds F385's fix in something observed rather than only read from a header: this
    // constructs a real, non-PCM `AVAudioFormat` (no device needed — a format is pure data) and
    // drives the SAME initializer `FloatTrackWriter.append` calls on a captured buffer's format,
    // proving the documented raise ("An exception is raised if the format is not PCM.",
    // AVAudioBuffer.h) is real and that `WMRunCatchingObjCExceptions` catches it.
    var asbd = AudioStreamBasicDescription(
        mSampleRate: 44_100,
        mFormatID: kAudioFormatMPEG4AAC,
        mFormatFlags: 0,
        mBytesPerPacket: 0,
        mFramesPerPacket: 1_024,
        mBytesPerFrame: 0,
        mChannelsPerFrame: 2,
        mBitsPerChannel: 0,
        mReserved: 0
    )
    let nonPCMFormat = try #require(AVAudioFormat(streamDescription: &asbd))

    var rawBuffer: AVAudioPCMBuffer?
    var raised: NSError?
    let completed = WMRunCatchingObjCExceptions({
        rawBuffer = AVAudioPCMBuffer(pcmFormat: nonPCMFormat, frameCapacity: 100)
    }, &raised)

    #expect(!completed)
    #expect(rawBuffer == nil)
    #expect(raised != nil)
}

// MARK: - F374 and F403: the recorder's own raising calls

/// Every `WMRunCatchingObjCExceptions({ … })` block in `source`, from its opening brace to its
/// matching closing one. `source` must have had its comments stripped and its string literals
/// blanked, or a brace in either would be counted as a scope (F285).
private func bridgedRanges(in source: String) -> [Range<String.Index>] {
    var ranges: [Range<String.Index>] = []
    var searchFrom = source.startIndex
    while let opening = source.range(of: "WMRunCatchingObjCExceptions({", range: searchFrom..<source.endIndex) {
        var depth = 1
        var cursor = opening.upperBound
        while cursor < source.endIndex, depth > 0 {
            if source[cursor] == "{" { depth += 1 }
            if source[cursor] == "}" { depth -= 1 }
            if depth > 0 { cursor = source.index(after: cursor) }
        }
        guard cursor < source.endIndex else { break }
        ranges.append(opening.upperBound..<cursor)
        searchFrom = source.index(after: cursor)
    }
    return ranges
}

/// The body of the declaration whose head is `head` (which must end with its opening brace).
private func bodyRange(of head: String, in source: String) -> Range<String.Index>? {
    guard head.hasSuffix("{"), let found = source.range(of: head) else { return nil }
    var depth = 1
    var cursor = found.upperBound
    while cursor < source.endIndex {
        if source[cursor] == "{" { depth += 1 }
        if source[cursor] == "}" {
            depth -= 1
            if depth == 0 { return found.upperBound..<cursor }
        }
        cursor = source.index(after: cursor)
    }
    return nil
}

/// Every occurrence of `needle` in `haystack`, as ranges.
private func occurrences(of needle: String, in haystack: String) -> [Range<String.Index>] {
    var found: [Range<String.Index>] = []
    var searchFrom = haystack.startIndex
    while let hit = haystack.range(of: needle, range: searchFrom..<haystack.endIndex) {
        found.append(hit)
        searchFrom = hit.upperBound
    }
    return found
}

/// The 1-based line `index` falls on, so a failure names a line somebody can open.
private func lineNumber(of index: String.Index, in source: String) -> Int {
    source[..<index].reduce(1) { $1 == "\n" ? $0 + 1 : $0 }
}

@Test("Every hardware call in start() is inside the bridge (F374, F403)")
func theHardwareCallsAreAllInsideTheBridge() throws {
    // The behavioural tests prove the bridge works, and `aRaisingProbeIsCaughtByTheBridge` proves
    // start() routes the probe through it; nothing headless can prove the rest of start() does,
    // because reaching its hardware section needs a device. This is the F306 source assertion that
    // stands in for that.
    //
    // F403: the first version of this test sliced the first bridged block and checked that it
    // CONTAINED `engine.inputNode`. That could never see the call that mattered, which was outside:
    // `AVAudioEngine.h` says the engine "creates a singleton on demand when this property is first
    // accessed", and in production the first access was the availability probe, read before the
    // block. So this now checks the other direction too — what is OUTSIDE every block.
    let source = SourceAssertion.stripComments(
        try String(
            contentsOf: SourceAssertion.url("Sources/WhisperMeet/Dictation/MicDictationRecorder.swift"),
            encoding: .utf8
        ),
        blankStringLiterals: true
    )
    let bridged = bridgedRanges(in: source)
    let setUp = try #require(bridged.first, "start() has no bridged block at all")
    func isBridged(_ hit: Range<String.Index>) -> Bool {
        bridged.contains { $0.contains(hit.lowerBound) }
    }

    // The probe's own real read is the one sanctioned `engine.inputNode` outside a block — and
    // only because the next check requires every call to the probe to be inside one.
    let probeBody = try #require(
        bodyRange(of: "func hardwareFormat() -> (sampleRate: Double, channels: UInt32) {", in: source),
        "hardwareFormat() not found; did it move?"
    )
    for hit in occurrences(of: "engine.inputNode", in: source)
    where !isBridged(hit) && !probeBody.contains(hit.lowerBound) {
        Issue.record("line \(lineNumber(of: hit.lowerBound, in: source)): `engine.inputNode` outside every bridged block")
    }
    let probeCalls = occurrences(of: "hardwareFormat()", in: source)
        .filter { !source[..<$0.lowerBound].hasSuffix("func ") }
    #expect(!probeCalls.isEmpty, "start() no longer consults the probe")
    for hit in probeCalls where !isBridged(hit) {
        Issue.record("line \(lineNumber(of: hit.lowerBound, in: source)): the probe is called outside every bridged block, and in production it is the first `inputNode` access")
    }
    // F367's ordering, kept inside the block: the probe is consulted before the node is reached.
    let block = source[setUp]
    if let probeInBlock = block.range(of: "self.hardwareFormat()"),
       let nodeInBlock = block.range(of: "engine.inputNode") {
        #expect(probeInBlock.lowerBound < nodeInBlock.lowerBound, "the probe must run before the node is reached (F367)")
    } else {
        Issue.record("start()'s bridged block must consult the probe and then reach the node")
    }
    #expect(block.contains("installTap(onBus: 0"))
    #expect(block.contains("try engine.start()"))

    // The teardown after a failed start runs on the engine that just failed, which may be the one
    // that raised, so it is bridged too.
    let startBody = try #require(
        bodyRange(of: "func start(onLevel: @escaping @Sendable (Float) -> Void) throws {", in: source)
    )
    for call in ["engine.stop()", "removeTap(onBus: 0)"] {
        let hits = occurrences(of: call, in: source).filter { startBody.contains($0.lowerBound) }
        #expect(!hits.isEmpty, "start() no longer tears down with \(call)")
        for hit in hits where !isBridged(hit) {
            Issue.record("line \(lineNumber(of: hit.lowerBound, in: source)): start()'s failure teardown calls \(call) outside every bridged block")
        }
    }

    // And the Swift `throws` is carried out rather than swallowed: a block that cannot throw makes
    // it far too easy to turn an ordinary error into a silent success. It leaves start() through
    // `startExit` (F404), whose rows (`startExitRows`) pin that the error comes back unchanged.
    #expect(block.contains("swiftFailure = error"))
    #expect(source[startBody].contains("swiftFailure: swiftFailure"), "start() no longer hands its Swift failure to startExit")
}

@Test("The capture path's raising AVAudioPCMBuffer construction is inside the bridge (F385)")
func theCaptureBufferConstructionIsInsideTheBridge() throws {
    // Reaching this call needs a live ScreenCaptureKit buffer, which nothing headless can drive —
    // the same reason `theHardwareCallsAreAllInsideTheBridge` above is a source assertion rather
    // than a behavioural test. `nonPCMBufferFormatRaiseIsCaught` proves the mechanism; this proves
    // `AudioCaptureEngine` actually uses it for the one call whose format is a device condition
    // the caller cannot pre-check.
    let source = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/AudioCaptureEngine.swift")
    let bridged = try #require(source.range(of: "WMRunCatchingObjCExceptions({"))
    let closing = try #require(source.range(of: "}, &raised)"))
    let block = source[bridged.upperBound..<closing.lowerBound]
    #expect(block.contains("AVAudioPCMBuffer("))
    #expect(block.contains("pcmFormat: inputFormat"))
    #expect(block.contains("bufferListNoCopy:"))
}
