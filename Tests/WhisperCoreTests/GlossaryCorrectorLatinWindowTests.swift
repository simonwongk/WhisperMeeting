import Foundation
import Testing
@testable import WhisperCore

// Correct Toward Vocabulary's Latin windows are whitespace-separated words (F65, kept by F536).
// F819: a window's phrase kept the punctuation attached to its words, so applying "Kestrol," →
// "Kestrel" deleted the comma. F820: a multi-word term already present in the segment was only
// recognised when it was a single token, so "Priya Raman said" was proposed as "Priya Raman".

private func seg(_ text: String) -> TranscriptSegment {
    TranscriptSegment(speaker: nil, start: 0, end: 1, text: text)
}

@Test("A Latin proposal leaves the punctuation around the misheard word where it was (F819)")
func latinProposalKeepsAttachedPunctuation() {
    let segments = [seg("the Kestrol, release"), seg("(Kestrol) shipped"), seg("we deployed cooper netties.")]
    let corrections = GlossaryCorrector.corrections(vocabulary: ["Kestrel", "Kubernetes"], segments: segments)
    #expect(corrections == [
        GlossaryCorrection(segmentIndex: 0, from: "Kestrol", to: "Kestrel"),
        GlossaryCorrection(segmentIndex: 1, from: "Kestrol", to: "Kestrel"),
        GlossaryCorrection(segmentIndex: 2, from: "cooper netties", to: "Kubernetes"),
    ])
    let applied = GlossaryCorrector.apply(corrections, to: segments).map(\.text)
    #expect(applied == ["the Kestrel, release", "(Kestrel) shipped", "we deployed Kubernetes."])
}

@Test("A trimmed proposal is never applied to an earlier word it only appears inside (F819, self-review)")
func trimmedProposalIsAppliedWhereItWasFound() {
    // The window is "Kestrol." at the end; "Kestrol" alone first occurs inside "Kestrol-ish", which
    // `apply` would have changed instead. The untrimmed phrase is proposed, as before F819.
    let segments = [seg("the Kestrol-ish build and the Kestrol.")]
    let corrections = GlossaryCorrector.corrections(vocabulary: ["Kestrel"], segments: segments)
    #expect(corrections == [GlossaryCorrection(segmentIndex: 0, from: "Kestrol.", to: "Kestrel")])
    #expect(GlossaryCorrector.apply(corrections, to: segments)[0].text == "the Kestrol-ish build and the Kestrel")
}

@Test("A term with its own outer punctuation keeps it once: .NET, Acme Inc., Yahoo!, @kestrel (F819)")
func termsOwnPunctuationIsNotDoubled() {
    func check(_ term: String, _ text: String, from: String, applied: String) {
        let segments = [seg(text)]
        let corrections = GlossaryCorrector.corrections(vocabulary: [term], segments: segments)
        #expect(corrections == [GlossaryCorrection(segmentIndex: 0, from: from, to: term)], "\(term) in \(text)")
        #expect(GlossaryCorrector.apply(corrections, to: segments)[0].text == applied, "\(term) in \(text)")
    }
    // F819's first round trimmed every window, and apply then wrote "..NET", "Inc..", "!!", "@@".
    check(".NET", "the .NOT runtime is old", from: ".NOT", applied: "the .NET runtime is old")
    check("Acme Inc.", "we signed with Acme Ink. yesterday", from: "Acme Ink.", applied: "we signed with Acme Inc. yesterday")
    check("Yahoo!", "Yahooo! said hi", from: "Yahooo!", applied: "Yahoo! said hi")
    check("@kestrel", "ping @kestrol now", from: "@kestrol", applied: "ping @kestrel now")
    // Only the term's own share goes with it: the comma and the brackets stay where they were.
    check("Acme Inc.", "Acme Ink., the vendor, signed", from: "Acme Ink.", applied: "Acme Inc., the vendor, signed")
    check(".NET", "the (.NOT) runtime", from: ".NOT", applied: "the (.NET) runtime")
}

@Test("A window whose untrimmed text is nowhere in the segment is never applied to other words (F819)")
func untrimmedWindowNotFoundIsNeverMisapplied() {
    // The window "(Kestrol⟨TAB⟩Release)" is proposed with a space between its words, so its text is
    // nowhere in the segment; its trimmed text is, inside "Kestrol Release-ish", and a tick changed
    // those words. Before F819 the row changed nothing, and it changes nothing again.
    let segments = [seg("(Kestrol\tRelease) ok, Kestrol Release-ish")]
    let corrections = GlossaryCorrector.corrections(vocabulary: ["Kestrel Release"], segments: segments)
    #expect(corrections == [GlossaryCorrection(segmentIndex: 0, from: "(Kestrol Release)", to: "Kestrel Release")])
    #expect(GlossaryCorrector.apply(corrections, to: segments)[0].text == "(Kestrol\tRelease) ok, Kestrol Release-ish")
}

@Test("An underscore is part of the word, so trimming stops at it and apply can still find the word (F819)")
func underscoreIsNeverTrimmed() {
    #expect(GlossaryCorrector.trimmingAttachedPunctuation("Kestrol_,") == "Kestrol_")
    #expect(GlossaryCorrector.trimmingAttachedPunctuation("(_Kestrol") == "_Kestrol")
    // "Kestrol" alone is no whole word inside "Kestrol_", so the proposal keeps the underscore, and
    // applying it replaces the underscore with the word, as before F819.
    let segments = [seg("the Kestrol_ build")]
    let corrections = GlossaryCorrector.corrections(vocabulary: ["Kestrel"], segments: segments)
    #expect(corrections == [GlossaryCorrection(segmentIndex: 0, from: "Kestrol_", to: "Kestrel")])
    #expect(GlossaryCorrector.apply(corrections, to: segments)[0].text == "the Kestrel build")
}

@Test("A multi-word term already in the segment proposes nothing, whatever follows it (F820)")
func multiWordTermAlreadyPresentProposesNothing() {
    #expect(GlossaryCorrector.corrections(vocabulary: ["Priya Raman"], segments: [seg("Priya Raman said the release is ready")]).isEmpty)
    #expect(GlossaryCorrector.corrections(vocabulary: ["Priya Raman"], segments: [seg("ask Priya\tRaman, she knows")]).isEmpty)
    #expect(GlossaryCorrector.corrections(vocabulary: ["Café Noir Paris"], segments: [seg("dinner at Café Noir Paris tonight")]).isEmpty)
    // A real mishearing of the same term is still proposed.
    #expect(
        GlossaryCorrector.corrections(vocabulary: ["Priya Raman"], segments: [seg("Priya Ramen said so")])
            == [GlossaryCorrection(segmentIndex: 0, from: "Priya Ramen", to: "Priya Raman")]
    )
}
