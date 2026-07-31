import Foundation
import Testing
@testable import WhisperCore

// MARK: - Signal analysis

private func tone(peak: Float, count: Int = 4_800) -> [Float] {
    // A simple ramp/sine-free deterministic signal whose max abs is exactly `peak`.
    guard count > 0 else { return [] }
    return (0..<count).map { i in
        let phase = Float(i % 2 == 0 ? 1 : -1)
        return peak * phase
    }
}

@Test("Silence (all zeros) is classified silent with zero peak and rms")
func silentSignal() {
    let signal = PreflightSignalAnalyzer.analyze(samples: [Float](repeating: 0, count: 1000))
    #expect(signal.level == .silent)
    #expect(signal.peak == 0)
    #expect(signal.rms == 0)
}

@Test("An empty track is silent, not a crash")
func emptySignal() {
    let signal = PreflightSignalAnalyzer.analyze(samples: [])
    #expect(signal.level == .silent)
    #expect(signal.peak == 0)
}

@Test("A very low peak is faint")
func faintSignal() {
    let signal = PreflightSignalAnalyzer.analyze(samples: tone(peak: 0.03))
    #expect(signal.level == .faint)
}

@Test("A healthy peak is ok")
func okSignal() {
    let signal = PreflightSignalAnalyzer.analyze(samples: tone(peak: 0.4))
    #expect(signal.level == .ok)
    #expect(abs(signal.peak - 0.4) < 1e-6)
    // A full-swing square wave has rms == peak.
    #expect(abs(signal.rms - 0.4) < 1e-6)
}

@Test("A near-full-scale peak is hot")
func hotSignal() {
    let signal = PreflightSignalAnalyzer.analyze(samples: tone(peak: 0.99))
    #expect(signal.level == .hot)
}

@Test("Level thresholds use the documented boundaries")
func levelBoundaries() {
    // Just below the silent ceiling is still silent; at it, faint begins.
    #expect(PreflightSignalAnalyzer.analyze(samples: tone(peak: 0.009)).level == .silent)
    #expect(PreflightSignalAnalyzer.analyze(samples: tone(peak: 0.01)).level == .faint)
    // At the faint ceiling, ok begins.
    #expect(PreflightSignalAnalyzer.analyze(samples: tone(peak: 0.05)).level == .ok)
    // At the hot floor, hot begins.
    #expect(PreflightSignalAnalyzer.analyze(samples: tone(peak: 0.98)).level == .hot)
}

@Test("Peak is the maximum absolute sample regardless of sign")
func peakIsAbsolute() {
    let signal = PreflightSignalAnalyzer.analyze(samples: [0.1, -0.7, 0.2, -0.05])
    #expect(abs(signal.peak - 0.7) < 1e-6)
}

@Test("Float32 little-endian data decodes to the same signal as the sample array")
func decodesFloat32Data() {
    let samples: [Float] = [0.0, 0.5, -0.5, 0.25]
    var data = Data()
    for s in samples {
        var le = s.bitPattern.littleEndian
        withUnsafeBytes(of: &le) { data.append(contentsOf: $0) }
    }
    let fromData = PreflightSignalAnalyzer.analyze(float32LittleEndian: data)
    let fromSamples = PreflightSignalAnalyzer.analyze(samples: samples)
    #expect(fromData == fromSamples)
    #expect(abs(fromData.peak - 0.5) < 1e-6)
}

@Test("Data whose length is not a multiple of 4 ignores the trailing bytes")
func decodesRaggedData() {
    var data = Data([0, 0, 0, 0])          // one clean float (0.0)
    data.append(contentsOf: [1, 2, 3])     // 3 dangling bytes
    let signal = PreflightSignalAnalyzer.analyze(float32LittleEndian: data)
    #expect(signal.level == .silent)       // only the one 0.0 sample counted
    #expect(signal.peak == 0)
}

// MARK: - Assessment

private func sig(_ level: ChannelSignalLevel, peak: Float) -> ChannelSignal {
    ChannelSignal(peak: peak, rms: peak, level: level)
}

@Test("Both channels healthy reads as ready")
func bothHealthy() {
    let report = PreflightAssessment.evaluate(
        microphone: sig(.ok, peak: 0.4),
        system: sig(.ok, peak: 0.3)
    )
    #expect(report.microphone.isCapturing)
    #expect(report.system.isCapturing)
    #expect(report.bothCapturing)
    #expect(report.microphone.note == nil)
    #expect(report.system.note == nil)
    #expect(report.isReady)
}

@Test("A silent microphone is a firm problem with guidance")
func silentMic() {
    let report = PreflightAssessment.evaluate(
        microphone: sig(.silent, peak: 0),
        system: sig(.ok, peak: 0.3)
    )
    #expect(!report.microphone.isCapturing)
    #expect(!report.bothCapturing)
    #expect(!report.isReady)
    #expect(report.microphone.note?.isEmpty == false)
    // Mic guidance mentions the input / mute, not "something playing".
    #expect(report.microphone.note?.lowercased().contains("mic") == true
        || report.microphone.note?.lowercased().contains("input") == true)
}

@Test("Silent system audio is informational, not a hard failure")
func silentSystem() {
    let report = PreflightAssessment.evaluate(
        microphone: sig(.ok, peak: 0.4),
        system: sig(.silent, peak: 0)
    )
    #expect(!report.system.isCapturing)
    #expect(report.system.note?.isEmpty == false)
    // The mic is fine, so this is treated as "ready with a note", not blocked.
    #expect(report.isReady)
}

@Test("A faint channel is capturing but carries a note")
func faintChannel() {
    let report = PreflightAssessment.evaluate(
        microphone: sig(.faint, peak: 0.03),
        system: sig(.ok, peak: 0.3)
    )
    #expect(report.microphone.isCapturing)
    #expect(report.microphone.note?.isEmpty == false)
    #expect(report.isReady)
}

@Test("A hot channel warns about clipping")
func hotChannel() {
    let report = PreflightAssessment.evaluate(
        microphone: sig(.hot, peak: 0.99),
        system: sig(.ok, peak: 0.3)
    )
    #expect(report.microphone.isCapturing)
    #expect(report.microphone.note?.lowercased().contains("loud") == true
        || report.microphone.note?.lowercased().contains("clip") == true
        || report.microphone.note?.lowercased().contains("distort") == true)
}

@Test("The headline reflects the worst channel state")
func headlineReflectsState() {
    let ready = PreflightAssessment.evaluate(microphone: sig(.ok, peak: 0.4), system: sig(.ok, peak: 0.3))
    let micDead = PreflightAssessment.evaluate(microphone: sig(.silent, peak: 0), system: sig(.ok, peak: 0.3))
    #expect(ready.headline != micDead.headline)
    #expect(!ready.headline.isEmpty)
    #expect(!micDead.headline.isEmpty)
}

@Test("A transient-only microphone gets a headline that agrees with its note, not a false 'no audio'")
func transientMicHeadlineAgreesWithNote() {
    // Big peak over a near-silent RMS → a lone click/tap (crest factor 50 > 20), not sustained.
    let mic = ChannelSignal(peak: 0.5, rms: 0.01, level: .ok)
    let system = ChannelSignal(peak: 0, rms: 0, level: .silent)

    let report = PreflightAssessment.evaluate(microphone: mic, system: system)

    #expect(!report.isReady) // a click is not speech — readiness is unchanged
    #expect(!report.headline.contains("No microphone audio was captured"))
    #expect(report.microphone.note?.contains("brief sound") == true)
    // The headline agrees with the note rather than contradicting it.
    #expect(report.headline.lowercased().contains("brief"))
}
