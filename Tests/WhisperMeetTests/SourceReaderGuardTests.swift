import Foundation
import Testing

// F412 — every source assertion in this target reads Swift source through `SourceAssertion`, so a
// comment can never satisfy it.
//
// F375 made `SourceAssertion` the one comment stripper and closed saying every source assertion
// went through it. Four did not, and a fifth arrived afterwards (F456's, with a line-cutting
// stripper of its own that missed `/* */`). All five built the path by hand from `#filePath` and
// read it raw, so the false positive F285 named was open in each: delete a guarded call, leave a
// comment naming it, and the test still passed. A list of "files that read source" would have had
// to be written by someone who already knew about them, which is how the fifth got in, so this
// scans every file in the target for the two shapes a raw read takes.
//
// 1. **A path built from `#filePath`** in a file that names a `Sources/` path. `SourceAssertion`
//    owns the repository root; a test that derives it itself has stepped around the stripper.
//    Scripts and bench clips are read that way legitimately, which is why `#filePath` alone is not
//    a finding.
// 2. **A read through `SourceAssertion.url` that is never stripped.** A `String(contentsOf:)` of a
//    `Sources/` path, of a path held in a variable (it could be anything, so it counts), or of a
//    URL in a file that enumerates `Sources/`, must reach `SourceAssertion.stripComments` in one of
//    three ways: wrapped directly in the call; bound to a name the file later strips; or handed
//    straight to a function in the same file whose body strips.
//
// Only code counts. A `#filePath` or a `String(contentsOf:` is looked for with string literals
// blanked as well as comments removed, so this file's fixtures, and a comment explaining a shape,
// are not findings. The path itself is a literal, so it is read from the comment-stripped text.
//
// What it cannot see: a path assembled some third way (concatenation onto
// `SourceAssertion.repositoryRoot`, say); a read through `Data(contentsOf:)` or
// `FileManager.contents(atPath:)`; and a bound name that is stripped on one path and used raw on
// another. It checks that a read flows into the stripper, not that every use of the text does.

/// One place a test file reads Swift source without `SourceAssertion` stripping its comments.
private struct RawSourceRead: Equatable, CustomStringConvertible {
    enum Shape: String {
        case pathFromFilePath = "builds a repository path from #filePath; use SourceAssertion.uncommentedSource"
        case unstrippedRead = "reads Swift source without SourceAssertion.stripComments"
    }

    let file: String
    let line: Int
    let shape: Shape

    var description: String { "\(file):\(line): \(shape.rawValue)" }
}

private let stripCall = "SourceAssertion.stripComments("
private let urlCall = "SourceAssertion.url("
/// `String(contentsOf:`, allowing the line break some files put after the parenthesis.
private let readPattern = #"String\(\s*contentsOf:\s*"#

private func lineNumber(of index: String.Index, in text: String) -> Int {
    text[..<index].reduce(into: 1) { line, character in if character == "\n" { line += 1 } }
}

private func ranges(of pattern: String, in text: String) -> [Range<String.Index>] {
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    return regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
        .compactMap { Range($0.range, in: text) }
}

