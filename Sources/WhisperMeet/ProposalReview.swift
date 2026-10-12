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

    /// Proposals that need a tick of their own: a Chinese near-miss from Correct Toward Vocabulary,
    /// a match by sound. Every differing character must sound like the term's, but a homophone can
    /// be another real word or another person's name — the Wave 5 review of F817 measured 15 wrong
    /// rows in 40 everyday sentences (经历 for 经理, 上限 for 上线, 张薇 for 张伟). So they arrive
    /// unticked, Select All leaves them (`selectableAll`), and each row shows its sentence (the
    /// sheet's `sentences`). Applying can be undone since F831, but a tick that renames a person in a
    /// long transcript may not be noticed to undo.
    var uncheckedByDefault: Set<Int> {
        guard source == .vocabulary else { return [] }
        return GlossaryReviewDefaults.chineseSpans(proposals)
    }

    /// What the sheet ticks when it opens, once it knows which proposals touch a vocabulary term
    /// (F245): everything else, less `uncheckedByDefault`.
    func preselected(touching: Set<Int>) -> Set<Int> {
        Set(proposals.indices).subtracting(touching).subtracting(uncheckedByDefault)
    }

    /// What Select All ticks (F817): every row but those that need a tick of their own. A row that
    /// rewrites a vocabulary term is still Select All's, as it always was — it arrives unticked and
    /// marked, and Select All is the deliberate act.
    var selectableAll: Set<Int> { Set(proposals.indices).subtracting(uncheckedByDefault) }

    /// Whether the sheet's Select All button reads Deselect All: everything Select All would tick is
    /// ticked, and something is (F817).
    func allTicked(_ selected: Set<Int>) -> Bool {
        !selected.isEmpty && selectableAll.isSubset(of: selected)
    }

    /// The ticks after the Select All / Deselect All button (F817): Deselect All clears every tick,
    /// a hand-ticked sound-alike row's too; Select All adds `selectableAll` and keeps the hand ticks.
    func toggledAll(_ selected: Set<Int>) -> Set<Int> {
        allTicked(selected) ? [] : selected.union(selectableAll)
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
