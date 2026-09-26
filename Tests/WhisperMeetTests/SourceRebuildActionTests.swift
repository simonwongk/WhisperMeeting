import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F267 — the user-triggered half: an explicit, reviewed "rebuild from source audio".
//
// Shaped like F193's library recovery, including the structural guarantee that makes
// "user-reviewed" real rather than conventional: only an offer this model actually produced can
// be acted on, so a caller cannot rebuild something the user never saw.

@MainActor
private func makeModel(root: URL, suite: String) -> AppModel {
    AppModel(
        store: MeetingStore(rootDirectory: root),
        recorder: AudioCaptureEngine(),
        defaults: UserDefaults(suiteName: suite)!
    )
}

/// A meeting whose indexed audio is a short rebuild, with full-length raw tracks beside it.
@MainActor
private func makeTruncatedMeeting(in root: URL) throws -> (AppModel, UUID, URL) {
    let id = UUID()
    let folder = root.appendingPathComponent("Recordings/\(id.uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let samples = [Float](repeating: 0.3, count: 96_000)          // 2s of tracks
    for name in ["system-audio.f32", "microphone-audio.f32"] {
        try samples.withUnsafeBytes { try Data($0).write(to: folder.appendingPathComponent(name)) }
    }
    try WAVWriter.wavData(from: [Float](repeating: 0.1, count: 4_800), sampleRate: 48_000)
        .write(to: folder.appendingPathComponent("meeting-recovered.wav"))   // 0.1s indexed

    let suite = "WhisperMeet.SourceRebuildAction.\(UUID().uuidString)"
    let model = makeModel(root: root, suite: suite)
    model.store.upsert(MeetingRecord(
        id: id,
        title: "Pricing sync",
        duration: 0.1,
        recordingPath: "Recordings/\(id.uuidString)/meeting-recovered.wav",
        status: .completed,
        transcriptText: "0:00 We agreed on the tiering.",
        segments: [
            TranscriptSegment(speaker: nil, start: 0, end: 0.1, text: "We agreed on the tiering.")
        ],
        markers: [RecordingMarker(offset: 0.05, label: "pricing")],
        notes: "Ask about the annual discount",
        tags: ["finance"],
        recoveryWarning: "The rebuilt audio stops at 0:00 because a source track could not be read past that point."
    ))
    return (model, id, folder)
}

@Test("A truncated meeting can be rebuilt again, and gains the longer audio")
@MainActor
func rebuildProducesTheLongerRecording() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("RebuildAction-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let (model, id, folder) = try makeTruncatedMeeting(in: root)

    model.requestSourceRebuild(id: id)
    let offer = try #require(model.pendingSourceRebuild)
    #expect(offer.meetingTitle == "Pricing sync")
    #expect(offer.offer.expectedDurationSeconds == 2.0)

    await model.performSourceRebuild(confirmed: true)?.value

    let meeting = try #require(model.store.meeting(id: id))
    #expect(abs(meeting.duration - 2.0) < 0.01)
    // The rebuild read cleanly this time, so the truncation notice is gone rather than stale.
    #expect(meeting.recoveryWarning == nil)
    #expect(model.pendingSourceRebuild == nil)
    // And the audio it replaced is still on disk.
    #expect(FileManager.default.fileExists(
        atPath: folder.appendingPathComponent("meeting-recovered-superseded-1.wav").path
    ))
}

