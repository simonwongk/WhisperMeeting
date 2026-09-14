import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F219 — AppModel wiring for optional, post-meeting speaker analysis. These are genuinely red without
// the wiring: `AppModel` has no `runSpeakerDiarization` seam, no `requestSpeakerDiarization`,
// `cancelSpeakerDiarization`, `clearSpeakerDiarization`, `renameSpeaker` or `speakerOverlay`, so the
// file does not even compile against the current model — and nothing writes or reads the
// `diarization.json` sidecar that Tasks 5–8 built. Every assertion below is about behaviour reached
// THROUGH the app-level call (the AGENTS.md "wiring an unreachable core" rule), never a direct core
// call: the seam receives the recording, a complete result becomes a sidecar, a cancelled or failed
// run writes nothing, and the recording and transcript are byte-identical in every path.

private func seg(_ text: String, _ start: Double, _ end: Double) -> TranscriptSegment {
    TranscriptSegment(speaker: nil, start: start, end: end, text: text)
}

private final class DiarizationBox: @unchecked Sendable {
    var calls = 0
    var meetingID: UUID?
    var audioPath: String?
    var durationSeconds: TimeInterval?
    var started = false
    var release = false
    var neverCancelled = false
}

/// A 16 kHz mono 16-bit WAV of silence — the format speaker analysis prepares, so the fixture needs no
/// transcode even when the real seam runs.
private func writeSilentWav(seconds: Double, to url: URL) throws {
    let sampleRate: UInt32 = 16_000
    let dataBytes = UInt32(seconds * Double(sampleRate)) * 2
    var wav = WAVWriter.header(sampleRate: sampleRate, dataByteCount: dataBytes)
    wav.append(Data(count: Int(dataBytes)))
    try wav.write(to: url)
}

@MainActor
private struct Fixture {
    let model: AppModel
    let id: UUID
    let root: URL
    let wavURL: URL
    var sidecarURL: URL { DiarizationArtifactStore.fileURL(meetingID: id, in: root) }
}

@MainActor
private func makeFixture(
    segments: [TranscriptSegment] = [seg("one", 0, 2), seg("two", 2, 4)],
    status: MeetingStatus = .completed,
    recordingFileName: String = "meeting.wav",
    source: MediaSource? = nil
) throws -> Fixture {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("DiarizationWiring-\(UUID().uuidString)", isDirectory: true)
    let id = UUID()
    let directory = root.appendingPathComponent("Recordings/\(id.uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let wavURL = directory.appendingPathComponent(recordingFileName)
    try writeSilentWav(seconds: 4, to: wavURL)

    let defaults = UserDefaults(suiteName: "F219.\(UUID().uuidString)")!
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(), defaults: defaults)
    model.isDiarizationModelInstalled = { true }
    model.store.upsert(MeetingRecord(
        id: id, title: "M", duration: 4,
        recordingPath: "Recordings/\(id.uuidString)/\(recordingFileName)",
        status: status,
        transcriptText: TranscriptFormatter.timestamped(segments),
        segments: segments,
        source: source
    ))
    return Fixture(model: model, id: id, root: root, wavURL: wavURL)
}

/// Bounded cooperative wait — a spin that can never wedge the suite the way an unbounded one would.
@MainActor
private func spin(_ label: String, until condition: @MainActor () -> Bool) async {
    var ticks = 0
    while !condition(), ticks < 200_000 {
        await Task.yield()
        ticks += 1
    }
    #expect(condition(), "timed out waiting for \(label)")
}

private func twoClusterResult() -> SpeakerDiarizationResult {
    SpeakerDiarizationResult(
        turns: [
            SpeakerTurn(startSeconds: 0, endSeconds: 2, clusterID: 0, kind: .speech),
            SpeakerTurn(startSeconds: 2, endSeconds: 4, clusterID: 1, kind: .speech)
        ],
        speakerCount: 2,
        audioSeconds: 4
    )
}

