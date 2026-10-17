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
    /// The review's pages (F818): `pageSize` rows each, run on to the end of the line the last one
    /// is on, so the rows for one place — which share a line — are never split across two pages.
    let pages: [Range<Int>]

    /// Rows per page of the review sheet (F818). The synthetic 5,000-term corpus gave one sheet
    /// 167,128 rows (F536), and the sheet worked out every row's warning and sentence when it opened.
    static let pageSize = 200

    init(proposals: [GlossaryCorrection], source: Source) {
        // In line order, each line's rows in the order given (F818, round 2): Correct with Local AI
        // lists rows by correction and then by line, so the model's two readings of one word could
        // sit 200 rows apart and land on different pages, neither page seeing the other.
        let proposals = proposals.enumerated()
            .sorted { ($0.element.segmentIndex, $0.offset) < ($1.element.segmentIndex, $1.offset) }
            .map(\.element)
        self.proposals = proposals
        self.source = source
        var pages: [Range<Int>] = []
        var start = 0
        while start < proposals.count {
            var end = min(start + Self.pageSize, proposals.count)
            while end < proposals.count, proposals[end].segmentIndex == proposals[end - 1].segmentIndex { end += 1 }
            pages.append(start..<end)
            start = end
        }
        self.pages = pages.isEmpty ? [0..<0] : pages
    }

    /// "Rows 202–402 of 3,000", under the rows of a review with more than one page (F818).
    static func pageLabel(_ page: Range<Int>, of total: Int) -> String {
        let english = Locale(identifier: "en_US")
        func number(_ value: Int) -> String { value.formatted(.number.locale(english)) }
        return "Rows \(number(page.lowerBound + 1))–\(number(page.upperBound)) of \(number(total))"
    }

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

    /// What the sheet ticks when a page first opens, once it knows which of its proposals touch a
    /// vocabulary term (F245): everything else, less `uncheckedByDefault`, and one row per place
    /// (F966, `groups` from `GlossaryCorrector.alternatives`) — the first, the one `apply` would take.
    func preselected(touching: Set<Int>, on page: Range<Int>? = nil, groups: [Int: Int] = [:]) -> Set<Int> {
        Self.onePerPlace(
            Set(page ?? proposals.indices).subtracting(touching).subtracting(uncheckedByDefault), groups: groups
        )
    }

    /// What Select All may tick (F817): every row but those that need a tick of their own. A row that
    /// rewrites a vocabulary term is still Select All's, as it always was — it arrives unticked and
    /// marked, and Select All is the deliberate act.
    var selectableAll: Set<Int> { Set(proposals.indices).subtracting(uncheckedByDefault) }

    /// The ticks after the row at `index` is ticked or unticked (F966): ticking a row unticks the
    /// other rows for its place, since `apply` would change that place once, with the first.
    func ticking(_ index: Int, on: Bool, in selected: Set<Int>, groups: [Int: Int]) -> Set<Int> {
        guard on else { return selected.subtracting([index]) }
        var result = selected
        if let place = groups[index] {
            result.subtract(groups.filter { $0.value == place && $0.key != index }.map(\.key))
        }
        result.insert(index)
        return result
    }

    /// Whether the sheet's Select All button reads Deselect All: every place on the page (all of the
    /// review by default) with a row Select All may tick has a tick — any of its rows, a hand-ticked
    /// sound-alike one too — and something is ticked (F817, F966).
    func allTicked(_ selected: Set<Int>, on page: Range<Int>? = nil, groups: [Int: Int] = [:]) -> Bool {
        let rows = Set(page ?? proposals.indices)
        guard !selected.isDisjoint(with: rows) else { return false }
        return selectablePlaces(of: rows, groups: groups).allSatisfy { !selected.isDisjoint(with: $0) }
    }

    /// The ticks after the Select All / Deselect All button (F817), on one page (F818; all of the
    /// review by default): Deselect All clears the page's ticks, a hand-ticked sound-alike row's too;
    /// Select All ticks one row for every place on the page that has none — the first — and keeps the
    /// hand ticks and other pages' ticks (F966).
    func toggledAll(_ selected: Set<Int>, on page: Range<Int>? = nil, groups: [Int: Int] = [:]) -> Set<Int> {
        let rows = Set(page ?? proposals.indices)
        if allTicked(selected, on: page, groups: groups) { return selected.subtracting(rows) }
        var result = selected
        for place in selectablePlaces(of: rows, groups: groups) where result.isDisjoint(with: place) {
            if let first = place.intersection(selectableAll).min() { result.insert(first) }
        }
        return result
    }

    /// `rows` grouped by place, keeping the places with a row Select All may tick. Built from every
    /// row, so a hand-ticked row Select All may not tick still stands for its place (F966, round 2).
    private func selectablePlaces(of rows: Set<Int>, groups: [Int: Int]) -> [Set<Int>] {
        Self.places(of: rows, groups: groups).filter { !$0.isDisjoint(with: selectableAll) }
    }

    /// `rows` grouped by place: each group of alternatives together, every other row alone.
    private static func places(of rows: Set<Int>, groups: [Int: Int]) -> [Set<Int>] {
        var byPlace: [Int: Set<Int>] = [:]
        for row in rows { byPlace[groups[row] ?? -1 - row, default: []].insert(row) }
        return Array(byPlace.values)
    }

    /// `selected` with at most one row per place, the first (F966).
    static func onePerPlace(_ selected: Set<Int>, groups: [Int: Int]) -> Set<Int> {
        Set(places(of: selected, groups: groups).compactMap { $0.min() })
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
