import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F366 — every error type this app can throw must say what went wrong in a sentence.
//
// Swift bridges any `Error` to `NSError`, so `localizedDescription` always answers something. What
// it answers for a type that supplies no copy is "The operation couldn't be completed.
// (WhisperMeet.MicDictationRecorder.RecorderError error 0.)" — a sentence shaped like an
// explanation that contains none, naming a case *index*. That string was used verbatim as
// user-facing copy and persisted into `dictation-log.json`, so the app's own diagnostics recorded
// the index instead of "no microphone was available".
//
// **The guard is derived, not restated, and that is what found the ticket's premise to be wrong.**
// F366 says `RecorderError` is "the only error type in the app that is not `LocalizedError`" and
// lists ten conforming siblings. It was one of SEVEN that did not. A hand-written list of ten
// would have been written from the same reading that produced the claim — and the derived scan
// also corrected ITSELF: it first accused `DiarizationArtifactError`, whose conformance is in an
// `extension` a few lines below its declaration, which is why the scan reads extensions too.

/// A type declaration found by scanning, with the text of its own body.
private struct DeclaredType {
    let file: String
    let line: Int
    let kind: String
    let name: String
    let conformances: String
    let body: String
}

/// An `extension` found by scanning: the type it extends (last path component), the conformances
/// it adds, and its body.
private struct DeclaredExtension {
    let name: String
    let conformances: String
    let body: String
}

/// `{ … }` starting at `open`, balanced. The source must already have had its string literals
/// blanked, or a `{` inside one would be counted as a scope.
private func balancedBody(_ characters: [Character], from open: Int) -> String {
    var depth = 0
    var index = open
    while index < characters.count {
        if characters[index] == "{" { depth += 1 }
        if characters[index] == "}" {
            depth -= 1
            if depth == 0 { return String(characters[open...index]) }
        }
        index += 1
    }
    return String(characters[open...])
}

// The declaration shapes the scan accepts (F415). Before, it took at most one access modifier, then
// `final`, then `indirect`, with no attribute, no generic clause, no `actor`, and the conformance
// list on the declaration's own line; a type counted only if its own declaration named `Error` or
// `LocalizedError`. So `@frozen public enum X: Error`, `struct Box<T>: Error`, `final public class`,
// a wrapped list, an extension-only conformance and `enum X: AppFailure` (where
// `protocol AppFailure: Error`) were never enumerated, and so never required to carry copy.
private let attributes = #"(?:@[A-Za-z_]\w*(?:\([^)\n]*\))?\s+)*"#
private let modifiers = #"(?:(?:public|internal|fileprivate|private|package|open|final|indirect|nonisolated)\s+)*"#
/// An optional generic clause, an optional conformance list (group `conformances`) and an optional
/// `where` clause, up to the opening brace, across lines.
private let headerTail = #"\s*(?:<[^{]*?>)?\s*(?::\s*(?<conformances>[^{]*?))?\s*(?:\bwhere\b[^{]*?)?\{"#
private let typePattern = #"(?m)^[ \t]*"# + attributes + modifiers
    + #"(?<kind>enum|struct|class|actor|protocol)\s+(?<name>[A-Za-z_]\w*)"# + headerTail
private let extensionPattern = #"(?m)^[ \t]*"# + attributes + modifiers
    + #"extension\s+(?<name>[A-Za-z_][\w.]*)"# + headerTail

private func capture(_ group: String, of match: NSTextCheckingResult, in code: String) -> String {
    Range(match.range(withName: group), in: code).map { String(code[$0]) } ?? ""
}

