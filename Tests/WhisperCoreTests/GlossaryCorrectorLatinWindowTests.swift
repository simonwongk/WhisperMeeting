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

@Test("A trimmed proposal is applied to the window it was trimmed from, not to an earlier word it only appears inside (F819, F914)")
func trimmedProposalIsAppliedWhereItWasFound() {
    // The window is "Kestrol." at the end; "Kestrol" alone first occurs inside "Kestrol/Falcon",
    // a whole word to `apply` (a slash is a word edge) that `apply` would have changed instead, so
    // until F914 the untrimmed "Kestrol." was proposed and the full stop went with it. The row now
    // carries the window's place, and the full stop stays.
    let segments = [seg("the Kestrol/Falcon build and the Kestrol.")]
    let corrections = GlossaryCorrector.corrections(vocabulary: ["Kestrel"], segments: segments)
    #expect(corrections == [GlossaryCorrection(segmentIndex: 0, from: "Kestrol", to: "Kestrel", characterOffset: 33)])
    #expect(GlossaryCorrector.apply(corrections, to: segments)[0].text == "the Kestrol/Falcon build and the Kestrel.")
    // Glued by a hyphen instead, the first "Kestrol" is a window of its own (F915), scores the same
    // as the last and comes first, so it is the one proposed — and "-ish" stays.
    let hyphenated = [seg("the Kestrol-ish build and the Kestrol.")]
    let hyphenatedRows = GlossaryCorrector.corrections(vocabulary: ["Kestrel"], segments: hyphenated)
    #expect(hyphenatedRows == [GlossaryCorrection(segmentIndex: 0, from: "Kestrol", to: "Kestrel")])
    #expect(GlossaryCorrector.apply(hyphenatedRows, to: hyphenated)[0].text == "the Kestrel-ish build and the Kestrol.")
}

@Test("A Latin proposal is applied to the window it scored, never to an earlier occurrence of its text, and names the text as it stands (F914)")
func latinProposalIsAppliedToTheWindowItScored() {
    // "Kestrol" inside "Kestrol/Falcon" is a whole word to `apply` (a slash is a word edge) but a
    // poor window here (14 letters against 7); the best window is the later "Kestrol", and a row
    // naming only its text changed the first. The row carries its place, and its sentence says so.
    let segments = [seg("the Kestrol/Falcon build and the Kestrol release")]
    let corrections = GlossaryCorrector.corrections(vocabulary: ["Kestrel"], segments: segments)
    #expect(corrections == [GlossaryCorrection(segmentIndex: 0, from: "Kestrol", to: "Kestrel", characterOffset: 33)])
    #expect(GlossaryCorrector.apply(corrections, to: segments)[0].text == "the Kestrol/Falcon build and the Kestrel release")
    #expect(GlossaryCorrector.context(of: corrections[0], in: segments[0].text)
        == ProposalContext(before: "…build and the ", match: "Kestrol", after: " release"))
    // A window across a tab or a double space is proposed as it stands, so `apply` finds it; until
    // F914 its words were joined with one space, which `apply` never found (F820 then dropped it).
    for text in ["we deployed cooper\tnetties today", "we deployed cooper  netties today"] {
        let joined = [seg(text)]
        let rows = GlossaryCorrector.corrections(vocabulary: ["Kubernetes"], segments: joined)
        #expect(rows.map(\.from) == [String(text.dropFirst(12).dropLast(6))], "\(text)")
        #expect(GlossaryCorrector.apply(rows, to: joined)[0].text == "we deployed Kubernetes today", "\(text)")
    }
    // The review's T8: the window across a tab, trimmed of its brackets, applies inside them; the
    // later "Kestrol Release-ish" is a different text and is left alone.
    let bracketed = [seg("(Kestrol\tRelease) ok, Kestrol Release-ish")]
    let bracketedRows = GlossaryCorrector.corrections(vocabulary: ["Kestrel Release"], segments: bracketed)
    #expect(bracketedRows == [GlossaryCorrection(segmentIndex: 0, from: "Kestrol\tRelease", to: "Kestrel Release")])
    #expect(GlossaryCorrector.apply(bracketedRows, to: bracketed)[0].text == "(Kestrel Release) ok, Kestrol Release-ish")
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
    // A full stop that is both the term's and the sentence's is written once.
    check("Acme Inc.", "we signed with Acme Ink.", from: "Acme Ink.", applied: "we signed with Acme Inc.")
}

