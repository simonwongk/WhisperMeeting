import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F515 — a completed meeting had no way to be transcribed again, although F420's lost timestamps come
// back only that way and three notices tell the user to "transcribe again". And a re-run that does
// not finish must not make a meeting that HAS a transcript look untranscribed: cancelling set
// `.recorded`, failing set `.failed`, and an interrupted run was recovered as `.recorded`.

private func seg(_ text: String, _ start: Double, _ end: Double) -> TranscriptSegment {
    TranscriptSegment(speaker: nil, start: start, end: end, text: text)
}

private let oldLines = [seg("Old first line.", 0, 2), seg("Old second line.", 2, 4)]

@MainActor
private func completedMeeting(
    engine: @escaping (MeetingTranscriptionSelection, URL) async throws -> TranscriptionResult
) throws -> (AppModel, UUID) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("TranscribeAgain-\(UUID().uuidString)")
    let id = UUID()
    try FileManager.default.createDirectory(
        at: root.appendingPathComponent("Recordings/\(id.uuidString)"), withIntermediateDirectories: true
    )
    let defaults = UserDefaults(suiteName: testSuiteName())!
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(), defaults: defaults)
    model.store.upsert(MeetingRecord(
        id: id, title: "Day 4 2", recordingPath: "Recordings/\(id.uuidString)/meeting.wav",
        status: .completed, transcriptText: TranscriptFormatter.timestamped(oldLines),
        languageCode: "en", segments: oldLines, transcriptNormalized: true
    ))
    model.findWhisperExecutable = { URL(fileURLWithPath: "/usr/bin/true") }
    model.runTranscriptionEngineOverride = engine
    return (model, id)
}

/// The run's outcome is the subject, so waiting for the queue to drain is the assertion's own
/// precondition and is required, never assumed (AGENTS.md: a timeout must fail as a timeout).
///
/// Polls under a wall-clock cap, never a yield count (F639): a fixed budget of `Task.yield()`s
/// expires under a starved scheduler before the condition it is waiting for becomes true, failing
/// a claim that was never false.
@MainActor
private func waitForTheRunToEnd(_ model: AppModel) async throws {
    var ticks = 0
    while model.hasActiveTranscription, ticks < 6_000 { try await Task.sleep(nanoseconds: 5_000_000); ticks += 1 }
    try #require(!model.hasActiveTranscription, "the transcription never finished")
}

@MainActor
@Test("A completed meeting can be transcribed again, and the new transcript replaces the old (F515)")
func aCompletedMeetingIsTranscribedAgain() async throws {
    let newLines = [seg("New first line.", 0, 2), seg("New second line.", 2, 4)]
    let (model, id) = try completedMeeting { _, _ in
        TranscriptionResult(id: "x", text: "New first line. New second line.", languageCode: "en",
                            audioDuration: 4, confidence: nil, segments: newLines)
    }
    #expect(model.transcribeAgainBlockedReason(for: id) == nil)

    model.transcribeAgain(id: id)
    try await waitForTheRunToEnd(model)

    let meeting = try #require(model.store.meeting(id: id))
    #expect(meeting.status == .completed)
    #expect(meeting.segments == newLines)
}

@MainActor
@Test("A cancelled re-run keeps the transcript it would have replaced, and stays completed (F515)")
func aCancelledReRunKeepsTheTranscript() async throws {
    let (model, id) = try completedMeeting { _, _ in throw CancellationError() }
    model.transcribeAgain(id: id)
    try await waitForTheRunToEnd(model)

    let meeting = try #require(model.store.meeting(id: id))
    #expect(meeting.status == .completed)
    #expect(meeting.segments == oldLines)
    #expect(meeting.transcriptText == TranscriptFormatter.timestamped(oldLines))
}

private struct EngineBroke: LocalizedError { var errorDescription: String? { "engine broke" } }

@MainActor
@Test("A failed re-run keeps the transcript too, and says why it failed (F515)")
func aFailedReRunKeepsTheTranscript() async throws {
    let (model, id) = try completedMeeting { _, _ in throw EngineBroke() }
    model.transcribeAgain(id: id)
    try await waitForTheRunToEnd(model)

    let meeting = try #require(model.store.meeting(id: id))
    #expect(meeting.status == .completed)
    #expect(meeting.segments == oldLines)
    #expect(model.alertMessage?.contains("previous transcript is unchanged") == true)
}

@MainActor
@Test("A re-run interrupted by quitting is recovered as completed; a first run still as recorded (F515)")
func anInterruptedReRunIsRecoveredAsCompleted() throws {
    let (model, id) = try completedMeeting { _, _ in throw CancellationError() }
    model.store.update(id: id) { $0.status = .processing }
    let firstRun = UUID()
    model.store.upsert(MeetingRecord(id: firstRun, title: "New", status: .processing))

    model.recoverInterruptedTranscriptions()

    #expect(model.store.meeting(id: id)?.status == .completed)
    #expect(model.store.meeting(id: id)?.segments == oldLines)
    #expect(model.store.meeting(id: firstRun)?.status == .recorded)
}

