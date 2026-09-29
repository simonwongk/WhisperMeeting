import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F520 part 2 — Qwen (F33), speaker analysis (F219) and the summarizer (F167) reclaim an
// interrupted install at launch; the meetings-critical Local Whisper venv never did. A battery that
// died during "Repair or Update" left the working venv in `Runtime/.venv-backup-<pid>` and the app
// reporting "Whisper not installed" until the user reinstalled.
//
// Mirrors `SummarizerInstallRecoveryWiringTests`: the app-level hop over temp fixtures, the reclaim
// itself an injected seam. The script's recovery-only branch is exercised for real by
// Scripts/tests/test_f520_installer_cancel_restores.py.

private final class Spy: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [String] = []
    private var arguments: [URL] = []
    private var installed = false
    func note(_ event: String) { lock.withLock { recorded.append(event) } }
    func record(_ url: URL) { lock.withLock { arguments.append(url) } }
    func markInstalled() { lock.withLock { installed = true } }
    var events: [String] { lock.withLock { recorded } }
    var urls: [URL] { lock.withLock { arguments } }
    var isInstalled: Bool { lock.withLock { installed } }
}

private func makeRuntime() throws -> URL {
    let runtime = FileManager.default.temporaryDirectory
        .appendingPathComponent("F520-reclaim-\(UUID().uuidString)", isDirectory: true)
        .appendingPathComponent("Runtime", isDirectory: true)
    try FileManager.default.createDirectory(at: runtime, withIntermediateDirectories: true)
    return runtime
}

@MainActor
private func makeModel() throws -> AppModel {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("F520-reclaim-store-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let defaults = try #require(UserDefaults(suiteName: "F520.reclaim.\(UUID().uuidString)"))
    return AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(), defaults: defaults)
}

@Test("Local Whisper's reclaim looks for .venv-backup-* and .venv-install-*, never the lock (F520)")
func whisperReclaimDetectsItsOwnArtifacts() throws {
    let runtime = try makeRuntime()
    defer { try? FileManager.default.removeItem(at: runtime.deletingLastPathComponent()) }
    let fm = FileManager.default

    try fm.createDirectory(at: runtime.appendingPathComponent("venv"), withIntermediateDirectories: true)
    try Data().write(to: runtime.appendingPathComponent(".venv-install.lock"))
    try fm.createDirectory(at: runtime.appendingPathComponent("Qwen3ASR"), withIntermediateDirectories: true)
    #expect(!AppModel.hasOrphanedInstallArtifacts(in: runtime, for: .whisper))

    try fm.createDirectory(at: runtime.appendingPathComponent(".venv-backup-123"), withIntermediateDirectories: true)
    #expect(AppModel.hasOrphanedInstallArtifacts(in: runtime, for: .whisper))
    try fm.removeItem(at: runtime.appendingPathComponent(".venv-backup-123"))
    try fm.createDirectory(at: runtime.appendingPathComponent(".venv-install-456"), withIntermediateDirectories: true)
    #expect(AppModel.hasOrphanedInstallArtifacts(in: runtime, for: .whisper))

    #expect(InstallReclaim.whisper.recoveryEnvironmentKey == "WHISPER_INSTALL_RECOVERY_ONLY")
    #expect(InstallReclaim.whisper.scriptResource == "setup-local-whisper")
    let all = [InstallReclaim.whisper, .qwen, .summarizer, .diarization]
    #expect(Set(all.map(\.artifactPrefix)).count == 4)
}

@Test("The script is given Runtime/ for the venv, and its own directory for the other runtimes (F520)")
func whisperReclaimHandsTheScriptTheRuntimeDirectory() throws {
    let runtime = URL(fileURLWithPath: "/tmp/WhisperMeet/Runtime", isDirectory: true)
    let venv = runtime.appendingPathComponent("venv", isDirectory: true)
    #expect(InstallReclaim.whisper.scriptArgument(for: venv).standardizedFileURL == runtime.standardizedFileURL)
    let qwen = runtime.appendingPathComponent("Qwen3ASR", isDirectory: true)
    #expect(InstallReclaim.qwen.scriptArgument(for: qwen) == qwen)
}

@MainActor
@Test("A clean Runtime/ runs no Whisper reclaim (F520)")
func cleanWhisperRuntimeRunsNoReclaim() async throws {
    let runtime = try makeRuntime()
    defer { try? FileManager.default.removeItem(at: runtime.deletingLastPathComponent()) }
    let model = try makeModel()
    let spy = Spy()
    model.runWhisperInstallRecovery = { spy.record($0); return 0 }

    let didRun = await model.reclaimInterruptedWhisperInstall(venvDirectory: runtime.appendingPathComponent("venv"))
    #expect(!didRun)
    #expect(spy.urls.isEmpty)
}

@MainActor
@Test("An orphaned backup beside the venv runs the reclaim — found from the venv, not from Runtime/ (F520)")
func orphanedWhisperBackupRunsTheReclaim() async throws {
    let runtime = try makeRuntime()
    defer { try? FileManager.default.removeItem(at: runtime.deletingLastPathComponent()) }
    try FileManager.default.createDirectory(
        at: runtime.appendingPathComponent(".venv-backup-999"), withIntermediateDirectories: true)
    let model = try makeModel()
    let spy = Spy()
    model.runWhisperInstallRecovery = { spy.record($0); return 0 }

    // Handed Runtime/ itself, the scan looks in Runtime/'s parent and finds nothing — the trap the
    // brief for F520 named. The venv is the right starting point.
    let fromRuntime = await model.reclaimInterruptedWhisperInstall(venvDirectory: runtime)
    #expect(!fromRuntime)

    let venv = runtime.appendingPathComponent("venv", isDirectory: true)
    let didRun = await model.reclaimInterruptedWhisperInstall(venvDirectory: venv)
    #expect(didRun)
    #expect(spy.urls == [venv])
}

@MainActor
@Test("Launch reclaims an interrupted Local Whisper install before probing the runtime (F520)")
func whisperReclaimRunsAtStartupBeforeTheRuntimeProbe() async throws {
    let runtime = try makeRuntime()
    defer { try? FileManager.default.removeItem(at: runtime.deletingLastPathComponent()) }
    try FileManager.default.createDirectory(
        at: runtime.appendingPathComponent(".venv-backup-777"), withIntermediateDirectories: true)
    let model = try makeModel()
    model.whisperVenvDirectory = runtime.appendingPathComponent("venv", isDirectory: true)
    let spy = Spy()
    model.runWhisperInstallRecovery = { _ in
        spy.note("reclaim")
        spy.markInstalled() // the reclaim restored the stranded venv
        return 0
    }
    model.findWhisperExecutable = {
        spy.note("probe")
        return spy.isInstalled ? URL(fileURLWithPath: "/usr/bin/true") : nil
    }
    // The other three reclaims run too; replaced so nothing is spawned (F655 — they could only look
    // in this model's temp library anyway).
    model.runQwenInstallRecovery = { _ in 0 }
    model.runSummarizerInstallRecovery = { _ in 0 }
    model.runDiarizationInstallRecovery = { _ in 0 }

    await model.performStartupRecovery()

    #expect(spy.events.first == "reclaim", "\(spy.events)")
    #expect(spy.events.contains("probe"))
    #expect(model.isRuntimeInstalled, "the restored venv is visible on this same launch")
}