/// Every `enum`/`struct`/`class`/`actor`/`protocol` declaration in one file, with or without a
/// conformance list, and every `extension`.
private func declarations(in code: String, file: String) -> (types: [DeclaredType], extensions: [DeclaredExtension]) {
    let characters = Array(code)
    let whole = NSRange(code.startIndex..., in: code)
    func openOffset(of match: NSTextCheckingResult) -> Int? {
        guard let range = Range(match.range, in: code) else { return nil }
        return code.distance(from: code.startIndex, to: code.index(before: range.upperBound))
    }
    var types: [DeclaredType] = []
    if let regex = try? NSRegularExpression(pattern: typePattern) {
        for match in regex.matches(in: code, range: whole) {
            guard let open = openOffset(of: match), let range = Range(match.range, in: code) else { continue }
            types.append(DeclaredType(
                file: file,
                line: code[code.startIndex..<range.lowerBound].filter { $0 == "\n" }.count + 1,
                kind: capture("kind", of: match, in: code),
                name: capture("name", of: match, in: code),
                conformances: capture("conformances", of: match, in: code),
                body: balancedBody(characters, from: open)
            ))
        }
    }
    var extensions: [DeclaredExtension] = []
    if let regex = try? NSRegularExpression(pattern: extensionPattern) {
        for match in regex.matches(in: code, range: whole) {
            guard let open = openOffset(of: match) else { continue }
            extensions.append(DeclaredExtension(
                name: capture("name", of: match, in: code).split(separator: ".").last.map(String.init) ?? "",
                conformances: capture("conformances", of: match, in: code),
                body: balancedBody(characters, from: open)
            ))
        }
    }
    return (types, extensions)
}

private func mentions(_ token: String, in text: String) -> Bool {
    text.range(of: "\\b" + token + "\\b", options: .regularExpression) != nil
}

/// `seeds` plus every scanned protocol that refines one of them, transitively.
private func refining(_ seeds: Set<String>, among protocols: [DeclaredType]) -> Set<String> {
    var found = seeds
    var grew = true
    while grew {
        grew = false
        for declared in protocols where !found.contains(declared.name)
            && found.contains(where: { mentions($0, in: declared.conformances) }) {
            found.insert(declared.name)
            grew = true
        }
    }
    return found
}

/// What the error-copy guard decides about a set of files.
private struct ErrorTypeScan {
    /// Every type that conforms to `Error`: in its declaration, in an extension, or through a
    /// protocol that refines it.
    var errorTypes: [DeclaredType] = []
    /// The error types declared silent with `UnsurfacedError`, as sorted `"File.swift: Name"`. This
    /// is the guard's own exemption, so the pin built from it cannot disagree with the guard.
    var silent: [String] = []
    /// Error types with no sentence of their own.
    var offenders: [String] = []
}

/// The guard's whole decision, over `(file name, code)` pairs so a fixture can be fed to it. `code`
/// must already be comment-stripped with its string literals blanked.
private func scanErrorTypes(in files: [(file: String, code: String)]) -> ErrorTypeScan {
    var types: [DeclaredType] = []
    var extensionsByType: [String: [DeclaredExtension]] = [:]
    for (file, code) in files {
        let found = declarations(in: code, file: file)
        types += found.types
        for declared in found.extensions { extensionsByType[declared.name, default: []].append(declared) }
    }
    let protocols = types.filter { $0.kind == "protocol" }
    let silentProtocols = refining(["UnsurfacedError"], among: protocols)
    let localizedProtocols = refining(["LocalizedError"], among: protocols)
    // `UnsurfacedError` refines `Error` by definition, so a fixture need not declare it to count.
    let errorProtocols = refining(
        Set(["Error", "LocalizedError", "CustomNSError", "RecoverableError"]).union(silentProtocols),
        among: protocols
    )

    var scan = ErrorTypeScan()
    for type in types where type.kind != "protocol" {
        // `extension Foo: LocalizedError { … }` is the other legal place for a conformance and for
        // the property, so the guard looks there before accusing anyone.
        let extensions = extensionsByType[type.name] ?? []
        let conformancePlaces = [type.conformances] + extensions.map(\.conformances)
        func conforms(toAnyOf names: Set<String>) -> Bool {
            conformancePlaces.contains { place in names.contains { mentions($0, in: place) } }
        }
        guard conforms(toAnyOf: errorProtocols) else { continue }
        scan.errorTypes.append(type)
        if conforms(toAnyOf: silentProtocols) {
            scan.silent.append("\(type.file): \(type.name)")
            continue   // declared silent in code, not exempted by a comment — see `UnsurfacedError`
        }
        if !conforms(toAnyOf: localizedProtocols) {
            scan.offenders.append("\(type.file):\(type.line): \(type.name) conforms to Error but supplies no sentence — add LocalizedError, or declare it silent with UnsurfacedError")
        } else if !([type.body] + extensions.map(\.body)).contains(where: { $0.contains("errorDescription") }) {
            // Conforming is not enough: `LocalizedError.errorDescription` defaults to nil, and a
            // nil description falls straight back to the bridge's case-index sentence.
            scan.offenders.append("\(type.file):\(type.line): \(type.name) is LocalizedError with no errorDescription")
        }
    }
    scan.silent.sort()
    return scan
}

