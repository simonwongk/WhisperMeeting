import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F602 — Transcribe Again on a COMPLETED meeting queues without changing the meeting's status (it
// stays `.completed` until the run starts), and the status card — the only place that says "Queued",
// says what the job is waiting for, and holds the Remove button, the sole UI caller of
// `cancelTranscription` — was drawn only for `status != .completed`. So the user confirmed Transcribe
// Again while another job ran, and the page showed nothing; the job could not be removed; confirming
// a second time did nothing (`TranscriptionQueue.enqueue` is false for a queued id); and F583 refuses
// Restore Library with "…or remove it from the queue", naming a control that was not there.

private func seg(_ text: String, _ start: Double, _ end: Double) -> TranscriptSegment {
    TranscriptSegment(speaker: nil, start: start, end: end, text: text)
}

private let oldLines = [seg("Old first line.", 0, 2), seg("Old second line.", 2, 4)]

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
    /// A meeting whose first transcription is held open by `running`, so everything after it queues.
    let busyID: UUID
    /// A completed meeting that can be transcribed again.
    let doneID: UUID
    let running: Gate
}

@MainActor
private func makeFixture() throws -> Fixture {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("F602-\(UUID().uuidString)")
    let busyID = UUID()
    let doneID = UUID()
    for id in [busyID, doneID] {
        try FileManager.default.createDirectory(
            at: root.appendingPathComponent("Recordings/\(id.uuidString)"), withIntermediateDirectories: true
        )
    }
    let defaults = try #require(UserDefaults(suiteName: testSuiteName()))
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(), defaults: defaults)
    model.store.upsert(MeetingRecord(
        id: busyID, title: "Busy", recordingPath: "Recordings/\(busyID.uuidString)/meeting.wav", status: .recorded
    ))
    model.store.upsert(MeetingRecord(
        id: doneID, title: "Done", recordingPath: "Recordings/\(doneID.uuidString)/meeting.wav",
        status: .completed, transcriptText: TranscriptFormatter.timestamped(oldLines),
        languageCode: "en", segments: oldLines, transcriptNormalized: true
    ))
    model.findWhisperExecutable = { URL(fileURLWithPath: "/usr/bin/true") }
    let running = Gate()
    model.runTranscriptionEngineOverride = { _, _ in
        running.enter()
        while !running.isOpen { try await Task.sleep(nanoseconds: 2_000_000) }
        return TranscriptionResult(id: "x", text: "New line.", languageCode: "en", audioDuration: 2,
                                   confidence: nil, segments: [seg("New line.", 0, 2)])
    }
    return Fixture(model: model, root: root, busyID: busyID, doneID: doneID, running: running)
}

/// Queues Transcribe Again on the completed meeting behind the busy one.
@MainActor
private func queueTranscribeAgain(_ fixture: Fixture) async throws {
    let model = fixture.model
    model.beginTranscription(id: fixture.busyID)
    try await waitUntil("the busy meeting's transcription to start") { fixture.running.hasEntered }
    model.transcribeAgain(id: fixture.doneID)
}

/// Lets everything still held finish, so no job outlives the test's temp directory.
@MainActor
private func drain(_ fixture: Fixture) async throws {
    fixture.running.release()
    try await waitUntil("the queue to drain") {
        !fixture.model.hasActiveTranscription && !fixture.model.hasQueuedTranscriptions
    }
}

@MainActor
@Test("A Transcribe Again that is waiting behind another job refuses a second one, and says why (F602)")
func aQueuedTranscribeAgainIsRefusedAsAlreadyQueued() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let model = fixture.model
    #expect(model.transcribeAgainBlockedReason(for: fixture.doneID) == nil, "control: nothing is ahead of it yet")

    try await queueTranscribeAgain(fixture)

    #expect(model.isQueuedForTranscription(fixture.doneID))
    #expect(model.store.meeting(id: fixture.doneID)?.status == .completed,
            "queuing does not change the status — which is why the card hid it")
    #expect(model.transcribeAgainBlockedReason(for: fixture.doneID) == AppModel.transcribeAgainAlreadyQueued)
    try await drain(fixture)
}

@MainActor
@Test("A queued Transcribe Again gets the status card, and it says what the wait will do (F602)")
func aQueuedTranscribeAgainShowsItsStatusCard() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let model = fixture.model
    let settled = try #require(model.store.meeting(id: fixture.doneID))
    #expect(!model.showsTranscriptionStatusCard(for: settled), "control: a settled transcript has no card")

    try await queueTranscribeAgain(fixture)

    // The card that holds "Queued" and Remove is drawn for the completed meeting while it waits…
    let queued = try #require(model.store.meeting(id: fixture.doneID))
    #expect(queued.status == .completed)
    #expect(model.showsTranscriptionStatusCard(for: queued))
    // …and says what it is waiting for, and that the new transcript replaces this one.
    #expect(model.queuedStatusDetail(for: queued).hasPrefix(model.queuedTranscriptionWaitMessage))
    #expect(model.queuedStatusDetail(for: queued).hasSuffix(AppModel.queuedTranscribeAgainReplaces))

    // The meeting that is actually running keeps its card, and a first transcription that is queued
    // says only what it waits for: it has no transcript to replace.
    let running = try #require(model.store.meeting(id: fixture.busyID))
    #expect(model.showsTranscriptionStatusCard(for: running))
    let recorded = MeetingRecord(id: UUID(), title: "Not yet transcribed", status: .recorded)
    #expect(model.queuedStatusDetail(for: recorded) == model.queuedTranscriptionWaitMessage)

    // Removing it takes the card away again.
    model.cancelTranscription(id: fixture.doneID)
    let removed = try #require(model.store.meeting(id: fixture.doneID))
    #expect(!model.showsTranscriptionStatusCard(for: removed))
    try await drain(fixture)
}

