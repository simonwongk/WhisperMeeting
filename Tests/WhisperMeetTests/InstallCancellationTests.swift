import AppKit
import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F520 part 1 — model installs could not be cancelled and kept running after Quit. Each installer
// ran a `Process` inside an unstored `Task.detached` and blocked in `waitUntilExit()`: nothing held
// it, and cancelling the task that awaited it did not reach the child. Every installer now runs
// under `ProcessGroupRunner`, awaited directly, and the install's task is held so Settings' Cancel
// and Quit can cancel it; the runner's cancellation handler sends SIGTERM to the installer's whole
// process group, and the script's traps restore what it was replacing
// (Scripts/tests/test_f520_installer_cancel_restores.py delivers that signal to all four real
// scripts).
//
// These drive the real runner over a stub installer in a temp directory: a zsh script that records
// when it starts, when its TERM trap runs, and when it finishes on its own.

private let isAppleSilicon: Bool = {
    #if arch(arm64)
    return true
    #else
    return false
    #endif
}()

private final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value
    init(_ value: Value) { self.value = value }
    func withLock<T>(_ body: (inout Value) -> T) -> T {
        lock.lock(); defer { lock.unlock() }; return body(&value)
    }
}

/// A stand-in installer: `$1` is the directory it reports into.
private func writeStubInstaller(in directory: URL) throws -> URL {
    let script = directory.appendingPathComponent("stub-installer.sh")
    try """
    trap 'print trapped > "$1/trapped"; exit 130' TERM
    print started > "$1/started"
    sleep 20
    print finished > "$1/finished"
    """.write(to: script, atomically: true, encoding: .utf8)
    return script
}

private func exists(_ directory: URL, _ name: String) -> Bool {
    FileManager.default.fileExists(atPath: directory.appendingPathComponent(name).path)
}

