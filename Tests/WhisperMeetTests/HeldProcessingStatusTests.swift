import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F935 — a transcription's `.processing` write that the banner is holding (F885).
//
// `AppModel.apply(progress:)` persists the `.processing` transition "once", using the list's status
// as its memory. A `.processing` whose save lost twice is held by the store, out of the list, and
// every later result for that meeting is queued behind it (`MeetingStore.update`) without reaching
// the list either. So while the banner waited, the list's copy stayed `.recorded`, and every progress
// tick queued one more closure to make the same transition: 200 ticks, 201 held (the review of Wave
// 5 lane Y, probe P-Y1). The progress path now asks the store whether a result is held for the
// meeting and writes nothing while one is; the held `.processing` lands with the answer, in order.
//
// The run is driven through the real path a Whisper run takes — `performTranscription` →
// `executeEngine` → `apply(progress:)` — with a stub engine that reports progress.

@MainActor
private func otherCopyCommits(in root: URL, _ change: ([MeetingRecord]) -> [MeetingRecord]) throws {
    let rival = BackupJSONStore<[MeetingRecord]>(
        primaryURL: root.appendingPathComponent("meetings.json"),
        backupURL: root.appendingPathComponent("meetings.backup.json"),
        writer: "ffff9999",
        recordCount: { $0.count }
    )
    let seen = try rival.load()
    _ = try rival.save(change(seen?.value ?? []), expecting: seen?.token)
}

@MainActor
private func onDisk(_ root: URL, _ id: UUID) -> MeetingRecord? {
    MeetingStore(rootDirectory: root).meeting(id: id)
}

private let finished = "We agreed to ship on Friday."

@MainActor
@Test("A held .processing status is not queued again by every progress tick, and lands with the answer (F935)")
func aHeldProcessingStatusIsNotQueuedPerTick() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("F935-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let suite = testSuiteName()
    let defaults = try #require(UserDefaults(suiteName: suite))
    defer {
        defaults.removePersistentDomain(forName: suite)
        try? FileManager.default.removeItem(at: root)
    }
    let model = AppModel(
        store: MeetingStore(rootDirectory: root, transcriptWriteDebounce: 60), recorder: AudioCaptureEngine(),
        defaults: defaults, whisperExecutable: { URL(fileURLWithPath: "/usr/bin/true") }, qwenInstalled: { true }
    )
    let store = model.store
    let standup = UUID(), review = UUID()
    store.upsert(MeetingRecord(id: standup, title: "Standup", status: .completed))
    store.upsert(MeetingRecord(id: review, title: "Review", recordingPath: "none", status: .recorded))
    // The banner, up: this window renamed the Standup, and the other copy renamed it first.
    try otherCopyCommits(in: root) { $0.map { var r = $0; if r.id == standup { r.title = "Standup, renamed there" }; return r } }
    store.update(id: standup) { $0.title = "Standup, renamed here" }
    try #require(store.conflictOffer?.delta.contains { $0.id == standup } == true, "fixture: the rename lost and was offered back")

    // A run that reports progress 200 times, then finishes.
    let ticks = 200
    model.runTranscriptionEngineWithProgressOverride = { _, _, onProgress in
        for tick in 0..<ticks {
            await onProgress(LocalTranscriptionProgress(phase: .transcribing, fractionCompleted: Double(tick) / Double(ticks)))
        }
        return TranscriptionResult(id: "F935", text: finished, languageCode: "en", audioDuration: 2, confidence: nil, segments: [])
    }
    // The other copy saves before the run's first write (`.processing`) and again before its re-save,
    // so that write is held for the banner's answer (F885).
    try otherCopyCommits(in: root) { $0 + [MeetingRecord(title: "The other copy's first", status: .recorded)] }
    var saves = 0
    store.beforeIndexSaveForTesting = {
        saves += 1
        if saves == 2 {
            try? otherCopyCommits(in: root) { $0 + [MeetingRecord(title: "The other copy's second", status: .recorded)] }
        }
    }

    model.beginTranscription(id: review)
    let deadline = Date().addingTimeInterval(30)
    while model.hasActiveTranscription || model.hasQueuedTranscriptions, Date() < deadline {
        try await Task.sleep(for: .milliseconds(5))
    }
    try #require(!model.hasActiveTranscription && !model.hasQueuedTranscriptions, "the run did not finish in 30 s")
    store.beforeIndexSaveForTesting = nil

    try #require(store.conflictOffer != nil, "fixture: the banner should still be up")
    try #require(store.meeting(id: review)?.status == .recorded, "fixture: the .processing write was applied, not held")
    #expect(store.heldResultCount(for: review) == 2,
            "held for Review: the .processing write and the result — one more per progress tick before F935")

    store.keepConflictedEdit()

    #expect(store.conflictOffer == nil)
    let saved = try #require(onDisk(root, review))
    #expect(saved.status == .completed, "the held .processing was made after the result: \(saved.status)")
    #expect(saved.transcriptText == finished)
}