// The shape F583's restore refusal is about: queued behind Quick Dictation, so nothing is RUNNING —
// no active transcription, no auxiliary run — and the only thing that says a job is waiting is the
// card. F583 tells the user to remove it; this is the Remove it points at.
@MainActor
@Test("A Transcribe Again queued behind Quick Dictation has its card and its Remove too (F602, F583)")
func aTranscribeAgainQueuedBehindDictationHasItsCard() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let model = fixture.model
    model.configureDictationGuard { true }

    model.transcribeAgain(id: fixture.doneID)

    try #require(model.isQueuedForTranscription(fixture.doneID))
    try #require(!model.hasActiveTranscription, "nothing is running: dictation is holding the queue")
    let queued = try #require(model.store.meeting(id: fixture.doneID))
    #expect(queued.status == .completed)
    #expect(model.showsTranscriptionStatusCard(for: queued))
    #expect(model.queuedStatusDetail(for: queued).hasPrefix(model.queuedTranscriptionWaitMessage))
    #expect(model.transcribeAgainBlockedReason(for: fixture.doneID) == AppModel.transcribeAgainAlreadyQueued)

    model.cancelTranscription(id: fixture.doneID)
    #expect(!model.hasQueuedTranscriptions, "Remove empties the queue, so F583's restore refusal clears")
    #expect(model.store.meeting(id: fixture.doneID)?.segments == oldLines)
}

@MainActor
@Test("Remove drops a queued Transcribe Again and leaves the transcript it would have replaced (F602)")
func removingAQueuedTranscribeAgainKeepsTheTranscript() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let model = fixture.model
    try await queueTranscribeAgain(fixture)
    try #require(model.isQueuedForTranscription(fixture.doneID))

    model.cancelTranscription(id: fixture.doneID)

    #expect(!model.isQueuedForTranscription(fixture.doneID))
    #expect(model.store.meeting(id: fixture.doneID)?.status == .completed)
    #expect(model.store.meeting(id: fixture.doneID)?.segments == oldLines)
    #expect(model.transcribeAgainBlockedReason(for: fixture.doneID) == nil, "and it can be asked for again")
    try await drain(fixture)
    #expect(model.store.meeting(id: fixture.doneID)?.segments == oldLines, "a removed job never ran")
}

@MainActor
@Test("A queued Transcribe Again that is left alone runs when its turn comes (F602 control)")
func aQueuedTranscribeAgainStillRuns() async throws {
    let fixture = try makeFixture()
    defer { try? FileManager.default.removeItem(at: fixture.root) }
    let model = fixture.model
    try await queueTranscribeAgain(fixture)

    try await drain(fixture)

    #expect(model.store.meeting(id: fixture.doneID)?.segments.map(\.text) == ["New line."])
    #expect(model.transcribeAgainBlockedReason(for: fixture.doneID) == nil, "settled again, so it is offered again")
}

// The view cannot be rendered here (F174's standing reason), so the one thing that decides whether
// the card is drawn is checked in the source, comments stripped first (F285): the card's gate asks the
// model, and the old gate — `status != .completed` on its own — is gone. The card holds the Queued
// text and the Remove button, so this is the guard that makes the F583 message true.
@Test("A queued meeting's status card is drawn whatever its status, with Remove (F602)")
func theStatusCardIsNotHiddenForACompletedMeeting() throws {
    let source = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/ContentView.swift")
    let start = try #require(source.range(of: "private func statusCard(_ meeting: MeetingRecord)"))
    let rest = source[start.upperBound...]
    let end = rest.range(of: "\n    private func statusIcon")?.lowerBound ?? rest.endIndex
    let card = String(rest[..<end]).split(whereSeparator: \.isWhitespace).joined(separator: " ")

    #expect(card.contains("if model.showsTranscriptionStatusCard(for: meeting) {"), "the card asks the model")
    #expect(!card.contains("if meeting.status != .completed {"), "and is not gated on status alone")
    #expect(card.contains("model.cancelTranscription(id: meeting.id)"), "Remove is still on it")
    #expect(card.contains(#"Button(isQueued ? "Remove" : "Cancel""#))
}