/// Every Swift file under `Sources/`, comment-stripped with literals blanked: brace-walking a body
/// must not be fooled by a `{` inside a string, and a sentence containing "Error" is not a conformance.
private func sourcesForErrorScan() throws -> [(file: String, code: String)] {
    try SourceAssertion.swiftFileURLs(under: "Sources").map { url in
        (file: url.lastPathComponent,
         code: SourceAssertion.stripComments(try String(contentsOf: url, encoding: .utf8), blankStringLiterals: true))
    }
}

/// Fixture text in the form the scan reads.
private func fixtureFile(_ file: String, _ text: String) -> (file: String, code: String) {
    (file: file, code: SourceAssertion.stripComments(text, blankStringLiterals: true))
}

@Test("Every error type in Sources conforms to LocalizedError and supplies a description (F366)")
func everyErrorTypeCarriesItsOwnSentence() throws {
    let scan = scanErrorTypes(in: try sourcesForErrorScan())

    // Anti-vacuity. A regex that stops matching would otherwise turn this guard into a pass, which
    // is the exact failure mode the guard exists to prevent elsewhere. Measured at F415: 32 error
    // types, 29 with copy and the 3 declared silent, which the scan now counts as error types too.
    #expect(
        scan.errorTypes.count >= 31,
        "the scan found only \(scan.errorTypes.count) error types — it found 32 at F415, so it is broken, not clean"
    )
    #expect(scan.offenders.isEmpty, "\(scan.offenders.count) error types have no sentence:\n\(scan.offenders.joined(separator: "\n"))")
}

@Test("The error-type scan enumerates every declaration shape that can conform to Error (F415)")
func errorTypeScanSeesEveryDeclarationShape() {
    // Every type here but the last two conforms to `Error` and supplies no sentence, so each of
    // those must be enumerated AND reported; the last two must not be. Before F415 the scan saw
    // only `Plain`.
    let scan = scanErrorTypes(in: [fixtureFile("Fixture.swift", """
        struct Box<T>: Error {}
        @frozen public enum Frozen: Error {}
        final public class Reordered: Error {}
        actor Worker: Error {}
        enum Wrapped:
            Equatable,
            Error {}
        enum ExtensionOnly { case a }
        extension ExtensionOnly: Error {}
        protocol AppFailure: Error {}
        enum Refined: AppFailure {}
        enum Plain: Error {}
        enum NotAnError: Equatable {}
        struct ErrorLog { let lines: [String] }
        """)])
    let expected: [String] = ["Box", "ExtensionOnly", "Frozen", "Plain", "Refined", "Reordered", "Worker", "Wrapped"]
    #expect(scan.errorTypes.map(\.name).sorted() == expected)
    #expect(scan.offenders.count == expected.count, "\(scan.offenders)")
}

