import Foundation
import Testing

/// F718 — no public WhisperCore declaration has a closure in a default argument.
///
/// A public default argument is compiled into every module that uses it. When it holds a closure,
/// each of those modules compiles its own copy of the closure. For an async closure, each copy also
/// has its own async context size, kept in a record that is a separate symbol from the body. At
/// `-Onone` those sizes disagreed for `DictationRefiner.init`'s default sleep: 144 bytes in
/// WhisperCore, 128 in its clients. The debug link paired WhisperCore's body with a client's
/// record, and the process aborted when the sleep returned. Nothing at a call site shows this, and
/// whether a link pairs the copies badly depends on the link. So the regression test
/// (`refinerBuiltWithTheDefaultSleepSurvivesItsBudgetSleep`) covers only the one site it drives,
/// and this check covers the shape instead. The way out is an optional parameter that defaults to
/// `nil`, with the closure in the body, where it is compiled once.
///
/// What this cannot see: a default that names a function instead of writing a closure
/// (`= ThrowingFileHandleIO.write`). Such a default is also copied into clients, as an implicit
/// closure, and could carry the same risk if the function were async. Telling that apart needs
/// type information, which a source check does not have.
@Test("No public declaration in WhisperCore has a closure in a default argument (F718)")
func whisperCorePublicDefaultArgumentsHoldNoClosure() throws {
    let root = SourceAssertion.repositoryRoot.path + "/"
    let files = try SourceAssertion.swiftFileURLs(under: "Sources/WhisperCore")
        .sorted { $0.path < $1.path }
    try #require(files.count > 10, "found only \(files.count) Swift files under Sources/WhisperCore")
    var publicDefaults = 0
    var offenders: [String] = []
    for file in files {
        let source = SourceAssertion.stripComments(
            try String(contentsOf: file, encoding: .utf8), blankStringLiterals: true
        )
        let path = file.path.hasPrefix(root) ? String(file.path.dropFirst(root.count)) : file.path
        for parameter in PublicDefaultArgumentScan.parameters(in: source) {
            publicDefaults += 1
            if parameter.defaultValue.contains("{") {
                offenders.append("\(path):\(parameter.line): \(parameter.text)")
            }
        }
    }
    // The scan found real public defaults, so an empty offender list is a finding, not a blind scan.
    #expect(publicDefaults > 20, "the scan found only \(publicDefaults) public default arguments")
    #expect(
        offenders == [],
        "A public default argument with a closure is copied into every module that uses it: take an optional that defaults to nil and put the closure in the body. \(offenders)"
    )
}