@MainActor
private func waitUntil(_ what: String, _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(30)
    while !condition(), Date() < deadline {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    try #require(condition(), "timed out waiting for \(what)")
}

private func makeDirectory(_ label: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("F520-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

@MainActor
@Test("Cancelling an install's task stops the installer's process group, and its trap runs (F520)")
func cancellingTheInstallTaskStopsTheScript() async throws {
    let directory = try makeDirectory("runner")
    defer { try? FileManager.default.removeItem(at: directory) }
    let job = InstallerJob(
        component: .whisper,
        scriptURL: try writeStubInstaller(in: directory),
        arguments: [directory.path],
        logURL: directory.appendingPathComponent("install.log")
    )

    let task = Task { try await AppModel.runInstallerScript(job) }
    try await waitUntil("the installer to start") { exists(directory, "started") }
    task.cancel()
    let result = await task.result

    #expect(exists(directory, "trapped"), "the installer never received SIGTERM")
    #expect(!exists(directory, "finished"), "the installer ran to completion after its install was cancelled")
    #expect(throws: CancellationError.self) { try result.get() }
}

@MainActor
private func makeModel(_ label: String) throws -> (model: AppModel, root: URL) {
    let root = try makeDirectory(label)
    let defaults = try #require(UserDefaults(suiteName: "F520.\(label).\(UUID().uuidString)"))
    let model = AppModel(store: MeetingStore(rootDirectory: root.appendingPathComponent("Library")),
                         recorder: AudioCaptureEngine(), defaults: defaults,
                         whisperExecutable: { URL(fileURLWithPath: "/usr/bin/true") }, qwenInstalled: { true })
    return (model, root)
}

/// Every installer's job, rewritten onto `directory` and run by the real runner.
@MainActor
private func routeInstallsToStub(_ model: AppModel, directory: URL) throws {
    let script = try writeStubInstaller(in: directory)
    model.installerScriptURL = { _ in script }
    model.runInstallerJob = { job in
        try await AppModel.runInstallerScript(InstallerJob(
            component: job.component, scriptURL: script, arguments: [directory.path],
            logURL: directory.appendingPathComponent("install.log")
        ))
    }
}

@MainActor
@Test("Settings' Cancel stops a Local Whisper repair, and the row says the previous version was kept (F520)")
func cancelStopsARepairAndKeepsThePreviousVersion() async throws {
    let (model, root) = try makeModel("cancel")
    defer { try? FileManager.default.removeItem(at: root) }
    try routeInstallsToStub(model, directory: root)
    model.refreshRuntime()
    #expect(model.isRuntimeInstalled)

    model.installLocalWhisper()
    try await waitUntil("the installer to start") { exists(root, "started") }
    #expect(!model.isCancellingInstall(.whisper))

    model.cancelInstall(.whisper)
    #expect(model.isCancellingInstall(.whisper), "the button shows Cancelling… while the script restores")
    try await waitUntil("the install to end") { !model.isInstallingRuntime }

    #expect(exists(root, "trapped"))
    #expect(!exists(root, "finished"))
    #expect(model.installationMessage == "Installation cancelled. The previous version was kept.")
    #expect(model.alertMessage == nil, "a cancel the user asked for is not an error")
    #expect(!model.isCancellingInstall(.whisper))
    #expect(model.installTasks.isEmpty)
    #expect(model.canInstall(.whisper), "a cancelled install must not leave the next one refused")
}

@MainActor
@Test("A cancelled first install does not claim a previous version (F520)")
func cancelledFirstInstallClaimsNothing() async throws {
    let (model, root) = try makeModel("first")
    defer { try? FileManager.default.removeItem(at: root) }
    try routeInstallsToStub(model, directory: root)
    model.checkQwenInstalled = { false }
    model.refreshRuntime()

    model.installQwenASR()
    guard model.isInstallingQwenRuntime else {
        // Qwen refuses Intel before it starts; nothing here is about the architecture.
        #expect(!isAppleSilicon)
        return
    }
    try await waitUntil("the installer to start") { exists(root, "started") }
    model.cancelInstall(.qwen)
    try await waitUntil("the install to end") { !model.isInstallingQwenRuntime }

    #expect(model.qwenInstallationMessage == "Installation cancelled.")
}

@MainActor
@Test("Quit stops a running install (F520)", .enabled(if: isAppleSilicon))
func quitStopsARunningInstall() async throws {
    let (model, root) = try makeModel("quit")
    defer { try? FileManager.default.removeItem(at: root) }
    try routeInstallsToStub(model, directory: root)
    model.isSummarizerModelInstalled = { false }

    model.installSummarizer()
    try await waitUntil("the installer to start") { exists(root, "started") }

    // What AppEntry wires `AppLifecycle.onTerminate` to.
    model.cancelAllInstalls()
    try await waitUntil("the installer's trap") { exists(root, "trapped") }
    try await waitUntil("the install to end") { !model.isInstallingSummarizer }
    #expect(!exists(root, "finished"))
    #expect(model.summarizerInstallationMessage == "Installation cancelled.")
}

@MainActor
@Test("willTerminate, and only willTerminate, runs the terminate hook — before the flush (F520)")
func terminateHookRunsOnQuitOnly() {
    let events = Locked<[String]>([])
    let lifecycle = AppLifecycle()
    lifecycle.onTerminate = { events.withLock { $0.append("terminate") } }
    lifecycle.onFlush = { events.withLock { $0.append("flush") } }
    lifecycle.begin()
    defer { lifecycle.end() }

    NotificationCenter.default.post(name: NSApplication.willResignActiveNotification, object: nil)
    NotificationCenter.default.post(name: NSApplication.willTerminateNotification, object: nil)

    let expected: [String] = ["flush", "terminate", "flush"]
    #expect(events.withLock { $0 } == expected)
}

@Test("Quit is wired to stop installs, and every install row has a Cancel beside its progress (F520)")
func quitAndCancelAreWired() throws {
    let entry = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/AppEntry.swift")
    let initRegion = try #require(entry.range(of: "var body: some Scene {")).lowerBound
    let wiring = try #require(entry.range(of: "lifecycle.onTerminate = { [weak model] in model?.cancelAllInstalls() }"),
                              "AppEntry does not stop installs on quit")
    #expect(wiring.lowerBound < initRegion, "the quit hook must be wired in init(), not in the window's .task (F465)")

    let view = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/ContentView.swift")
        .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    for (progress, component) in [
        ("ProgressView(\"Installing. This can take several minutes…\")", "whisper"),
        ("ProgressView(\"Installing about 4.5 GB. This can take several minutes…\")", "qwen"),
        ("ProgressView(SpeakerAnalysisCopy.installProgressLabel)", "diarization"),
        ("ProgressView(\"Downloading the local summarization model. This can take several minutes…\")", "summarizer"),
    ] {
        #expect(view.contains("\(progress) Spacer() InstallCancelButton(model: model, component: .\(component))"),
                "no Cancel beside the .\(component) install's progress")
    }
    #expect(view.contains("Text(\"Downloading the search model…\").font(.caption).foregroundStyle(.secondary) InstallCancelButton(model: model, component: .askEmbeddings)"))

    let button = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/InstallCancelButton.swift")
    #expect(button.contains("model.cancelInstall(component)"))
    #expect(button.contains(".disabled(model.isCancellingInstall(component))"))
}
