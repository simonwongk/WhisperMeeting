import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F582 — F470 made `beginTranscription` queue instead of refuse while an auxiliary engine run or
// Quick Dictation holds the models, and left the model-install guard as it was: a transcription
// requested while a Whisper or Qwen install ran got "Wait for the local recognition model
// installation to finish before transcribing" and stayed `.recorded`, and no installer's epilogue
// pumped the queue. The install check now lives in `pumpTranscriptionQueue()` beside F470's gates,
// and every install's epilogue — success, failure, cancel — pumps (`launchInstall`).
//
// (What reaches `beginTranscription` during an install is the Transcribe and Transcribe Again
// buttons. The ticket's other examples do not: recording and every import already refuse or hold
// while a recognition install runs, before any meeting exists — the watched folder holds its files
// and delivers them on its next three-second look once the install ends.)

private func seg(_ text: String, _ start: Double, _ end: Double) -> TranscriptSegment {
    TranscriptSegment(speaker: nil, start: start, end: end, text: text)
}

private final class Gate: @unchecked Sendable {
    private let lock = NSLock()
    private var entered = false
    private var open = false
    func enter() { lock.withLock { entered = true } }
    var hasEntered: Bool { lock.withLock { entered } }
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

private struct Fixture {
    let model: AppModel
    let root: URL
    let meetingID: UUID
    let install: Gate
}

/// A `.recorded` meeting, a stub engine, and a Local Whisper install held open by `install` until
/// the test releases it (or it is cancelled). `failInstall` makes the released install fail.
@MainActor
private func makeFixture(whisperInstalled: Bool, failInstall: Bool = false) throws -> Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("F582-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root.appendingPathComponent("Recordings"), withIntermediateDirectories: true)
    let defaults = try #require(UserDefaults(suiteName: testSuiteName()))
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(), defaults: defaults,
                         whisperExecutable: { whisperInstalled ? URL(fileURLWithPath: "/usr/bin/true") : nil },
                         qwenInstalled: { true })
    model.selectedEngine = .whisperLarge
    let id = UUID()
    model.store.upsert(MeetingRecord(
        id: id, title: "Recorded during the install", recordingPath: "Recordings/\(id.uuidString)/meeting.wav",
        status: .recorded
    ))
    model.runTranscriptionEngineOverride = { _, _ in
        TranscriptionResult(id: "stub", text: "transcribed after the install", languageCode: "en",
                            audioDuration: 2, confidence: nil, segments: [seg("transcribed after the install", 0, 2)])
    }
    let install = Gate()
    model.installerScriptURL = { _ in URL(fileURLWithPath: "/usr/bin/true") }
    model.runInstallerJob = { job in
        install.enter()
        while !install.isOpen { try await Task.sleep(nanoseconds: 2_000_000) }
        if failInstall {
            throw InstallerError.scriptFailed(job.component, reason: "No network.", previousKept: false)
        }
    }
    return Fixture(model: model, root: root, meetingID: id, install: install)
}

@MainActor
@Test("A transcription requested during a model install waits in the queue and starts when the install ends (F582)")
func transcriptionDuringInstallIsQueuedThenRun() async throws {
    let fixture = try makeFixture(whisperInstalled: true)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let model = fixture.model

    model.installLocalWhisper()
    try await waitUntil("the install to start") { fixture.install.hasEntered }
    #expect(model.isInstallingRecognitionRuntime)

    model.beginTranscription(id: fixture.meetingID)

    #expect(model.alertMessage == nil, "refused instead of queued: \(model.alertMessage ?? "")")
    #expect(model.isQueuedForTranscription(fixture.meetingID))
    #expect(!model.hasActiveTranscription, "a transcription started while its engine was being replaced")
    #expect(model.store.meeting(id: fixture.meetingID)?.status == .recorded)
    #expect(model.queuedTranscriptionWaitMessage.contains("installation"), "\(model.queuedTranscriptionWaitMessage)")

    fixture.install.release()
    try await waitUntil("the queued meeting to be transcribed") {
        model.store.meeting(id: fixture.meetingID)?.status == .completed
    }
    #expect(model.store.meeting(id: fixture.meetingID)?.transcriptText.contains("transcribed after the install") == true)
}

@MainActor
@Test("A cancelled repair still starts the waiting transcription (F582)")
func cancelledInstallStillPumpsTheQueue() async throws {
    let fixture = try makeFixture(whisperInstalled: true)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let model = fixture.model

    model.installLocalWhisper()
    try await waitUntil("the install to start") { fixture.install.hasEntered }
    model.beginTranscription(id: fixture.meetingID)
    #expect(model.isQueuedForTranscription(fixture.meetingID))

    model.cancelInstall(.whisper)
    try await waitUntil("the queued meeting to be transcribed") {
        model.store.meeting(id: fixture.meetingID)?.status == .completed
    }
    #expect(model.installationMessage == "Installation cancelled. The previous version was kept.")
}

@MainActor
@Test("A first install that fails leaves the waiting meeting ready to transcribe, not failed (F582)")
func failedFirstInstallReturnsTheMeetingToReady() async throws {
    let fixture = try makeFixture(whisperInstalled: false, failInstall: true)
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let model = fixture.model
    #expect(!model.isRuntimeInstalled)

    model.installLocalWhisper()
    try await waitUntil("the install to start") { fixture.install.hasEntered }
    // The engine it needs is the one being installed: it waits for it, rather than being told to
    // install what is already installing.
    model.beginTranscription(id: fixture.meetingID)
    #expect(model.alertMessage == nil, "\(model.alertMessage ?? "")")
    #expect(model.isQueuedForTranscription(fixture.meetingID))

    fixture.install.release()
    try await waitUntil("the install to end") { !model.isInstallingRuntime }

    // Running it now could only fail it with "not installed" and replace the install's own alert;
    // it goes back to Transcribe instead, and the alert is the install's.
    #expect(!model.isQueuedForTranscription(fixture.meetingID))
    #expect(!model.hasActiveTranscription)
    #expect(model.store.meeting(id: fixture.meetingID)?.status == .recorded)
    #expect(model.alertMessage?.contains("Local Whisper could not be installed") == true, "\(model.alertMessage ?? "")")
}

@Test("The install check sits in the queue's pump beside F470's gates, not in beginTranscription (F582)")
func installCheckLivesInThePump() throws {
    let source = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/AppModel.swift")
    let begin = try #require(source.range(of: "func beginTranscription(id: UUID) {"))
    let beginBody = source[begin.upperBound...].prefix(600)
    #expect(!beginBody.contains("guard !isInstallingRecognitionRuntime"), "beginTranscription still refuses during an install")

    let pump = try #require(source.range(of: "private func pumpTranscriptionQueue() {"))
    let pumpBody = source[pump.upperBound...].prefix(1_200)
    #expect(pumpBody.contains("isInstallingRecognitionRuntime"), "the pump does not hold the queue during an install")

    let installs = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/ModelInstalls.swift")
    let launch = try #require(installs.range(of: "func launchInstall("))
    #expect(installs[launch.upperBound...].prefix(600).contains("resumeTranscriptionQueueAfterInstall()"),
            "an install's epilogue does not pump the queue")
}
