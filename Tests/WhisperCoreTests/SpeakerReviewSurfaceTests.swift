import Foundation
import Testing
@testable import WhisperCore

// F220 — the review surface's words and its per-state rules. Genuinely red against the current tree:
// `SpeakerReviewState`, `SpeakerAnalysisCopy.reviewHeadline/reviewDetail`, the legend and the
// rename/clear/rerun copy, and `SpeakerOverlay.labelsByIndex` do not exist, so this file does not
// compile.
//
// They are values rather than literals in a SwiftUI body because the `WhisperMeet` target has no
// view-render harness and will not get one (`AGENTS.md` "Wiring an unreachable core", layer 3): copy
// left inside an `.alert(…)` or a `.confirmationDialog(…)` is copy no test can read. And these
// particular words are the honest half of the feature — every state has to say what happened in
// plain language, the single-voice state has to not read like a failure, and nothing anywhere may
// claim a person was recognized (`AccessibilityPhrase.swift:4`).

private func allReviewCopy() -> [String] {
    SpeakerReviewState.allCases.flatMap {
        [SpeakerAnalysisCopy.reviewHeadline(for: $0), SpeakerAnalysisCopy.reviewDetail(for: $0)]
    } + [
        SpeakerAnalysisCopy.legendNotice,
        SpeakerAnalysisCopy.renameTitle,
        SpeakerAnalysisCopy.renameFieldLabel,
        SpeakerAnalysisCopy.renameMessage,
        SpeakerAnalysisCopy.clearTitle,
        SpeakerAnalysisCopy.clearMessage,
        SpeakerAnalysisCopy.clearConfirmButton,
        SpeakerAnalysisCopy.clearCancelButton,
        SpeakerAnalysisCopy.analyzeAgainTitle,
        SpeakerAnalysisCopy.analyzeAgainMessage
    ]
}

@Test("Every review state has its own non-empty headline and explanation (F220)")
func speakerReviewCopyCoversEveryStateDistinctly() {
    var headlines: Set<String> = []
    var details: Set<String> = []
    for state in SpeakerReviewState.allCases {
        let headline = SpeakerAnalysisCopy.reviewHeadline(for: state)
        let detail = SpeakerAnalysisCopy.reviewDetail(for: state)
        #expect(!headline.isEmpty, "\(state) has no headline")
        #expect(!detail.isEmpty, "\(state) has no explanation")
        // A shared sentence across two states is a mystery banner with extra steps.
        #expect(headlines.insert(headline).inserted, "two states share the headline “\(headline)”")
        #expect(details.insert(detail).inserted, "two states share the explanation “\(detail)”")
    }
}

@Test("No review-surface string claims a person was recognized, identified, or verified (F220)")
func speakerReviewCopyNeverClaimsIdentity() {
    // Same denylist as `speakerAnalysisCopyNeverClaimsIdentity`, including the un-negated forms: a
    // sentence promising the app "did not identify anyone" still prints the word.
    let forbidden = ["recognized", "recognised", "recognizes", "identified", "identifies",
                     "verified", "voiceprint", "enrolled", "who spoke", "whose voice"]
    for text in allReviewCopy() {
        let lowered = text.lowercased()
        for word in forbidden {
            #expect(!lowered.contains(word), "review copy claims identity with “\(word)”: \(text)")
        }
    }
}

@Test("The single-voice state is explained as a normal outcome, not as a failure (F220)")
func singleVoiceStateDoesNotReadLikeAnError() {
    let text = (SpeakerAnalysisCopy.reviewHeadline(for: .singleVoice) + " "
        + SpeakerAnalysisCopy.reviewDetail(for: .singleVoice)).lowercased()
    for word in ["error", "failed", "failure", "problem", "unable", "went wrong", "sorry"] {
        #expect(!text.contains(word), "the single-voice state reads like an error: “\(word)”")
    }
    #expect(text.contains("one voice"))
    // Both true causes are named, so a real monologue and a failed separation read the same calm way.
    #expect(text.contains("single speaker"))
    #expect(text.contains("sound alike") || text.contains("sound similar"))
    // Renaming the one cluster would attribute the other person's words to that name.
    #expect(!SpeakerReviewState.singleVoice.offersRename)
    #expect(SpeakerReviewState.singleVoice.offersClear)
    #expect(SpeakerReviewState.singleVoice.offersAnalyzeAgain)
}

@Test("The legend states that labels are inferred and that similar voices can be merged (F220)")
func legendStatesTheInferenceAndTheMergedVoiceWeakness() {
    let notice = SpeakerAnalysisCopy.legendNotice.lowercased()
    #expect(notice.contains("inferred"))
    #expect(notice.contains("sound alike") || notice.contains("sound similar"))
    #expect(notice.contains("merged into a single label") || notice.contains("merged into one label"))
    // The limitation is measured (F217 corpus), so it is stated here rather than left in the docs.
    #expect(SpeakerAnalysisCopy.legendNotice.contains("this Mac"))
}