@Test("A window's outer mark goes with the word only where it is the term's own mark, never a different one (F819)")
func onlyTheTermsOwnMarksGoWithTheWord() {
    func check(_ term: String, _ text: String, from: String, applied: String) {
        let segments = [seg(text)]
        let corrections = GlossaryCorrector.corrections(vocabulary: [term], segments: segments)
        #expect(corrections == [GlossaryCorrection(segmentIndex: 0, from: from, to: term)], "\(term) in \(text)")
        #expect(GlossaryCorrector.apply(corrections, to: segments)[0].text == applied, "\(term) in \(text)")
    }
    // Round 2 kept as many of the window's outer marks as the term has, whatever they were, so a
    // comma or a question mark was swallowed and a bracket or quote lost half its pair (the Wave 5
    // review of round 2, R6).
    check("Acme Inc.", "Acme Ink, the vendor, signed", from: "Acme Ink", applied: "Acme Inc., the vendor, signed")
    check("Acme Inc.", "we signed with Acme Ink?", from: "Acme Ink", applied: "we signed with Acme Inc.?")
    check("Acme Inc.", "(Acme Ink) signed", from: "Acme Ink", applied: "(Acme Inc.) signed")
    check(".NET", "the (NOT) runtime is old", from: "NOT", applied: "the (.NET) runtime is old")
    check(".NET", "the \"NOT\" runtime", from: "NOT", applied: "the \".NET\" runtime")
    check("@kestrel", "ping (kestrol) now", from: "kestrol", applied: "ping (@kestrel) now")
    check("Yahoo!", "Yahooo, said hi", from: "Yahooo", applied: "Yahoo!, said hi")
    check("(beta)", "the betta, release", from: "betta", applied: "the (beta), release")
    // On the trim itself: the longest run of the window's outer marks that is the term's own.
    #expect(GlossaryCorrector.trimmingAttachedPunctuation("Ink..", keepingTheEdgesOf: "Inc.") == "Ink.")
    #expect(GlossaryCorrector.trimmingAttachedPunctuation("(.NOT.)", keepingTheEdgesOf: ".NET") == ".NOT")
    #expect(GlossaryCorrector.trimmingAttachedPunctuation("Kestrol_,", keepingTheEdgesOf: "Kestrel") == "Kestrol_")
}

@Test("A window is never applied to other words its text appears inside (F819, F914)")
func untrimmedWindowNotFoundIsNeverMisapplied() {
    // The window "(Kestrol⟨TAB⟩Release)" used to be proposed with a space between its words, so its
    // text was nowhere in the segment; its trimmed text was, inside "Kestrol Release-ish", and a tick
    // changed those words. Since F914 the window is proposed as it stands and applied where it was
    // scored: inside the brackets, and nowhere else.
    let segments = [seg("(Kestrol\tRelease) ok, Kestrol Release-ish")]
    let corrections = GlossaryCorrector.corrections(vocabulary: ["Kestrel Release"], segments: segments)
    #expect(corrections.map(\.from) == ["Kestrol\tRelease"])
    #expect(GlossaryCorrector.apply(corrections, to: segments)[0].text == "(Kestrel Release) ok, Kestrol Release-ish")
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

@Test("A row that applying would leave unchanged is not proposed: a correct term of four or more words (F820)")
func noOpRowsAreNotProposed() {
    // Windows went up to three words, so a correct four-word term's best window lay inside it
    // ("Bank of New" in "Bank of New York"); apply never changes text inside the term, so the row
    // did nothing (since F940 a four-word term is compared with four-word windows and is present
    // here; the guard still stands). Words joined across a tab or a double space used to be
    // proposed with one space, which apply never found; since F914 they are proposed as they stand
    // (`latinProposalIsAppliedToTheWindowItScored`).
    #expect(GlossaryCorrector.corrections(vocabulary: ["Bank of New York"], segments: [seg("the Bank of New York said yes")]).isEmpty)
    #expect(GlossaryCorrector.corrections(vocabulary: ["Bank of New York Mellon"], segments: [seg("we bank with Bank of New York Mellon today")]).isEmpty)
    // The same words with one space are a working row, as before.
    #expect(GlossaryCorrector.corrections(vocabulary: ["Kubernetes"], segments: [seg("we deployed cooper netties today")])
        == [GlossaryCorrection(segmentIndex: 0, from: "cooper netties", to: "Kubernetes")])
}

