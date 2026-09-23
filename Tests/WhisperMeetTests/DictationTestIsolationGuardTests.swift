import Foundation
import Testing

// F427 — a `DictationController` built without a `textInjector:` gets `TextInjector()`, which is the
// user's real clipboard and, with auto-paste on, a real ⌘V into whatever app is focused. Every test
// harness that drove a dictation to delivery therefore wrote its fake transcript to the clipboard of
// whoever ran the suite. `DictationRefinerReleaseOrderingTests` dictates the text "raw transcript",
// and that is exactly what the user found on their clipboard on 2026-09-23, after the app's own log
// showed its dictation had put their clipboard back.
//
// A guard rather than a reminder, because the failure is silent: the suite passes, the developer's
// clipboard is quietly replaced, and on CI it is invisible. Comments are stripped first (F285).

@Test("Every DictationController a test builds is given a TextInjector of its own (F427)")
func everyTestControllerIsKeptOffTheRealClipboard() throws {
    var calls = 0
    var offenders: [String] = []
    for url in try SourceAssertion.swiftFileURLs(under: "Tests/WhisperMeetTests") {
        // String literals are blanked as well as comments, or this file's own search string
        // would count as a call.
        let source = SourceAssertion.stripComments(
            try String(contentsOf: url, encoding: .utf8), blankStringLiterals: true
        )
        var searchFrom = source.startIndex
        while let open = source.range(of: "DictationController(", range: searchFrom..<source.endIndex) {
            searchFrom = open.upperBound
            // `MockDictationController(` and the like are other types, not this initialiser.
            if open.lowerBound > source.startIndex,
               source[source.index(before: open.lowerBound)].isLetter {
                continue
            }
            // Walk to the matching parenthesis, so a multi-line call is read whole.
            var depth = 1
            var cursor = open.upperBound
            while cursor < source.endIndex, depth > 0 {
                if source[cursor] == "(" { depth += 1 } else if source[cursor] == ")" { depth -= 1 }
                cursor = source.index(after: cursor)
            }
            calls += 1
            if !source[open.lowerBound..<cursor].contains("textInjector:") {
                let line = source[..<open.lowerBound].filter { $0 == "\n" }.count + 1
                offenders.append("\(url.lastPathComponent):\(line)")
            }
            searchFrom = cursor
        }
    }
    #expect(calls > 0, "found no DictationController construction at all, so this guard checked nothing")
    #expect(
        offenders.isEmpty,
        "these build a DictationController on the real clipboard; pass `textInjector: isolatedTextInjector()`: \(offenders.joined(separator: ", "))"
    )
}
