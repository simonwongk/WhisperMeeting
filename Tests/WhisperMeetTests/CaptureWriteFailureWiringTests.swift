import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F386 — the engine has to report write outcomes, or the warning in `RecordingHealthMonitor` is a
// mechanism with no input.
//
// Source-asserted, and the reason is the ticket's own: driving a real append failure needs a
// `FloatTrackWriter` that fails, and there is no seam for one — `beginTestTrackSession` builds
// real writers over a real directory. Manufacturing a failure would mean filling a disk or
// revoking a descriptor mid-test, neither of which `swift test` may do. The rule that the outcome
// is reported on BOTH paths is checkable as text, and it is the half that regresses silently:
// dropping the success call would latch the warning on forever, and dropping the failure call
// would return the app to F386's original state with the warning still apparently in place.

private let engineSource = "Sources/WhisperMeet/AudioCaptureEngine.swift"

@Test("A failed append is reported to the health monitor (F386)")
func aFailedAppendIsReported() throws {
    let source = try SourceAssertion.uncommentedSource(engineSource)
    // The catch that F363 left as the only record of a write failure, and which surfaced nowhere.
    let handler = try #require(source.range(of: "_streamError = error"))
    let window = source[handler.lowerBound...].prefix(240)
    #expect(window.contains("healthMonitor?.recordWriteOutcome(succeeded: false)"), "\(window)")
}

@Test("A successful append is reported too, so the count cannot latch (F386)")
func aSuccessfulAppendIsReported() throws {
    // Both channels. The consecutive count is only safe to warn on at three because any success
    // resets it; a path that never reports success turns a threshold of three into "three write
    // failures ever, in any order, for the rest of the recording".
    let source = try SourceAssertion.uncommentedSource(engineSource)
    let successes = source.components(separatedBy: "healthMonitor?.recordWriteOutcome(succeeded: true)").count - 1
    #expect(successes == 2, "expected one per channel, found \(successes)")
    for channel in ["_systemWriter?.append(sampleBuffer)", "_microphoneWriter?.append(sampleBuffer)"] {
        let call = try #require(source.range(of: channel))
        let window = source[call.upperBound...].prefix(120)
        #expect(window.contains("recordWriteOutcome(succeeded: true)"), "\(channel): \(window)")
    }
}

@Test("The new warning is at risk everywhere it is read (F386)")
func theWarningIsAtRiskEverywhere() {
    // `MenuBarRecording.isAtRisk` and `RecordingRiskAnnouncer` both key off `overallStatus ==
    // .atRisk` and `warning.isAtRisk`, so this one line is what gets the user told without any new
    // UI — the ⚠︎ in the menu-bar title and a spoken announcement.
    #expect(RecordingHealthWarning.captureWritesFailing.isAtRisk)
    let snapshot = RecordingHealthSnapshot(
        microphoneLevel: .silent, systemAudioLevel: .silent,
        availableStorageBytes: nil, warnings: [.captureWritesFailing]
    )
    #expect(snapshot.overallStatus == .atRisk)
    #expect(MenuBarRecording.isAtRisk(isRecording: true, isStopping: false, health: snapshot))
    var announcer = RecordingRiskAnnouncer()
    #expect(announcer.announcement(for: snapshot) != nil, "a new at-risk warning must be announced")
}