@MainActor
@Test("Speaker analysis threads the recording through the seam and publishes an overlay (F219)")
func diarizationRunWritesSidecarAndPublishesOverlay() async throws {
    let fixture = try makeFixture()
    let box = DiarizationBox()
    fixture.model.runSpeakerDiarization = { request, _ in
        box.calls += 1
        box.meetingID = request.meetingID
        box.audioPath = request.audioURL.path
        box.durationSeconds = request.durationSeconds
        return twoClusterResult()
    }
    let wavBefore = try Data(contentsOf: fixture.wavURL)
    let transcriptBefore = try #require(fixture.model.store.meeting(id: fixture.id)?.transcriptText)

    fixture.model.requestSpeakerDiarization(for: fixture.id)
    #expect(fixture.model.diarizationRunningID == fixture.id)   // scoped to this meeting only
    #expect(fixture.model.isRunningAuxiliaryEngine == true)     // transcription refuses to start
    await spin("the analysis to finish") { fixture.model.diarizationRunningID == nil }

    // The seam got a path and a duration — never the transcript, the title, or the record.
    #expect(box.calls == 1)
    #expect(box.meetingID == fixture.id)
    #expect(box.audioPath == fixture.wavURL.path)
    #expect(box.durationSeconds == 4)

    #expect(FileManager.default.fileExists(atPath: fixture.sidecarURL.path))
    let overlay = try #require(fixture.model.speakerOverlay(for: fixture.id))
    #expect(overlay.rows == [
        SpeakerOverlayRow(segmentIndex: 0, label: .speaker(clusterID: 0)),
        SpeakerOverlayRow(segmentIndex: 1, label: .speaker(clusterID: 1))
    ])
    #expect(overlay.clusterIDs == [0, 1])
    #expect(overlay.isStale == false)
    #expect(overlay.isSingleCluster == false)

    // Nothing about the meeting changed: not the audio, not the text, not TranscriptSegment.speaker.
    #expect(try Data(contentsOf: fixture.wavURL) == wavBefore)
    let after = try #require(fixture.model.store.meeting(id: fixture.id))
    #expect(after.transcriptText == transcriptBefore)
    #expect(after.segments.allSatisfy { $0.speaker == nil })
    #expect(fixture.model.alertMessage == nil)
    #expect(fixture.model.isRunningAuxiliaryEngine == false)
    #expect(fixture.model.diarizationProgress == nil)
}

@MainActor
@Test("Speaker analysis publishes the runtime's progress while it runs (F219)")
func diarizationPublishesProgressWhileRunning() async throws {
    let fixture = try makeFixture()
    let box = DiarizationBox()
    fixture.model.runSpeakerDiarization = { _, progress in
        await progress(0.25)
        box.started = true
        while !box.release { await Task.yield() }
        return twoClusterResult()
    }

    fixture.model.requestSpeakerDiarization(for: fixture.id)
    await spin("the seam to report progress") { box.started }
    #expect(fixture.model.diarizationProgress == 0.25)

    box.release = true
    await spin("the analysis to finish") { fixture.model.diarizationRunningID == nil }
    #expect(fixture.model.diarizationProgress == nil)
}

@MainActor
@Test("Cancelling speaker analysis writes no sidecar and leaves the meeting untouched (F219)")
func diarizationCancellationWritesNothing() async throws {
    let fixture = try makeFixture()
    let box = DiarizationBox()
    fixture.model.runSpeakerDiarization = { _, _ in
        box.calls += 1
        box.started = true
        for _ in 0..<200_000 {
            try Task.checkCancellation()
            await Task.yield()
        }
        box.neverCancelled = true
        return twoClusterResult()
    }
    let wavBefore = try Data(contentsOf: fixture.wavURL)
    let transcriptBefore = try #require(fixture.model.store.meeting(id: fixture.id)?.transcriptText)
    let segmentsBefore = try #require(fixture.model.store.meeting(id: fixture.id)?.segments)

    fixture.model.requestSpeakerDiarization(for: fixture.id)
    await spin("the seam to start") { box.started }
    fixture.model.cancelSpeakerDiarization()
    await spin("the cancelled run to clear") { fixture.model.diarizationRunningID == nil }

    #expect(box.neverCancelled == false)                                        // cancellation really propagated
    #expect(!FileManager.default.fileExists(atPath: fixture.sidecarURL.path))   // nothing persisted
    #expect(fixture.model.speakerOverlay(for: fixture.id) == nil)
    #expect(fixture.model.alertMessage == nil)                                  // a cancel is not an error
    #expect(try Data(contentsOf: fixture.wavURL) == wavBefore)
    let after = try #require(fixture.model.store.meeting(id: fixture.id))
    #expect(after.transcriptText == transcriptBefore)
    #expect(after.segments == segmentsBefore)
    #expect(fixture.model.isRunningAuxiliaryEngine == false)
}

