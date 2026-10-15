import Foundation
import Testing
import WhisperCore
@testable import WhisperMeet

// F879 — `DictationController.ensureHelperInstalled()` runs at init with `activateOnInit: true` (what
// the app does at launch), on `setEnabled(true)`, on an engine switch and on a self-test. It looked
// for installed runtimes under the real `~/Library/Application Support/WhisperMeet` — read-only, and
// the test bundle ships no helper scripts to copy, but the outcome depended on what the host had
// installed. F442's shape: the real library is refused in a test process and recorded, and a test
// that wants the sync names a library of its own through the `applicationSupport:` seam.

@MainActor
private func makeController(in directory: URL, applicationSupport: URL? = nil) throws -> DictationController {
    let defaults = try #require(UserDefaults(suiteName: testSuiteName()))
    return DictationController(
        defaults: defaults,
        engine: EmptyDictationEngine(),
        recorder: FakeDictationRecorder(outputURL: directory.appendingPathComponent("c.wav")),
        overlay: SilentDictationOverlay(),
        hotkeyMonitor: FakeHotkeyMonitor(),
        logStore: DictationLogStore(directory: directory),
        textInjector: isolatedTextInjector(),
        applicationSupport: applicationSupport,
        activateOnInit: true
    )
}

private func refusals(since count: Int) -> [String] {
    Array(TestProcess.refusedAccesses.dropFirst(count)).filter { $0 == "runtime helper sync" }
}

@MainActor
@Test("A controller activated at init without a library of its own does not read the real Application Support runtime (F879)")
func aDefaultControllerNeverSyncsAgainstTheRealRuntime() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("F879-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let before = TestProcess.refusedAccesses.count
    _ = try makeController(in: directory)
    // `init` asked to sync the helpers (that is production behaviour) and was refused once.
    #expect(refusals(since: before) == ["runtime helper sync"])
}

@MainActor
@Test("A controller given a library syncs against it and is refused nothing (F879)")
func aControllerWithItsOwnLibraryIsNotRefused() throws {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent("F879-\(UUID().uuidString)")
    let library = directory.appendingPathComponent("Application Support", isDirectory: true)
    try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let before = TestProcess.refusedAccesses.count
    _ = try makeController(in: directory, applicationSupport: library)
    #expect(refusals(since: before).isEmpty)
    // No runtime is installed in that library, so the sync creates nothing there.
    #expect(!FileManager.default.fileExists(atPath: library.appendingPathComponent("WhisperMeet").path))
}
