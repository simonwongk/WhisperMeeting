import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F33 — the Qwen installer's recovery-only reclaim is wired to launch so an interrupted install
// self-heals. These tests drive the app-level hop over a temp fixture directory; the reclaim itself
// is the injected `runQwenInstallRecovery` seam (never a real process), and the script's own reclaim
// logic is covered by WhisperCoreTests/QwenInstallerRecoveryTests.

@MainActor
private func makeModel() -> AppModel {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("QwenInstallRecoveryWiringTests-store-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let defaults = UserDefaults(
        suiteName: "WhisperMeet.QwenInstallRecoveryWiringTests.\(UUID().uuidString)")!
    return AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(), defaults: defaults)
}

private func makeRuntimeParent() throws -> URL {
    let parent = FileManager.default.temporaryDirectory
        .appendingPathComponent("QwenInstallRecoveryWiringTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    return parent
}

/// A leftover backup or abandoned staging dir is detected; a clean runtime (live dirs only) is not.
@Test("Orphaned Qwen-install artifacts are detected; a clean runtime is not (F33)")
func detectsOrphanedQwenInstallArtifacts() throws {
    let parent = try makeRuntimeParent()
    defer { try? FileManager.default.removeItem(at: parent) }

    // Clean: only the live runtime dirs, no installer orphans.
    try FileManager.default.createDirectory(
        at: parent.appendingPathComponent("Qwen3ASR"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: parent.appendingPathComponent("venv"), withIntermediateDirectories: true)
    #expect(!AppModel.hasOrphanedQwenInstallArtifacts(in: parent))

    // A leftover backup is an orphan; an abandoned staging dir is too.
    try FileManager.default.createDirectory(
        at: parent.appendingPathComponent(".Qwen3ASR-backup-123"), withIntermediateDirectories: true)
    #expect(AppModel.hasOrphanedQwenInstallArtifacts(in: parent))

    let stagingOnly = try makeRuntimeParent()
    defer { try? FileManager.default.removeItem(at: stagingOnly) }
    try FileManager.default.createDirectory(
        at: stagingOnly.appendingPathComponent(".Qwen3ASR-install-999"), withIntermediateDirectories: true)
    #expect(AppModel.hasOrphanedQwenInstallArtifacts(in: stagingOnly))
}

/// The headline reachability hop: with an orphaned backup present, the app runs the reclaim (through
/// the injected seam) over the correct runtime directory.
@MainActor
@Test("An orphaned Qwen install triggers the reclaim through the app-level call (F33)")
func orphanedInstallTriggersReclaim() async throws {
    let parent = try makeRuntimeParent()
    defer { try? FileManager.default.removeItem(at: parent) }
    let runtimeDirectory = parent.appendingPathComponent("Qwen3ASR", isDirectory: true)
    try FileManager.default.createDirectory(
        at: parent.appendingPathComponent(".Qwen3ASR-backup-111"), withIntermediateDirectories: true)

    let model = makeModel()
    let marker = parent.appendingPathComponent("reclaim-ran")
    model.runQwenInstallRecovery = { dir in
        // Proves BOTH that the seam ran and that it received the runtime directory to reclaim.
        try? Data(dir.path.utf8).write(to: marker)
        return 0
    }

    let ran = await model.reclaimInterruptedQwenInstall(runtimeDirectory: runtimeDirectory)

    #expect(ran)
    #expect(FileManager.default.fileExists(atPath: marker.path))
    #expect(try String(contentsOf: marker, encoding: .utf8) == runtimeDirectory.path)
}

/// A clean runtime parent must NOT spawn the reclaim — a common launch (or a Mac that never installed
/// Qwen) does no work.
@MainActor
@Test("A clean runtime does not trigger the Qwen reclaim (F33)")
func cleanRuntimeSkipsReclaim() async throws {
    let parent = try makeRuntimeParent()
    defer { try? FileManager.default.removeItem(at: parent) }
    let runtimeDirectory = parent.appendingPathComponent("Qwen3ASR", isDirectory: true)
    try FileManager.default.createDirectory(at: runtimeDirectory, withIntermediateDirectories: true)

    let model = makeModel()
    let marker = parent.appendingPathComponent("reclaim-ran")
    model.runQwenInstallRecovery = { _ in try? Data("x".utf8).write(to: marker); return 0 }

    let ran = await model.reclaimInterruptedQwenInstall(runtimeDirectory: runtimeDirectory)

    #expect(!ran)
    #expect(!FileManager.default.fileExists(atPath: marker.path)) // the seam was never invoked
}
