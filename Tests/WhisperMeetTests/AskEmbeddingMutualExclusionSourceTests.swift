import Foundation
import Testing

// F440 part 2 — installSummarizer() and installAskEmbeddingModel() both write into
// Runtime/Summarizer/embedding-model (the former by swapping the whole Summarizer/ directory, the
// latter by downloading into it), and were not mutually exclusive: isInstallingAnyRuntime omitted
// isInstallingAskEmbeddings, so a concurrent run of the other could start while one was mid-swap or
// mid-download.
//
// Not exercised end to end: installAskEmbeddingModel() resolves the REAL
// Scripts/setup-ask-embeddings.sh via `developmentScriptURL` (it finds this checkout's copy from a
// test binary the same way it would from a debug build) and, once its guard passes, launches it as
// a real subprocess against LocalWhisperRuntime.managedDirectory() — the real
// `~/Library/Application Support/WhisperMeet/Runtime` unless overridden, which this repo's rules
// forbid a test from touching. `isInstallingAskEmbeddings` is also `private(set)`, so no test in
// this module can force it to `true` to observe the OTHER guard refusing. A source assertion is the
// deliberate substitute here (the WhisperMeet target has no view-render harness either, and this is
// the same shape of problem): comments are stripped first (F285's own lesson) so a paragraph
// describing the fix can never satisfy the check meant to require it.

private func body(ofDeclarationContaining marker: String, in source: String) throws -> String {
    guard let markerRange = source.range(of: marker) else {
        Issue.record("could not find \(marker.debugDescription) in AppModel.swift; did it move?")
        return ""
    }
    guard let openBrace = source.range(of: "{", range: markerRange.upperBound..<source.endIndex) else {
        Issue.record("no opening brace found after \(marker.debugDescription)")
        return ""
    }
    var depth = 1
    var cursor = openBrace.upperBound
    while cursor < source.endIndex, depth > 0 {
        if source[cursor] == "{" { depth += 1 } else if source[cursor] == "}" { depth -= 1 }
        cursor = source.index(after: cursor)
    }
    return String(source[openBrace.upperBound..<cursor])
}

@Test("isInstallingAnyRuntime covers the Ask embedding install too (F440)")
func isInstallingAnyRuntimeCoversAskEmbeddings() throws {
    let source = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/AppModel.swift")
    let propertyBody = try body(ofDeclarationContaining: "var isInstallingAnyRuntime: Bool", in: source)
    #expect(!propertyBody.isEmpty)
    #expect(
        propertyBody.contains("isInstallingAskEmbeddings"),
        """
        isInstallingAnyRuntime must include isInstallingAskEmbeddings, or installSummarizer() \
        can start while the Ask embedding model is mid-download into the same directory it swaps
        """
    )
}

@Test("installAskEmbeddingModel refuses via the shared isInstallingAnyRuntime guard, not just its own flag (F440)")
func installAskEmbeddingModelUsesTheSharedGuard() throws {
    let source = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/AppModel.swift")
    let functionBody = try body(ofDeclarationContaining: "func installAskEmbeddingModel()", in: source)
    #expect(!functionBody.isEmpty)
    guard let guardRange = functionBody.range(of: "guard ") else {
        Issue.record("installAskEmbeddingModel() has no leading guard at all")
        return
    }
    let guardLine = functionBody[guardRange.lowerBound...].prefix { $0 != "\n" }
    #expect(
        guardLine.contains("isInstallingAnyRuntime"),
        """
        installAskEmbeddingModel()'s first guard must read isInstallingAnyRuntime (which now \
        includes isInstallingAskEmbeddings), not only its own flag, or a summarizer repair can \
        start mid-download and vice versa: \(guardLine)
        """
    )
}