@Test("A mishearing of a term of four or more words is compared with windows of its own length, so applying it duplicates no words (F940)")
func longTermMishearingIsProposedWhole() {
    // Windows went up to three words, so the best window was a part of the mishearing and applying
    // its row wrote the whole term beside the rest: "the Bank of New York Yolk said yes" (the Wave 5
    // probe, `probe-four-word.txt`).
    func row(_ term: String, _ text: String) -> (proposed: [GlossaryCorrection], applied: String) {
        let segments = [seg(text)]
        let proposed = GlossaryCorrector.corrections(vocabulary: [term], segments: segments)
        return (proposed, GlossaryCorrector.apply(proposed, to: segments)[0].text)
    }
    let yolk = row("Bank of New York", "the Bank of New Yolk said yes")
    #expect(yolk.proposed == [GlossaryCorrection(segmentIndex: 0, from: "Bank of New Yolk", to: "Bank of New York")])
    #expect(yolk.applied == "the Bank of New York said yes")
    let bonk = row("Bank of New York", "the Bonk of New York said yes")
    #expect(bonk.proposed == [GlossaryCorrection(segmentIndex: 0, from: "Bonk of New York", to: "Bank of New York")])
    #expect(bonk.applied == "the Bank of New York said yes")
    let melon = row("Bank of New York Mellon", "Bank of New York Melon")
    #expect(melon.proposed == [GlossaryCorrection(segmentIndex: 0, from: "Bank of New York Melon", to: "Bank of New York Mellon")])
    #expect(melon.applied == "Bank of New York Mellon")
    // A short term is still compared with windows of up to three words, as F65 always did.
    #expect(row("Kubernetes", "we deployed cooper netties today").applied == "we deployed Kubernetes today")
    // A term of four or more words spelled across a tab is still present, at any length.
    #expect(row("Bank of New York", "the Bank\tof New York said yes").proposed.isEmpty)
}

