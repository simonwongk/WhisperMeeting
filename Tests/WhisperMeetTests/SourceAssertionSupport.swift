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
/// This is one copy. **Step 1 of F375 is extraction with no behaviour change**: `stripComments`
/// below is, deliberately, the same full-line rule the eight copies used. The improvement is a
/// separate commit so that a change in what the stripper accepts shows up on its own, rather than
/// arriving inside a refactor where a newly-failing assertion would look like a merge accident.
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

    /// Blanks comment lines, preserving line count.
    ///
    /// **This is the old rule, on purpose.** It strips a line whose first non-space characters are
    /// `//` and nothing else — so a trailing comment and a `/* */` block both survive, and both can
    /// still satisfy a `contains` check they were never meant to. F375 replaces this in its own
    /// commit; until then the eight call sites keep exactly the behaviour they had.
    static func stripComments(_ source: String) -> String {
        source.split(separator: "\n", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces).hasPrefix("//") ? "" : String($0) }
            .joined(separator: "\n")
    }
}
