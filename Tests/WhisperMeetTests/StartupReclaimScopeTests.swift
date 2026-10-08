import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F655 — the launch reclaims found their runtimes through the process-wide defaults
// (`QwenASRRuntime.managedDirectory()`, `whisperVenvDirectory`, …), which point at the user's real
// `~/Library/Application Support/WhisperMeet/Runtime`. Eighteen other test files call
// `performStartupRecovery()` on a model over a temp library, and each reclaim whose seam a test did
// not replace would — on a Mac with leftover install artifacts — have run the real installer's
// recovery against the real runtime: restoring or deleting its backups. `RestoreReadOnlyLibraryTests`
// replaced three of the four; F520's own launch test replaced one.
//
// Stubbing every seam in every fixture is a list someone has to remember. Instead the reclaims now
// look in the runtime of the library the model was opened on — `store.rootDirectory/Runtime`, which
// in the app IS the managed runtime (`MeetingStore()` opens `WhisperMeetLibrary.root()`, and the
// runtimes live under the same root), and in a test is the test's temp library. A test cannot reach
// the real runtime this way without opening the real library, which no test may do anyway.
//
// These run with every reclaim seam replaced by a recorder, so nothing is spawned; the red run of
// the first one therefore only LISTED the real Runtime, as every existing startup-recovery test
// already does, and planted nothing there.

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var calls: [String: URL] = [:]
    func record(_ name: String, _ url: URL) { lock.withLock { calls[name] = url } }
    var recorded: [String: URL] { lock.withLock { calls } }
}

@MainActor
private func makeModel(libraryRoot: URL) throws -> AppModel {
    let defaults = try #require(UserDefaults(suiteName: testSuiteName()))
    return AppModel(store: MeetingStore(rootDirectory: libraryRoot), recorder: AudioCaptureEngine(), defaults: defaults,
                    whisperExecutable: { nil }, qwenInstalled: { false })
}

@MainActor
@Test("Every launch reclaim looks in the runtime of the library the model was opened on (F655)")
func launchReclaimsStayInsideTheModelsLibrary() async throws {
    let library = FileManager.default.temporaryDirectory
        .appendingPathComponent("F655-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: library) }
    let runtime = library.appendingPathComponent("Runtime", isDirectory: true)
    // One orphan per reclaim, derived from the descriptors — a fifth reclaim is planted too.
    for reclaim in InstallReclaim.all {
        try FileManager.default.createDirectory(
            at: runtime.appendingPathComponent(reclaim.backupPrefix + "1"), withIntermediateDirectories: true)
    }

    let model = try makeModel(libraryRoot: library)
    let recorder = Recorder()
    model.runWhisperInstallRecovery = { recorder.record("whisper", $0); return 0 }
    model.runQwenInstallRecovery = { recorder.record("qwen", $0); return 0 }
    model.runSummarizerInstallRecovery = { recorder.record("summarizer", $0); return 0 }
    model.runDiarizationInstallRecovery = { recorder.record("diarization", $0); return 0 }

    await model.performStartupRecovery()

    let recorded = recorder.recorded
    #expect(recorded.count == InstallReclaim.all.count,
            "reclaims that did not look in this model's library: \(Set(["whisper", "qwen", "summarizer", "diarization"]).subtracting(recorded.keys).sorted())")
    for (name, url) in recorded {
        #expect(url.standardizedFileURL.path.hasPrefix(runtime.standardizedFileURL.path + "/"),
                "the \(name) reclaim was handed \(url.path), outside this model's library")
    }
}

@MainActor
@Test("In the app, the library's runtime is the managed runtime, so the launch reclaims still find it (F655)")
func libraryRuntimeIsTheManagedRuntimeInTheApp() throws {
    // `MeetingStore()` opens `WhisperMeetLibrary.root()`, and the runtimes live under that root.
    // Checked as source rather than by constructing the default store, which would open the user's
    // real library.
    let store = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/MeetingStore.swift")
    #expect(store.contains("self.rootDirectory = rootDirectory ?? WhisperMeetLibrary.root()"))
    let appModel = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/AppModel.swift")
    #expect(appModel.contains("store: MeetingStore(),"), "AppModel() no longer opens the default library")
    #expect(LocalWhisperRuntime.managedDirectory().deletingLastPathComponent().standardizedFileURL
            == WhisperMeetLibrary.root().standardizedFileURL)

    // And each reclaim's directory under a library root is exactly the runtime's own managed
    // directory for that root, so the descriptors' names cannot drift from the runtimes'.
    let applicationSupport = FileManager.default.temporaryDirectory
        .appendingPathComponent("F655-names-\(UUID().uuidString)", isDirectory: true)
    let model = try makeModel(libraryRoot: applicationSupport.appendingPathComponent("WhisperMeet", isDirectory: true))
    defer { try? FileManager.default.removeItem(at: applicationSupport) }
    let expected: [(InstallReclaim, URL)] = [
        (.whisper, LocalWhisperRuntime.managedDirectory(applicationSupport: applicationSupport).appendingPathComponent("venv")),
        (.qwen, QwenASRRuntime.managedDirectory(applicationSupport: applicationSupport)),
        (.summarizer, SummarizerRuntime.managedDirectory(applicationSupport: applicationSupport)),
        (.diarization, DiarizationRuntime.managedDirectory(applicationSupport: applicationSupport)),
    ]
    #expect(expected.count == InstallReclaim.all.count)
    for (reclaim, directory) in expected {
        #expect(model.runtimeDirectory(for: reclaim).standardizedFileURL.path == directory.standardizedFileURL.path,
                "\(reclaim.scriptResource)")
    }
}