@Test("A recorder failure reads as a sentence, not as a case index (F366)")
func recorderErrorsDoNotRenderAsTheBridgeDefault() throws {
    // The placeholder's own opening sentence, taken from the bridge rather than typed. Typed, it
    // was "couldn't" with an ASCII apostrophe; Foundation writes U+2019, so the check could never
    // fire (F415). Everything before the parenthetical, in whatever language Foundation renders.
    enum Mute: Error { case only }
    let placeholder = (Mute.only as any Error).localizedDescription
    let opening = try #require(placeholder.range(of: " (", options: .backwards).map { placeholder[..<$0.lowerBound] })
    try #require(!opening.isEmpty, "no sentence before the parenthetical in \(placeholder)")
    for error in [
        MicDictationRecorder.RecorderError.audioFormatUnavailable,
        .notRecording,
        .noAudioCaptured,
    ] {
        let rendered = (error as any Error).localizedDescription
        #expect(!rendered.contains(opening), "\(rendered)")
        #expect(!rendered.contains("RecorderError error"), "\(rendered)")
        #expect(rendered.hasSuffix("."), "user-facing copy is a sentence: \(rendered)")
    }
    #expect(
        MicDictationRecorder.RecorderError.audioFormatUnavailable.localizedDescription
            .localizedCaseInsensitiveContains("microphone")
    )
}

@Test("An error with no copy of its own is given a sentence before it reaches the user (F366)")
func bridgedErrorsAreGivenASentence() {
    // The other half of F366: errors from `engine.start()` are `NSError`s from AVFAudio and reach
    // the same sinks just as opaquely — "com.apple.coreaudio.avfaudio error -10851". Nothing can
    // make AVFAudio write English, so the app supplies the sentence and keeps the raw text for the
    // diagnostic log.
    let avfaudio = NSError(domain: "com.apple.coreaudio.avfaudio", code: -10_851)
    let sentence = ErrorPresentation.sentence(for: avfaudio, fallback: "The microphone could not be started.")
    #expect(sentence == "The microphone could not be started.")
    #expect(ErrorPresentation.diagnostic(for: avfaudio).contains("-10851"))

    // And the other direction, which matters just as much: Cocoa writes real sentences for file
    // errors, so a blanket fallback would have made this function a DOWNGRADE for the commonest
    // error the app sees. Only the bridge's own placeholder is discarded.
    let cocoa = NSError(domain: NSCocoaErrorDomain, code: NSFileWriteNoPermissionError)
    let cocoaSentence = ErrorPresentation.sentence(for: cocoa, fallback: "generic fallback")
    #expect(cocoaSentence != "generic fallback", "Cocoa's own copy was thrown away")
    #expect(!cocoaSentence.contains("NSCocoaErrorDomain error"), "\(cocoaSentence)")

    // And a type that HAS copy keeps it — the fallback must not flatten the ten types that were
    // already doing the right thing.
    let ours = MicDictationRecorder.RecorderError.audioFormatUnavailable
    #expect(ErrorPresentation.sentence(for: ours, fallback: "unused") == ours.errorDescription)
}

@Test("Dictation shows the sentence and logs the raw text (F366)")
func dictationFailuresAreMappedBeforeTheyReachTheUser() throws {
    // The two `catch` blocks are the sinks F366 names: `DictationController.swift:656` renders the
    // string to the user and `:836` persists it. Source-asserted because reaching them needs a
    // real engine failure; the mapping itself is covered by the unit tests above.
    let controller = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/Dictation/DictationController.swift")
    #expect(!controller.contains("fail(error.localizedDescription)"),
            "a bridged NSError's localizedDescription must not be used as user-facing copy")
    #expect(!controller.contains("session.handle(.engineFailed(error.localizedDescription))"))
    // Four sinks, not the two F366 named: the start failure, the transcription failure, the
    // Settings self-test result line — which was rendering `error.localizedDescription` too — and,
    // since F368, the `stop()` failure that is not silence.
    let mapped = controller.components(separatedBy: "ErrorPresentation.sentence(").count - 1
    #expect(mapped == 4, "expected all four user-facing sinks to be mapped, found \(mapped)")
    #expect(controller.contains("ErrorPresentation.diagnostic(for: error)"))
    #expect(!controller.contains("\"✗ \\(error.localizedDescription)\""))
}