@Test("A possessive 's and a dash-glued word beside a term are outside the window, so applying deletes neither (F915)")
func possessiveAndDashGluedWordsAreOutsideTheWindow() {
    func rows(_ term: String, _ text: String) -> [GlossaryCorrection] {
        GlossaryCorrector.corrections(vocabulary: [term], segments: [seg(text)])
    }
    func check(_ term: String, _ text: String, from: String, applied: String) {
        let segments = [seg(text)]
        let corrections = GlossaryCorrector.corrections(vocabulary: [term], segments: segments)
        #expect(corrections.map(\.from) == [from], "\(term) in \(text)")
        #expect(GlossaryCorrector.apply(corrections, to: segments)[0].text == applied, "\(term) in \(text)")
    }
    // The possessive (the Wave 5 review of F819): "Kestrel's" normalized to "kestrels", so the
    // term was not present and the window scored 7/8; the row deleted the 's.
    #expect(rows("Kestrel", "Kestrel's release is ready").isEmpty)
    #expect(rows("Priya Raman", "Priya Raman's report is in").isEmpty)
    #expect(rows("Kestrel", "Kestrel’s release is ready").isEmpty)
    // A misheard term keeps its 's, straight or curly.
    check("Kestrel", "the Kestrol's build", from: "Kestrol", applied: "the Kestrel's build")
    check("Kestrel", "the Kestrol’s build", from: "Kestrol", applied: "the Kestrel’s build")
    check("Priya Raman", "Pria Ramen's report", from: "Pria Ramen", applied: "Priya Raman's report")
    // A term whose own spelling ends in 's keeps the window's: McDonald's.
    check("McDonald's", "lunch at MacDonald's today", from: "MacDonald's", applied: "lunch at McDonald's today")
    check("McDonald's", "lunch at MacDonald today", from: "MacDonald", applied: "lunch at McDonald's today")
    // A dash-glued word (the review's T9): "Kestrol—the" was one window, and the row deleted "—the".
    check("Kestrel", "Kestrol—the build", from: "Kestrol", applied: "Kestrel—the build")
    check("Kestrel", "Kestrol–the build", from: "Kestrol", applied: "Kestrel–the build")
    check("Kestrel", "the Kestrol-ish build", from: "Kestrol", applied: "the Kestrel-ish build")
    check("Kestrel Release", "ok, Kestrol Release-ish", from: "Kestrol Release", applied: "ok, Kestrel Release-ish")
    // A hyphenated term is present spelled with its hyphen, without it, or with a space.
    #expect(rows("Wi-Fi", "the wi-fi is down").isEmpty)
    #expect(rows("Wi-Fi", "the wifi is down").isEmpty)
    #expect(rows("Wi-Fi", "the wi fi is down").isEmpty)
    // And a mishearing across the hyphen is still one window, proposed whole with its hyphen.
    check("Wi-Fi", "the why-fi is down", from: "why-fi", applied: "the Wi-Fi is down")
}

@Test("A mishearing with one more word than its term is compared whole, so applying it leaves no stray word (F968)")
func mishearingWithAnExtraWordLeavesNoStrayWord() {
    func rows(_ term: String, _ text: String) -> [GlossaryCorrection] {
        GlossaryCorrector.corrections(vocabulary: [term], segments: [seg(text)])
    }
    func check(_ term: String, _ text: String, from: String, applied: String) {
        let segments = [seg(text)]
        let corrections = GlossaryCorrector.corrections(vocabulary: [term], segments: segments)
        #expect(corrections.map(\.from) == [from], "\(term) in \(text)")
        #expect(GlossaryCorrector.apply(corrections, to: segments)[0].text == applied, "\(term) in \(text)")
    }
    // A term's windows went up to its own number of words (F940), so a mishearing that split one
    // of its words was compared with too short a window and the row left the fragment behind:
    // "the Bank of New York k said yes", "ask Priya Raman Iyer Iyer now" (F940's own probe).
    check("Bank of New York", "the Bank of New Yor k said yes", from: "Bank of New Yor k", applied: "the Bank of New York said yes")
    check("Priya Raman Iyer", "ask Priya Ram an Iyer now", from: "Priya Ram an Iyer", applied: "ask Priya Raman Iyer now")
    // A split word that spells the term exactly is that mishearing, not the term present: F820
    // counted any window equal to the term as present, however many words it took.
    check("Kubernetes", "we deployed Kuber netes today", from: "Kuber netes", applied: "we deployed Kubernetes today")
    check("Priya Raman", "ask Priya Ram an now", from: "Priya Ram an", applied: "ask Priya Raman now")
    // Spelled across its own number of words the term is present, whatever the separators (F820,
    // F940), and a short term is still compared with windows of up to three (F65).
    #expect(rows("Bank of New York", "the Bank\tof New York said yes").isEmpty)
    #expect(rows("Priya Raman", "Priya\tRaman said so").isEmpty)
    #expect(rows("Wi-Fi", "the wi fi is down").isEmpty)
    check("Kubernetes", "we deployed cooper netties today", from: "cooper netties", applied: "we deployed Kubernetes today")
}

