import Foundation
import Testing
@testable import WhisperCore

// F79 — a completed recording's health rollup must surface as a one-line, channel-level advisory on
// the meeting (so a user learns after the fact that e.g. no system audio was captured). Healthy
// recordings show nothing; the message is channel-level only, never speaker identity.
@Test("A healthy report yields no advisory; an at-risk one names the channel-level problem (F79)")
func recordingHealthAdvisoryMessage() {
    let healthy = RecordingHealthReport(
        warnings: [], worstStatus: .good,
        microphoneStaleSeconds: 0, systemAudioStaleSeconds: 0, systemAudioEverDetected: true
    )
    #expect(RecordingHealthAdvisory.message(for: healthy) == nil)

    let noSystemAudio = RecordingHealthReport(
        warnings: [.systemAudioNotDetected], worstStatus: .atRisk,
        microphoneStaleSeconds: 0, systemAudioStaleSeconds: 0, systemAudioEverDetected: false
    )
    let message = RecordingHealthAdvisory.message(for: noSystemAudio)
    #expect(message?.lowercased().contains("system") == true)
    #expect(message?.lowercased().contains("audio") == true)
}
