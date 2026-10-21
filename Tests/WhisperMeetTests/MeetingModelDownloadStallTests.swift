import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F901 — the app half. The meetings path builds its Whisper client through `makeWhisperClient`, whose
// default now carries `meetingModelDownloadStallTimeout`; a meeting whose first-use model download
// stalls fails with the reason and stays retryable. The run uses the REAL client with a stub `whisper`
// and a one-second window, through `beginTranscription`, as Stop & Transcribe queues one.

@MainActor
private func waitUntil(_ what: String, _ condition: () -> Bool) async throws {
    let deadline = SuspendingClock.now + .seconds(30)
    while !condition(), SuspendingClock.now < deadline { try await Task.sleep(for: .milliseconds(5)) }
    try #require(condition(), "timed out waiting for \(what)")
}

@MainActor
@Test("The app's own Whisper client stops a stalled model download after three minutes (F901)")
func appWhisperClientBoundsTheModelDownload() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("F901-default-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(),
                         defaults: try #require(UserDefaults(suiteName: testSuiteName())),
                         whisperExecutable: { nil }, qwenInstalled: { false })
    #expect(model.makeWhisperClient(URL(fileURLWithPath: "/usr/bin/true")).downloadStallTimeout
            == AppModel.meetingModelDownloadStallTimeout)
    #expect(AppModel.meetingModelDownloadStallTimeout == 180)
}

@MainActor
@Test("A meeting whose first-use model download stalls fails with the reason and can be transcribed again (F901)")
func aMeetingWithAStalledDownloadFailsRetryably() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("F901-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let folder = root.appendingPathComponent("Recordings/\(id.uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let tone = (0..<16_000).map { Float(0.3 * sin(2 * Double.pi * 440 * Double($0) / 16_000)) }
    try WAVWriter.wavData(from: tone, sampleRate: 16_000).write(to: folder.appendingPathComponent("meeting.wav"))
    let whisper = root.appendingPathComponent("whisper")
    try """
    #!/bin/zsh
    printf ' 42%%|####2     | 650M/1.51G [00:05<00:07, 120MiB/s]\\r' >&2
    exec sleep 120
    """.write(to: whisper, atomically: true, encoding: .utf8)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: whisper.path)

    let model = AppModel(
        store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(),
        defaults: try #require(UserDefaults(suiteName: testSuiteName())),
        whisperExecutable: { whisper }, qwenInstalled: { false }, carryInitialPromptSupport: { _ in true }
    )
    model.selectedEngine = .whisperLarge
    let scratch = root.appendingPathComponent("scratch", isDirectory: true)
    model.engineScratchDirectory = scratch
    model.makeWhisperClient = { executable in
        LocalWhisperClient(executableURL: executable, modelDirectory: root.appendingPathComponent("Models"),
                           scratchDirectory: scratch, downloadStallTimeout: 1)
    }
    model.store.upsert(MeetingRecord(id: id, title: "First meeting", duration: 1,
                                     recordingPath: "Recordings/\(id.uuidString)/meeting.wav", status: .recorded))

    model.beginTranscription(id: id)
    try await waitUntil("the meeting to fail") { model.store.meeting(id: id)?.status == .failed }

    let meeting = try #require(model.store.meeting(id: id))
    let reason = LocalWhisperError.modelDownloadStalled(seconds: 1).errorDescription ?? ""
    #expect(meeting.errorMessage?.contains(reason) == true, "\(meeting.errorMessage ?? "nil")")
    #expect(TranscriptionFailureClassifier.classify(LocalWhisperError.modelDownloadStalled(seconds: 1)).action == .retry)
    try await waitUntil("the run to end") { !model.hasActiveTranscription }
    // Retryable: the meeting can be queued again, and is.
    model.beginTranscription(id: id)
    #expect(model.hasActiveTranscription || model.isQueuedForTranscription(id), "the failed meeting could not be transcribed again")
    model.cancelTranscription(id: id)
    try await waitUntil("the retry to stop") { !model.hasActiveTranscription }
}
