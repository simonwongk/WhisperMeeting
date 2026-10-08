import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F567 part 2 — every installer's guard refused in states its Settings button did not know about,
// so the press did nothing: no progress, no message. The summarizer's button ignored a running
// second opinion or segment re-run; the speaker-analysis button ignored a running summarizer or
// search-model install. (The ticket also said the speaker-analysis button stayed enabled while an
// analysis ran. It did not: `requestSpeakerDiarization` claims `isRunningAuxiliaryEngine`, which
// that button's hand-written list already included.)
//
// One `canInstall(_:)` now answers for the guard and the button alike, as F514 did for Whisper and
// Qwen. The views have no render harness (F174), so the buttons' wiring is pinned against the
// comment-stripped source (F285); the check itself is driven for real.

private let isAppleSilicon: Bool = {
    #if arch(arm64)
    return true
    #else
    return false
    #endif
}()

private func seg(_ text: String, _ start: Double, _ end: Double) -> TranscriptSegment {
    TranscriptSegment(speaker: nil, start: start, end: end, text: text)
}

private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var entered = false
    private var open = false
    private var runs = 0
    func enter() { lock.withLock { entered = true; runs += 1 } }
    var hasEntered: Bool { lock.withLock { entered } }
    var runCount: Int { lock.withLock { runs } }
    func release() { lock.withLock { open = true } }
    var isOpen: Bool { lock.withLock { open } }
}

@MainActor
private func waitUntil(_ what: String, _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(30)
    while !condition(), Date() < deadline {
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    try #require(condition(), "timed out waiting for \(what)")
}

@MainActor
private func makeModel(_ label: String) throws -> (model: AppModel, root: URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("F567-\(label)-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root.appendingPathComponent("Recordings"), withIntermediateDirectories: true)
    let defaults = try #require(UserDefaults(suiteName: testSuiteName()))
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(), defaults: defaults,
                         whisperExecutable: { URL(fileURLWithPath: "/usr/bin/true") }, qwenInstalled: { true })
    return (model, root)
}

@Test("The summarizer and speaker-analysis buttons are disabled on the check their installers ask (F567)")
func settingsInstallButtonsShareTheInstallersCheck() throws {
    let source = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/ContentView.swift")
        .split(whereSeparator: \.isWhitespace).joined(separator: " ")
    #expect(source.contains(
        "Button(model.isSummarizerInstalled ? \"Repair or Update\" : \"Install Local Model\") { model.installSummarizer() } .buttonStyle(.bordered) .disabled(!model.canInstall(.summarizer))"
    ), "the summarizer's Settings button is not disabled on canInstall(.summarizer)")
    #expect(source.contains(
        "Button(model.isDiarizationInstalled ? \"Repair or Update\" : \"Install Speaker Analysis\") { model.installSpeakerDiarization() } .buttonStyle(.bordered) .disabled(!model.canInstall(.diarization))"
    ), "the speaker-analysis Settings button is not disabled on canInstall(.diarization)")

    let model = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/AppModel.swift")
    for (function, check) in [
        ("func installSummarizer()", "guard canInstall(.summarizer) else { return }"),
        ("func installSpeakerDiarization()", "guard canInstall(.diarization) else { return }"),
    ] {
        let start = try #require(model.range(of: function), "\(function) not found")
        #expect(model[start.upperBound...].prefix(400).contains(check), "\(function) does not guard on the shared check")
    }
}

