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

/// Every `enum`/`struct`/`class` declaration in one file that lists conformances.
private func declaredTypes(in code: String, file: String) -> [DeclaredType] {
    let characters = Array(code)
    let pattern = #"(?m)^[ \t]*(?:public |internal |fileprivate |private |package )?(?:final )?(?:indirect )?(enum|struct|class) ([A-Za-z_]\w*)\s*:\s*([^{\n]*?)\s*\{"#
    guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
    let whole = NSRange(code.startIndex..., in: code)
    var found: [DeclaredType] = []
    for match in regex.matches(in: code, range: whole) {
        guard let nameRange = Range(match.range(at: 2), in: code),
              let conformanceRange = Range(match.range(at: 3), in: code),
              let matchRange = Range(match.range, in: code) else { continue }
        let openOffset = code.distance(from: code.startIndex, to: code.index(before: matchRange.upperBound))
        let line = code[code.startIndex..<matchRange.lowerBound].filter { $0 == "\n" }.count + 1
        found.append(DeclaredType(
            file: file,
            line: line,
            name: String(code[nameRange]),
            conformances: String(code[conformanceRange]),
            body: balancedBody(characters, from: openOffset)
        ))
    }
    return found
}

private func mentions(_ token: String, in text: String) -> Bool {
    text.range(of: "\\b" + token + "\\b", options: .regularExpression) != nil
}

@Test("Every error type in Sources conforms to LocalizedError and supplies a description (F366)")
func everyErrorTypeCarriesItsOwnSentence() throws {
    var errorTypes: [DeclaredType] = []
    var extensionsByType: [String: [String]] = [:]

    for url in try SourceAssertion.swiftFileURLs(under: "Sources") {
        let raw = try String(contentsOf: url, encoding: .utf8)
        // Literals blanked: brace-walking a declaration's body must not be fooled by a `{` inside
        // a string, and a sentence that happens to contain the word "Error" is not a conformance.
        let code = SourceAssertion.stripComments(raw, blankStringLiterals: true)
        let file = url.lastPathComponent
        for declared in declaredTypes(in: code, file: file) {
            if mentions("Error", in: declared.conformances) || mentions("LocalizedError", in: declared.conformances) {
                errorTypes.append(declared)
            }
        }
        // `extension Foo: LocalizedError { … }` is the other legal place for the conformance and
        // for the property, so the guard has to look there before accusing anyone.
        let extensionPattern = #"(?m)^[ \t]*extension ([A-Za-z_][\w.]*)\b[^{\n]*\{"#
        if let regex = try? NSRegularExpression(pattern: extensionPattern) {
            let characters = Array(code)
            for match in regex.matches(in: code, range: NSRange(code.startIndex..., in: code)) {
                guard let nameRange = Range(match.range(at: 1), in: code),
                      let matchRange = Range(match.range, in: code) else { continue }
                let open = code.distance(from: code.startIndex, to: code.index(before: matchRange.upperBound))
                let name = String(code[nameRange]).split(separator: ".").last.map(String.init) ?? ""
                extensionsByType[name, default: []].append(
                    String(code[matchRange]) + balancedBody(characters, from: open)
                )
            }
        }
    }

    // Anti-vacuity. A regex that stops matching would otherwise turn this guard into a pass, which
    // is the exact failure mode the guard exists to prevent elsewhere.
    #expect(
        errorTypes.count >= 24,
        "the scan found only \(errorTypes.count) error types — it used to find 25, so it is broken, not clean"
    )

    var offenders: [String] = []
    for type in errorTypes {
        let attachments = [type.body] + (extensionsByType[type.name] ?? [])
        let conformancePlaces = [type.conformances] + (extensionsByType[type.name] ?? [])
        if conformancePlaces.contains(where: { mentions("UnsurfacedError", in: $0) }) {
            continue   // declared silent in code, not exempted by a comment — see `UnsurfacedError`
        }
        if !conformancePlaces.contains(where: { mentions("LocalizedError", in: $0) }) {
            offenders.append("\(type.file):\(type.line): \(type.name) conforms to Error but supplies no sentence — add LocalizedError, or declare it silent with UnsurfacedError")
        } else if !attachments.contains(where: { $0.contains("errorDescription") }) {
            // Conforming is not enough: `LocalizedError.errorDescription` defaults to nil, and a
            // nil description falls straight back to the bridge's case-index sentence.
            offenders.append("\(type.file):\(type.line): \(type.name) is LocalizedError with no errorDescription")
        }
    }
    #expect(offenders.isEmpty, "\(offenders.count) error types have no sentence:\n\(offenders.joined(separator: "\n"))")
}

@Test("A recorder failure reads as a sentence, not as a case index (F366)")
func recorderErrorsDoNotRenderAsTheBridgeDefault() {
    for error in [
        MicDictationRecorder.RecorderError.audioFormatUnavailable,
        .notRecording,
        .noAudioCaptured,
    ] {
        let rendered = (error as any Error).localizedDescription
        #expect(!rendered.contains("couldn't be completed"), "\(rendered)")
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
    // trustworthy as the count of who uses it. Two today, both found BY the guard rather than
    // listed for it, and neither has "Error" in its name.
    var silent: [String] = []
    for url in try SourceAssertion.swiftFileURLs(under: "Sources") {
        let code = SourceAssertion.stripComments(try String(contentsOf: url, encoding: .utf8),
                                                 blankStringLiterals: true)
        for declared in declaredTypes(in: code, file: url.lastPathComponent)
        where mentions("UnsurfacedError", in: declared.conformances) {
            silent.append(declared.name)
        }
    }
    #expect(Set(silent) == ["Problem", "ImportRefusal"], "\(silent)")
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
