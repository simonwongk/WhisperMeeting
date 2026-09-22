import Foundation
import ObjCExceptionBridge
import Testing
@testable import WhisperMeet

// F374 — the one test in this whole area that can be written honestly.
//
// Every other guard around `MicDictationRecorder.start()` is either a source assertion or a probe
// that narrows a window. This one drives the actual mechanism: a raised `NSException` becomes a
// Swift-visible error and the process survives. It can be written only because the bridge makes
// the raise catchable — before it, a test that raised would have taken the test runner down with
// it, which is why F367 warns against trying to make a fake raise.
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

@Test("Every hardware call in start() is inside the bridge (F374)")
func theHardwareCallsAreAllInsideTheBridge() throws {
    // The behavioural tests above prove the bridge works; nothing headless can prove the recorder
    // USES it, because reaching `start()`'s hardware section needs a device. This is the F306
    // source assertion that stands in for that, and it checks the three calls AVAudioEngine.h
    // documents as able to raise.
    let source = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/Dictation/MicDictationRecorder.swift")
    let bridged = try #require(source.range(of: "WMRunCatchingObjCExceptions({"))
    let closing = try #require(source.range(of: "}, &raised)"))
    let block = source[bridged.upperBound..<closing.lowerBound]
    #expect(block.contains("engine.inputNode"))
    #expect(block.contains("installTap(onBus: 0"))
    #expect(block.contains("try engine.start()"))
    // And the Swift `throws` is carried out rather than swallowed: a block that cannot throw makes
    // it far too easy to turn an ordinary error into a silent success.
    #expect(block.contains("swiftFailure = error"))
    #expect(source.contains("if let swiftFailure { throw swiftFailure }"))
}