@Test("Rename asks for the reader's own label, never for a name or for who spoke (F220)")
func renameCopyAsksForALabelRatherThanAnIdentity() {
    #expect(SpeakerAnalysisCopy.renameFieldLabel == "Your label")
    let message = SpeakerAnalysisCopy.renameMessage.lowercased()
    #expect(message.contains("this meeting"))
    // The alias never escapes into the canonical paths, and the alert has to say so.
    #expect(message.contains("transcript"))
    #expect(message.contains("export") || message.contains("summary"))
}

@Test("Clearing is confirmed with a destructive verb and a keep-them way out (F220)")
func clearCopyOffersAnExplicitWayOut() {
    #expect(SpeakerAnalysisCopy.clearCancelButton == "Keep labels")
    #expect(SpeakerAnalysisCopy.clearConfirmButton.lowercased().contains("clear"))
    let message = SpeakerAnalysisCopy.clearMessage.lowercased()
    // Throwing away labels is not throwing away the meeting, and the dialog says which is which.
    #expect(message.contains("recording"))
    #expect(message.contains("transcript"))
    #expect(message.contains("unchanged"))
}

@Test("Analyzing again says new labels are created and existing ones replaced (F220)")
func rerunCopySaysLabelsAreReplaced() {
    let message = SpeakerAnalysisCopy.analyzeAgainMessage.lowercased()
    #expect(message.contains("replace"))
    // Cluster ids permute between runs, so a typed label is deliberately not carried across.
    #expect(message.contains("not carried over") || message.contains("are not kept"))
    #expect(message.contains("new labels"))
}

@Test("Only a labeled result offers rename, and only a stored one offers clear or rerun (F220)")
func reviewStateGatesItsOwnActions() {
    #expect(!SpeakerReviewState.notAnalyzed.showsReviewBanner)
    for state in SpeakerReviewState.allCases where state != .notAnalyzed {
        #expect(state.showsReviewBanner, "\(state) would render nothing at all")
    }
    #expect(SpeakerReviewState.labeled.offersRename)
    for state in SpeakerReviewState.allCases where state != .labeled {
        #expect(!state.offersRename, "\(state) offers a rename with no shown cluster to rename")
    }
    // Analyzing has nothing stored yet; cancelling it is the only action.
    #expect(!SpeakerReviewState.analyzing.offersClear)
    #expect(!SpeakerReviewState.analyzing.offersAnalyzeAgain)
    #expect(!SpeakerReviewState.notAnalyzed.offersClear)
    for state in [SpeakerReviewState.unreadable, .stale, .noTurnsFound, .singleVoice,
                  .noConfidentLabels, .labeled] {
        #expect(state.offersClear, "\(state) has a stored file the user cannot remove")
        #expect(state.offersAnalyzeAgain, "\(state) cannot be re-run")
    }
}

@Test("Stale and unreadable both say the transcript survived and a rerun is the way out (F220)")
func recoverableStatesSayTheTranscriptIsSafe() {
    for state in [SpeakerReviewState.stale, .unreadable] {
        let detail = SpeakerAnalysisCopy.reviewDetail(for: state).lowercased()
        #expect(detail.contains("unchanged") || detail.contains("kept"),
                "\(state) does not say what survived")
        #expect(detail.contains("analyz"), "\(state) does not point at analyzing again")
    }
}

// MARK: - The precomputed row labels

private func row(_ index: Int, _ label: SpeakerOverlayLabel) -> SpeakerOverlayRow {
    SpeakerOverlayRow(segmentIndex: index, label: label)
}

@Test("Row labels are precomputed once into a segment-index map, text only (F220)")
func rowLabelsArePrecomputedForEveryLabeledSegment() {
    let rows = [
        row(0, .speaker(clusterID: 0)),
        row(1, .speaker(clusterID: 1)),
        row(2, .overlapping),
        row(3, .uncertain),
        row(4, .unlabeled)
    ]
    let labels = SpeakerOverlay.labelsByIndex(rows: rows, aliases: [1: "Nadia"])
    #expect(labels[0] == "Speaker 1")
    #expect(labels[1] == "Nadia")
    #expect(labels[2] == SpeakerOverlay.overlappingName)
    #expect(labels[3] == SpeakerOverlay.uncertainName)
    // An unlabeled row carries no entry at all: an empty chip would read as a fourth kind of speaker.
    #expect(labels[4] == nil)
    #expect(labels.count == 4)
}

@Test("A blank or whitespace alias falls back to the anonymous label rather than an empty chip (F220)")
func rowLabelsIgnoreABlankAlias() {
    let rows = [row(0, .speaker(clusterID: 0)), row(1, .speaker(clusterID: 1))]
    let labels = SpeakerOverlay.labelsByIndex(rows: rows, aliases: [0: "   ", 1: "Ada\nLovelace"])
    #expect(labels[0] == "Speaker 1")
    // An alias keeps interior newlines on disk; a chip is one line, so it is folded.
    #expect(labels[1] == "Ada Lovelace")
}

@Test("The anonymous label is one-based and matches the labeled export's spelling (F220)")
func rowLabelsUseTheExportersAnonymousName() {
    let labels = SpeakerOverlay.labelsByIndex(rows: [row(0, .speaker(clusterID: 4))], aliases: [:])
    #expect(labels[0] == TranscriptExporter.anonymousSpeakerName(clusterID: 4))
    #expect(labels[0] == "Speaker 5")
}
