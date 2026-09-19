import Foundation

/// Why a recording had to be recovered, as a fact the index owns (F305).
///
/// F274 put this in prose: it appended "The recording stopped because this Mac went to sleep." to
/// the `errorMessage` that already explained the recovery, and said so deliberately — *"No new field
/// for it: the message that already explains the recovery says which interruption it was."*
///
/// But `performTranscription` clears `errorMessage` on start and on success, so transcribing a
/// recovered meeting kept **that** it was recovered and erased **why**. That is F273's defect for a
/// second fact, decided one commit after F273 ruled it out — which is the useful part: the rule was
/// written, agreed, and then not applied to the next fact that came along.
///
/// A `String` raw value stored on `MeetingRecord`, not the enum, for F250's reason one file over: a
/// value a newer build writes must decode and be ignored rather than make the index unreadable. An
/// unrecognised one renders nothing, because a raw identifier shown to a user is worse than silence.
public enum RecoveryInterruption: String, Sendable, Equatable, CaseIterable {
    /// The Mac slept mid-recording. `RecordingSession.interruptedBySleepAt` records the moment
    /// beside the audio (F253); this is the same fact reaching the index, where it survives.
    case systemSleep

    /// The sentence shown beside the provenance one. Present tense about the recording, not about
    /// the transcript, because it is true of the audio whatever happens to the text.
    public var caveat: String {
        switch self {
        case .systemSleep:
            // "or was about to": a docked lid close posts `willSleep` without the Mac ever
            // sleeping (the user's 2026-09-19 rerun), and the recording still stops and saves.
            return "The recording stopped because this Mac went to sleep, or was about to — closing the lid does this. Everything captured before then was kept."
        }
    }
}
