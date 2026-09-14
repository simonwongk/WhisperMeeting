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

    // MARK: - The review surface (F220)

    /// The sentence that sits beside the labels, every time they are shown.
    ///
    /// It is not a disclaimer to be read once and dismissed: it is the difference between a reader
    /// treating a label as a fact about who spoke and treating it as a grouping of similar audio. The
    /// merged-voices clause is the runtime's measured weakness on the F217 corpus, not a hypothetical,
    /// and it is stated here rather than left in documentation nobody opens.
    ///
    /// It says "inferred" and describes what the labels ARE, never what they are not: a sentence like
    /// "these are not identified speakers" still prints the word, which is exactly what
    /// `AccessibilityPhrase.swift:4` and `speakerAnalysisCopyNeverClaimsIdentity` refuse.
    public static let legendNotice = """
    These labels were inferred on this Mac by local analysis of the audio. They group similar-sounding \
    voices inside this one meeting — they are labels for voices, not for people, and they can be \
    wrong: voices that sound alike are sometimes merged into a single label. Rename a label to \
    whatever is useful to you; your labels stay with this meeting and never appear in the transcript, \
    an ordinary export, or a summary.
    """

    /// The banner's first line for one review state.
    public static func reviewHeadline(for state: SpeakerReviewState) -> String {
        switch state {
        case .notAnalyzed: return "No speaker analysis yet"
        case .analyzing: return "Analyzing speaker turns…"
        case .unreadable: return "Speaker labels could not be read"
        case .stale: return "Speaker labels are out of date"
        case .noTurnsFound: return "No speaker turns were found"
        case .singleVoice: return "Only one voice could be told apart"
        case .noConfidentLabels: return "No line was clearly enough one voice to label"
        case .labeled: return "Speaker labels"
        }
    }

    /// The banner's explanation for one review state. Every one of them says what happened in plain
    /// words and what survived it, because five of these states end with an empty transcript and
    /// "nothing appeared" is the single most alarming way for a privacy-sensitive feature to fail.
    public static func reviewDetail(for state: SpeakerReviewState) -> String {
        switch state {
        case .notAnalyzed:
            return "This meeting has not been analyzed for speaker turns. Running it changes nothing about your recording or transcript."
        case .analyzing:
            return "This runs on this Mac and reads only the recording. You can cancel at any time — nothing is saved until it finishes."
        case .unreadable:
            return "This meeting's speaker-analysis file could not be read, so no labels are shown. Your recording and transcript are unchanged. Analyzing again writes a fresh result."
        case .stale:
            return "The transcript's timings changed after this analysis ran, so its labels no longer line up with these lines and are hidden. The saved result is kept. Analyzing again matches the current transcript."
        case .noTurnsFound:
            return "The analysis finished without finding speech it could separate, so there is nothing to label. Your recording and transcript are unchanged."
        case .singleVoice:
            // The plan's wording, near-verbatim: not an error, and both true causes named so a real
            // monologue and a failed separation read the same calm way.
            return "Only one voice could be told apart in this recording, so no speaker labels are shown. This happens with a single speaker, and also when two people's voices sound alike."
        case .noConfidentLabels:
            return "More than one voice was told apart, but no line belonged clearly enough to one of them to label, so none are shown. This happens when people talk over each other or take very short turns."
        case .labeled:
            return "Labels group similar-sounding voices in this meeting only. They are inferred from the audio and can be wrong — voices that sound alike are sometimes merged into a single label."
        }
    }

    /// The inline-TextField rename alert. "Your label" rather than "Name" or "Who is this?": the field
    /// is asking what the reader wants this voice called, not who it was.
    public static let renameTitle = "Rename this label"
    public static let renameFieldLabel = "Your label"
    public static let renameSaveButton = "Save"
    public static let renameMessage = """
    This label applies to this meeting only. It is stored with the analysis — never written into your \
    transcript, and never included in an ordinary export, a summary, or anything sent to Claude. Leave \
    it empty to go back to the anonymous label.
    """

    /// The destructive-clear confirmation. The cancel verb says what keeping costs (nothing), and the
    /// message separates what is deleted from what is not.
    public static let clearTitle = "Clear speaker labels for this meeting?"
    public static let clearConfirmButton = "Clear Labels"
    public static let clearCancelButton = "Keep labels"
    public static let clearMessage = """
    This deletes the analysis and any labels you typed for this meeting. Your recording, transcript, \
    and notes are unchanged, and you can analyze again later.
    """

    /// The rerun confirmation. A rerun is not a refresh: clusters are formed afresh, so a label typed
    /// against the old run could land on a different voice — which is why aliases are deliberately
    /// dropped rather than carried across (`AppModel.performSpeakerDiarization`).
    public static let analyzeAgainTitle = "Analyze again?"
    public static let analyzeAgainButton = "Analyze Again"
    public static let analyzeAgainMessage = """
    This runs the model over the recording again and replaces the current result. New labels are \
    created, and labels you typed are not carried over: voices are grouped afresh each run, so an old \
    label could end up on a different voice. Your recording and transcript are unchanged.
    """

    /// The in-flight banner's stop verb, and the label read out beside the progress bar.
    public static let cancelAnalysisButton = "Cancel"

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
