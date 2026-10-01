import Foundation
import Testing

// F575 — the two repetition notices (the orange "N repeated copies" with Remove Repeated Lines, and
// the red F186 warning) are computed off the render path by `refreshRepetitionState()`, which zeroes
// both on a hand-edited transcript. It ran on appear and when the lines changed. A hand edit changes
// only `transcriptText`, so the notice stayed on screen beside a button that then refused, because
// `lineRemovalBlockedReason` refuses an edited transcript.
//
// `ContentView` cannot be rendered in this target (F174's standing reason), so this is a source
// guard, comments stripped first (F285). That the key itself flips on an edit and back on an undo
// to the rendered text is `MeetingStore.isTranscriptEdited`'s memo, pinned headlessly by
// `TranscriptRenderMemoTests` (F541).

private func contentView() throws -> String {
    try SourceAssertion.uncommentedSource("Sources/WhisperMeet/ContentView.swift")
}

/// The `.onChange(of: <key>)` modifiers whose closure calls `refreshRepetitionState()`, by key.
private func repetitionRefreshKeys(in source: String) throws -> [String] {
    let pattern = try NSRegularExpression(
        pattern: #"\.onChange\(of: ([^\n]*)\)\s*\{[^}]*refreshRepetitionState\(\)"#
    )
    let range = NSRange(source.startIndex..., in: source)
    return pattern.matches(in: source, range: range).compactMap { match in
        Range(match.range(at: 1), in: source).map { String(source[$0]) }
    }
}

@Test("The repetition notices are recomputed when the transcript's edit state flips, as well as when its lines change (F575)")
func repetitionNoticesRefreshOnTheEditState() throws {
    let keys = try repetitionRefreshKeys(in: try contentView())
    #expect(keys.contains { $0.contains(".segments") }, "the lines-changed refresh (F422) is gone: \(keys)")
    #expect(
        keys.contains { $0.contains("isTranscriptEdited") },
        "a hand edit changes only the text, so nothing recomputes the notices on it: \(keys)"
    )
}

@Test("The edit-state refresh is keyed on the remembered Bool, not on the text, so it does not run per keystroke (F575)")
func repetitionRefreshIsNotKeyedOnTheText() throws {
    // Keyed on the text, every keystroke in the Edit view would re-run the repetition analysis over
    // the whole transcript. `isTranscriptEdited` is memoised (F541) and changes only when the edit
    // state does.
    let keys = try repetitionRefreshKeys(in: try contentView())
    #expect(!keys.contains { $0.contains("transcriptText") }, "\(keys)")
}
