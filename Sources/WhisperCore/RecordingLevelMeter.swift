import Foundation

/// Perceptual presentation values for the recording UI. Values are normalized to `0...1`, but
/// unlike raw PCM amplitudes they use a dBFS scale so ordinary speech occupies a useful portion of
/// the meter instead of bunching up near zero.
public struct RecordingMeterSnapshot: Sendable, Equatable {
    public let microphone: Float
    public let systemAudio: Float
    public let combined: Float
    public let isSpeaking: Bool
    public let microphoneActive: Bool
    public let systemAudioActive: Bool

    public init(
        microphone: Float,
        systemAudio: Float,
        combined: Float,
        isSpeaking: Bool,
        microphoneActive: Bool,
        systemAudioActive: Bool
    ) {
        self.microphone = microphone
        self.systemAudio = systemAudio
        self.combined = combined
        self.isSpeaking = isSpeaking
        self.microphoneActive = microphoneActive
        self.systemAudioActive = systemAudioActive
    }

    public static let silent = RecordingMeterSnapshot(
        microphone: 0,
        systemAudio: 0,
        combined: 0,
        isSpeaking: false,
        microphoneActive: false,
        systemAudioActive: false
    )
}

/// Converts raw levels from the saved audio path into stable UI values. The module owns channel
/// freshness, perceptual dBFS calibration, attack/release smoothing, and speaking hysteresis so all
/// meter call sites use one consistent interpretation.
public struct RecordingLevelMeter: Sendable {
    private struct ChannelState: Sendable {
        var level = RecordingAudioLevel.silent
        var receivedAt: TimeInterval?
        var displayed: Float = 0
        var active = false
    }

    private var microphone = ChannelState()
    private var systemAudio = ChannelState()
    private var lastSnapshotAt: TimeInterval?

    private let silenceAfter: TimeInterval
    private let noiseFloorDB: Float
    private let attackSeconds: TimeInterval
    private let releaseSeconds: TimeInterval

    public init(
        silenceAfter: TimeInterval = 0.35,
        noiseFloorDB: Float = -60,
        attackSeconds: TimeInterval = 0.05,
        releaseSeconds: TimeInterval = 0.25
    ) {
        self.silenceAfter = silenceAfter
        self.noiseFloorDB = min(-1, noiseFloorDB)
        self.attackSeconds = max(0.001, attackSeconds)
        self.releaseSeconds = max(0.001, releaseSeconds)
    }

    public mutating func receive(
        _ channel: RecordingChannel,
        level: RecordingAudioLevel,
        at time: TimeInterval
    ) {
        switch channel {
        case .microphone:
            microphone.level = level
            microphone.receivedAt = time
        case .systemAudio:
            systemAudio.level = level
            systemAudio.receivedAt = time
        }
    }

    public mutating func snapshot(at time: TimeInterval) -> RecordingMeterSnapshot {
        let elapsed = lastSnapshotAt.map { max(0, time - $0) }
        microphone = updatedDisplay(microphone, at: time, elapsed: elapsed)
        systemAudio = updatedDisplay(systemAudio, at: time, elapsed: elapsed)
        lastSnapshotAt = time

        let combined = max(microphone.displayed, systemAudio.displayed)
        microphone.active = isActive(
            microphone.active,
            evidence: speakingEvidence(for: freshLevel(microphone, at: time))
        )
        systemAudio.active = isActive(
            systemAudio.active,
            evidence: speakingEvidence(for: freshLevel(systemAudio, at: time))
        )
        let speaking = microphone.active || systemAudio.active

        return RecordingMeterSnapshot(
            microphone: microphone.displayed,
            systemAudio: systemAudio.displayed,
            combined: combined,
            isSpeaking: speaking,
            microphoneActive: microphone.active,
            systemAudioActive: systemAudio.active
        )
    }

    private func isActive(_ wasActive: Bool, evidence: Float) -> Bool {
        evidence >= (wasActive ? 0.16 : 0.28)
    }

    private func updatedDisplay(
        _ channel: ChannelState,
        at time: TimeInterval,
        elapsed: TimeInterval?
    ) -> ChannelState {
        var channel = channel
        let target = displayedLevel(for: freshLevel(channel, at: time))
        guard let elapsed else {
            channel.displayed = target
            return channel
        }
        let timeConstant = target > channel.displayed ? attackSeconds : releaseSeconds
        let alpha = Float(1 - exp(-elapsed / timeConstant))
        channel.displayed += (target - channel.displayed) * alpha
        if channel.displayed < 0.001 { channel.displayed = 0 }
        return channel
    }

    private func freshLevel(_ channel: ChannelState, at time: TimeInterval) -> RecordingAudioLevel {
        guard let receivedAt = channel.receivedAt,
              time - receivedAt <= silenceAfter else {
            return .silent
        }
        return channel.level
    }

    private func displayedLevel(for level: RecordingAudioLevel) -> Float {
        calibrated(max(level.rms, level.peak * 0.35))
    }

    private func speakingEvidence(for level: RecordingAudioLevel) -> Float {
        max(calibrated(level.rms), calibrated(level.peak * 0.2))
    }

    private func calibrated(_ amplitude: Float) -> Float {
        guard amplitude > 0 else { return 0 }
        let decibels = 20 * log10(max(amplitude, 0.000_001))
        return min(1, max(0, (decibels - noiseFloorDB) / -noiseFloorDB))
    }
}
