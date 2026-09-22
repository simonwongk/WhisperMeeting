import Foundation

/// Shared support for the repo's source assertions (F375).
///
/// The `WhisperMeet` target has no view-render harness (F174's standing reason), so a handful of
/// contracts are checkable only as source text: that a view calls a model method, that a new audio
/// path does not reintroduce a fixed bug, that a marker is never read to make a decision. F306
/// established the pattern and F285 established its one sharp edge — a paragraph *explaining* a
/// regression satisfied the `contains` check meant to detect it — so every such check strips
/// comments first.
///
/// That stripper was then copied into eight files. Each copy strips only lines whose first
/// non-space characters are `//`, so the blind spot F285 named is half-open in all eight: a
/// trailing `// format: nil` on a code line, or a `/* */` block, still satisfies a `contains`
/// check. Improving it meant editing eight files, which is why nobody did.
///
/// This is one copy, and it strips what the eight did not: a trailing `//`, a `/* */` block, and
/// nested blocks. `SourceAssertionSupportTests` is the first test any version of this helper has
/// had, and it pins both directions — comments must not satisfy a check, and a `//` inside a
/// string literal must not truncate a real line.
enum SourceAssertion {
    /// The repository root, derived from this file's own location.
    static let repositoryRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // WhisperMeetTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // repository root

    static func url(_ repositoryRelativePath: String) -> URL {
        repositoryRoot.appendingPathComponent(repositoryRelativePath)
    }

    /// One Swift file's text with its comments removed, ready for `contains` checks.
    static func uncommentedSource(_ repositoryRelativePath: String) throws -> String {
        stripComments(try String(contentsOf: url(repositoryRelativePath), encoding: .utf8))
    }

    /// The same text as 1-based numbered lines, so a failure can name a line somebody can open.
    /// Line count is preserved: a stripped line becomes empty rather than disappearing.
    static func uncommentedLines(_ repositoryRelativePath: String) throws -> [(number: Int, text: String)] {
        numbered(try uncommentedSource(repositoryRelativePath))
    }

    /// Every `.swift` file under a repo-relative directory, in enumeration order.
    static func swiftFileURLs(under repositoryRelativeDirectory: String) throws -> [URL] {
        let root = url(repositoryRelativeDirectory)
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil) else {
            return []
        }
        return enumerator.compactMap { $0 as? URL }.filter { $0.pathExtension == "swift" }
    }

    static func numbered(_ source: String) -> [(number: Int, text: String)] {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .enumerated()
            .map { (number: $0.offset + 1, text: String($0.element)) }
    }

    /// Removes Swift comments, preserving line count so a reported line number still opens the
    /// right line.
    ///
    /// A single left-to-right pass with three states: code, inside a `/* */` block (nesting
    /// counted, because Swift's nest), and inside a string literal (copied out verbatim). The
    /// literal state is not a nicety — this tree has URLs, glob patterns and regexes in string
    /// literals, and treating the `//` in `"https://…"` as a comment would delete the rest of a
    /// real line and make an assertion fail for a reason nobody could locate.
    ///
    /// Two deliberate choices at the edges:
    ///
    /// - An **unterminated** block comment swallows the rest of the file. That is the safe
    ///   direction: the alternative is a stripper that hands back code it should have hidden, and
    ///   a source assertion that gets *weaker* on malformed input passes silently.
    /// - **Bare regex literals** (`/.../`, Swift 5.7) are not recognised. One containing `//`
    ///   would be truncated. There are none in this tree; if one arrives, its test fails loudly
    ///   rather than silently, because the symbol it was looking for goes missing.
    ///
    /// `blankStringLiterals` additionally empties every literal's contents, keeping its delimiters
    /// and its newlines. A `contains` check wants literals kept — a URL or a glob is often the
    /// thing being asserted — but a check that walks braces to find a declaration's body wants
    /// them gone, because a `{` inside a literal is not a scope.
    static func stripComments(_ source: String, blankStringLiterals: Bool = false) -> String {
        let characters = Array(source)
        var output = String()
        output.reserveCapacity(characters.count)
        var index = 0
        var blockDepth = 0

        /// `#`-delimited raw literals take no escapes and close on `"` + the same number of `#`.
        func copyStringLiteral(openedAt start: Int) -> Int {
            var cursor = start
            var hashes = 0
            while cursor < characters.count, characters[cursor] == "#" { hashes += 1; cursor += 1 }
            guard cursor < characters.count, characters[cursor] == "\"" else {
                // A `#` that begins no literal — `#expect`, `#filePath`. Emit it and move on.
                output.append(characters[start])
                return start + 1
            }
            var quotes = 0
            while cursor < characters.count, characters[cursor] == "\"", quotes < 3 {
                quotes += 1; cursor += 1
            }
            // `""` is an empty literal, not the opening of a multiline one.
            let delimiter = quotes == 3 ? "\"\"\"" : "\""
            if quotes == 2 {
                output.append(contentsOf: characters[start..<cursor])
                return cursor
            }
            output.append(contentsOf: characters[start..<cursor])
            while cursor < characters.count {
                if hashes == 0, characters[cursor] == "\\", cursor + 1 < characters.count {
                    if !blankStringLiterals {
                        output.append(characters[cursor]); output.append(characters[cursor + 1])
                    }
                    cursor += 2
                    continue
                }
                if characters[cursor] == "\"" {
                    var closing = 0
                    while cursor + closing < characters.count,
                          characters[cursor + closing] == "\"",
                          closing < delimiter.count { closing += 1 }
                    if closing == delimiter.count {
                        var trailing = 0
                        while cursor + closing + trailing < characters.count,
                              characters[cursor + closing + trailing] == "#",
                              trailing < hashes { trailing += 1 }
                        if trailing == hashes {
                            let end = cursor + closing + trailing
                            output.append(contentsOf: characters[cursor..<end])
                            return end
                        }
                    }
                }
                if !blankStringLiterals || characters[cursor] == "\n" {
                    output.append(characters[cursor])
                }
                cursor += 1
            }
            return cursor
        }

        while index < characters.count {
            let character = characters[index]
            if blockDepth > 0 {
                if character == "/", index + 1 < characters.count, characters[index + 1] == "*" {
                    blockDepth += 1; index += 2; continue
                }
                if character == "*", index + 1 < characters.count, characters[index + 1] == "/" {
                    blockDepth -= 1; index += 2; continue
                }
                // Newlines are kept so line numbers do not shift under a multi-line block.
                if character == "\n" { output.append(character) }
                index += 1
                continue
            }
            if character == "/", index + 1 < characters.count {
                if characters[index + 1] == "/" {
                    while index < characters.count, characters[index] != "\n" { index += 1 }
                    continue   // the newline itself is emitted by the next iteration
                }
                if characters[index + 1] == "*" { blockDepth = 1; index += 2; continue }
            }
            if character == "\"" || character == "#" {
                index = copyStringLiteral(openedAt: index)
                continue
            }
            output.append(character)
            index += 1
        }
        return output
    }
}
