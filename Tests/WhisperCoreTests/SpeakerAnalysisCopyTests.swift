import Foundation
import Testing
@testable import WhisperCore

// F220 — the words on the analyze entry point, the disclosure and the install row ARE the feature's
// privacy and honesty contract, so they are pinned here rather than left as literals inside a SwiftUI
// body no harness can render. This file is genuinely red without the fix: `SpeakerAnalysisCopy` and
// `SpeakerAnalysisUnavailability` do not exist, so it does not compile against the current tree.
//
// Each test pins one clause that a reviewer could otherwise soften without noticing: the analysis
// stays on this Mac, the labels are guesses, voices that sound alike can be merged into ONE label
// (the measured weakness of this runtime, not a hypothetical), no string ever claims a person was
// recognized, and the install row states the real download size and what is — and is not — sent.

/// Every user-visible string this type owns, so the audits below cannot pass by forgetting one.
private func allCopy() -> [String] {
    [
        SpeakerAnalysisCopy.menuItemTitle,
        SpeakerAnalysisCopy.disclosureTitle,
        SpeakerAnalysisCopy.disclosureMessage,
        SpeakerAnalysisCopy.installProgressLabel,
        SpeakerAnalysisCopy.installDescription,
        SpeakerAnalysisCopy.appleSiliconOnly
    ] + SpeakerAnalysisUnavailability.allCases.map(SpeakerAnalysisCopy.footnote(for:))
}

@Test("The disclosure says the analysis stays on this Mac and changes nothing (F220)")
func speakerAnalysisDisclosureStatesTheLocalBoundary() {
    let message = SpeakerAnalysisCopy.disclosureMessage
    #expect(message.contains("on this Mac"))
    #expect(message.lowercased().contains("nothing is uploaded"))
    // The Claude confirmation's inverse: that one warns content leaves the Mac, this one promises the
    // recording and transcript survive untouched.
    #expect(message.lowercased().contains("not changed"))
    #expect(SpeakerAnalysisCopy.disclosureTitle == "Analyze speaker turns?")
}

@Test("The disclosure states plainly that similar voices can be merged into one label (F220)")
func speakerAnalysisDisclosureNamesTheMergedVoiceWeakness() {
    let message = SpeakerAnalysisCopy.disclosureMessage.lowercased()
    #expect(message.contains("sound alike") || message.contains("sound similar"))
    #expect(message.contains("merged into a single label") || message.contains("merged into one label"))
    // And that the labels are guesses at all — the merge sentence is useless beside a claim of fact.
    #expect(message.contains("can be wrong") || message.contains("guesses"))
}

@Test("No speaker-analysis string claims a person was recognized, identified, or verified (F220)")
func speakerAnalysisCopyNeverClaimsIdentity() {
    // `AccessibilityPhrase.swift:4` and the PRD bind this: a label is a guess about voices, never a
    // claim about a person. "does not identify people" is a denial and is required below.
    let forbidden = ["recognized", "recognised", "recognizes", "identified", "identifies",
                     "verified", "voiceprint", "enrolled", "who spoke", "whose voice"]
    for text in allCopy() {
        let lowered = text.lowercased()
        for word in forbidden {
            #expect(!lowered.contains(word), "speaker-analysis copy claims identity with “\(word)”: \(text)")
        }
    }
    #expect(SpeakerAnalysisCopy.disclosureMessage.contains("does not identify people"))
}

@Test("The install row states the real size, the source, the location, and that no meeting content is sent (F220)")
func speakerAnalysisInstallCopyStatesSizeAndWhatLeavesTheMac() {
    let description = SpeakerAnalysisCopy.installDescription
    // The pinned payload is 21,599,417 B — Scripts/setup-speaker-diarization.sh and
    // docs/DIARIZATION_RUNTIME_DECISION.md §1. A rounded-down "20 MB" would be a different promise.
    #expect(description.contains("21.6 MB"))
    #expect(SpeakerAnalysisCopy.installProgressLabel.contains("21.6 MB"))
    #expect(description.contains("FluidInference"))
    #expect(description.contains("Runtime/Diarization"))
    // The whole point of the row: what travels is model files, in one direction.
    #expect(description.lowercased().contains("only model files"))
    #expect(description.lowercased().contains("never"))
    #expect(description.lowercased().contains("meeting"))
}

@Test("Every reason the analyze entry is unavailable has its own plain-language footnote (F220)")
func speakerAnalysisFootnoteNamesEveryReason() {
    var seen: Set<String> = []
    for reason in SpeakerAnalysisUnavailability.allCases {
        let footnote = SpeakerAnalysisCopy.footnote(for: reason)
        #expect(!footnote.isEmpty)
        // A shared sentence is a mystery-gray row with extra steps: each reason says its own thing.
        #expect(seen.insert(footnote).inserted, "two reasons share one footnote: \(footnote)")
    }
    #expect(SpeakerAnalysisCopy.footnote(for: .modelNotInstalled).contains("Settings"))
    #expect(SpeakerAnalysisCopy.footnote(for: .noTimestamps).contains("unchanged"))
    #expect(SpeakerAnalysisCopy.footnote(for: .unsupportedRecording).contains("WhisperMeet"))
}
