import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F167 — `setup-local-summarizer.sh` already reclaims orphaned `.Summarizer-backup-*` and
// `.Summarizer-install-*` artifacts, but only on its next run. So after a crash mid-install the
// previous model could sit in a hidden backup with `Summarizer/` gone — reporting "not installed"
// — until the user happened to open the installer again. The Qwen and speaker-analysis runtimes
// both got a launch-time reclaim (F33, F219); this one did not.
//
// Mirrors `QwenInstallRecoveryWiringTests`: the app-level hop over a temp fixture, with the reclaim
// itself an injected seam so nothing spawns a process.

@MainActor
private func makeModel() -> AppModel {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("SummarizerInstallRecovery-store-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let defaults = UserDefaults(
        suiteName: "WhisperMeet.SummarizerInstallRecovery.\(UUID().uuidString)")!
    return AppModel(
        store: MeetingStore(rootDirectory: root),
        recorder: AudioCaptureEngine(),
        defaults: defaults
    )
}

private func makeRuntimeParent() throws -> URL {
    let parent = FileManager.default.temporaryDirectory
        .appendingPathComponent("SummarizerInstallRecovery-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    return parent
}

@Test("Orphaned summarizer-install artifacts are detected; a clean runtime is not (F167)")
func detectsOrphanedSummarizerArtifacts() throws {
    let parent = try makeRuntimeParent()
    defer { try? FileManager.default.removeItem(at: parent) }

    // The live runtime carries none of the installer's hidden prefixes, so a clean Mac — and one
    // that never installed the summarizer at all — must spawn nothing.
    try FileManager.default.createDirectory(
        at: parent.appendingPathComponent("Summarizer"), withIntermediateDirectories: true)
    #expect(!AppModel.hasOrphanedSummarizerInstallArtifacts(in: parent))

    try FileManager.default.createDirectory(
        at: parent.appendingPathComponent(".Summarizer-backup-123"), withIntermediateDirectories: true)
    #expect(AppModel.hasOrphanedSummarizerInstallArtifacts(in: parent))

    let staging = try makeRuntimeParent()
    defer { try? FileManager.default.removeItem(at: staging) }
    try FileManager.default.createDirectory(
        at: staging.appendingPathComponent(".Summarizer-install-999"), withIntermediateDirectories: true)
    #expect(AppModel.hasOrphanedSummarizerInstallArtifacts(in: staging))
}

@Test("A directory that cannot be listed reports no orphans rather than throwing (F167)")
func unlistableParentIsNotAnOrphan() {
    let missing = FileManager.default.temporaryDirectory
        .appendingPathComponent("SummarizerInstallRecovery-absent-\(UUID().uuidString)")
    // A Mac that never installed the summarizer has no runtime parent at all. That is the common
    // case, not an error, and it must not spawn a reclaim.
    #expect(!AppModel.hasOrphanedSummarizerInstallArtifacts(in: missing))
}

@MainActor
@Test("A clean runtime parent runs no reclaim (F167)")
func cleanRuntimeRunsNoReclaim() async throws {
    let parent = try makeRuntimeParent()
    defer { try? FileManager.default.removeItem(at: parent) }
    try FileManager.default.createDirectory(
        at: parent.appendingPathComponent("Summarizer"), withIntermediateDirectories: true)

    let model = makeModel()
    let runs = Counter()
    model.runSummarizerInstallRecovery = { _ in runs.increment(); return 0 }

    let didRun = await model.reclaimInterruptedSummarizerInstall(
        runtimeDirectory: parent.appendingPathComponent("Summarizer")
    )

    #expect(!didRun)
    #expect(runs.value == 0, "spawned a reclaim on a clean runtime")
}

@MainActor
@Test("An orphaned backup runs the reclaim over the runtime directory (F167)")
func orphanedBackupRunsTheReclaim() async throws {
    let parent = try makeRuntimeParent()
    defer { try? FileManager.default.removeItem(at: parent) }
    try FileManager.default.createDirectory(
        at: parent.appendingPathComponent(".Summarizer-backup-7"), withIntermediateDirectories: true)
    let runtime = parent.appendingPathComponent("Summarizer")

    let model = makeModel()
    let seen = Box<URL?>(nil)
    model.runSummarizerInstallRecovery = { url in seen.value = url; return 0 }

    let didRun = await model.reclaimInterruptedSummarizerInstall(runtimeDirectory: runtime)

    #expect(didRun)
    // The runtime directory, not its parent: the installer takes the canonical path and derives the
    // parent itself, exactly as the Qwen script does.
    #expect(seen.value == runtime)
}

private final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    func increment() { lock.lock(); count += 1; lock.unlock() }
    var value: Int { lock.lock(); defer { lock.unlock() }; return count }
}

private final class Box<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var stored: Value
    init(_ value: Value) { stored = value }
    var value: Value {
        get { lock.lock(); defer { lock.unlock() }; return stored }
        set { lock.lock(); stored = newValue; lock.unlock() }
    }
}
