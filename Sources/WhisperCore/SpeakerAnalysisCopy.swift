import Foundation

/// Why the "Analyze Speaker Turns…" entry cannot run right now. One case per reason a person could
/// act on differently, because a single greyed-out row with one generic sentence is the thing this
/// menu's footnote convention exists to prevent (F220).
public enum SpeakerAnalysisUnavailability: String, Sendable, Equatable, CaseIterable {
    /// This meeting can never be analyzed as it stands: it is not a completed WhisperMeet recording.
    case unsupportedRecording
    /// The transcript has no timings for turns to be reconciled against.
    case noTimestamps
    /// The library is open read-only, so a result could not be saved even if it were computed.
    case libraryReadOnly
    /// The model has not been downloaded yet.
    case modelNotInstalled
    /// The model is downloading right now.
    case installing
    /// An analysis is already running, here or on another meeting.
    case analyzing
    /// A transcription, another engine pass, or dictation is using this Mac.
    case busy
}

/// The user-facing words for optional local speaker analysis: the menu entry, the disclosure shown
/// before a run, the Settings install row, and the reason the entry is greyed out (F220).
///
/// These are values rather than literals inside a SwiftUI body because the `WhisperMeet` target has
/// no view-render harness and will not get one — copy left in a `.alert(…)` is copy no test can
/// read. And this copy IS the feature's contract: the analysis stays on this Mac, the labels are
/// guesses about voices, similar-sounding voices are sometimes merged into a single label, and no
/// string here ever claims a person was recognized (`AccessibilityPhrase.swift:4`, and the PRD's
/// "never identify a person" rule). `SpeakerAnalysisCopyTests` pins each of those clauses.
public enum SpeakerAnalysisCopy {
    /// The Improve-menu entry. A trailing ellipsis because it opens the disclosure first.
    public static let menuItemTitle = "Analyze Speaker Turns…"

    public static let disclosureTitle = "Analyze speaker turns?"

    /// The inverse of the Claude confirmation, which warns that content leaves this Mac. This one
    /// promises it does not — and then spends its second paragraph being honest about what the
    /// result is worth, because a reassurance without the limitation reads as a claim of fact.
    ///
    /// The merged-voices sentence is not hedging: on the F217 corpus this runtime collapsed genuine
    /// two-person conversations into one voice, so it is a measured weakness stated up front. A
    /// person told this reads a wrong label as a known limit; a person not told reads it as who
    /// spoke.
    public static let disclosureMessage = """
    WhisperMeet will look for speaker turns using a model on this Mac. Nothing is uploaded, and your \
    recording, transcript, and notes are not changed.

    It marks parts of the transcript with anonymous labels such as “Speaker 1”. It does not identify \
    people, and the labels are guesses that can be wrong: voices that sound alike are sometimes \
    merged into a single label, so one label can cover two people. You can rename a label for this \
    meeting, clear the labels, or analyze again at any time.
    """

    /// Shown while the installer runs. The size is the real pinned payload, so a stalled download is
    /// measurable against something rather than against "a while".
    public static let installProgressLabel = "Installing about 21.6 MB of model files…"

    /// The Settings row's disclosure. Names the publisher, the real size, where the files land, and
    /// the one-directional traffic: model files come down, nothing about a meeting goes up. The size
    /// is the manifest's 21,599,417 B (`Scripts/setup-speaker-diarization.sh`,
    /// `docs/DIARIZATION_RUNTIME_DECISION.md` §1) — rounding it down would be a different promise.
    public static let installDescription = """
    Downloads about 21.6 MB of speaker-analysis models published by FluidInference on Hugging Face \
    into Runtime/Diarization inside WhisperMeet's application-support folder, checking every file \
    against a pinned checksum. Only model files are downloaded; meeting content — your recordings, \
    transcripts, and notes — is never uploaded. Analysis itself runs entirely on this Mac.
    """

    /// Same constraint as Qwen3-ASR and on-device summaries, and said the same way: what is missing,
    /// and what is unaffected.
    public static let appleSiliconOnly =
        "Speaker analysis requires an Apple-silicon Mac. Everything else in WhisperMeet is unchanged on Intel Macs."

    /// The plain-language reason under the menu's divider. Every sentence says what the person can do
    /// next, or that nothing was lost — never just "unavailable".
    public static func footnote(for reason: SpeakerAnalysisUnavailability) -> String {
        switch reason {
        case .unsupportedRecording:
            return "Speaker analysis needs a completed recording made in WhisperMeet. Imported and downloaded audio is not supported yet."
        case .noTimestamps:
            return "This transcript has no timestamps to analyze against, so there is nothing to label. The transcript itself is unchanged."
        case .libraryReadOnly:
            return "Your meeting library is open in read-only mode, so a new analysis could not be saved. Nothing about this meeting is at risk."
        case .modelNotInstalled:
            return "Speaker analysis needs its model. Install it in Settings under Local recognition — about 21.6 MB, downloaded once."
        case .installing:
            return "The speaker-analysis model is still downloading. This becomes available when it finishes."
        case .analyzing:
            return "Speaker analysis is already running. Only one meeting is analyzed at a time."
        case .busy:
            return "This Mac is busy with a transcription, another engine, or Quick Dictation. Speaker analysis can start once that finishes."
        }
    }
}