@MainActor
@Test("A failed speaker analysis explains itself and writes no sidecar (F219)")
func diarizationFailureLeavesTranscriptAndWritesNothing() async throws {
    let fixture = try makeFixture()
    fixture.model.runSpeakerDiarization = { _, _ in
        throw LocalDiarizationError.processFailed("the runtime exited with status 3.")
    }
    let wavBefore = try Data(contentsOf: fixture.wavURL)
    let transcriptBefore = try #require(fixture.model.store.meeting(id: fixture.id)?.transcriptText)

    fixture.model.requestSpeakerDiarization(for: fixture.id)
    await spin("the failed run to clear") { fixture.model.diarizationRunningID == nil }

    #expect(fixture.model.alertMessage?.contains("Your transcript is unchanged") == true)
    #expect(!FileManager.default.fileExists(atPath: fixture.sidecarURL.path))
    #expect(fixture.model.speakerOverlay(for: fixture.id) == nil)
    #expect(try Data(contentsOf: fixture.wavURL) == wavBefore)
    #expect(fixture.model.store.meeting(id: fixture.id)?.transcriptText == transcriptBefore)
}

@MainActor
@Test("Renaming a speaker changes only the alias, never the turns, audio, or transcript (F219)")
func diarizationRenameChangesOnlyTheAlias() async throws {
    let fixture = try makeFixture()
    fixture.model.runSpeakerDiarization = { _, _ in twoClusterResult() }
    fixture.model.requestSpeakerDiarization(for: fixture.id)
    await spin("the analysis to finish") { fixture.model.diarizationRunningID == nil }

    let wavBefore = try Data(contentsOf: fixture.wavURL)
    let transcriptBefore = try #require(fixture.model.store.meeting(id: fixture.id)?.transcriptText)
    let turnsBefore = try DiarizationArtifactCodec.decode(Data(contentsOf: fixture.sidecarURL)).turns

    fixture.model.renameSpeaker(clusterID: 1, to: "  Ada  ", in: fixture.id)

    let stored = try DiarizationArtifactCodec.decode(Data(contentsOf: fixture.sidecarURL))
    #expect(stored.aliases == ["1": "Ada"])       // trimmed, and only that one cluster
    #expect(stored.turns == turnsBefore)          // the analysis itself is untouched
    #expect(fixture.model.speakerOverlay(for: fixture.id)?.aliases == [1: "Ada"])
    #expect(try Data(contentsOf: fixture.wavURL) == wavBefore)
    #expect(fixture.model.store.meeting(id: fixture.id)?.transcriptText == transcriptBefore)
    #expect(fixture.model.alertMessage == nil)
}

@MainActor
@Test("Clearing speaker analysis deletes the sidecar and keeps the recording and transcript (F219)")
func diarizationClearRemovesOnlyTheSidecar() async throws {
    let fixture = try makeFixture()
    fixture.model.runSpeakerDiarization = { _, _ in twoClusterResult() }
    fixture.model.requestSpeakerDiarization(for: fixture.id)
    await spin("the analysis to finish") { fixture.model.diarizationRunningID == nil }
    let wavBefore = try Data(contentsOf: fixture.wavURL)
    let transcriptBefore = try #require(fixture.model.store.meeting(id: fixture.id)?.transcriptText)

    fixture.model.clearSpeakerDiarization(for: fixture.id)

    #expect(!FileManager.default.fileExists(atPath: fixture.sidecarURL.path))
    #expect(fixture.model.speakerOverlay(for: fixture.id) == nil)
    #expect(FileManager.default.fileExists(atPath: fixture.wavURL.path))
    #expect(try Data(contentsOf: fixture.wavURL) == wavBefore)
    #expect(fixture.model.store.meeting(id: fixture.id)?.transcriptText == transcriptBefore)
}