@Test("The default-argument scan finds a closure in a public default and nowhere else (F718)")
func publicDefaultArgumentScanSeesOnlyClientVisibleClosures() {
    func offenders(_ source: String) -> [String] {
        PublicDefaultArgumentScan.parameters(in: SourceAssertion.stripComments(source, blankStringLiterals: true))
            .filter { $0.defaultValue.contains("{") }
            .map(\.text)
    }
    // The shape F718 fixed, and its replacement.
    #expect(offenders("""
    public actor R {
        public init(
            engine: any E,
            sleep: @escaping Sleep = { try await Task.sleep(for: $0) }
        ) {}
    }
    """) == ["sleep: @escaping Sleep = { try await Task.sleep(for: $0) }"])
    #expect(offenders("""
    public actor R {
        public init(engine: any E, sleep: Sleep? = nil) {
            self.sleep = sleep ?? { try await Task.sleep(for: $0) }
        }
    }
    """) == [])
    // A trailing closure inside a default value is still a closure in the default.
    #expect(offenders("public func f(handler: H = H { _ in }, count: Int = 1) {}") == ["handler: H = H { _ in }"])
    // Generic and function types do not split a parameter, and `->` does not close a `<`.
    #expect(offenders("public func g<T>(map: [String: (Int) -> T] = [:], done: @escaping (Int, String) -> Void = { _, _ in }) {}")
        == ["done: @escaping (Int, String) -> Void = { _, _ in }"])
    // Members of a public extension are public without saying so; members of a public type are not.
    #expect(offenders("public extension P { func h(x: @escaping () -> Void = {}) {} }") == ["x: @escaping () -> Void = {}"])
    #expect(offenders("public struct S { func h(x: @escaping () -> Void = {}) {} }") == [])
    // Not visible to a client module, so never copied into one.
    #expect(offenders("final class C { init(process: Process, willRun: @escaping () -> Void = {}) {} }") == [])
    #expect(offenders("public struct S { private func run(onProgress: @escaping P = { _ in }) {} }") == [])
    // A local function inside a public method is not public.
    #expect(offenders("public extension P { func h() { func local(x: () -> Void = {}) {} } }") == [])
    // A brace in a string literal in a default is not a closure.
    #expect(offenders(#"public func k(label: String = "{") {}"#) == [])
    // A comment is not code (F285).
    #expect(offenders("public func m(x: Int = 1 /* = { } */) {} // = { }") == [])
}

/// Finds the parameters with a default value on declarations another module can call: those
/// marked `public`, `open` or `package`, and those with no access modifier directly inside a
/// `public extension`. Expects source with comments stripped and string literals blanked, so that
/// every brace and parenthesis it counts is code.
enum PublicDefaultArgumentScan {
    struct Parameter: Equatable {
        let line: Int
        /// The whole parameter, whitespace collapsed.
        let text: String
        /// What follows its top-level `=`.
        let defaultValue: String
    }

    static func parameters(in source: String) -> [Parameter] {
        let characters = Array(source)
        var found: [Parameter] = []
        // For each open `{`: whether it opened a `public extension`.
        var scopes: [Bool] = []
        var statementStart = 0
        var index = 0
        while index < characters.count {
            let character = characters[index]
            if character == "{" {
                let header = String(characters[statementStart..<index])
                scopes.append(header.range(of: #"(^|\s)public\s+extension\s"#, options: .regularExpression) != nil)
                statementStart = index + 1
                index += 1
                continue
            }
            if character == "}" {
                if !scopes.isEmpty { scopes.removeLast() }
                statementStart = index + 1
                index += 1
                continue
            }
            if character == ";" { statementStart = index + 1 }
            if let open = parameterClauseStart(in: characters, at: index),
               let close = matchingParenthesis(in: characters, from: open) {
                if isClientVisible(
                    declarationAt: index, statementStart: statementStart, in: characters,
                    insidePublicExtension: scopes.last ?? false
                ) {
                    found += defaultedParameters(in: characters, from: open + 1, to: close)
                }
                // Skip the clause, so a closure in a default never counts as a scope.
                index = close + 1
                continue
            }
            index += 1
        }
        return found
    }

    /// The index of the `(` that opens a parameter clause, when a `func`, `init` or `subscript`
    /// keyword starts at `index`. An operator's name can contain `=` (`static func ==`), so only a
    /// `{` or `;` before the `(` means this was not a declaration with parameters.
    private static func parameterClauseStart(in characters: [Character], at index: Int) -> Int? {
        let first = characters[index]
        guard first == "f" || first == "i" || first == "s" else { return nil }
        if index > 0, isIdentifier(characters[index - 1]) || characters[index - 1] == "." { return nil }
        for keyword in ["func", "init", "subscript"] {
            let word = Array(keyword)
            let after = index + word.count
            guard after < characters.count,
                  word.indices.allSatisfy({ characters[index + $0] == word[$0] }),
                  !isIdentifier(characters[after]) else { continue }
            var cursor = after
            while cursor < characters.count {
                switch characters[cursor] {
                case "(": return cursor
                case "{", ";": return nil
                default: cursor += 1
                }
            }
            return nil
        }
        return nil
    }

    private static func matchingParenthesis(in characters: [Character], from open: Int) -> Int? {
        var depth = 0
        var cursor = open
        while cursor < characters.count {
            if characters[cursor] == "(" { depth += 1 }
            if characters[cursor] == ")" {
                depth -= 1
                if depth == 0 { return cursor }
            }
            cursor += 1
        }
        return nil
    }

    /// The modifiers before the keyword decide: those on its own line, after the last `{`, `}` or
    /// `;`. With none, a member directly inside a `public extension` is public.
    private static func isClientVisible(
        declarationAt index: Int, statementStart: Int, in characters: [Character],
        insidePublicExtension: Bool
    ) -> Bool {
        var lineStart = index
        while lineStart > 0, characters[lineStart - 1] != "\n" { lineStart -= 1 }
        let modifiers = Set(
            String(characters[max(lineStart, statementStart)..<index])
                .split(whereSeparator: { !$0.isLetter })
                .map(String.init)
        )
        if !modifiers.isDisjoint(with: ["private", "fileprivate", "internal"]) { return false }
        if !modifiers.isDisjoint(with: ["public", "open", "package"]) { return true }
        return insidePublicExtension
    }

    private static func defaultedParameters(in characters: [Character], from start: Int, to end: Int) -> [Parameter] {
        var parameters: [Parameter] = []
        var depth = 0
        var angles = 0
        var partStart = start
        var equals: Int?
        func finish(at cursor: Int) {
            if let equals {
                let collapse = { (range: Range<Int>) in
                    String(characters[range]).split(whereSeparator: \.isWhitespace).joined(separator: " ")
                }
                let line = characters[0..<partStart].filter { $0 == "\n" }.count + 1
                    + characters[partStart..<cursor].prefix(while: \.isWhitespace).filter { $0 == "\n" }.count
                parameters.append(Parameter(
                    line: line, text: collapse(partStart..<cursor), defaultValue: collapse((equals + 1)..<cursor)
                ))
            }
        }
        var cursor = start
        while cursor < end {
            let character = characters[cursor]
            switch character {
            case "(", "[", "{": depth += 1
            case ")", "]", "}": depth -= 1
            case "<" where depth == 0 && equals == nil: angles += 1
            case ">" where depth == 0 && equals == nil && angles > 0 && characters[cursor - 1] != "-": angles -= 1
            case "=" where depth == 0 && angles == 0 && equals == nil:
                let next = cursor + 1 < end ? characters[cursor + 1] : " "
                let previous = characters[cursor - 1]
                if next != "=", previous != "=", previous != "!", previous != "<", previous != ">" { equals = cursor }
            case "," where depth == 0 && angles == 0:
                finish(at: cursor)
                partStart = cursor + 1
                equals = nil
            default: break
            }
            cursor += 1
        }
        finish(at: end)
        return parameters
    }

    private static func isIdentifier(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }
}
