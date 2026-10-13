import Foundation

/// The state chip beside one channel's meter on the record screen: a few words and a tone (F970).
///
/// Pure, so the choice is tested: `RecordMeetingView`'s `RecordingChannelHealthRow` cannot be
/// rendered in this target (F174), and the rule lived in its `private var state`, where F931 broke
/// it unseen. Capture warnings take precedence over the meter's activity, because the meter is fed
/// only by a buffer that reached the disk: a track whose buffers arrive and fail to save reads as
/// silent to the meter while the user is speaking.
public struct RecordingChannelRowState: Sendable, Equatable {
    public enum Tone: Sendable, Equatable {
        /// Audio is being lost on this channel right now.
        case lost
        /// Worth a look; nothing is lost.
        case caution
        /// Audio is arriving and being saved.
        case receiving
        /// Nothing is arriving, and that is normal or at least not a failure.
        case quiet
    }

    public let text: String
    public let tone: Tone

    public init(text: String, tone: Tone) {
        self.text = text
        self.tone = tone
    }

    /// - Parameter isActive: the level meter's activity for this channel
    ///   (`RecordingMeterSnapshot.microphoneActive` / `.systemAudioActive`), consulted last.
    public static func make(
        channel: RecordingChannel,
        health: RecordingHealthSnapshot,
        isActive: Bool
    ) -> RecordingChannelRowState {
        // Before the channel's own cautions and its activity (F970): a track whose buffers arrive
        // and fail to save is not stale (F931), so nothing else here names its loss, and the meter
        // has not heard a buffer from it since the failures began. On the system row it also
        // precedes "Not detected yet", which the monitor still raises for a track whose first
        // buffer failed, since detection too is counted from a buffer that was saved.
        if health.tracksWithFailingWrites.contains(channel) {
            return RecordingChannelRowState(text: "Not being saved", tone: .lost)
        }
        switch channel {
        case .microphone:
            if health.warnings.contains(.microphoneCaptureStopped) {
                return RecordingChannelRowState(text: "No audio for 3s+", tone: .lost)
            }
            if health.warnings.contains(.microphoneClipping) {
                return RecordingChannelRowState(text: "Too loud", tone: .caution)
            }
            return isActive
                ? RecordingChannelRowState(text: "Receiving audio", tone: .receiving)
                : RecordingChannelRowState(text: "Silent", tone: .quiet)
        case .systemAudio:
            if health.warnings.contains(.systemAudioCaptureStopped) {
                return RecordingChannelRowState(text: "No audio for 3s+", tone: .lost)
            }
            if health.warnings.contains(.systemAudioNotDetected) {
                return RecordingChannelRowState(text: "Not detected yet", tone: .caution)
            }
            if health.warnings.contains(.systemAudioClipping) {
                return RecordingChannelRowState(text: "Too loud", tone: .caution)
            }
            return isActive
                ? RecordingChannelRowState(text: "Receiving audio", tone: .receiving)
                : RecordingChannelRowState(text: "Silent (normal until others speak)", tone: .quiet)
        }
    }
}