@MainActor
@Test("Re-running speaker analysis replaces the result and drops the previous aliases (F219)")
func diarizationRerunDropsPreviousAliases() async throws {
    let fixture = try makeFixture()
    fixture.model.runSpeakerDiarization = { _, _ in twoClusterResult() }
    fixture.model.requestSpeakerDiarization(for: fixture.id)
    await spin("the first analysis to finish") { fixture.model.diarizationRunningID == nil }
    fixture.model.renameSpeaker(clusterID: 0, to: "Ada", in: fixture.id)
    #expect(try DiarizationArtifactCodec.decode(Data(contentsOf: fixture.sidecarURL)).aliases == ["0": "Ada"])

    // Cluster ids permute between runs, so carrying "Ada" across would silently relabel someone else.
    fixture.model.runSpeakerDiarization = { _, _ in
        SpeakerDiarizationResult(
            turns: [
                SpeakerTurn(startSeconds: 0, endSeconds: 2, clusterID: 1, kind: .speech),
                SpeakerTurn(startSeconds: 2, endSeconds: 4, clusterID: 0, kind: .speech)
            ],
            speakerCount: 2, audioSeconds: 4
        )
    }
    fixture.model.requestSpeakerDiarization(for: fixture.id)
    await spin("the second analysis to finish") { fixture.model.diarizationRunningID == nil }

    let stored = try DiarizationArtifactCodec.decode(Data(contentsOf: fixture.sidecarURL))
    #expect(stored.aliases.isEmpty)
    #expect(stored.turns.first?.clusterID == 1)   // the new result, not the old one
    // Ascending id, not order of first labelled row: the legend shows "Speaker \(id + 1)", so any
    // other order makes it read out of sequence (F220, caught on a real meeting).
    #expect(fixture.model.speakerOverlay(for: fixture.id)?.clusterIDs == [0, 1])
}

@MainActor
@Test("An overlay is withheld once the transcript timings no longer match the analysis (F219)")
func diarizationOverlayIsWithheldWhenTimingsChange() async throws {
    let fixture = try makeFixture()
    fixture.model.runSpeakerDiarization = { _, _ in twoClusterResult() }
    fixture.model.requestSpeakerDiarization(for: fixture.id)
    await spin("the analysis to finish") { fixture.model.diarizationRunningID == nil }
    #expect(fixture.model.speakerOverlay(for: fixture.id) != nil)

    // A re-aligned segment: same text, different timings.
    fixture.model.store.update(id: fixture.id) { meeting in
        meeting.segments[1] = seg("two", 2.5, 4)
    }

    #expect(fixture.model.speakerOverlay(for: fixture.id) == nil)             // no labels are shown
    #expect(fixture.model.diarizationPresentation(for: fixture.id)?.isStale == true)  // and the reason is knowable
    #expect(FileManager.default.fileExists(atPath: fixture.sidecarURL.path))  // the result itself is kept
}

