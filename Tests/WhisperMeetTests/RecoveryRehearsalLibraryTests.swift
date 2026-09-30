import Foundation
import Testing
@testable import WhisperMeet
@testable import WhisperCore

// F550 — the recovery rehearsal has to hand the app something to recover, and a rehearsal instance
// must not share its settings with the real library.
//
// Part 1. `docs/RECOVERY.md` told a responder to practise the in-app restore by launching
// WhisperMeet against `rehearse-recovery.sh --keep`'s directory. That directory had already been
// restored by hand, so the app opened two healthy meetings with no read-only banner and no Recover
// Library button. `--keep-damaged` stops before the restore; the test below runs the real script
// and opens what it leaves through the same `AppModel` path the app uses, so "the app detects this"
// is asserted rather than inferred from the file shapes (those are `test_rehearse_recovery.py`'s).
// Following the restore through found two more defects in the script, both fixed with it: it named
// its generations with a SHA-256 prefix rather than the app's `StoreFingerprint`, so the app
// refused all three, and it wrote them in the same second, so their date-only labels were identical.
//
// Part 2. `WHISPERMEET_LIBRARY` moved every FILE, but the app still read and wrote
// `UserDefaults.standard` — the watched folder's path and its known-files snapshot, the dictation
// hotkey, the last-launch stamp. A rehearsal instance could therefore import a newly dropped
// watched-folder file into the rehearsal library and mark it known, so the real library never
// imported it. The production entry points now take their defaults from `WhisperMeetLibrary`.

/// Runs `Scripts/rehearse-recovery.sh` with TMPDIR pointed at `tmp`, returning exit status and stdout.
private func runRehearsal(_ arguments: [String], tmp: URL) async throws -> (status: Int32, stdout: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = [SourceAssertion.url("Scripts/rehearse-recovery.sh").path] + arguments
    var environment = ProcessInfo.processInfo.environment
    environment["TMPDIR"] = tmp.path
    process.environment = environment
    let output = Pipe()
    process.standardOutput = output
    process.standardError = output
    // Armed before `run()`, and awaited rather than `waitUntilExit()` (F169).
    let exited = armedExitStream(for: process)
    try process.run()
    for await _ in exited {}
    let data = output.fileHandleForReading.readDataToEndOfFile()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

private func keptRoot(in stdout: String) throws -> URL {
    let line = try #require(
        stdout.split(separator: "\n").first { $0.hasPrefix("Rehearsal library: ") },
        "the script must name the library it built:\n\(stdout)"
    )
    return URL(fileURLWithPath: String(line.dropFirst("Rehearsal library: ".count)), isDirectory: true)
}

@Test("--keep-damaged hands the app a library it opens read-only and can recover from (F550)")
@MainActor
func keepDamagedOpensReadOnlyWithTheTwoMeetingGenerationOffered() async throws {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("RecoveryRehearsal-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let run = try await runRehearsal(["--keep-damaged"], tmp: tmp)
    try #require(run.status == 0, "the rehearsal failed:\n\(run.stdout)")
    let root = try keptRoot(in: run.stdout)
    try #require(FileManager.default.fileExists(atPath: root.path), "--keep-damaged must keep its library")

    let suite = "RecoveryRehearsal.\(UUID().uuidString)"
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer { defaults.removePersistentDomain(forName: suite) }
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(), defaults: defaults)

    // What the responder sees: the read-only footnote, which is also the only thing that shows the
    // Settings ▸ Recover Library button (ContentView gates it on this).
    #expect(model.store.isDegraded)
    #expect(model.libraryReadOnlyFootnote != nil)

    model.requestLibraryRecovery()
    let offered = try #require(model.pendingLibraryRecovery, "alert instead of an offer: \(model.alertMessage ?? "nil")")
    // Every generation must be restorable: the script used to name them with a SHA-256 prefix, and
    // the app disabled all three as "damaged — cannot be used".
    #expect(offered.count == 3 && offered.allSatisfy(\.bytesMatchName), "\(offered)")
    // With no ledger the labels carry only dates, so the dates must tell them apart.
    #expect(Set(offered.map(AppModel.generationLabel)).count == offered.count,
            "indistinguishable choices: \(offered.map(AppModel.generationLabel))")

    // The steps RECOVERY.md gives: the newest copy is the empty one, and restoring it leaves the
    // library read-only and says so; the copy before it brings the two meetings back.
    let empty = try #require(offered.first { $0.sequence == 42 })
    let previous = try #require(offered.first { $0.sequence == 41 })
    model.recoverLibrary(from: empty, confirmed: true)
    #expect(model.store.isDegraded)
    #expect(model.alertMessage?.contains("stays in read-only mode") == true, "\(model.alertMessage ?? "nil")")

    model.alertMessage = nil
    model.requestLibraryRecovery()
    let again = try #require(model.pendingLibraryRecovery)
    let previousAgain = try #require(again.first { $0.name == previous.name })
    model.recoverLibrary(from: previousAgain, confirmed: true)
    #expect(!model.store.isDegraded, "\(model.alertMessage ?? "nil")")
    #expect(model.store.meetings.count == 2)
}

@Test("The production AppModel and DictationController take their settings from the library, not .standard (F550)")
func productionEntryPointsUseTheLibraryDefaults() throws {
    // Source, because the convenience init and the default argument read the real process
    // environment, and a test that set WHISPERMEET_LIBRARY would move every other test's library
    // with it (the suite runs in one process). The behaviour of the value they call is
    // `WhisperMeetLibraryRootTests`'s.
    //
    // Bound to Bools first so a failure names the file instead of printing all of it.
    let appModel = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/AppModel.swift")
    let appModelUsesLibrary = appModel.contains("defaults: WhisperMeetLibrary.defaults()")
    let appModelUsesStandard = appModel.contains("defaults: .standard")
    #expect(appModelUsesLibrary, "AppModel's convenience init must pass WhisperMeetLibrary.defaults()")
    #expect(!appModelUsesStandard, "AppModel still passes .standard somewhere")

    let dictation = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/Dictation/DictationController.swift")
    let dictationUsesLibrary = dictation.contains("defaults: UserDefaults = WhisperMeetLibrary.defaults()")
    let dictationUsesStandard = dictation.contains("defaults: UserDefaults = .standard")
    #expect(dictationUsesLibrary, "DictationController's default argument must be WhisperMeetLibrary.defaults()")
    #expect(!dictationUsesStandard, "DictationController still defaults to .standard")
}
