import WhisperCore

/// The last value computed from an input, recomputed only when the input changes (F541).
///
/// For derivations a SwiftUI body needs on every render from an input that rarely changes. A render
/// asks as often as it likes and pays one comparison; the work runs again only when the input
/// differs from the last one. A class, so a view can keep one in `@State` and fill it from its body
/// without that being a state change that schedules another render.
///
/// Keyed on the values themselves, never on which code path changed them, so no path can leave the
/// answer stale.
final class LastValueMemo<Input: Equatable, Output> {
    private var last: (input: Input, output: Output)?

    func value(for input: Input, compute: (Input) -> Output) -> Output {
        if let last, last.input == input {
            // Keep the caller's copy. Equal contents in different storage — a record decoded again —
            // compare element by element; after this the stored input is the caller's storage, and
            // `String` and `Array` both check storage identity before comparing any contents.
            self.last = (input, last.output)
            return last.output
        }
        let output = compute(input)
        last = (input, output)
        return output
    }
}

/// The quality flags the Read view draws over one list of transcript lines (F541).
///
/// `PlayableTranscriptView` used to build this in its initializer, which runs on every render of the
/// detail view above it — each Notes keystroke, each progress update the model publishes — so the
/// quality review ran over the whole transcript that often. The view now keeps a `LastValueMemo` of
/// this in `@State`, and the review runs when the lines or the edited state change.
struct TranscriptReviewOverlay {
    struct Input: Equatable {
        let segments: [TranscriptSegment]
        let isEdited: Bool
    }

    let report: TranscriptQualityReport
    let flagsByIndex: [Int: [SegmentQualityFlag]]

    init(
        _ input: Input,
        review: ([TranscriptSegment]) -> TranscriptQualityReport = TranscriptQuality.review
    ) {
        // Edited transcript → the flags describe the original segments, not what's shown, so drop
        // them (no banner, no per-line markers) rather than present stale review state.
        report = input.isEdited ? TranscriptQualityReport(flagged: [], scoredCount: 0) : review(input.segments)
        flagsByIndex = Dictionary(uniqueKeysWithValues: report.flagged.map { ($0.index, $0.flags) })
    }
}
