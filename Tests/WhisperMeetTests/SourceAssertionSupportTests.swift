import Foundation
import Testing

// F375 — the stripper the repo's source assertions rest on, tested for the first time.
//
// Eight copies of it existed and none had a test. Each stripped only lines whose first non-space
// characters are `//`, which leaves F285's false positive half-open: the point of stripping is that
// prose about a symbol must not satisfy a `contains` check for that symbol, and a trailing comment
// is prose on a code line.
//
// The two directions matter equally and pull against each other. Strip too little and a comment
// vouches for code that does not exist; strip too much and a `//` inside a string literal — this
// codebase has URLs, shell fragments and regexes in string literals — silently truncates a real
// line, which would make an assertion fail for a reason nobody could find.

@Test("A trailing comment no longer satisfies a contains check (F375)")
func trailingCommentsAreStripped() {
    let source = """
        input.installTap(onBus: 0, bufferSize: 1_024, format: nil)   // format: someHardwareFormat
        """
    let stripped = SourceAssertion.stripComments(source)
    #expect(stripped.contains("format: nil"))
    #expect(!stripped.contains("someHardwareFormat"), "the whole reason to strip: \(stripped)")
}

@Test("A block comment no longer satisfies a contains check, and nesting is followed (F375)")
func blockCommentsAreStripped() {
    let source = """
        let a = 1 /* model.rebuildLibraryFromFolders(confirmed: true) */ + 2
        /* outer /* inner mentions performSourceRebuild */ still inside */ let b = 3
        """
    let stripped = SourceAssertion.stripComments(source)
    #expect(stripped.contains("let a = 1"))
    #expect(stripped.contains("let b = 3"), "a nested close must not end the outer block early")
    #expect(!stripped.contains("rebuildLibraryFromFolders"))
    #expect(!stripped.contains("performSourceRebuild"))
}

@Test("A full-line comment is still blanked, which is the behaviour that already existed (F375)")
func fullLineCommentsAreStillStripped() {
    let source = """
        // This paragraph explains why requestSourceRebuild was deleted.
            /// And this doc comment mentions requestSourceRebuild too.
        let kept = 1
        """
    let stripped = SourceAssertion.stripComments(source)
    #expect(!stripped.contains("requestSourceRebuild"))
    #expect(stripped.contains("let kept = 1"))
}

@Test("A slash-slash inside a string literal survives (F375)")
func stringLiteralsAreNotTreatedAsComments() {
    let source = #"""
        let endpoint = "https://example.com/path"
        let glob = "Scripts/tests/test_*.py"
        let blockish = "a /* not a comment */ b"
        let escaped = "he said \"https://quoted\" and stopped"
        """#
    let stripped = SourceAssertion.stripComments(source)
    #expect(stripped.contains("https://example.com/path"), "a URL is not a comment: \(stripped)")
    #expect(stripped.contains("/* not a comment */"))
    #expect(stripped.contains("https://quoted"), "an escaped quote must not end the literal early")
    #expect(stripped.contains("let glob"))
}

@Test("Multiline and raw string literals survive intact (F375)")
func multilineAndRawLiteralsAreNotTreatedAsComments() {
    // Written with a raw delimiter here so the fixture's own quotes stay literal.
    let source = #"""
        let banner = """
            see https://whispermeet.example for details
            """
        let pattern = #"^// not a comment$"#
        let after = 1
        """#
    let stripped = SourceAssertion.stripComments(source)
    #expect(stripped.contains("https://whispermeet.example"))
    #expect(stripped.contains("^// not a comment$"), "a raw literal's contents are not code: \(stripped)")
    #expect(stripped.contains("let after = 1"), "the raw literal must close, or everything after it is eaten")
}

@Test("Line count is preserved, so a reported line number is still openable (F375)")
func lineCountSurvivesStripping() {
    let source = """
        let a = 1
        // a comment line
        /* a block
           spanning
           three lines */
        let b = 2
        """
    let stripped = SourceAssertion.stripComments(source)
    #expect(stripped.split(separator: "\n", omittingEmptySubsequences: false).count == 6)
    let lines = SourceAssertion.numbered(stripped)
    #expect(lines.last?.number == 6)
    #expect(lines.last?.text.contains("let b = 2") == true)
}

@Test("An unterminated block comment eats the rest of the file rather than reopening code (F375)")
func unterminatedBlockCommentDoesNotResurrectCode() {
    // Not a case any real file should hit — it would not compile — but the stripper must fail in
    // the safe direction: a source assertion that becomes *weaker* on malformed input is the
    // failure mode worth pinning, because a weaker assertion passes silently.
    let stripped = SourceAssertion.stripComments("let a = 1\n/* opened and never closed\nrequestSourceRebuild()\n")
    #expect(stripped.contains("let a = 1"))
    #expect(!stripped.contains("requestSourceRebuild"))
}

@Test("The stripper leaves the real tree's code intact, not just the fixtures above (F375)")
func theStripperDoesNotEatRealSourceFiles() throws {
    // The fixtures are small and hand-made; a stripper can pass all of them and still swallow a
    // real file whole on one unbalanced delimiter. That failure would be silent, because every
    // source assertion in this suite checks for the ABSENCE of offenders or the presence of a
    // handful of symbols, and an empty string has no offenders.
    //
    // Two of the biggest files in the tree, checked for symbols that are unambiguously code.
    for path in ["Sources/WhisperMeet/ContentView.swift", "Sources/WhisperMeet/AppModel.swift"] {
        let raw = try String(contentsOf: SourceAssertion.url(path), encoding: .utf8)
        let stripped = SourceAssertion.stripComments(raw)
        #expect(
            stripped.count * 2 > raw.count,
            "\(path) lost more than half its characters to comment stripping — \(stripped.count) of \(raw.count)"
        )
        #expect(SourceAssertion.numbered(stripped).count == SourceAssertion.numbered(raw).count)
    }
    let view = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/ContentView.swift")
    #expect(view.contains("struct ContentView"))
    #expect(view.contains("var body: some View"))
    let model = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/AppModel.swift")
    #expect(model.contains("final class AppModel"))
    #expect(model.contains("func performStartupRecovery() async"))
}

@Test("Blanking literals keeps their delimiters, their newlines, and nothing else (F366's guard needs it)")
func literalsCanBeBlankedForStructuralScans() {
    let source = #"""
        let a = "a { brace } in a string"
        let b = """
            another { brace }
            """
        struct Thing { let x = 1 }
        """#
    let blanked = SourceAssertion.stripComments(source, blankStringLiterals: true)
    #expect(!blanked.contains("brace"), "a scan that walks braces must not see literal contents: \(blanked)")
    #expect(blanked.contains("struct Thing { let x = 1 }"))
    // Line count survives, so an offender reported by line number is still findable.
    #expect(SourceAssertion.numbered(blanked).count == SourceAssertion.numbered(source).count)
    // And the default keeps them, because most checks want the literal.
    #expect(SourceAssertion.stripComments(source).contains("a { brace } in a string"))
}
