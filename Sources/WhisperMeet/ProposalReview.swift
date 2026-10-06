import Foundation
import WhisperCore

/// One set of correction proposals to review, and the tool that made it (F536).
///
/// Its own identity, so the review sheet is presented per set (`.sheet(item:)`) and its ticks and
/// warnings are worked out for exactly these proposals. The sheet used to be keyed by a bare
/// `[GlossaryCorrection]?`: a Correct Toward Vocabulary pass finishing in the background while the
/// rules' sheet was open replaced the rows under the old sheet's ticks and warning labels, so a row
/// that rewrites a vocabulary term could arrive ticked and unmarked.
struct ProposalReview: Identifiable, Equatable {
    enum Source: Equatable {
        /// Correct Toward Vocabulary — near-misses found by spelling and sound.
        case vocabulary
        /// Apply Replacement Rules — the user's own exact rules.
        case replacementRules
        /// Correct with Local AI (with or without a reference document).
        case localModel
    }

    let id = UUID()
    let proposals: [GlossaryCorrection]
    let source: Source

    /// Proposals that arrive unticked whatever else is true of them: a Chinese near-miss from Correct
    /// Toward Vocabulary. The pass now requires every differing character to sound the same, which
    /// removed every wrong proposal the F536 review measured; this is the backstop for the reading
    /// Foundation gives a character being wrong, because applying cannot be undone.
    var uncheckedByDefault: Set<Int> {
        guard source == .vocabulary else { return [] }
        return GlossaryReviewDefaults.chineseSpans(proposals)
    }

    /// What the sheet ticks when it opens, once it knows which proposals touch a vocabulary term
    /// (F245): everything else, less `uncheckedByDefault`.
    func preselected(touching: Set<Int>) -> Set<Int> {
        Set(proposals.indices).subtracting(touching).subtracting(uncheckedByDefault)
    }
}

/// A meeting's review sheets, one at a time (F536).
///
/// Correct Toward Vocabulary and Correct with Local AI finish in the background, so a result can
/// arrive while another review is open. It waits for that review to close instead of replacing it.
struct ProposalReviewQueue: Equatable {
    private(set) var current: ProposalReview?
    private(set) var waiting: [ProposalReview] = []

    /// Shows `review` now, or after the open one closes.
    mutating func present(_ review: ProposalReview) {
        if current == nil {
            current = review
        } else {
            waiting.append(review)
        }
    }

    /// The open sheet was dismissed (its binding was set to nil).
    mutating func close() {
        current = nil
    }

    /// After a dismissal has finished: shows the next waiting review, if any.
    mutating func advance() {
        guard current == nil, !waiting.isEmpty else { return }
        current = waiting.removeFirst()
    }
}
