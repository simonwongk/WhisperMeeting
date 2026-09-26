import Foundation
import Testing
@testable import WhisperCore

// F592 — `ProtectedTerms.contains` (F534) and `ReplacementBoundary.occurs` (F444) each decide
// whether a Latin term is a genuine "whole token" occurrence, and before this ticket they were two
// independently-written character predicates that disagreed on some inputs (an underscore
// neighbour; a non-Han Unicode letter neighbour). This table drives BOTH callers over the same
// inputs and requires them to agree with each other and with an explicit, reasoned `expected` value
// — the decision this ticket makes, not "whichever regex happens to win" (the ticket's own words).

private struct BoundaryCase {
    let name: String
    let term: String
    let text: String
    let expected: Bool
    let reason: String
}

private let boundaryCases: [BoundaryCase] = [
    BoundaryCase(
        name: "an underscore after the term is a same-token connector",
        term: "term", text: "term_id", expected: false,
        reason: "an underscore continues an identifier — term_id is one snake_case token, not the "
            + "word 'term' followed by punctuation — so it must block the match exactly like a "
            + "letter or digit would (F534's own comment: 'a Latin letter, digit, or underscore')"
    ),
    BoundaryCase(
        name: "an underscore before the term is a same-token connector",
        term: "id", text: "term_id", expected: false,
        reason: "symmetric with the case above: the connector rule applies on both sides of a match"
    ),
    BoundaryCase(
        name: "a non-Han Unicode letter (Cyrillic) is a boundary",
        term: "Kestrel", text: "КKestrelЙ", expected: true,
        reason: "WhisperMeet transcribes English or Mandarin only (docs/PRODUCT_SPEC.md); Cyrillic "
            + "never legitimately continues a Latin token in a real transcript, so — like a CJK "
            + "neighbour, which is also not ASCII — it counts as a boundary rather than a connector"
    ),
    BoundaryCase(
        name: "full-width Latin is a boundary",
        term: "Kestrel", text: "\u{FF38}Kestrel\u{FF39}", expected: true,
        reason: "a full-width letter is not in [A-Za-z0-9_] either, so it gets the same boundary "
            + "answer as any other non-ASCII neighbour — a token boundary and a search match "
            + "(F590's width-insensitive comparison) are different questions"
    ),
    BoundaryCase(
        name: "an apostrophe is a boundary",
        term: "Jon", text: "Jon's here", expected: true,
        reason: "a possessive/contraction apostrophe ends the word; consistent with the existing "
            + "\"L'École\" case already pinned in ProtectedTermsTests"
    ),
    BoundaryCase(
        name: "a hyphen is a boundary",
        term: "well", text: "well-known", expected: true,
        reason: "a hyphen separates compound-word components; both pre-F592 definitions already "
            + "agreed here — this locks it in with an explicit test rather than by accident"
    ),
    BoundaryCase(
        name: "a digit extends the token",
        term: "Kubernetes", text: "Kubernetes2 cluster", expected: false,
        reason: "Kubernetes2 is a different identifier than Kubernetes — the cult/culture false "
            + "positive whole-word matching exists to prevent"
    ),
    BoundaryCase(
        name: "a term starting with punctuation, glued to a leading digit, is refused",
        term: ".NET", text: "the 1.NET build", expected: false,
        reason: "the digit immediately before the match is a connector character, so the match is "
            + "refused even though the term's own first character ('.') is not alphanumeric — the "
            + "F534 review's 'arguably more correct' call for this exact input, now pinned by a test"
    ),
    BoundaryCase(
        name: "a term starting with punctuation, word-spaced, matches",
        term: ".NET", text: "I love .NET today", expected: true,
        reason: "ordinary word-spaced usage is unaffected by the leading-digit edge case above"
    ),
    BoundaryCase(
        name: "a term ending with punctuation, glued to a trailing letter, is refused",
        term: "C++", text: "the C++abc identifier", expected: false,
        reason: "the letter right after the term's trailing '+' is a connector, so this is a "
            + "different token ('C++abc'), not a whole occurrence of 'C++'"
    ),
    BoundaryCase(
        name: "a term ending with punctuation, word-spaced, matches",
        term: "C++", text: "Learn C++ well", expected: true,
        reason: "ordinary word-spaced usage is unaffected by the trailing-letter edge case above"
    ),
    BoundaryCase(
        name: "a term ending in punctuation followed by more punctuation matches",
        term: "Yahoo!", text: "I searched Yahoo! today", expected: true,
        reason: "the character after the term's own trailing '!' is a space — an ordinary boundary"
    ),
]

@Test("ProtectedTerms and ReplacementBoundary agree on every pinned Latin-token-boundary case (F592)")
func boundaryDefinitionsAgree() {
    for testCase in boundaryCases {
        let protectedTermsResult = ProtectedTerms.contains(testCase.text, term: testCase.term)
        let replacementBoundaryResult = ReplacementBoundary.occurs(
            testCase.term, notCoveredBy: "", in: testCase.text
        )
        #expect(
            protectedTermsResult == testCase.expected,
            "ProtectedTerms — \(testCase.name): \(testCase.reason)"
        )
        #expect(
            replacementBoundaryResult == testCase.expected,
            "ReplacementBoundary — \(testCase.name): \(testCase.reason)"
        )
        #expect(
            protectedTermsResult == replacementBoundaryResult,
            "callers disagree on: \(testCase.name)"
        )
    }
}
