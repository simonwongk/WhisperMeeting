import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F511 — LocalWhisperClient/QwenASRClient already cap a raw subprocess log to ~4,000 characters
// at their own throw site (`SubprocessLogSummary`), and `LocalWhisperClientTests`/
// `QwenASRClientTests` test exactly that (LocalWhisperClientTests.swift:166,
// QwenASRClientTests.swift:141ish). Neither test drives the result through
// `AppModel.handle(error:id:)` into a persisted `MeetingRecord`, so nothing confirmed the FULL
// path — client throw → `handle` → `store.update` → `meetings.json` — actually keeps the cap
// rather than re-inflating it (the classifier's own explanation prose, "recording is safe"/
// "previous transcript unchanged" suffixes) or losing it entirely for an error whose
// `localizedDescription` never went through the client's own summarizer at all.
//
// `handle(error:id:)` is `private`, so this drives it the same way every real failure reaches it:
// through `runTranscriptionEngineOverride` throwing, `performTranscription` catching, and
// `handle` persisting — the real call path, not a direct call into a private method.

@MainActor
private func waitUntil(_ what: String, timeoutSeconds: Double = 3, _ condition: () -> Bool) async throws {
    let deadline = Date().addingTimeInterval(timeoutSeconds)
    while !condition(), Date() < deadline {
        try await Task.sleep(nanoseconds: 5_000_000)
    }
    try #require(condition(), "timed out waiting for \(what)")
}

@MainActor
@Test("An oversized helper failure is capped in the persisted MeetingRecord.errorMessage (F511)")
func oversizedHelperLogIsCappedInPersistedErrorMessage() async throws {
    let suite = testSuiteName()
    let defaults = UserDefaults(suiteName: suite)!
    defaults.removePersistentDomain(forName: suite)
    defer { defaults.removePersistentDomain(forName: suite) }
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("OversizedErrorMessageCapTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(
        at: root.appendingPathComponent("Recordings"), withIntermediateDirectories: true
    )
    let model = AppModel(
        store: MeetingStore(rootDirectory: root),
        recorder: AudioCaptureEngine(),
        defaults: defaults,
        whisperExecutable: { URL(fileURLWithPath: "/usr/bin/true") },
        qwenInstalled: { false },
        carryInitialPromptSupport: { _ in true }
    )
    model.selectedEngine = .whisperLarge

    // Stands in for a helper that never applied `SubprocessLogSummary` at all — the untrimmed
    // ~200 KB payload openai-whisper's exit-0-no-output failure used to produce whole (F511's
    // original bug). ~220,000 characters, well past any reasonable cap.
    let hugeLog = String(repeating: "noise line\n", count: 20_000)
    model.runTranscriptionEngineOverride = { _, _ in
        throw LocalWhisperError.processFailed(hugeLog)
    }

    let id = UUID()
    model.store.upsert(MeetingRecord(
        id: id, title: "Oversized failure",
        recordingPath: "Recordings/\(id.uuidString)/meeting.wav",
        status: .recorded
    ))
    model.beginTranscription(id: id)

    try await waitUntil("the meeting to reach a terminal status") {
        model.store.meeting(id: id)?.status == .failed
    }

    let persisted = try #require(
        model.store.meeting(id: id)?.errorMessage,
        "a failed meeting with no prior transcript must persist an errorMessage"
    )
    #expect(
        persisted.count < 4_500,
        "persisted errorMessage was \(persisted.count) characters, expected under the cap"
    )
    // The alert the user sees is built from the same message — it must stay short too.
    #expect((model.alertMessage?.count ?? 0) < 4_500)
}