@MainActor
@Test("A single distinguished voice suppresses every label and blocks renaming (F219)")
func diarizationSingleClusterSuppressesLabels() async throws {
    let fixture = try makeFixture()
    fixture.model.runSpeakerDiarization = { _, _ in
        SpeakerDiarizationResult(
            turns: [
                SpeakerTurn(startSeconds: 0, endSeconds: 2, clusterID: 0, kind: .speech),
                SpeakerTurn(startSeconds: 2, endSeconds: 4, clusterID: 0, kind: .speech)
            ],
            speakerCount: 1, audioSeconds: 4
        )
    }
    fixture.model.requestSpeakerDiarization(for: fixture.id)
    await spin("the analysis to finish") { fixture.model.diarizationRunningID == nil }

    let overlay = try #require(fixture.model.speakerOverlay(for: fixture.id))
    #expect(overlay.isSingleCluster == true)
    #expect(overlay.clusterIDs.isEmpty)
    #expect(overlay.rows.allSatisfy { $0.label == .unlabeled })   // nothing is labelled at all

    // There is nothing safe to name: renaming the only cluster would attribute the other voice to it.
    fixture.model.renameSpeaker(clusterID: 0, to: "Ada", in: fixture.id)
    #expect(try DiarizationArtifactCodec.decode(Data(contentsOf: fixture.sidecarURL)).aliases.isEmpty)
    #expect(fixture.model.alertMessage != nil)
}

@MainActor
@Test("An unsaveable label says which of three things went wrong, not one generic line (F219)")
func diarizationRenameExplainsWhyTheSidecarCouldNotBeRead() async throws {
    // Task 9 hard-coded "could not be read" for every failure, because `load` reported one
    // undifferentiated `.unavailable`. Three different things hide in there and their advice is
    // opposite: a damaged file left a copy the user can go and find, a newer build's file needs an
    // update rather than a repair, and a locked file is a permissions problem somewhere else.
    let fixture = try makeFixture()
    fixture.model.runSpeakerDiarization = { _, _ in twoClusterResult() }
    fixture.model.requestSpeakerDiarization(for: fixture.id)
    await spin("the analysis to finish") { fixture.model.diarizationRunningID == nil }
    // The overlay must stay renameable, so replace the bytes only after it has been computed and
    // cached: the rename's own guard reads the cache, and the message under test is the next step.
    _ = fixture.model.speakerOverlay(for: fixture.id)

    try Data("{ half-written aliases".utf8).write(to: fixture.sidecarURL)
    fixture.model.renameSpeaker(clusterID: 1, to: "Ada", in: fixture.id)
    let damaged = try #require(fixture.model.alertMessage)
    let directory = fixture.sidecarURL.deletingLastPathComponent()
    let kept = try #require(
        (try FileManager.default.contentsOfDirectory(atPath: directory.path))
            .first { $0.hasPrefix("diarization.unreadable-") }
    )
    #expect(damaged.contains(kept))                       // the file they can actually go and find
    #expect(damaged.contains("Your transcript is unchanged"))

    fixture.model.alertMessage = nil
    try Data(#"{"schemaVersion":99,"somethingNew":true}"#.utf8).write(to: fixture.sidecarURL)
    fixture.model.renameSpeaker(clusterID: 1, to: "Ada", in: fixture.id)
    let newer = try #require(fixture.model.alertMessage)
    #expect(newer.contains("newer version"))
    #expect(newer.contains("99"))                          // the format it declared, not a vague hint
    #expect(newer != damaged)
    // And a newer build's intact file is never copied aside — only the damaged one was.
    #expect((try FileManager.default.contentsOfDirectory(atPath: directory.path))
        .filter { $0.hasPrefix("diarization.unreadable-") }.count == 1)
}

