import Foundation
import Testing

/// F631 — the refine-stage bench builds its refine engine with the app's arguments.
///
/// `DictationController` builds its `DictationRefiner` around a `WarmRefineEngine` inside its own
/// initializer, which the WhisperCore test target cannot call. So the refine bench and the F206
/// latency suite share one test-side copy, `ProductionRefineConstruction.engine()`. A copy cannot
/// notice the app changing, for example a new prime prompt or another model directory. This test
/// compares the two argument lists as source, with comments stripped (F285).
@Test("The refine bench's WarmRefineEngine gets the arguments DictationController gives it (F631)")
func refineBenchBuildsTheEngineTheAppBuilds() throws {
    let app = try warmRefineEngineArguments(
        in: "Sources/WhisperMeet/Dictation/DictationController.swift",
        after: "self.refiner = refiner ?? DictationRefiner("
    )
    let bench = try warmRefineEngineArguments(
        in: "Tests/WhisperCoreTests/ProductionRefineConstruction.swift",
        after: "static func engine() -> WarmRefineEngine {"
    )
    // The extraction found a real argument list, not two empty strings that happen to match.
    #expect(app.contains("primePrompt:"))
    #expect(
        app == bench,
        "DictationController builds WarmRefineEngine(\(app)) but the bench builds WarmRefineEngine(\(bench)). Update ProductionRefineConstruction.engine() to match the app."
    )
}

/// The text between `WarmRefineEngine(` and its matching `)`, after `anchor`, comments stripped
/// and whitespace collapsed: line breaks and indentation carry no meaning in an argument list.
private func warmRefineEngineArguments(in path: String, after anchor: String) throws -> String {
    let start = "WarmRefineEngine("
    let source = try SourceAssertion.uncommentedSource(path)
    let anchored = try #require(source.range(of: anchor), "\(path) no longer contains `\(anchor)`")
    var rest = source[anchored.upperBound...]
    let found = try #require(rest.range(of: start), "\(path): no `\(start)` after `\(anchor)`")
    rest = rest[found.upperBound...]
    var depth = 1
    var cursor = rest.startIndex
    while cursor < rest.endIndex {
        if rest[cursor] == "(" { depth += 1 }
        if rest[cursor] == ")" { depth -= 1 }
        if depth == 0 { break }
        cursor = rest.index(after: cursor)
    }
    try #require(depth == 0, "\(path): `\(start)` after `\(anchor)` is never closed")
    return rest[rest.startIndex..<cursor]
        .split(whereSeparator: \.isWhitespace)
        .joined(separator: " ")
}