@MainActor
@Test("Transcribe Again is refused while the meeting is already being transcribed (F515)")
func transcribeAgainIsBlockedWhileProcessing() throws {
    let (model, id) = try completedMeeting { _, _ in throw CancellationError() }
    model.store.update(id: id) { $0.status = .processing }
    #expect(model.transcribeAgainBlockedReason(for: id) != nil)
}

@Test("Transcribe Again is in the Improve menu and beside the alignment notice, behind a confirmation (F515)")
func transcribeAgainIsWired() throws {
    let source = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/ContentView.swift")
    #expect(source.contains(#"Label("Transcribe Again…", systemImage: "arrow.clockwise")"#))
    #expect(source.contains(#"Button("Transcribe Again…") { confirmTranscribeAgain = true }"#))
    #expect(source.contains("model.transcribeAgain(id: meetingID)"))
    #expect(source.contains(".disabled(model.transcribeAgainBlockedReason(for: meetingID) != nil)"))
}

// F507 — `recoverInterruptedTranscriptions()` reset every `.processing` meeting to `.recorded` (or
// `.completed`, F515's case) on the assumption that `.processing` means "left over from a run this
// process never started". Startup recovery runs it near the end of `performStartupRecovery`, after
// several awaits that can take seconds (installer reclaim, notes backfill, detached orphan
// rebuilds) — long enough for the user to press Transcribe on a meeting in that window, or for one
// to queue behind Quick Dictation. Either way `.processing` can belong to a job this process IS
// running or has already queued, and the sweep must not relabel it as interrupted.

/// Holds a transcription open until the test releases it, so "active" is a state under the test's
/// control rather than a race it hopes to win — the RestoreBusyGuardTests shape.
private actor Latch {
    private var isOpen = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    func wait() async {
        if isOpen { return }
        await withCheckedContinuation { waiters.append($0) }
    }
    func open() {
        isOpen = true
        waiters.forEach { $0.resume() }
        waiters = []
    }
}

/// Polls the caller's own subject under a wall-clock cap, never a yield count (F639): a fixed
/// budget of `Task.yield()`s expires under a starved scheduler before the condition it is waiting
/// for becomes true, failing a claim that was never false.
@MainActor
private func waitUntil(_ condition: () -> Bool) async throws {
    var ticks = 0
    while !condition(), ticks < 6_000 { try await Task.sleep(nanoseconds: 5_000_000); ticks += 1 }
    try #require(condition(), "timed out waiting for the condition")
}

@MainActor
@Test("Startup recovery does not mark a transcription running right now as interrupted (F507)")
func recoveryDoesNotInterruptARunningTranscription() async throws {
    let latch = Latch()
    let (model, id) = try completedMeeting { _, _ in
        await latch.wait()
        return TranscriptionResult(id: "x", text: "New line.", languageCode: "en",
                                   audioDuration: 2, confidence: nil, segments: [])
    }
    model.transcribeAgain(id: id)
    // `activeID` is set synchronously inside `beginTranscription`'s own call, before the spawned
    // Task has run at all — waiting on it would return before `performTranscription` reaches its
    // own `store.update` to `.processing`. The status itself is the fact this test needs, and
    // waiting on it is also the precondition the rest of the test depends on.
    try await waitUntil { model.store.meeting(id: id)?.status == .processing }
    try #require(model.transcription.activeID == id)

    model.recoverInterruptedTranscriptions()

    #expect(model.store.meeting(id: id)?.status == .processing,
            "startup recovery relabelled a transcription that is running right now")

    await latch.open()
    try await waitForTheRunToEnd(model)
}

@MainActor
@Test("Startup recovery does not mark a queued transcription as interrupted (F507)")
func recoveryDoesNotInterruptAQueuedTranscription() async throws {
    // A meeting whose status is still `.processing` from a run this launch never started (the
    // ordinary stale-crash case `holdsTranscript` already covers), but which is ALSO queued for a
    // fresh run right now — `beginTranscription` does not look at the current status before
    // enqueueing, and a queued job's status is left alone until it actually starts. Sweeping it
    // to `.recorded` here would contradict the transcription about to run for it.
    let latch = Latch()
    let (model, heldID) = try completedMeeting { _, _ in
        await latch.wait()
        return TranscriptionResult(id: "held", text: "Held.", languageCode: "en",
                                   audioDuration: 2, confidence: nil, segments: [])
    }
    model.transcribeAgain(id: heldID)
    try await waitUntil { model.transcription.activeID == heldID }

    let queuedID = UUID()
    model.store.upsert(MeetingRecord(id: queuedID, title: "Stale", status: .processing))
    model.transcribeAgain(id: queuedID)
    try #require(model.isQueuedForTranscription(queuedID))
    #expect(model.store.meeting(id: queuedID)?.status == .processing)

    model.recoverInterruptedTranscriptions()

    #expect(model.store.meeting(id: queuedID)?.status == .processing,
            "startup recovery relabelled a transcription that is queued right now")

    await latch.open()
    try await waitForTheRunToEnd(model)
    try await waitUntil { model.store.meeting(id: queuedID)?.status == .completed || model.store.meeting(id: queuedID)?.status == .recorded }
}