/// Capture group 1 of `pattern`, when the pattern matches at the very end of `text`.
private func trailingCapture(_ pattern: String, in text: Substring) -> String? {
    let tail = String(text.suffix(400))
    guard let regex = try? NSRegularExpression(pattern: pattern + #"\s*$"#),
          let match = regex.firstMatch(in: tail, range: NSRange(tail.startIndex..., in: tail)),
          let range = Range(match.range(at: 1), in: tail) else { return nil }
    return String(tail[range])
}

/// Whether the read that starts at `read` flows into `SourceAssertion.stripComments`.
private func readIsStripped(_ read: Range<String.Index>, in code: String) -> Bool {
    var before = code[..<read.lowerBound]
    func trimTrailingSpace() { while before.last?.isWhitespace == true { before = before.dropLast() } }
    trimTrailingSpace()
    if let keyword = ["try?", "try!", "try"].first(where: { before.hasSuffix($0) }) {
        before = before.dropLast(keyword.count)
        trimTrailingSpace()
    }

    // `SourceAssertion.stripComments(try String(contentsOf: …), …)`
    if before.hasSuffix(stripCall) { return true }
    // `let raw = try String(contentsOf: …)`, with `SourceAssertion.stripComments(raw` in the file.
    if let name = trailingCapture(#"\b(?:let|var)\s+([A-Za-z_]\w*)\s*(?::\s*String\s*)?="#, in: before) {
        return code.contains(stripCall + name)
    }
    // `helper(in: try String(contentsOf: …))`, where the body of `func helper(` strips.
    if let function = trailingCapture(#"\b([A-Za-z_]\w*)\(\s*(?:[A-Za-z_]\w*\s*:)?"#, in: before),
       let declaration = code.range(of: "func \(function)("),
       let open = code.range(of: "{", range: declaration.upperBound..<code.endIndex) {
        var depth = 1
        var cursor = open.upperBound
        while cursor < code.endIndex, depth > 0 {
            if code[cursor] == "{" { depth += 1 } else if code[cursor] == "}" { depth -= 1 }
            cursor = code.index(after: cursor)
        }
        return code[open.upperBound..<cursor].contains(stripCall)
    }
    return false
}

/// Every raw read of Swift source in one test file's text, and how many reads were stripped.
private func sourceReads(in text: String, file: String) -> (raw: [RawSourceRead], stripped: Int) {
    let code = SourceAssertion.stripComments(text)                                 // literals kept
    let blanked = SourceAssertion.stripComments(text, blankStringLiterals: true)  // literals emptied
    var raw: [RawSourceRead] = []
    var stripped = 0

    // Shape 1. A `#filePath` inside a literal is blanked, so only a real one is seen.
    if code.contains("\"Sources/") {
        for line in SourceAssertion.numbered(blanked) where line.text.contains("#filePath") {
            raw.append(RawSourceRead(file: file, line: line.number, shape: .pathFromFilePath))
        }
    }

    // Shape 2. The path is read from `code`, where literals survive; whether the read is code at
    // all is decided from `blanked`, which keeps line count. The call contains no literal of its
    // own, so blanking cannot move it to another line.
    func codeLines(_ pattern: String) -> Set<Int> {
        Set(ranges(of: pattern, in: blanked).map { lineNumber(of: $0.lowerBound, in: blanked) })
    }
    let readLinesInCode = codeLines(readPattern)
    // The directory is a literal, so it is read from `code`, and counted only on a line where the
    // call is code.
    let enumerationLines = codeLines(#"swiftFileURLs\(under:"#)
    let enumeratesSources = ranges(of: #"swiftFileURLs\(under:\s*"Sources"#, in: code)
        .contains { enumerationLines.contains(lineNumber(of: $0.lowerBound, in: code)) }
    for read in ranges(of: readPattern, in: code) {
        let line = lineNumber(of: read.lowerBound, in: code)
        guard readLinesInCode.contains(line) else { continue }
        let argument = code[read.upperBound...]
        let readsSwiftSource: Bool
        if argument.hasPrefix(urlCall) {
            let path = argument.dropFirst(urlCall.count)
            // A literal names its target; a name could hold any path, so it counts.
            readsSwiftSource = path.hasPrefix("\"") ? path.dropFirst().hasPrefix("Sources/") : true
        } else {
            let startsWithName = argument.first.map { $0.isLetter || $0 == "_" } ?? false
            readsSwiftSource = enumeratesSources && startsWithName && !argument.hasPrefix("URL(")
        }
        guard readsSwiftSource else { continue }
        if readIsStripped(read, in: code) {
            stripped += 1
        } else {
            raw.append(RawSourceRead(file: file, line: line, shape: .unstrippedRead))
        }
    }
    return (raw, stripped)
}

@Test("Every WhisperMeetTests read of Swift source goes through SourceAssertion's stripper (F412)")
func everySwiftSourceReaderGoesThroughSourceAssertion() throws {
    var examined = 0
    var stripped = 0
    var raw: [RawSourceRead] = []
    for url in try SourceAssertion.swiftFileURLs(under: "Tests/WhisperMeetTests") {
        let scanned = sourceReads(in: try String(contentsOf: url, encoding: .utf8), file: url.lastPathComponent)
        examined += 1
        stripped += scanned.stripped
        raw += scanned.raw
    }
    // Anti-vacuity: an enumeration that returned nothing, or a read pattern that stopped matching,
    // would otherwise make this pass.
    #expect(examined >= 200, "only \(examined) test files were examined")
    #expect(stripped >= 10, "only \(stripped) stripped reads were recognised, so the read pattern is broken")
    #expect(raw.isEmpty, "\(raw.count) raw source reads:\n\(raw.map(\.description).joined(separator: "\n"))")
}

@Test("The source-reader guard names each raw shape it is meant to catch (F412)")
func sourceReaderGuardCatchesEachRawShape() {
    let cases: [(name: String, text: String, expected: [RawSourceRead.Shape])] = [
        ("a hand-built path", #"""
            let url = URL(fileURLWithPath: #filePath).deletingLastPathComponent()
                .appendingPathComponent("Sources/WhisperMeet/AppEntry.swift")
            let text = try String(contentsOf: url, encoding: .utf8)
            """#, [.pathFromFilePath]),
        ("an unwrapped read of a Sources literal", #"""
            let entry = try String(contentsOf: SourceAssertion.url("Sources/WhisperMeet/AppEntry.swift"), encoding: .utf8)
            #expect(entry.contains("model.isRecordingAtRisk"))
            """#, [.unstrippedRead]),
        ("a read split over lines", #"""
            #expect(try String(
                contentsOf: SourceAssertion.url("Sources/WhisperMeet/AppEntry.swift"), encoding: .utf8
            ).contains("model.isRecordingAtRisk"))
            """#, [.unstrippedRead]),
        ("a path in a name, bound and never stripped", #"""
            let raw = try String(contentsOf: SourceAssertion.url(path), encoding: .utf8)
            #expect(raw.contains("x"))
            """#, [.unstrippedRead]),
        ("handed to a function that does not strip", #"""
            private func lines(of text: String) -> [Substring] { text.split(separator: "\n") }
            let found = lines(of: try String(contentsOf: SourceAssertion.url("Sources/A.swift"), encoding: .utf8))
            """#, [.unstrippedRead]),
        ("an enumerated Sources URL, unstripped", #"""
            for url in try SourceAssertion.swiftFileURLs(under: "Sources") {
                let text = try String(contentsOf: url, encoding: .utf8)
                #expect(!text.contains("Int(seconds)"))
            }
            """#, [.unstrippedRead]),
    ]
    for item in cases {
        let found = sourceReads(in: item.text, file: "Fixture.swift").raw.map(\.shape)
        #expect(found == item.expected, "\(item.name): \(found)")
    }
}

@Test("The source-reader guard accepts each way a read reaches the stripper (F412)")
func sourceReaderGuardAcceptsEachStrippedShape() {
    let accepted: [(name: String, text: String)] = [
        ("uncommentedSource", #"""
            let source = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/AppEntry.swift")
            """#),
        ("wrapped directly, over several lines", #"""
            let code = SourceAssertion.stripComments(
                try String(
                    contentsOf: SourceAssertion.url("Sources/WhisperMeet/ContentView.swift"), encoding: .utf8
                ),
                blankStringLiterals: true
            )
            """#),
        ("bound, then stripped", #"""
            for url in try SourceAssertion.swiftFileURLs(under: "Sources") {
                let raw = try String(contentsOf: url, encoding: .utf8)
                let code = SourceAssertion.stripComments(raw, blankStringLiterals: true)
            }
            """#),
        ("handed to a function that strips", #"""
            private func conditions(in rawSource: String) -> [String] {
                let source = SourceAssertion.stripComments(rawSource, blankStringLiterals: true)
                return [source]
            }
            let found = conditions(in: try String(contentsOf: SourceAssertion.url("Sources/A.swift"), encoding: .utf8))
            """#),
        ("a script, not Swift source", #"""
            let build = try String(contentsOf: SourceAssertion.url("Scripts/build-app.sh"), encoding: .utf8)
            """#),
        ("#filePath for a bench clip, in a file that names no Sources path", #"""
            let clip = URL(fileURLWithPath: #filePath).appendingPathComponent("Scripts/bench/clips/en1.wav")
            """#),
        ("both shapes, only inside a comment and a literal", #"""
            // let url = URL(fileURLWithPath: #filePath).appendingPathComponent("Sources/A.swift")
            let message = "never String(contentsOf: SourceAssertion.url(\"Sources/A.swift\")) raw"
            """#),
    ]
    for item in accepted {
        let found = sourceReads(in: item.text, file: "Fixture.swift").raw
        #expect(found.isEmpty, "\(item.name): \(found)")
    }
}
