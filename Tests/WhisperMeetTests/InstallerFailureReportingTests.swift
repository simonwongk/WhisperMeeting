import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F567 part 1 — an installer failure used to be reported through the error type of the feature it
// installs. Speaker analysis was the worst: `LocalDiarizationError.processFailed` renders a fixed
// "Speaker analysis did not finish. Your transcript is unchanged." and never its associated value,
// so the one line saying what went wrong — the script's own "Could not download … Check your
// connection" — was dropped, and the alert talked about a transcript nobody had touched. The Qwen,
// summarizer and speaker-analysis rows also said "The previous … was preserved" on a first install,
// where there was nothing to preserve.
//
// These run the REAL installer runner (`spawnDiarizationInstaller`, a real `/bin/zsh` process) over
// a stub script in a temp directory — the runner is what builds the error, so stubbing it out would
// test nothing. Only the installer script and the runtime directory are stand-ins.

/// `installSpeakerDiarization` refuses Intel before it reaches the runner (F219); the architecture is
/// not what these tests are about. (`AppModel.diarizationIsSupportedOnCurrentMac` is main-actor
/// isolated, so a trait cannot read it.)
private let isAppleSilicon: Bool = {
    #if arch(arm64)
    return true
    #else
    return false
    #endif
}()

private let failureLine = "Could not download the speaker-analysis files. Check your connection and try again."

private struct Fixture {
    let model: AppModel
    let root: URL
}

@MainActor
private func makeFixture(installedBefore: Bool) throws -> Fixture {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("F567-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root.appendingPathComponent("Runtime"), withIntermediateDirectories: true)
    let defaults = try #require(UserDefaults(suiteName: testSuiteName()))
    let model = AppModel(
        store: MeetingStore(rootDirectory: root.appendingPathComponent("Library")),
        recorder: AudioCaptureEngine(),
        defaults: defaults
    )
    model.diarizationRuntimeDirectory = root.appendingPathComponent("Runtime/Diarization", isDirectory: true)
    model.isDiarizationModelInstalled = { installedBefore }
    model.refreshRuntime()

    // Output the way the real script produces it: progress first, the user-facing line last.
    let script = root.appendingPathComponent("failing-installer.sh")
    try """
    print "Fetching Segmentation.mlmodelc/coremldata.bin"
    print -u2 "curl: (6) Could not resolve host: huggingface.co"
    print -u2 "\(failureLine)"
    exit 1
    """.write(to: script, atomically: true, encoding: .utf8)
    model.runDiarizationInstaller = { _, runtime in
        try await AppModel.spawnDiarizationInstaller(scriptURL: script, runtimeDirectory: runtime)
    }
    return Fixture(model: model, root: root)
}

@MainActor
private func waitForInstallToEnd(_ model: AppModel) async throws {
    let deadline = Date().addingTimeInterval(30)
    while model.isInstallingDiarizationRuntime, Date() < deadline {
        try await Task.sleep(nanoseconds: 10_000_000)
    }
    try #require(!model.isInstallingDiarizationRuntime, "the install never finished")
}

@MainActor
@Test(
    "A failed speaker-analysis install shows the installer's own reason, not a transcript message (F567)",
    .enabled(if: isAppleSilicon)
)
func speakerAnalysisInstallFailureShowsTheScriptReason() async throws {
    let fixture = try makeFixture(installedBefore: false)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let model = fixture.model

    model.installSpeakerDiarization()
    try await waitForInstallToEnd(model)

    let alert = try #require(model.alertMessage)
    #expect(alert.contains(failureLine), "the script's reason was dropped: \(alert)")
    #expect(!alert.contains("transcript"), "an install failure is not a transcript failure: \(alert)")
    let status = try #require(model.diarizationInstallationMessage)
    #expect(status.contains("failed"))
    #expect(status.contains(failureLine), "the Settings row does not say why: \(status)")
    // Nothing was installed before, so nothing was kept.
    #expect(!status.contains("kept") && !status.contains("preserved"), "claims a previous version on a first install: \(status)")
}

@MainActor
@Test(
    "A failed repair says the previous version was kept, because it was (F567)",
    .enabled(if: isAppleSilicon)
)
func speakerAnalysisRepairFailureSaysThePreviousVersionWasKept() async throws {
    let fixture = try makeFixture(installedBefore: true)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let model = fixture.model

    model.installSpeakerDiarization()
    try await waitForInstallToEnd(model)

    let status = try #require(model.diarizationInstallationMessage)
    #expect(status.contains(failureLine))
    #expect(status.contains("The previous version was kept."), "\(status)")
    #expect(model.isDiarizationInstalled)
}
