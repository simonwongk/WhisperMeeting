import Foundation

/// Why a dictation capture ended without the user releasing the key (F357).
///
/// One case today, and it is an enum rather than a bare callback because the *reason* is what the
/// user has to be told: "the audio device changed" and "the microphone was taken by another app"
/// call for different sentences and different next actions, and a `() -> Void` would have to be
/// widened at the first of those.
public enum DictationCaptureInterruption: Sendable, Equatable {
    /// The audio hardware's sample rate or channel count changed. `AVAudioEngine.h` documents that
    /// the engine **stops itself** when its I/O unit observes this, so by the time anyone hears
    /// about it the capture is already over — there is nothing to cancel, only something to say.
    case deviceConfigurationChanged

    /// What the person sees. Ends by telling them the recording is theirs to retry, because the
    /// failure is silent otherwise: the tap simply stops delivering.
    public var message: String {
        switch self {
        case .deviceConfigurationChanged:
            return "The audio device changed, so dictation stopped. Press the key again to start over."
        }
    }
}
