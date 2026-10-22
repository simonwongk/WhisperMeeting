import Foundation
import Testing
import WhisperCore
@testable import WhisperMeet

// F991 — two ways a test could act on the user's real runtime by omission, closed F442's way: the real
// thing is refused in a test process and the refusal recorded. A `DictationController` built without
// `engine:` or `refiner:` built its helpers from the real library's paths (16 test constructions omit
// `refiner:`), and the installers that run through `runInstallerScript` — `installAskEmbeddingModel()`
// among them — and the downloader update ran their scripts against `Runtime/` under the real library. The installer checks run a harmless stub
// that only NAMES the real library, so even before the fix nothing real was touched.

private func scratch(_ label: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("F991-\(label)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// A stand-in installer that records that it ran and touches nothing else.
private func stubScript(in directory: URL) throws -> (script: URL, ran: URL) {
    let ran = directory.appendingPathComponent("ran")
    let script = directory.appendingPathComponent("installer.sh")
    try "#!/bin/zsh\ntouch '\(ran.path)'\n".write(to: script, atomically: true, encoding: .utf8)
    return (script, ran)
}

private func refusals(since count: Int) -> [String] { Array(TestProcess.refusedAccesses.dropFirst(count)) }

@MainActor
@Test("A dictation controller built in a test without engine: or refiner: is refused the real ones (F991)")
func aControllerWithoutEngineOrRefinerIsRefusedTheRealOnes() throws {
    let directory = try scratch("controller")
    defer { try? FileManager.default.removeItem(at: directory) }
    let defaults = try #require(UserDefaults(suiteName: testSuiteName()))

    let before = TestProcess.refusedAccesses.count
    _ = DictationController(
        defaults: defaults,
        recorder: FakeDictationRecorder(outputURL: directory.appendingPathComponent("c.wav")),
        overlay: SilentDictationOverlay(),
        hotkeyMonitor: FakeHotkeyMonitor(),
        logStore: DictationLogStore(directory: directory),
        textInjector: isolatedTextInjector(),
        applicationSupport: directory,
        activateOnInit: false
    )

    let refused = refusals(since: before)
    #expect(refused.contains("the real dictation engine"), "\(refused)")
    #expect(refused.contains("the real dictation refiner"), "\(refused)")
}

@MainActor
@Test("The stand-ins refuse every request and start nothing; the refine runtime reads as absent (F991)")
func theStandInsRefuseEveryRequest() async throws {
    let directory = try scratch("standins")
    defer { try? FileManager.default.removeItem(at: directory) }
    for selection in [DictationTranscriptionEngine.whisperTurbo, .qwenBalanced] {
        let engine = DictationController.makeEngine(for: selection)
        await #expect(throws: RefusedDictationEngine.Refused.self) { try await engine.warmUp() }
        await #expect(throws: RefusedDictationEngine.Refused.self) {
            _ = try await engine.transcribe(wavAt: directory.appendingPathComponent("c.wav"), language: .automatic, initialPrompt: nil)
        }
    }
    let refiner = DictationController.makeRefiner()
    #expect(await refiner.warmUp() == false)
    #expect(await refiner.attempt(text: "hello", languageCode: nil) == RefineAttempt(text: "hello", outcome: .rawError))

    let defaults = try #require(UserDefaults(suiteName: testSuiteName()))
    let controller = DictationController(
        defaults: defaults, engine: EmptyDictationEngine(),
        recorder: FakeDictationRecorder(outputURL: directory.appendingPathComponent("c.wav")),
        overlay: SilentDictationOverlay(), hotkeyMonitor: FakeHotkeyMonitor(),
        logStore: DictationLogStore(directory: directory), refiner: RefusedDictationRefiner(),
        textInjector: isolatedTextInjector(), applicationSupport: directory, activateOnInit: false
    )
    #expect(!controller.isRefineRuntimeInstalled, "the host's refine runtime decided a test's outcome")
}

@Test("An installer whose runtime is in the real library is refused in a test, and never runs (F991)")
func anInstallerIntoTheRealLibraryIsRefused() async throws {
    let directory = try scratch("installer")
    defer { try? FileManager.default.removeItem(at: directory) }
    let (script, ran) = try stubScript(in: directory)
    let real = WhisperMeetLibrary.root().appendingPathComponent("Runtime", isDirectory: true)

    let before = TestProcess.refusedAccesses.count
    await #expect(throws: InstallerError.self) {
        try await AppModel.runInstallerScript(InstallerJob(
            component: .askEmbeddings, scriptURL: script, arguments: [real.path], logURL: nil
        ))
    }

    #expect(!FileManager.default.fileExists(atPath: ran.path), "the installer ran against the real library")
    #expect(refusals(since: before).contains("an installer into the real library"))
}

@Test("An installer into a test's own runtime still runs (F991 control)")
func anInstallerIntoATestsOwnRuntimeRuns() async throws {
    let directory = try scratch("own")
    defer { try? FileManager.default.removeItem(at: directory) }
    let (script, ran) = try stubScript(in: directory)

    try await AppModel.runInstallerScript(InstallerJob(
        component: .askEmbeddings, scriptURL: script, arguments: [directory.appendingPathComponent("Runtime").path], logURL: nil
    ))

    #expect(FileManager.default.fileExists(atPath: ran.path))
}

@Test("The downloader update is refused for the real library's runtime in a test, and runs for a test's own (F991)")
func theDownloaderUpdateIsRefusedForTheRealLibrary() async throws {
    let directory = try scratch("downloader")
    defer { try? FileManager.default.removeItem(at: directory) }
    let (script, ran) = try stubScript(in: directory)

    let refused = await AppModel.runDownloaderUpdate(arguments: AppModel.downloaderUpdateArguments(script: script))
    #expect(refused == nil)
    #expect(!FileManager.default.fileExists(atPath: ran.path), "the downloader update ran against the real library")

    let own = await AppModel.runDownloaderUpdate(arguments: [script.path, directory.appendingPathComponent("Runtime").path])
    #expect(own?.exitStatus == 0)
    #expect(FileManager.default.fileExists(atPath: ran.path))
}