@Test("A rebuild changes the audio's facts and nothing the user wrote")
@MainActor
func rebuildPreservesEveryUserField() async throws {
    // F148 #1, asserted field by field rather than by a spot check. A rebuild that blanks a
    // user's text is worse than the imperfect audio it replaces, and it is the whole reason this
    // action is safe enough to offer.
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("RebuildPreserve-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let (model, id, _) = try makeTruncatedMeeting(in: root)
    let before = try #require(model.store.meeting(id: id))

    model.requestSourceRebuild(id: id)
    await model.performSourceRebuild(confirmed: true)?.value

    let after = try #require(model.store.meeting(id: id))
    #expect(after.title == before.title)
    #expect(after.transcriptText == before.transcriptText)
    #expect(after.segments == before.segments)
    #expect(after.notes == before.notes)
    #expect(after.tags == before.tags)
    #expect(after.summary == before.summary)
    #expect(after.markers == before.markers)
    #expect(after.recordingPath == before.recordingPath)
}

@Test("A longer rebuild says the transcript no longer describes the audio")
@MainActor
func longerRebuildMarksTheTranscriptStale() async throws {
    // F281's rule, applied to a new case: the transcript covers only the old prefix and its
    // timestamps point into a file that has been replaced. Blanking it is forbidden and would be
    // the greater harm, so it stays — and nothing contradicting it would make the document read
    // as current, which is a false claim by omission.
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("RebuildStale-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let (model, id, _) = try makeTruncatedMeeting(in: root)

    model.requestSourceRebuild(id: id)
    await model.performSourceRebuild(confirmed: true)?.value

    let meeting = try #require(model.store.meeting(id: id))
    #expect(meeting.staleTranscriptWarning?.contains("rebuilt") == true)
    // And it reaches the notes.md mirror through the caveats list F281 built.
    model.store.flushPendingNotesSidecars()
    let notes = try String(
        contentsOf: root.appendingPathComponent("Recordings/\(id.uuidString)/notes.md"),
        encoding: .utf8
    )
    #expect(notes.contains("## About this recording"))
    #expect(notes.contains("rebuilt"))
}

@Test("An untranscribed meeting gains no stale-transcript notice")
@MainActor
func untranscribedRebuildSaysNothingAboutTheTranscript() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("RebuildNoText-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let folder = root.appendingPathComponent("Recordings/\(id.uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let samples = [Float](repeating: 0.3, count: 96_000)
    try samples.withUnsafeBytes { try Data($0).write(to: folder.appendingPathComponent("system-audio.f32")) }
    try WAVWriter.wavData(from: [Float](repeating: 0.1, count: 4_800), sampleRate: 48_000)
        .write(to: folder.appendingPathComponent("meeting-recovered.wav"))

    let model = makeModel(root: root, suite: "WhisperMeet.RebuildNoText.\(UUID().uuidString)")
    model.store.upsert(MeetingRecord(
        id: id,
        title: "Never transcribed",
        duration: 0.1,
        recordingPath: "Recordings/\(id.uuidString)/meeting-recovered.wav",
        status: .recorded
    ))

    model.requestSourceRebuild(id: id)
    await model.performSourceRebuild(confirmed: true)?.value

    #expect(model.store.meeting(id: id)?.staleTranscriptWarning == nil)
}

// MARK: - F309: the notice must describe the direction the audio actually moved

/// A transcribed meeting indexed at `indexedSeconds`, beside 2s of raw tracks. `keepIndexedAudio`
/// decides whether the indexed `meeting-recovered.wav` is on disk — which is what decides whether
/// the rebuild moves an earlier recording aside or has nothing to keep.
@MainActor
private func makeTranscribedMeeting(
    in root: URL, indexedSeconds: Double, keepIndexedAudio: Bool
) throws -> (AppModel, UUID, URL) {
    let id = UUID()
    let folder = root.appendingPathComponent("Recordings/\(id.uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let samples = [Float](repeating: 0.3, count: 96_000)          // 2s of tracks
    for name in ["system-audio.f32", "microphone-audio.f32"] {
        try samples.withUnsafeBytes { try Data($0).write(to: folder.appendingPathComponent(name)) }
    }
    if keepIndexedAudio {
        try WAVWriter.wavData(
            from: [Float](repeating: 0.1, count: Int(indexedSeconds * 48_000)), sampleRate: 48_000
        ).write(to: folder.appendingPathComponent("meeting-recovered.wav"))
    }
    let model = makeModel(root: root, suite: "WhisperMeet.RebuildDirection.\(UUID().uuidString)")
    model.store.upsert(MeetingRecord(
        id: id,
        title: "Roadmap review",
        duration: indexedSeconds,
        recordingPath: "Recordings/\(id.uuidString)/meeting-recovered.wav",
        status: .completed,
        transcriptText: "0:00 We moved the launch."
    ))
    return (model, id, folder)
}

@Test("A longer rebuild keeps the sentence it has always had (F309)")
@MainActor
func longerRebuildKeepsItsSentence() async throws {
    // Pinned whole rather than by a fragment: F309 changes the shorter direction only, and a
    // fragment would let the longer sentence drift while this still passed.
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("RebuildLonger-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let (model, id, _) = try makeTranscribedMeeting(in: root, indexedSeconds: 1, keepIndexedAudio: true)

    model.requestSourceRebuild(id: id)
    await model.performSourceRebuild(confirmed: true)?.value

    #expect(model.store.meeting(id: id)?.staleTranscriptWarning
        == "This transcript was made from an earlier, 0:01 version of the audio, which has since been rebuilt to 0:02. Its text and timestamps do not cover the whole recording — transcribe again to replace it.")
}

@Test("A shorter rebuild does not call the transcript short, or advise replacing it (F309)")
@MainActor
func shorterRebuildDoesNotAdviseRetranscribing() async throws {
    // The transcript covers MORE than the recording now does. Re-transcribing would replace the
    // more complete artefact with a less complete one, so the app must not recommend it — F281's
    // rule is that saying so is the alternative to blanking, and here the saying was wrong.
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("RebuildShorter-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let (model, id, folder) = try makeTranscribedMeeting(in: root, indexedSeconds: 3, keepIndexedAudio: true)

    model.requestSourceRebuild(id: id)
    await model.performSourceRebuild(confirmed: true)?.value

    let meeting = try #require(model.store.meeting(id: id))
    #expect(abs(meeting.duration - 2.0) < 0.01)
    let notice = try #require(meeting.staleTranscriptWarning)
    #expect(notice.contains("0:03") && notice.contains("0:02"))
    #expect(notice.contains("covers more than the recording does"))
    #expect(!notice.contains("do not cover the whole recording"))
    #expect(!notice.contains("transcribe again to replace it"))
    #expect(notice.contains("Transcribing again would replace this transcript with a shorter one."))
    // The claim that the earlier audio is kept is checked against the disk, not taken on trust.
    #expect(notice.contains("The earlier audio is kept in this meeting's folder."))
    #expect(FileManager.default.fileExists(
        atPath: folder.appendingPathComponent("meeting-recovered-superseded-1.wav").path
    ))
}

@Test("A shorter rebuild with no earlier audio on disk says the transcript is the only record (F309)")
@MainActor
func shorterRebuildWithoutEarlierAudioSaysSo() async throws {
    // The ticket's proposed wording said the previous audio "is kept in the folder". That is true
    // only when there was a file to move aside. When the indexed audio was already gone, nothing
    // on disk covers the transcript's tail, and claiming otherwise would be a new false sentence.
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("RebuildShorterGone-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let (model, id, folder) = try makeTranscribedMeeting(in: root, indexedSeconds: 3, keepIndexedAudio: false)

    model.requestSourceRebuild(id: id)
    await model.performSourceRebuild(confirmed: true)?.value

    let notice = try #require(model.store.meeting(id: id)?.staleTranscriptWarning)
    #expect(!notice.contains("is kept in this meeting's folder"))
    #expect(notice.contains("The earlier audio is no longer in this meeting's folder, so this transcript is the only record of what was said after 0:02."))
    #expect(notice.contains("Transcribing again would replace it with a shorter one."))
    #expect(!notice.contains("transcribe again to replace it"))
    #expect(!FileManager.default.fileExists(
        atPath: folder.appendingPathComponent("meeting-recovered-superseded-1.wav").path
    ))
}

@Test("A rebuild that reproduces the same duration declares nothing (F309)")
@MainActor
func sameLengthRebuildDeclaresNothing() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("RebuildSame-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let (model, id, _) = try makeTranscribedMeeting(in: root, indexedSeconds: 2, keepIndexedAudio: true)

    model.requestSourceRebuild(id: id)
    await model.performSourceRebuild(confirmed: true)?.value

    #expect(model.store.meeting(id: id)?.staleTranscriptWarning == nil)
}

@Test("Without confirmation nothing happens at all")
@MainActor
func unconfirmedRebuildIsANoOp() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("RebuildUnconfirmed-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let (model, id, folder) = try makeTruncatedMeeting(in: root)

    model.requestSourceRebuild(id: id)
    await model.performSourceRebuild(confirmed: false)?.value

    #expect(model.store.meeting(id: id)?.duration == 0.1)
    #expect(model.pendingSourceRebuild != nil, "the offer stays up; the user has not answered yet")
    #expect(!FileManager.default.fileExists(
        atPath: folder.appendingPathComponent("meeting-recovered-superseded-1.wav").path
    ))
}

