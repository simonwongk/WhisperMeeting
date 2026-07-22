import Foundation

/// How much real signal a single captured channel carried, classified by peak amplitude.
public enum ChannelSignalLevel: String, Sendable, Equatable {
    case silent
    case faint
    case ok
    case hot
}

/// The measured signal of one captured channel (peak/rms in `0...~1`).
public struct ChannelSignal: Sendable, Equatable {
    public let peak: Float
    public let rms: Float
    public let level: ChannelSignalLevel

    public init(peak: Float, rms: Float, level: ChannelSignalLevel) {
        self.peak = peak
        self.rms = rms
        self.level = level
    }
}

/// Pure analysis of a captured `.f32` track (48 kHz Float32 samples in `-1...1`).
public enum PreflightSignalAnalyzer {
    // Peak thresholds (documented in docs/PREFLIGHT_TEST.md).
    static let silentCeiling: Float = 0.01   // below this → silent
    static let faintCeiling: Float = 0.05    // below this → faint
    static let hotFloor: Float = 0.98        // at/above this → hot

    public static func analyze(samples: [Float]) -> ChannelSignal {
        guard !samples.isEmpty else {
            return ChannelSignal(peak: 0, rms: 0, level: .silent)
        }
        var peak: Float = 0
        var sumSquares: Double = 0
        for sample in samples {
            let magnitude = abs(sample)
            if magnitude > peak { peak = magnitude }
            sumSquares += Double(sample) * Double(sample)
        }
        let rms = Float((sumSquares / Double(samples.count)).squareRoot())
        return ChannelSignal(peak: peak, rms: rms, level: level(forPeak: peak))
    }

    /// Decodes raw little-endian Float32 bytes (as written to a `.f32` track) and analyzes them.
    /// Trailing bytes that don't complete a 4-byte float are ignored.
    public static func analyze(float32LittleEndian data: Data) -> ChannelSignal {
        let count = data.count / 4
        guard count > 0 else {
            return ChannelSignal(peak: 0, rms: 0, level: .silent)
        }
        var samples = [Float](repeating: 0, count: count)
        data.withUnsafeBytes { raw in
            for i in 0..<count {
                var bits: UInt32 = 0
                withUnsafeMutableBytes(of: &bits) { dst in
                    dst.copyBytes(from: UnsafeRawBufferPointer(rebasing: raw[(i * 4)..<(i * 4 + 4)]))
                }
                samples[i] = Float(bitPattern: UInt32(littleEndian: bits))
            }
        }
        return analyze(samples: samples)
    }

    static func level(forPeak peak: Float) -> ChannelSignalLevel {
        if peak >= hotFloor { return .hot }
        if peak < silentCeiling { return .silent }
        if peak < faintCeiling { return .faint }
        return .ok
    }
}

/// The verdict for one channel of a preflight test.
public struct PreflightChannelReport: Sendable, Equatable {
    public let signal: ChannelSignal
    /// Any level above `silent` means audio was captured.
    public let isCapturing: Bool
    /// Actionable guidance when the channel isn't ideal; `nil` when it's healthy.
    public let note: String?

    public init(signal: ChannelSignal, isCapturing: Bool, note: String?) {
        self.signal = signal
        self.isCapturing = isCapturing
        self.note = note
    }
}

/// The combined verdict of a preflight test.
public struct PreflightReport: Sendable, Equatable {
    public let microphone: PreflightChannelReport
    public let system: PreflightChannelReport
    public let headline: String
    /// Ready to record a meeting: the microphone is capturing. A silent *system* channel does not
    /// block readiness (it's only captured while another app is playing sound).
    public let isReady: Bool

    public var bothCapturing: Bool {
        microphone.isCapturing && system.isCapturing
    }

    public init(
        microphone: PreflightChannelReport,
        system: PreflightChannelReport,
        headline: String,
        isReady: Bool
    ) {
        self.microphone = microphone
        self.system = system
        self.headline = headline
        self.isReady = isReady
    }
}

/// Turns two measured channel signals into a human verdict. The two channels are judged differently
/// on purpose: a silent microphone is a real problem; silent system audio is usually just "nothing
/// was playing during the test".
public enum PreflightAssessment {
    public static func evaluate(microphone: ChannelSignal, system: ChannelSignal) -> PreflightReport {
        let mic = PreflightChannelReport(
            signal: microphone,
            isCapturing: microphone.level != .silent,
            note: micNote(microphone.level)
        )
        let sys = PreflightChannelReport(
            signal: system,
            isCapturing: system.level != .silent,
            note: systemNote(system.level)
        )

        let isReady = mic.isCapturing
        let headline: String
        if !mic.isCapturing {
            headline = "No microphone audio was captured — fix this before your meeting."
        } else if !sys.isCapturing {
            headline = "Your microphone is capturing. System audio was silent — see the note if you expected it."
        } else if mic.note != nil || sys.note != nil {
            headline = "Recording works, with a couple of things worth checking."
        } else {
            headline = "Both channels are capturing cleanly. You're ready to record."
        }

        return PreflightReport(microphone: mic, system: sys, headline: headline, isReady: isReady)
    }

    private static func micNote(_ level: ChannelSignalLevel) -> String? {
        switch level {
        case .silent:
            return "No microphone signal was detected. Check that the right input device is selected and that you aren't muted."
        case .faint:
            return "Microphone level is very low. Move closer or raise the input level."
        case .hot:
            return "Microphone level is very loud and may clip or distort. Lower it slightly."
        case .ok:
            return nil
        }
    }

    private static func systemNote(_ level: ChannelSignalLevel) -> String? {
        switch level {
        case .silent:
            return "No system audio was detected. System audio is only captured while another app is playing sound — make sure something was playing during the test."
        case .faint:
            return "System audio level is very low. Consider raising the playback volume."
        case .hot:
            return "System audio level is very loud and may clip. Lower the playback volume slightly."
        case .ok:
            return nil
        }
    }
}
