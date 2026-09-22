import Foundation
import Testing

// Repo-wide contracts that no type system enforces, checked as source text because that is the only
// place they are visible. This is the F306/F174 shape — crude, and it would have caught the bug that
// prompted it — generalised from one file to the whole tree, so a NEW audio path cannot reintroduce
// F356 the way the existing one did. The gate already reads Swift source this way in nine
// WhisperMeetTests files; this one just does it for rules rather than for call sites.
//
// Comments are stripped before every check. AGENTS.md records why: in F285 a paragraph explaining a
// regression satisfied the assertion that was supposed to detect it.

private let repositoryRoot = SourceAssertion.repositoryRoot

private struct SwiftFile {
    let path: String
    let lines: [(number: Int, text: String)]
}

/// Every `.swift` file under `Sources/`, comment lines blanked, with 1-based line numbers kept so a
/// failure names the line a person can open.
private func sourceFiles(under directory: String) throws -> [SwiftFile] {
    var files: [SwiftFile] = []
    for url in try SourceAssertion.swiftFileURLs(under: directory) {
        let text = try String(contentsOf: url, encoding: .utf8)
        files.append(SwiftFile(path: url.path.replacingOccurrences(of: repositoryRoot.path + "/", with: ""),
                               lines: SourceAssertion.numbered(SourceAssertion.stripComments(text))))
    }
    #expect(!files.isEmpty, "found no Swift files under \(directory) — this guard would pass vacuously")
    return files
}

// MARK: - F373 (prevention for F356)

@Test("No audio tap anywhere pins a client format (F373, prevention for F356)")
func noTapPinsAClientFormat() throws {
    var offenders: [String] = []
    for file in try sourceFiles(under: "Sources") {
        for line in file.lines where line.text.contains("installTap(") {
            if !line.text.contains("format: nil") {
                offenders.append("\(file.path):\(line.number) — \(line.text.trimmingCharacters(in: .whitespaces))")
            }
        }
    }
    #expect(offenders.isEmpty, """
        installTap must be called with `format: nil`.

        A non-nil format is a claim about the hardware that AVFAudio validates against the live device at
        install time, and it answers a mismatch by RAISING an NSException — which Swift cannot catch, so
        the process aborts. The device can change between reading a format and installing the tap; in
        F356 it did, in both directions, because enabling the input stream is itself what reconfigures
        it. Derive the format from each buffer instead (see DictationTapConverter, and
        AudioCaptureEngine.append which has always done it this way).

        \(offenders.joined(separator: "\n"))
        """)
}

// MARK: - F372

/// What `WhisperCore` is allowed to import. A fail-CLOSED allowlist on purpose: a denylist cannot
/// notice the framework nobody thought of, which is the same reason AGENTS.md's F304 paragraph
/// prefers a derived check to a hand-written list. Four names, and adding a fifth should be a
/// deliberate decision made here rather than an import that slips in unnoticed.
private let whisperCoreAllowedImports: Set<String> = [
    "Foundation", "UniformTypeIdentifiers", "Darwin", "CryptoKit",
]

@Test("WhisperCore stays framework-free (F372)")
func whisperCoreImportsNothingUnexpected() throws {
    var offenders: [String] = []
    for file in try sourceFiles(under: "Sources/WhisperCore") {
        for line in file.lines {
            let text = line.text.trimmingCharacters(in: .whitespaces)
            guard text.hasPrefix("import ") else { continue }
            let module = String(text.dropFirst("import ".count))
                .split(separator: ".").first.map(String.init) ?? ""
            let name = module.trimmingCharacters(in: .whitespaces)
            if !whisperCoreAllowedImports.contains(name) {
                offenders.append("\(file.path):\(line.number) — import \(name)")
            }
        }
    }
    #expect(offenders.isEmpty, """
        WhisperCore must stay free of UI and media frameworks so the pure core is testable without a
        host. SwiftPM does NOT enforce this — AGENTS.md says so explicitly, and until F372 the rule was
        upheld by a grep in the definition of done that did not exist. If an addition is deliberate, add
        it to `whisperCoreAllowedImports` in this file and say why in the ticket.

        \(offenders.joined(separator: "\n"))
        """)
}

// MARK: - F364

/// The fields `AudioCaptureEngine`'s own comment declares queue-protected. Until F364 that sentence
/// was false for two of them, for months, and no test could see it — the claim lives in prose and the
/// violation lives in a declaration twenty lines away. This is the crude check that would have caught
/// it, which is exactly the argument F306 makes.
private let queueProtectedCaptureFields = [
    "stream", "streamError", "streamDied", "restartInProgress", "sessionGeneration",
]

@Test("Every field AudioCaptureEngine calls queue-protected actually is (F364)")
func captureEngineQueueProtectedFieldsHaveAccessors() throws {
    let file = try #require(
        try sourceFiles(under: "Sources/WhisperMeet")
            .first { $0.path.hasSuffix("AudioCaptureEngine.swift") }
    )
    var offenders: [String] = []
    for field in queueProtectedCaptureFields {
        guard file.lines.contains(where: { $0.text.contains("private var _\(field)") }) else {
            offenders.append("_\(field): no `private var _\(field)` storage")
            continue
        }
        // The ACCESSOR's own declaration, not the file at large. The first version of this guard
        // searched the whole source for `captureQueue.sync { _streamDied }` and passed after the
        // protection was deliberately removed, because `captureDidDie` contains that same text —
        // F285's shape, in the check written to prevent F285's shape.
        guard let declaration = file.lines.firstIndex(where: {
            $0.text.contains("private var \(field):") || $0.text.contains("private var \(field) ")
        }) else {
            offenders.append("\(field): no un-prefixed accessor declared")
            continue
        }
        let body = file.lines[declaration..<min(declaration + 6, file.lines.count)]
            .map(\.text).joined(separator: "\n")
        if !body.contains("captureQueue.sync") {
            offenders.append("\(field): its accessor does not go through captureQueue.sync")
        }
    }
    #expect(offenders.isEmpty, """
        AudioCaptureEngine's comment on `_stream` names the fields stored behind `captureQueue`. Each
        needs `_`-prefixed storage AND an un-prefixed accessor whose own body syncs on that queue —
        code already on the queue uses the storage directly, because a `sync` from the queue
        deadlocks.

        \(offenders.joined(separator: "\n"))
        """)
}
