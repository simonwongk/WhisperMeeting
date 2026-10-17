import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F383 — F366 routed the dictation sinks through `ErrorPresentation`, and left about a hundred other
// `localizedDescription` reads alone. Every error this repo declares carries a sentence, so most of
// those read well; the ones that do not are the sites a FRAMEWORK error can reach with no copy of
// its own, where the bridge's "The operation couldn't be completed. (OSStatus error -10868.)"
// went straight into an alert.
//
// Classifying the sites one by one would be a hand list, and a hand list is how F366's premise was
// wrong in the first place. So the guard is derived: no `localizedDescription` read anywhere in
// `Sources/` except `ErrorPresentation` itself and the one log formatter, and every site goes
// through `ErrorPresentation.readable`, which returns `localizedDescription` unchanged whenever it
// is real copy. The two app-level tests drive real sites with a mute framework error.

/// A framework error with no copy: Foundation renders it "(OSStatus error -10868.)".
private let muteFrameworkError = NSError(domain: NSOSStatusErrorDomain, code: -10_868)

@MainActor
private func makeModel() throws -> AppModel {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("F383-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(),
                         defaults: UserDefaults(suiteName: testSuiteName())!)
    model.findWhisperExecutable = { nil }
    model.checkQwenInstalled = { false }
    return model
}

private func makeRecordingFile() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("F383Source-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent("call.wav")
    try WAVWriter.wavData(from: [Float](repeating: 0.05, count: 3_200), sampleRate: 16_000).write(to: url)
    return url
}

@MainActor
@Test("An import refused by a framework error with no copy says so in a sentence, not the bridge's case number (F383)")
func importFailureWithAMuteFrameworkErrorReadsAsASentence() async throws {
    let model = try makeModel()
    defer { try? FileManager.default.removeItem(at: model.store.rootDirectory) }
    let file = try makeRecordingFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    model.copyRecordingIntoLibrary = { _, _ in throw muteFrameworkError }

    let imported = await model.importRecordings(from: [file], title: "").firstID

    #expect(imported == nil)
    let message = try #require(model.alertMessage)
    #expect(message.hasPrefix("The recording could not be imported: "), "\(message)")
    #expect(!message.contains("(OSStatus error"), "the bridge's placeholder reached the alert: \(message)")
    #expect(message.contains(ErrorPresentation.undescribedFallback(domain: NSOSStatusErrorDomain, code: -10_868)),
            "\(message)")
}

@MainActor
@Test("The same import keeps Foundation's own sentence when the framework wrote one (F383 control)")
func importFailureKeepsFoundationsOwnSentence() async throws {
    let model = try makeModel()
    defer { try? FileManager.default.removeItem(at: model.store.rootDirectory) }
    let file = try makeRecordingFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let denied = NSError(domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError)
    model.copyRecordingIntoLibrary = { _, _ in throw denied }

    _ = await model.importRecordings(from: [file], title: "")

    #expect(model.alertMessage == "The recording could not be imported: \(denied.localizedDescription)")
}

@Test("No user-facing site reads localizedDescription directly; all go through ErrorPresentation (F383)")
func noRawLocalizedDescriptionInSources() throws {
    // The two files allowed to read it, and why. Per file, because each holds exactly one read.
    let allowed: [String: String] = [
        // The one reader: it decides whether the text is real copy.
        "ErrorPresentation.swift": "func sentence(for error",
        // `publicLogDescription` formats errors for the unified log, never for a person; there the
        // bridge's domain and code are the useful part.
        "DiagnosticsBundleBuilder.swift": "publicLogDescription",
    ]
    var offenders: [String] = []
    var scanned = 0
    for directory in ["Sources/WhisperCore", "Sources/WhisperMeet"] {
        for url in try SourceAssertion.swiftFileURLs(under: directory) {
            scanned += 1
            let code = SourceAssertion.stripComments(try String(contentsOf: url, encoding: .utf8))
            guard allowed[url.lastPathComponent] == nil else { continue }
            for (number, text) in SourceAssertion.numbered(code) where text.contains("localizedDescription") {
                offenders.append("\(url.lastPathComponent):\(number): \(text.trimmingCharacters(in: .whitespaces))")
            }
        }
    }
    #expect(scanned > 100, "the scan must actually read the source tree (\(scanned) files)")
    #expect(offenders.isEmpty, "use ErrorPresentation.readable(_:) or sentence(for:fallback:):\n\(offenders.joined(separator: "\n"))")
    // The allowance is not stale: each allowed file still holds its one read.
    for (file, symbol) in allowed {
        let url = try #require(try SourceAssertion.swiftFileURLs(under: "Sources").first { $0.lastPathComponent == file })
        let code = SourceAssertion.stripComments(try String(contentsOf: url, encoding: .utf8))
        #expect(code.contains("localizedDescription") && code.contains(symbol), "\(file) no longer needs its allowance")
    }
}
