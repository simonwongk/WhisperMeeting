import Foundation

/// Reconciles the *selected* transcription engine against the engines actually installed (F262).
///
/// Before this existed, `AppModel` decoded a missing `localWhisperModel` preference to
/// `.whisperLarge` and then asked `isRuntimeInstalled`, which is false forever on a Mac that has
/// only Qwen. Nothing closed the gap — `refreshRuntime()` rewrote booleans and `installQwenASR()`
/// never touched the selection — so a user who installed only Qwen recorded a meeting and was told
/// to "install the selected transcription model", with no hint that the fix was a picker in
/// Settings. This type is the single place that decides both halves of that problem.
///
/// The two halves are deliberately different, and the distinction is the point:
///
/// * **No stored preference is not a choice.** Picking an installed engine for a user who has never
///   opened the picker overrides nothing, so `initialSelection` does exactly that.
/// * **A stored preference IS a choice.** It is preserved even when that engine is missing, because
///   `AppModel`'s `didSet` persists the selection — silently switching would overwrite the user's
///   decision on disk, not merely for this launch. The refusal from `unavailableMessage` names the
///   engine that is installed instead, and the user stays in control of the switch.
///
/// Pure and framework-free so both rules are testable without a runtime, a Mac, or a UI.
public enum TranscriptionEngineAvailability {

    /// The engine to select at launch.
    ///
    /// `isQwenSupported` is passed in rather than read from `isSupportedOnCurrentMac`, which is a
    /// compile-time `#if arch(arm64)` check — injecting it is what lets a test cover the non-arm64
    /// case at all.
    public static func initialSelection(
        stored: MeetingTranscriptionEngine?,
        isWhisperInstalled: Bool,
        isQwenInstalled: Bool,
        isQwenSupported: Bool
    ) -> MeetingTranscriptionEngine {
        if let stored, isSupported(stored, isQwenSupported: isQwenSupported) {
            return stored
        }
        // No usable stored choice, so nothing is being overridden. Prefer an engine that can
        // actually run, keeping Whisper Large first because the spec and the Settings copy both
        // call it the default and Qwen opt-in.
        if isWhisperInstalled { return .whisperLarge }
        if isQwenInstalled, isQwenSupported { return .qwenBalanced }
        return .whisperLarge
    }

    /// A plain-language refusal when `selected` is not installed, or nil when it is.
    ///
    /// When another engine *is* installed the message names both sides of the mismatch and points at
    /// the picker, because the failure a user hits is "I installed a model and it still says install
    /// a model". When nothing is installed it offers no alternative, because there isn't one.
    public static func unavailableMessage(
        selected: MeetingTranscriptionEngine,
        isWhisperInstalled: Bool,
        isQwenInstalled: Bool
    ) -> String? {
        let selectedIsInstalled = selected == .qwenBalanced ? isQwenInstalled : isWhisperInstalled
        guard !selectedIsInstalled else { return nil }

        let alternative: MeetingTranscriptionEngine? = selected == .qwenBalanced
            ? (isWhisperInstalled ? .whisperLarge : nil)
            : (isQwenInstalled ? .qwenBalanced : nil)

        guard let alternative else {
            return """
            No transcription model is installed yet, so this recording is saved but not transcribed. \
            Open Settings ▸ Transcription to install one, then choose Transcribe.
            """
        }
        return """
        \(selected.shortDisplayName) is selected but not installed, and \
        \(alternative.shortDisplayName) is. The recording is saved. Open Settings ▸ Transcription, \
        choose \(alternative.shortDisplayName) as the model, then choose Transcribe — or install \
        \(selected.shortDisplayName) to keep using it.
        """
    }

    private static func isSupported(
        _ engine: MeetingTranscriptionEngine,
        isQwenSupported: Bool
    ) -> Bool {
        engine == .qwenBalanced ? isQwenSupported : true
    }
}