@MainActor
@Test("A rename of 64 flag emoji clamps to the codec's byte bound and comes back intact (F227)")
func diarizationRenameClampsAliasToTheCodecByteBound() async throws {
    // Genuinely red without the fix: `renameSpeaker` clamps with `.prefix(maximumAliasLength)`, which
    // counts GRAPHEMES, while the codec bounds an alias at `4 * maximumAliasLength` UTF-8 bytes. 64
    // flag emoji is 64 graphemes and 512 bytes, so the clamp hands `encode` a value it refuses and the
    // rename dies with `.malformed("aliasLength")` — a name a user could reasonably type, in a control
    // that offers no way to know why it failed.
    let fixture = try makeFixture()
    fixture.model.runSpeakerDiarization = { _, _ in twoClusterResult() }
    fixture.model.requestSpeakerDiarization(for: fixture.id)
    await spin("the analysis to finish") { fixture.model.diarizationRunningID == nil }

    let wavBefore = try Data(contentsOf: fixture.wavURL)
    let transcriptBefore = try #require(fixture.model.store.meeting(id: fixture.id)?.transcriptText)
    let turnsBefore = try DiarizationArtifactCodec.decode(Data(contentsOf: fixture.sidecarURL)).turns

    let typed = String(repeating: "\u{1F1FA}\u{1F1F8}", count: 64)
    #expect(typed.count == 64)          // inside the grapheme bound the old clamp enforced…
    #expect(typed.utf8.count == 512)    // …and twice the byte bound the codec enforces
    fixture.model.renameSpeaker(clusterID: 1, to: typed, in: fixture.id)

    #expect(fixture.model.alertMessage == nil)
    let stored = try DiarizationArtifactCodec.decode(Data(contentsOf: fixture.sidecarURL))
    let saved = try #require(stored.aliases["1"])
    #expect(!saved.isEmpty)
    #expect(saved.utf8.count <= DiarizationArtifactV1.maximumAliasByteLength)
    #expect(saved.count <= DiarizationArtifactV1.maximumAliasLength)
    // Clamped, not mangled: whole flags only, and a prefix of what was typed.
    #expect(typed.hasPrefix(saved))
    #expect(saved == String(repeating: "\u{1F1FA}\u{1F1F8}", count: 32))
    // It survives the round trip the codec would otherwise have refused outright.
    #expect(fixture.model.speakerOverlay(for: fixture.id)?.aliases == [1: saved])
    #expect(stored.turns == turnsBefore)
    #expect(try Data(contentsOf: fixture.wavURL) == wavBefore)
    #expect(fixture.model.store.meeting(id: fixture.id)?.transcriptText == transcriptBefore)
}

@MainActor
@Test("A name too heavy for one character is refused, never turned into a deletion (F227)")
func diarizationRenameRefusesAnAliasNoPrefixCanFit() async throws {
    // This one is red against the obvious FIX rather than against the old code, and that is the point:
    // a byte clamp that just drops characters until the value fits empties a string whose FIRST
    // grapheme already exceeds the bound (one 'a' under 300 combining acutes is 601 bytes), and
    // `renameSpeaker` reads an empty alias as "clear this label". Measured with the guard removed from
    // `clampedAlias`: the saved "Ada" is DELETED and no alert is shown. The old grapheme-only clamp
    // happened to pass here by failing in `encode` instead, so without this test the fix could quietly
    // trade a refusal for a silent deletion.
    let fixture = try makeFixture()
    fixture.model.runSpeakerDiarization = { _, _ in twoClusterResult() }
    fixture.model.requestSpeakerDiarization(for: fixture.id)
    await spin("the analysis to finish") { fixture.model.diarizationRunningID == nil }
    fixture.model.renameSpeaker(clusterID: 1, to: "Ada", in: fixture.id)
    #expect(try DiarizationArtifactCodec.decode(Data(contentsOf: fixture.sidecarURL)).aliases == ["1": "Ada"])

    let heavy = "a" + String(repeating: "\u{0301}", count: 300)
    #expect(heavy.count == 1)
    #expect(heavy.utf8.count == 601)
    fixture.model.renameSpeaker(clusterID: 1, to: heavy, in: fixture.id)

    #expect(fixture.model.alertMessage != nil)
    #expect(fixture.model.alertMessage?.contains("transcript is unchanged") == true)
    #expect(try DiarizationArtifactCodec.decode(Data(contentsOf: fixture.sidecarURL)).aliases == ["1": "Ada"])
    #expect(fixture.model.speakerOverlay(for: fixture.id)?.aliases == [1: "Ada"])

    // Clearing a label is still a deliberate empty string, and still works.
    fixture.model.alertMessage = nil
    fixture.model.renameSpeaker(clusterID: 1, to: "   ", in: fixture.id)
    #expect(fixture.model.alertMessage == nil)
    #expect(try DiarizationArtifactCodec.decode(Data(contentsOf: fixture.sidecarURL)).aliases.isEmpty)
}
