import Testing
import Foundation
@testable import WhisperCore

private func silentChannel() -> ChannelSignal { ChannelSignal(peak: 0, rms: 0, level: .silent) }

private func sine(amplitude: Float, count: Int = 48_000) -> [Float] {
    (0..<count).map { amplitude * sin(Float($0) * 0.05) }
}

@Test("preflight readiness needs sustained audio, not a single transient click")
func preflightRejectsTransientClick() {
    // One loud sample among silence: high peak, negligible energy across the window — a click/tap,
    // not a captured voice. This must NOT pass preflight.
    var click = [Float](repeating: 0, count: 48_000)
    click[10_000] = 0.95
    let mic = PreflightSignalAnalyzer.analyze(samples: click)
    let report = PreflightAssessment.evaluate(microphone: mic, system: silentChannel())
    #expect(!report.microphone.isCapturing)
    #expect(!report.isReady)
}

@Test("preflight accepts sustained speech, including quiet speech")
func preflightAcceptsSustainedSpeech() {
    let normal = PreflightSignalAnalyzer.analyze(samples: sine(amplitude: 0.3))
    let quiet = PreflightSignalAnalyzer.analyze(samples: sine(amplitude: 0.03))
    #expect(PreflightAssessment.evaluate(microphone: normal, system: silentChannel()).isReady)
    // Quiet but SUSTAINED speech must still count as capturing — not mistaken for a transient.
    let quietReport = PreflightAssessment.evaluate(microphone: quiet, system: silentChannel())
    #expect(quietReport.microphone.isCapturing)
    #expect(quietReport.isReady)
}

@Test("isSustained separates sustained tones from spiky transients")
func preflightIsSustainedCrestFactor() {
    let tone = PreflightSignalAnalyzer.analyze(samples: sine(amplitude: 0.3))
    #expect(PreflightSignalAnalyzer.isSustained(tone))

    var click = [Float](repeating: 0, count: 48_000)
    click[0] = 0.9
    #expect(!PreflightSignalAnalyzer.isSustained(PreflightSignalAnalyzer.analyze(samples: click)))

    // Nothing at all is not "sustained" either.
    #expect(!PreflightSignalAnalyzer.isSustained(silentChannel()))
}