@Test("A rebuild the model never offered is refused")
@MainActor
func unofferedRebuildIsRefused() async throws {
    // The same structural guarantee F193 established: "user-reviewed" enforced by the code, not
    // by convention. Without this a caller could rebuild a meeting the user never saw a prompt for.
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("RebuildUnoffered-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let (model, id, _) = try makeTruncatedMeeting(in: root)

    await model.performSourceRebuild(confirmed: true)?.value   // never requested

    #expect(model.store.meeting(id: id)?.duration == 0.1)
}

@Test("A meeting with a finished capture is told why it cannot be rebuilt")
@MainActor
func finishedCaptureExplainsTheRefusal() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("RebuildFinished-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let folder = root.appendingPathComponent("Recordings/\(id.uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let samples = [Float](repeating: 0.3, count: 96_000)
    try samples.withUnsafeBytes { try Data($0).write(to: folder.appendingPathComponent("system-audio.f32")) }
    try WAVWriter.wavData(from: samples, sampleRate: 48_000)
        .write(to: folder.appendingPathComponent("meeting.wav"))

    let model = makeModel(root: root, suite: "WhisperMeet.RebuildFinished.\(UUID().uuidString)")
    model.store.upsert(MeetingRecord(
        id: id,
        title: "Finished normally",
        duration: 2.0,
        recordingPath: "Recordings/\(id.uuidString)/meeting.wav",
        status: .completed
    ))

    model.requestSourceRebuild(id: id)

    // Refused, and explained rather than silently absent — the user asked for something.
    #expect(model.pendingSourceRebuild == nil)
    #expect(model.alertMessage?.isEmpty == false)
    #expect(model.canRebuildFromSourceTracks(id: id) == false)
}

@Test("The confirmation states what changes, what is kept, and what it costs")
@MainActor
func confirmationDisclosesTheTrade() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("RebuildCopy-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let (model, id, _) = try makeTruncatedMeeting(in: root)

    model.requestSourceRebuild(id: id)
    let request = try #require(model.pendingSourceRebuild)
    let message = AppModel.rebuildConfirmationMessage(request)

    #expect(message.contains("Pricing sync"))
    #expect(message.contains("0:00"))   // what it has now
    #expect(message.contains("0:02"))   // what the tracks hold
    // The cost is disclosed rather than solved.
    #expect(message.contains("grow"))
    // And the F148 #1 guarantee is stated to the user, not just honoured in code.
    #expect(message.contains("transcript"))
}

@Test("A meeting with no previous audio is not told its folder will grow")
@MainActor
func missingRecordingConfirmationOmitsTheCost() throws {
    // Nothing to keep means no extra copy, so claiming a cost would be a small false statement.
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("RebuildNoCost-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let id = UUID()
    let folder = root.appendingPathComponent("Recordings/\(id.uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let samples = [Float](repeating: 0.3, count: 96_000)
    try samples.withUnsafeBytes { try Data($0).write(to: folder.appendingPathComponent("system-audio.f32")) }

    let model = makeModel(root: root, suite: "WhisperMeet.RebuildNoCost.\(UUID().uuidString)")
    model.store.upsert(MeetingRecord(
        id: id,
        title: "Lost audio",
        recordingPath: "Recordings/\(id.uuidString)/meeting-recovered.wav",
        status: .recorded
    ))

    model.requestSourceRebuild(id: id)
    let request = try #require(model.pendingSourceRebuild)
    #expect(!AppModel.rebuildConfirmationMessage(request).contains("grow"))
}

// MARK: - F306: the offer has to be reachable, not merely correct

@Test("The view layer still reaches the source rebuild (F306)")
func theRebuildOfferIsReachableFromTheView() throws {
    // F273 consolidated three hand-written banners into one `ForEach` list — a good change — and
    // deleted the Rebuild Audio button that lived inside one of them. `requestSourceRebuild` then
    // had no production caller: the confirmation dialog reads `pendingSourceRebuild`, which only
    // that method sets, so F267's entire rebuild became unreachable and `staleTranscriptWarning`
    // could never be set. Every test in this file kept passing, because they all drive the model
    // directly.
    //
    // Asserted against `ContentView`'s source, which is crude and is the honest option: the
    // `WhisperMeet` target has no UI harness (F174's standing reason), so there is no way to render
    // the view and look. `InstallReclaimTests` set the precedent of asserting against source when
    // the behaviour itself is out of reach. It would have caught this exact regression, which is
    // the bar that matters.
    // Comments stripped, so a mention of the name in prose — including the explanation of this
    // very regression — cannot satisfy the assertion. F285's false positive was exactly that.
    let source = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/ContentView.swift")

    #expect(
        source.contains("requestSourceRebuild"),
        "no view calls requestSourceRebuild, so the rebuild cannot be started — F267's mechanism is unreachable"
    )
    #expect(
        source.contains("canRebuildFromSourceTracks"),
        "the offer must be gated on whether raw tracks exist, or it is shown when it cannot work"
    )
    #expect(
        source.contains("performSourceRebuild"),
        "the confirmation must be able to run the rebuild"
    )
}

// MARK: - F459: the rebuild's heavy read/write must not freeze the main actor

/// Holds the (real, injected) rebuild open until the test releases it, so "running" is a state the
/// test controls rather than a race it hopes to win. `performSourceTracksRebuild` is a synchronous
/// throwing closure (it mirrors `SourceRebuild.rebuild`'s own signature, and `AppModel` is what
/// wraps it in `Task.detached`), so this blocks the background thread it runs on with a busy-wait
/// rather than suspending — never the main actor, which is the whole point of the test.
private final class RebuildGate: @unchecked Sendable {
    private let lock = NSLock()
    private var entered = false
    private var open = false
    func enter() { lock.withLock { entered = true } }
    var hasEntered: Bool { lock.withLock { entered } }
    func release() { lock.withLock { open = true } }
    func wait() {
        enter()
        while !(lock.withLock { open }) { Thread.sleep(forTimeInterval: 0.002) }
    }
}

@MainActor
private func waitUntil(_ what: String, _ condition: () -> Bool) async throws {
    var ticks = 0
    while !condition(), ticks < 6_000 {
        try await Task.sleep(nanoseconds: 5_000_000)
        ticks += 1
    }
    try #require(condition(), "timed out waiting for \(what)")
}

@Test("Rebuild Audio runs off the main actor, and sourceRebuildRunningID is observable while it does (F459)")
@MainActor
func rebuildRunsDetachedAndReportsProgress() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("RebuildDetached-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let (model, id, _) = try makeTruncatedMeeting(in: root)
    let gate = RebuildGate()
    // Injected so the test can hold the (otherwise real) rebuild open long enough to observe the
    // running state without a fixed sleep on the assertion's own subject — polling
    // `gate.hasEntered`/`sourceRebuildRunningID`, never a clock (AGENTS.md's "fixed time budget"
    // trap: the wait below has its own bounded poll, but what it polls for is the fact under test).
    model.performSourceTracksRebuild = { offer in
        gate.wait()
        return try SourceRebuild.rebuild(offer)
    }

    model.requestSourceRebuild(id: id)
    let task = try #require(model.performSourceRebuild(confirmed: true))

    try await waitUntil("the rebuild to reach its core") { gate.hasEntered }
    #expect(model.sourceRebuildRunningID == id, "the running meeting is not observable while the rebuild works")
    // The main actor is free while the rebuild runs: a store read completes instantly instead of
    // waiting behind the rebuild, which is exactly what F459 reports was not true before.
    #expect(model.store.meeting(id: id)?.title == "Pricing sync")

    gate.release()
    await task.value

    #expect(model.sourceRebuildRunningID == nil, "the running id was not cleared once the rebuild finished")
    #expect(abs((model.store.meeting(id: id)?.duration ?? 0) - 2.0) < 0.01)
}

// MARK: - F469: a rebuild must not race a transcription of the same meeting

/// Holds an (injected) transcription engine pass open until the test releases it — the
/// RestoreBusyGuardTests/TranscribeAgainTests shape, local to this file.
private actor EngineLatch {
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

/// A rebuild-eligible meeting (raw tracks plus a short indexed recording, no `meeting.wav`) whose
/// recognition runtime is pinned installed, so `beginTranscription` can actually start rather than
/// passing or failing by what this host happens to have installed (the F441 lesson).
@MainActor
private func makeRebuildableTranscribableMeeting(in root: URL) throws -> (model: AppModel, id: UUID) {
    let id = UUID()
    let folder = root.appendingPathComponent("Recordings/\(id.uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let samples = [Float](repeating: 0.3, count: 96_000)          // 2s of tracks
    for name in ["system-audio.f32", "microphone-audio.f32"] {
        try samples.withUnsafeBytes { try Data($0).write(to: folder.appendingPathComponent(name)) }
    }
    try WAVWriter.wavData(from: [Float](repeating: 0.1, count: 4_800), sampleRate: 48_000)
        .write(to: folder.appendingPathComponent("meeting-recovered.wav"))   // 0.1s indexed

    let model = AppModel(
        store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(),
        defaults: UserDefaults(suiteName: "WhisperMeet.RebuildVsTranscription.\(UUID().uuidString)")!,
        whisperExecutable: { URL(fileURLWithPath: "/usr/bin/true") }, qwenInstalled: { true }
    )
    model.selectedEngine = .whisperLarge
    model.store.upsert(MeetingRecord(
        id: id, title: "Recovered", duration: 0.1,
        recordingPath: "Recordings/\(id.uuidString)/meeting-recovered.wav",
        status: .recorded
    ))
    return (model, id)
}

@Test("Rebuild Audio is refused while this meeting's transcription is running (F469)")
@MainActor
func rebuildRefusedWhileTranscribing() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("RebuildVsTranscribeActive-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let (model, id) = try makeRebuildableTranscribableMeeting(in: root)
    let latch = EngineLatch()
    model.runTranscriptionEngineOverride = { _, _ in
        await latch.wait()
        return TranscriptionResult(id: "x", text: "partial", languageCode: "en", audioDuration: 0.1,
                                   confidence: nil, segments: [])
    }
    model.beginTranscription(id: id)
    try await waitUntil("the transcription to become active") { model.hasActiveTranscription }

    model.requestSourceRebuild(id: id)

    #expect(model.pendingSourceRebuild == nil, "a rebuild was offered over a running transcription")
    #expect(model.alertMessage?.contains("transcription") == true, "\(model.alertMessage ?? "no message")")
    // Nothing was touched: the tracks are still there, unmoved, and the indexed duration unchanged.
    #expect(model.store.meeting(id: id)?.duration == 0.1)

    await latch.open()
    try await waitUntil("the transcription to finish") { !model.hasActiveTranscription }
}

@Test("Rebuild Audio is refused while this meeting's transcription is queued (F469)")
@MainActor
func rebuildRefusedWhileQueued() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("RebuildVsTranscribeQueued-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let (model, id) = try makeRebuildableTranscribableMeeting(in: root)
    // A second, unrelated meeting occupies the one concurrent transcription slot, so the rebuild
    // target's own job sits pending rather than active — the F583 distinction ("queued" is not
    // "running") applied to this ticket.
    let heldID = UUID()
    model.store.upsert(MeetingRecord(
        id: heldID, title: "Held", recordingPath: "Recordings/\(heldID.uuidString)/meeting.wav",
        status: .completed, transcriptText: "held",
        segments: [TranscriptSegment(speaker: nil, start: 0, end: 2, text: "held")]
    ))
    let latch = EngineLatch()
    model.runTranscriptionEngineOverride = { _, url in
        if url.path.contains(heldID.uuidString) { await latch.wait() }
        return TranscriptionResult(id: "x", text: "text", languageCode: "en", audioDuration: 2,
                                   confidence: nil, segments: [])
    }
    model.transcribeAgain(id: heldID)
    try await waitUntil("the held meeting to become active") { model.hasActiveTranscription }
    model.beginTranscription(id: id)
    try #require(model.isQueuedForTranscription(id))

    model.requestSourceRebuild(id: id)

    #expect(model.pendingSourceRebuild == nil, "a rebuild was offered over a queued transcription")
    #expect(model.alertMessage?.contains("queue") == true, "\(model.alertMessage ?? "no message")")
    #expect(model.store.meeting(id: id)?.duration == 0.1)

    await latch.open()
    try await waitUntil("both transcriptions to finish") { !model.hasActiveTranscription }
}

@Test("A rebuild confirmed after this meeting's transcription started is refused, and changes nothing (F469)")
@MainActor
func rebuildRefusedAtConfirmationWhenTranscriptionStarted() async throws {
    // The offer can stand for as long as the confirmation dialog is open, so "nothing was
    // transcribing when it was offered" says nothing about the moment of confirmation — the same
    // re-check `performLibraryRestore` does for F506.
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("RebuildVsTranscribeConfirm-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let (model, id) = try makeRebuildableTranscribableMeeting(in: root)
    model.requestSourceRebuild(id: id)
    try #require(model.pendingSourceRebuild != nil)

    let latch = EngineLatch()
    model.runTranscriptionEngineOverride = { _, _ in
        await latch.wait()
        return TranscriptionResult(id: "x", text: "partial", languageCode: "en", audioDuration: 0.1,
                                   confidence: nil, segments: [])
    }
    model.beginTranscription(id: id)
    try await waitUntil("the transcription to become active") { model.hasActiveTranscription }

    let task = model.performSourceRebuild(confirmed: true)

    #expect(task == nil, "the rebuild started over a running transcription")
    #expect(model.alertMessage?.contains("transcription") == true, "\(model.alertMessage ?? "no message")")
    #expect(model.store.meeting(id: id)?.duration == 0.1, "the rebuild changed the audio's facts")

    await latch.open()
    try await waitUntil("the transcription to finish") { !model.hasActiveTranscription }
}

// MARK: - F469: the stale-transcript warning's clearing is a fact, not a side effect of "finished"

@Test("apply(result:) does not clear a stale-transcript warning when the audio changed since this run started (F469)")
@MainActor
func applyResultKeepsAStaleWarningWhenDurationChangedMidRun() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ApplyKeepsStale-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = makeModel(root: root, suite: "WhisperMeet.ApplyKeepsStale.\(UUID().uuidString)")
    let id = UUID()
    // The meeting's CURRENT duration (5.0) already reflects a rebuild that happened after this run
    // started — `requestSourceRebuild`/`performSourceRebuild` refuse to let that happen, so this is
    // the additional-refusal case where that gate is wrong somewhere nobody has thought of (F279).
    model.store.upsert(MeetingRecord(
        id: id, title: "Raced", duration: 5.0, recordingPath: "Recordings/\(id.uuidString)/meeting.wav",
        status: .processing,
        staleTranscriptWarning: "This transcript was made from an earlier, 0:02 version of the audio, which has since been rebuilt to 0:05. Its text and timestamps do not cover the whole recording — transcribe again to replace it."
    ))

    model.apply(
        result: TranscriptionResult(id: "x", text: "Text from the superseded audio.", languageCode: "en",
                                    audioDuration: 2, confidence: nil, segments: []),
        to: id,
        audioDurationAtStart: 2.0
    )

    let meeting = try #require(model.store.meeting(id: id))
    #expect(meeting.status == .completed)
    #expect(meeting.staleTranscriptWarning != nil, "the warning was cleared even though the audio changed mid-run")
}

@Test("apply(result:) clears the stale-transcript warning when the audio matches what this run started with (F469)")
@MainActor
func applyResultClearsStaleWarningWhenDurationMatches() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ApplyClearsStale-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let model = makeModel(root: root, suite: "WhisperMeet.ApplyClearsStale.\(UUID().uuidString)")
    let id = UUID()
    model.store.upsert(MeetingRecord(
        id: id, title: "Not raced", duration: 2.0, recordingPath: "Recordings/\(id.uuidString)/meeting.wav",
        status: .processing,
        staleTranscriptWarning: "This transcript was made from an earlier, 0:01 version of the audio, which has since been rebuilt to 0:02. Its text and timestamps do not cover the whole recording — transcribe again to replace it."
    ))

    model.apply(
        result: TranscriptionResult(id: "x", text: "Text from the current audio.", languageCode: "en",
                                    audioDuration: 2, confidence: nil, segments: []),
        to: id,
        audioDurationAtStart: 2.0
    )

    let meeting = try #require(model.store.meeting(id: id))
    #expect(meeting.status == .completed)
    #expect(meeting.staleTranscriptWarning == nil, "the warning was kept even though the audio matches this run")
}
