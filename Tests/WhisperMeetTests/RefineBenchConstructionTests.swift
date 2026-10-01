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

/// The bench cannot take `DictationRefiner`'s default budget sleep: inside the Swift Testing host
/// that default-argument closure aborts the process when its sleep returns (see
/// `ProductionRefineConstruction.budgetSleep`). So the bench passes its own copy of the closure,
/// and this keeps the copy equal to the default the app gets.
@Test("The refine bench's budget sleep is DictationRefiner's default sleep, as source (F631)")
func refineBenchSleepsAsTheAppsRefinerSleeps() throws {
    let app = try delimitedText(
        in: "Sources/WhisperCore/DictationRefiner.swift",
        after: "sleep: @escaping Sleep = ", opening: "{", closing: "}"
    )
    let bench = try delimitedText(
        in: "Tests/WhisperCoreTests/ProductionRefineConstruction.swift",
        after: "static let budgetSleep: DictationRefiner.Sleep = ", opening: "{", closing: "}"
    )
    #expect(app.contains("Task.sleep"))
    #expect(
        app == bench,
        "DictationRefiner's default sleep is {\(app)} but the bench sleeps with {\(bench)}. Update ProductionRefineConstruction.budgetSleep to match."
    )
}

/// The text between `WarmRefineEngine(` and its matching `)`, after `anchor`, with whitespace
/// collapsed: line breaks and indentation carry no meaning in an argument list.
private func warmRefineEngineArguments(in path: String, after anchor: String) throws -> String {
    try delimitedText(
        in: path, after: anchor, from: "WarmRefineEngine(", opening: "(", closing: ")"
    )
}

/// The text inside the first balanced `opening`…`closing` pair after `anchor` (and after `from`,
/// when given), comments stripped and whitespace collapsed.
private func delimitedText(
    in path: String, after anchor: String, from start: String? = nil,
    opening: Character, closing: Character
) throws -> String {
    let source = try SourceAssertion.uncommentedSource(path)
    let anchored = try #require(source.range(of: anchor), "\(path) no longer contains `\(anchor)`")
    var rest = source[anchored.upperBound...]
    if let start {
        let found = try #require(rest.range(of: start), "\(path): no `\(start)` after `\(anchor)`")
        rest = rest[found.upperBound...]
    } else {
        let found = try #require(rest.firstIndex(of: opening), "\(path): no `\(opening)` after `\(anchor)`")
        rest = rest[rest.index(after: found)...]
    }
    var depth = 1
    var cursor = rest.startIndex
    while cursor < rest.endIndex {
        if rest[cursor] == opening { depth += 1 }
        if rest[cursor] == closing { depth -= 1 }
        if depth == 0 { break }
        cursor = rest.index(after: cursor)
    }
    try #require(depth == 0, "\(path): `\(opening)` after `\(anchor)` is never closed")
    return rest[rest.startIndex..<cursor]
        .split(whereSeparator: \.isWhitespace)
        .joined(separator: " ")
}
