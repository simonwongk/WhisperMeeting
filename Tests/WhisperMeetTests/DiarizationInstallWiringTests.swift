import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F219 — the speaker-analysis runtime's install and its launch self-heal. Genuinely red without the
// fix: `AppModel` has no `installSpeakerDiarization()`, no `runDiarizationInstaller` /
// `runDiarizationInstallRecovery` seams, and no `reclaimInterruptedDiarizationInstall()`, so this
// file does not compile against today's app target — nothing can install the runtime, and an
// install interrupted by a force-quit leaves the previous runtime stranded in a
// `.Diarization-backup-*` directory that reports forever as "not installed" (the exact F33 failure
// mode, which is why the reclaim is wired to launch BEFORE the runtime probe).
//
// The two behaviours these tests pin, and which no exit status can establish:
//   1. Success is decided by RE-PROBING THE FILESYSTEM after the installer returns. A script that
//      exits 0 having written nothing must never leave the app claiming the model is ready.
//   2. The reclaim runs only when installer-owned orphans actually exist, so a clean launch (or a
//      Mac that never installed speaker analysis) spawns no process at all.
//
// Every test points `diarizationRuntimeDirectory` at a temp directory, so the suite never reads or
// writes the user's real `~/Library/Application Support/WhisperMeet/Runtime/Diarization`.

private final class InstallSpy: @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [(script: URL, runtime: URL)] = []
    private var installed = false
    private var order: [String] = []

    var calls: [(script: URL, runtime: URL)] { lock.withLock { recorded } }
    var isInstalled: Bool { lock.withLock { installed } }
    var events: [String] { lock.withLock { order } }

    func record(script: URL, runtime: URL) {
        lock.withLock { recorded.append((script, runtime)) }
    }

    func markInstalled() { lock.withLock { installed = true } }
    func note(_ event: String) { lock.withLock { order.append(event) } }
}

/// Gives the install `Task` a real chance to run to completion, so an assertion is about behaviour
/// rather than scheduling luck. Returns once the condition holds or the budget is spent.
@MainActor
private func settle(until condition: () -> Bool) async {
    var ticks = 0
    while !condition(), ticks < 200_000 {
        await Task.yield()
        ticks += 1
    }
}

/// Gives any task a refused request might have spawned a real chance to reach a seam, so a "nothing
/// ran" assertion is about the guard rather than about scheduling luck.
@MainActor
private func settle() async {
    for _ in 0..<200 { await Task.yield() }
}

@MainActor
private struct InstallFixture {
    let model: AppModel
    let storeRoot: URL
    let runtimeParent: URL
    var runtimeDirectory: URL { runtimeParent.appendingPathComponent("Diarization", isDirectory: true) }
}