@MainActor
@Test("A running second opinion blocks the summarizer install, and says so (F567)")
func secondOpinionBlocksTheSummarizerInstall() async throws {
    let (model, root) = try makeModel("aux")
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    model.store.upsert(MeetingRecord(
        id: id, title: "Held", recordingPath: "Recordings/\(id.uuidString)/meeting.wav",
        status: .completed, transcriptText: "held", segments: [seg("held", 0, 2)],
        transcriptionEngine: .whisperLarge
    ))
    let gate = Gate()
    model.runTranscriptionEngineOverride = { _, _ in
        gate.enter()
        while !gate.isOpen { try await Task.sleep(nanoseconds: 2_000_000) }
        return TranscriptionResult(id: "stub", text: "held", languageCode: "en", audioDuration: 2,
                                   confidence: nil, segments: [seg("held", 0, 2)])
    }
    let jobs = Gate()
    model.installerScriptURL = { _ in URL(fileURLWithPath: "/usr/bin/true") }
    model.runInstallerJob = { _ in jobs.enter() }

    #expect(model.canInstall(.summarizer))
    model.requestSecondOpinion(id: id)
    try await waitUntil("the second opinion to reach its engine") { gate.hasEntered }

    #expect(!model.canInstall(.summarizer))
    let reason = try #require(model.installBlockedReason(for: .summarizer))
    #expect(reason.contains("second opinion"), "\(reason)")
    model.installSummarizer()
    #expect(!model.isInstallingSummarizer)
    #expect(jobs.runCount == 0, "the summarizer installer ran atop a second opinion")

    gate.release()
    try await waitUntil("the second opinion to finish") { !model.isRunningAuxiliaryEngine }
    #expect(model.canInstall(.summarizer))
}

@MainActor
@Test(
    "A running summarizer install blocks the speaker-analysis install, and says so (F567)",
    .enabled(if: isAppleSilicon)
)
func summarizerInstallBlocksSpeakerAnalysis() async throws {
    let (model, root) = try makeModel("summarizer")
    defer { try? FileManager.default.removeItem(at: root) }
    let gate = Gate()
    model.installerScriptURL = { _ in URL(fileURLWithPath: "/usr/bin/true") }
    model.runInstallerJob = { _ in
        gate.enter()
        while !gate.isOpen { try await Task.sleep(nanoseconds: 2_000_000) }
    }
    let diarizationRuns = Gate()
    model.runDiarizationInstaller = { _, _ in diarizationRuns.enter() }
    model.isSummarizerModelInstalled = { false }

    #expect(model.canInstall(.diarization))
    model.installSummarizer()
    try await waitUntil("the summarizer installer to start") { gate.hasEntered }

    #expect(model.isInstallingSummarizer)
    #expect(!model.canInstall(.diarization))
    #expect(model.installBlockedReason(for: .diarization) == "Another install is already running.")
    model.installSpeakerDiarization()
    #expect(diarizationRuns.runCount == 0, "speaker analysis installed atop a summarizer install")

    gate.release()
    try await waitUntil("the summarizer install to end") { !model.isInstallingSummarizer }
    #expect(model.canInstall(.diarization))
}

@MainActor
@Test("A failed Local Whisper install shows the installer's reason, not 'Local transcription failed' (F567)")
func whisperInstallFailureShowsTheScriptReason() async throws {
    let (model, root) = try makeModel("whisper")
    defer { try? FileManager.default.removeItem(at: root) }
    let script = root.appendingPathComponent("failing-installer.sh")
    try """
    print "==> Installing python@3.11"
    print -u2 "Error: python@3.11: the bottle could not be downloaded."
    exit 1
    """.write(to: script, atomically: true, encoding: .utf8)
    let runtime = root.appendingPathComponent("Runtime")
    model.installerScriptURL = { _ in script }
    // The real runner, over a job rewritten onto the temp runtime — never the real one.
    model.runInstallerJob = { job in
        try await AppModel.runInstallerScript(InstallerJob(
            component: job.component, scriptURL: job.scriptURL, arguments: [runtime.path],
            logURL: runtime.appendingPathComponent("install.log")
        ))
    }

    model.installLocalWhisper()
    try await waitUntil("the install to finish") { !model.isInstallingRuntime }

    let alert = try #require(model.alertMessage)
    #expect(alert == "Local Whisper could not be installed. Error: python@3.11: the bottle could not be downloaded. The previous version was kept.",
            "\(alert)")
    #expect(!alert.contains("transcription"))
    // The whole output is still on disk for diagnosis.
    let log = try String(contentsOf: runtime.appendingPathComponent("install.log"), encoding: .utf8)
    #expect(log.contains("==> Installing python@3.11"))
}