@Test("An error that is control flow declares itself silent rather than inventing copy (F366)")
func unsurfacedErrorsAreDeclaredInCode() throws {
    // The guard above skips a type that conforms to `UnsurfacedError`, so the exemption is only as
    // trustworthy as the count of who uses it. Three today, all found BY the guard rather than
    // listed for it, and none has "Error" in its name. The third is F425's
    // `PasteboardSnapshot.Refusal`, a "do not restore the clipboard" reason that only reaches the
    // diagnostic log.
    let silent = scanErrorTypes(in: try sourcesForErrorScan()).silent
    let expected: [String] = [
        "AppModel.swift: ImportRefusal",
        "PasteboardSnapshot.swift: Refusal",
        "WatchedFolderMonitor.swift: Problem",
    ]
    #expect(silent == expected, "\(silent)")
}

@Test("The silent-type pin reports what the guard exempts, extensions and repeated names included (F415)")
func silentPinSeesEveryExemption() {
    let scan = scanErrorTypes(in: [
        fixtureFile("A.swift", "enum Problem: UnsurfacedError {}"),
        fixtureFile("B.swift", "enum NewError: Error {}\nextension NewError: UnsurfacedError {}"),
        fixtureFile("C.swift", "enum Problem: UnsurfacedError {}"),
    ])
    let expected: [String] = ["A.swift: Problem", "B.swift: NewError", "C.swift: Problem"]
    #expect(scan.silent == expected)
    #expect(scan.offenders.isEmpty, "\(scan.offenders)")
}

// MARK: - F391, reported by whisper-9d and confirmed here

@Test("A diagnostic never carries an absolute path into a public log line (F391)")
func diagnosticsAreRedacted() {
    // Reported from a read-only review of `f9e3a79..f3b2e45`, and it is my own regression from
    // F366. `diagnostic(for:)` returns `String(describing: error)` for anything conforming to
    // `LocalizedError`, and `LocalWhisperError.processFailed(String)` carries the helper
    // subprocess's raw stderr — a Python traceback, full of absolute paths — which
    // `DictationController.swift:832` then interpolates at `privacy: .public`.
    //
    // F154 exists to stop exactly that, and `publicLogDescription` is on the same line doing its
    // job while the call I added walks around it.
    let helperFailure = LocalWhisperError.processFailed(
        "Traceback (most recent call last):\n  File \"/Users/someone/Library/Application Support/whisper/run.py\", line 42"
    )
    let diagnostic = ErrorPresentation.diagnostic(for: helperFailure)
    #expect(!diagnostic.contains("/Users/"), "\(diagnostic)")
    #expect(!diagnostic.contains("Application Support"), "\(diagnostic)")
    #expect(diagnostic.contains("<path>"), "the redaction marker must survive: \(diagnostic)")
    // The case name is the useful part and must not be redacted away with the path.
    #expect(diagnostic.contains("processFailed"), "\(diagnostic)")

    // A framework NSError still reports its domain and code, which carry nothing private and are
    // the whole point of the function for that class.
    let avfaudio = NSError(domain: "com.apple.coreaudio.avfaudio", code: -10_851)
    #expect(ErrorPresentation.diagnostic(for: avfaudio).contains("-10851"))
}

@Test("Redaction happens inside the helper, not at its call sites (F391)")
func redactionIsNotLeftToCallers() throws {
    // Four sites call `diagnostic(for:)` today. Redacting at each one is how the fifth caller
    // reintroduces this, so the guarantee lives in the function.
    let source = try SourceAssertion.uncommentedSource("Sources/WhisperCore/ErrorPresentation.swift")
    let body = try #require(source.range(of: "static func diagnostic(for error: any Error) -> String {"))
    let window = source[body.lowerBound...].prefix(600)
    #expect(window.contains("redactPaths"), "\(window)")
}