/// A model whose library and speaker-analysis runtime both live in temp directories.
@MainActor
private func makeInstallFixture() throws -> InstallFixture {
    let storeRoot = FileManager.default.temporaryDirectory
        .appendingPathComponent("DiarizationInstall-store-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: storeRoot, withIntermediateDirectories: true)
    let runtimeParent = FileManager.default.temporaryDirectory
        .appendingPathComponent("DiarizationInstall-runtime-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: runtimeParent, withIntermediateDirectories: true)

    let defaults = UserDefaults(suiteName: "F219install.\(UUID().uuidString)")!
    let model = AppModel(
        store: MeetingStore(rootDirectory: storeRoot),
        recorder: AudioCaptureEngine(),
        defaults: defaults
    )
    model.diarizationRuntimeDirectory = runtimeParent
        .appendingPathComponent("Diarization", isDirectory: true)
    model.isDiarizationModelInstalled = { false }
    return InstallFixture(model: model, storeRoot: storeRoot, runtimeParent: runtimeParent)
}

/// The headline install invariant: the installer's own success is not evidence. The runtime is only
/// "ready" when a fresh filesystem probe finds it.
@MainActor
@Test("A speaker-analysis installer that exits clean without writing the runtime is reported as failed (F219)")
func diarizationInstallVerifiesByReprobingTheFilesystem() async throws {
    let fixture = try makeInstallFixture()
    defer {
        try? FileManager.default.removeItem(at: fixture.storeRoot)
        try? FileManager.default.removeItem(at: fixture.runtimeParent)
    }
    let model = fixture.model
    let spy = InstallSpy()
    // Returns without throwing — the installer "succeeded" — but the runtime never appears on disk.
    model.runDiarizationInstaller = { script, runtime in spy.record(script: script, runtime: runtime) }
    model.isDiarizationModelInstalled = { false }

    model.installSpeakerDiarization()
    #expect(model.isInstallingDiarizationRuntime) // set optimistically, before any work
    await settle { !model.isInstallingDiarizationRuntime }

    #expect(spy.calls.count == 1)
    #expect(spy.calls.first?.script.lastPathComponent == "setup-speaker-diarization.sh")
    #expect(spy.calls.first?.runtime == fixture.runtimeDirectory)
    #expect(!model.isDiarizationInstalled)
    #expect(model.diarizationInstallationMessage?.contains("failed") == true)
    #expect(model.alertMessage != nil) // the failure is explained, not swallowed
}

/// The same probe decides the happy path: the runtime is announced ready only once it is really there.
@MainActor
@Test("Speaker analysis reports ready only after the filesystem probe finds the runtime (F219)")
func diarizationInstallReportsReadyWhenTheProbeFindsTheRuntime() async throws {
    let fixture = try makeInstallFixture()
    defer {
        try? FileManager.default.removeItem(at: fixture.storeRoot)
        try? FileManager.default.removeItem(at: fixture.runtimeParent)
    }
    let model = fixture.model
    let spy = InstallSpy()
    model.runDiarizationInstaller = { script, runtime in
        spy.record(script: script, runtime: runtime)
        spy.markInstalled() // the installer actually wrote the runtime this time
    }
    model.isDiarizationModelInstalled = { spy.isInstalled }

    model.installSpeakerDiarization()
    await settle { !model.isInstallingDiarizationRuntime }

    #expect(spy.calls.count == 1)
    #expect(model.isDiarizationInstalled)
    #expect(model.diarizationInstallationMessage?.contains("ready") == true)
    #expect(model.alertMessage == nil)
}

/// The install must never start on top of a busy Mac: dictation owning the microphone, or a second
/// install of its own. A refusal starts NO work — the seam counter is what proves it.
@MainActor
@Test("The speaker-analysis install refuses while the Mac is already busy (F219)")
func diarizationInstallRefusesWhileBusy() async throws {
    let fixture = try makeInstallFixture()
    defer {
        try? FileManager.default.removeItem(at: fixture.storeRoot)
        try? FileManager.default.removeItem(at: fixture.runtimeParent)
    }
    let model = fixture.model
    let spy = InstallSpy()
    let gate = InstallSpy()
    model.runDiarizationInstaller = { script, runtime in
        spy.record(script: script, runtime: runtime)
        while !gate.isInstalled { await Task.yield() }
    }

    // 1. Quick Dictation owns the microphone: nothing starts, and no busy flag is left behind.
    model.configureDictationGuard { true }
    model.installSpeakerDiarization()
    await settle() // a refusal must still have started nothing, given every chance to run
    #expect(spy.calls.isEmpty)
    #expect(!model.isInstallingDiarizationRuntime)

    // 2. An install already running: the second request is refused, not queued behind the first.
    model.configureDictationGuard { false }
    model.installSpeakerDiarization()
    await settle { spy.calls.count == 1 }
    #expect(spy.calls.count == 1)

    model.installSpeakerDiarization()
    await settle()
    #expect(spy.calls.count == 1) // still one: the second request started nothing

    gate.markInstalled()
    await settle { !model.isInstallingDiarizationRuntime }
}

/// Only installer-owned orphans count. A live runtime directory is not an orphan.
@Test("Orphaned speaker-analysis install artifacts are detected; a clean runtime is not (F219)")
func reclaimDiarizationDetectsOnlyInstallerOrphans() throws {
    let parent = FileManager.default.temporaryDirectory
        .appendingPathComponent("DiarizationReclaim-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: parent) }

    // Clean: the live runtime and its siblings carry none of the installer's hidden prefixes.
    for name in ["Diarization", "Qwen3ASR", "venv"] {
        try FileManager.default.createDirectory(
            at: parent.appendingPathComponent(name), withIntermediateDirectories: true)
    }
    #expect(!AppModel.hasOrphanedDiarizationInstallArtifacts(in: parent))

    try FileManager.default.createDirectory(
        at: parent.appendingPathComponent(".Diarization-backup-123"), withIntermediateDirectories: true)
    #expect(AppModel.hasOrphanedDiarizationInstallArtifacts(in: parent))

    let stagingOnly = FileManager.default.temporaryDirectory
        .appendingPathComponent("DiarizationReclaim-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: stagingOnly, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: stagingOnly) }
    try FileManager.default.createDirectory(
        at: stagingOnly.appendingPathComponent(".Diarization-install-999"), withIntermediateDirectories: true)
    #expect(AppModel.hasOrphanedDiarizationInstallArtifacts(in: stagingOnly))
}

/// The app-level hop: with an orphaned backup present the reclaim runs through the injected seam and
/// receives the runtime directory to reclaim; a clean runtime spawns nothing at all.
@MainActor
@Test("An orphaned speaker-analysis install triggers the reclaim through the app-level call (F219)")
func reclaimDiarizationRunsOnlyWhenOrphansExist() async throws {
    let fixture = try makeInstallFixture()
    defer {
        try? FileManager.default.removeItem(at: fixture.storeRoot)
        try? FileManager.default.removeItem(at: fixture.runtimeParent)
    }
    let model = fixture.model
    let marker = fixture.runtimeParent.appendingPathComponent("reclaim-ran")
    model.runDiarizationInstallRecovery = { directory in
        // Proves BOTH that the seam ran and that it received the runtime directory to reclaim.
        try? Data(directory.path.utf8).write(to: marker)
        return 0
    }

    // Clean parent: the live runtime only.
    try FileManager.default.createDirectory(
        at: fixture.runtimeDirectory, withIntermediateDirectories: true)
    let ranOnCleanRuntime = await model.reclaimInterruptedDiarizationInstall()
    #expect(!ranOnCleanRuntime)
    #expect(!FileManager.default.fileExists(atPath: marker.path)) // the seam was never invoked

    // A force-quit mid-install: the previous runtime is stranded in a hidden backup directory.
    try FileManager.default.removeItem(at: fixture.runtimeDirectory)
    try FileManager.default.createDirectory(
        at: fixture.runtimeParent.appendingPathComponent(".Diarization-backup-111"),
        withIntermediateDirectories: true)
    let ranOnOrphan = await model.reclaimInterruptedDiarizationInstall()

    #expect(ranOnOrphan)
    #expect(try String(contentsOf: marker, encoding: .utf8) == fixture.runtimeDirectory.path)
}

/// The reachability hop, and the ordering that makes it worth anything: launch runs the reclaim
/// BEFORE the runtime probe, so a runtime restored from a backup shows as installed on that same
/// launch instead of as "not installed" until the user reinstalls 60 MB by hand.
@MainActor
@Test("Launch reclaims an interrupted speaker-analysis install before probing the runtime (F219)")
func reclaimDiarizationRunsAtStartupBeforeTheRuntimeProbe() async throws {
    let fixture = try makeInstallFixture()
    defer {
        try? FileManager.default.removeItem(at: fixture.storeRoot)
        try? FileManager.default.removeItem(at: fixture.runtimeParent)
    }
    let model = fixture.model
    try FileManager.default.createDirectory(
        at: fixture.runtimeParent.appendingPathComponent(".Diarization-backup-222"),
        withIntermediateDirectories: true)

    let spy = InstallSpy()
    model.runDiarizationInstallRecovery = { _ in
        spy.note("reclaim")
        spy.markInstalled() // the reclaim restored the stranded runtime
        return 0
    }
    model.isDiarizationModelInstalled = {
        spy.note("probe")
        return spy.isInstalled
    }

    await model.performStartupRecovery()

    #expect(spy.events.first == "reclaim")           // ordering, not merely presence
    #expect(spy.events.contains("probe"))
    #expect(model.isDiarizationInstalled)            // restored runtime, visible on this same launch
}

// F228 — the reverse of the guard above. `installSpeakerDiarization` refuses while any other
// install runs, but the other three never learned about it: `installLocalWhisper` and
// `installQwenASR` guard only `isInstallingRecognitionRuntime` (Whisper + Qwen), so they would
// start on top of a running speaker-analysis install — and, as it turns out, on top of a running
// summarizer install too, which the ticket did not notice. Two installers then compete for network
// and disk and both call `refreshRuntime()` on completion, so the slower one reports its result
// against state the faster one has already replaced.
//
// The Settings row's `.disabled` currently hides this, which is exactly why it needs a test: the
// hole reappears the moment a menu command or a first-run flow calls an installer without
// repeating the button's condition.
//
// How a refusal is observed without a seam on the other three installers: in the test bundle
// `Bundle.main.url(forResource:)` finds no installer script, so an installer that gets PAST its
// busy guard sets `alertMessage` to "…installer is missing". A guard that refuses returns before
// that line. So `alertMessage == nil` means the request was refused, and the control at the end
// proves the assertion is not vacuous by letting the same call through.

@MainActor
@Test("The other three model installers refuse while speaker analysis is installing (F228)")
func otherInstallersRefuseWhileTheDiarizationInstallIsRunning() async throws {
    let fixture = try makeInstallFixture()
    defer {
        try? FileManager.default.removeItem(at: fixture.storeRoot)
        try? FileManager.default.removeItem(at: fixture.runtimeParent)
    }
    let model = fixture.model
    let spy = InstallSpy()
    let gate = InstallSpy()
    model.runDiarizationInstaller = { script, runtime in
        spy.record(script: script, runtime: runtime)
        while !gate.isInstalled { await Task.yield() }
    }

    model.installSpeakerDiarization()
    await settle { spy.calls.count == 1 }
    #expect(model.isInstallingDiarizationRuntime)

    model.installLocalWhisper()
    await settle()
    #expect(model.alertMessage == nil, "installLocalWhisper ran while speaker analysis was installing")
    #expect(!model.isInstallingRuntime)

    model.installQwenASR()
    await settle()
    #expect(model.alertMessage == nil, "installQwenASR ran while speaker analysis was installing")
    #expect(!model.isInstallingQwenRuntime)

    model.installSummarizer()
    await settle()
    #expect(model.alertMessage == nil, "installSummarizer ran while speaker analysis was installing")
    #expect(!model.isInstallingSummarizer)

    #expect(spy.calls.count == 1) // and none of them disturbed the install that was already running

    gate.markInstalled()
    await settle { !model.isInstallingDiarizationRuntime }

    // The control. With nothing in flight the same call goes through and reaches the missing-script
    // branch, so the three assertions above were about the guard and not about a call that could
    // never have done anything.
    model.installLocalWhisper()
    await settle()
    #expect(model.alertMessage?.contains("installer is missing") == true)
}

// F228 — the same hole in the other direction, and the reason the fix is one shared property rather
// than three added clauses. `isInstallingAnyRuntime` is the single question every installer asks;
// a flag added to `AppModel` in future is wrong in one place instead of three.

@MainActor
@Test("One property answers whether any runtime install is in flight (F228)")
func installingAnyRuntimeCoversEveryInstallFlag() async throws {
    let fixture = try makeInstallFixture()
    defer {
        try? FileManager.default.removeItem(at: fixture.storeRoot)
        try? FileManager.default.removeItem(at: fixture.runtimeParent)
    }
    let model = fixture.model
    #expect(!model.isInstallingAnyRuntime)

    let gate = InstallSpy()
    model.runDiarizationInstaller = { _, _ in while !gate.isInstalled { await Task.yield() } }
    model.installSpeakerDiarization()
    await settle { model.isInstallingDiarizationRuntime }
    #expect(model.isInstallingAnyRuntime, "a speaker-analysis install is a runtime install")

    gate.markInstalled()
    await settle { !model.isInstallingDiarizationRuntime }
    #expect(!model.isInstallingAnyRuntime)

    // The recognition pair is already covered by `isInstallingRecognitionRuntime`; the property must
    // subsume it rather than replace it, because other callers still ask the narrower question.
    #expect(!model.isInstallingRecognitionRuntime)
}