@Test("A term of four or more words is compared only with a line that holds at least half its words; a three-word term gets its fourth window there, or where a shorter one scored (F972, F968)")
func longTermsAreComparedOnlyWhereTheLineHoldsHalfTheirWords() {
    func rows(_ term: String, _ text: String) -> [GlossaryCorrection] {
        GlossaryCorrector.corrections(vocabulary: [term], segments: [seg(text)])
    }
    func check(_ term: String, _ text: String, from: String, applied: String) {
        let segments = [seg(text)]
        let corrections = GlossaryCorrector.corrections(vocabulary: [term], segments: segments)
        #expect(corrections.map(\.from) == [from], "\(term) in \(text)")
        #expect(GlossaryCorrector.apply(corrections, to: segments)[0].text == applied, "\(term) in \(text)")
    }
    // One long phrase made every line build windows up to its own length: +22% on ordinary lines
    // and +78% on long ones with 50 phrases of 10–20 words (the Wave 6 review of F940). A
    // mishearing keeps most of a phrase's words, so a line holding fewer than half of them, as
    // whole words, is not compared with the phrase at all — and builds no window for it.
    #expect(rows("Bank of New York", "the Bonk off Noo Yolk said yes").isEmpty)
    check("Bank of New York", "the Bonk of Noo York said yes", from: "Bonk of Noo York", applied: "the Bank of New York said yes")
    check("Bank of New York", "the Bonk of New York said yes", from: "Bonk of New York", applied: "the Bank of New York said yes")
    // A three-word term keeps F65's windows of up to three on every line; its fourth (F968) is
    // built where the line holds one of its words, or where a window of up to three already
    // scored for it — so a mishearing split across four words and sharing none of the term's is
    // proposed whole (until round 2 of Wave 7 it was "Pria Ram an", which left "Eyer" behind),
    // while a line on which nothing scored builds no fourth window.
    check("Priya Raman Iyer", "ask Pria Ram an Iyer now", from: "Pria Ram an Iyer", applied: "ask Priya Raman Iyer now")
    check("Priya Raman Iyer", "ask Pria Ramen Eyer now", from: "Pria Ramen Eyer", applied: "ask Priya Raman Iyer now")
    check("Priya Raman Iyer", "ask Pria Ram an Eyer now", from: "Pria Ram an Eyer", applied: "ask Priya Raman Iyer now")
    // Its four words "pr iy ar am" would score 8/14, but no three of them reach half the term.
    #expect(rows("Priya Raman Iyer", "ask pr iy ar am now").isEmpty)
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

@Test("A Latin window that is itself a vocabulary term is never proposed toward another term (F1003)")
func aLatinVocabularyTermIsNeverProposedTowardAnother() {
    // F916's round 2 refused this for Chinese only: with both "Kestrel" and "Kestrol" listed, every
    // correct Kestrol got a row toward Kestrel and every Kestrel one toward Kestrol. The user listed
    // both spellings, so neither is a mishearing of the other — in any case, and with its comma —
    // and a window across one ("the Kestrol", 7/10 like Kestrel) would rewrite it as well.
    let segments = [seg("the Kestrol release"), seg("the Kestrel build"), seg("the kestrol, again"), seg("the Kestral fix")]
    let rows = GlossaryCorrector.corrections(vocabulary: ["Kestrel", "Kestrol"], segments: segments)
    // A window that is no term is still proposed toward the term it is nearest, as before.
    #expect(rows == [
        GlossaryCorrection(segmentIndex: 3, from: "Kestral", to: "Kestrel"),
        GlossaryCorrection(segmentIndex: 3, from: "Kestral", to: "Kestrol"),
    ])
    // A term that holds the other's spelling keeps it, so its row is still made.
    #expect(GlossaryCorrector.corrections(vocabulary: ["Priya Raman", "Raman"], segments: [seg("ask Pria Raman now")])
        == [GlossaryCorrection(segmentIndex: 0, from: "Pria Raman", to: "Priya Raman")])
    // With one of the pair listed, the other is a near-miss of it, as before.
    #expect(GlossaryCorrector.corrections(vocabulary: ["Kestrel"], segments: [segments[0]])
        == [GlossaryCorrection(segmentIndex: 0, from: "Kestrol", to: "Kestrel")])
}
