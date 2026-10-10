import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F885 — a finished result (a transcript, a summary, a status) whose save loses to another copy of the
// app twice in a row.
//
// F662 (`MeetingStore.saveResult`): on a lost race the result is taken out, the library re-read, and the
// result made again to the copy the re-read found and saved once more. If the other copy saved again
// between that re-read and the re-save, the second recovery saw the result as the person's change: the
// banner said "Keep My Edit saves your changes to “Review”", and Use the Other Copy erased the transcript
// from disk (the round-2 review of Wave 4 lane Q). The result now waits beside the banner, out of the
// list, and either answer makes it to the copy it keeps.
//
// These drive two real `BackupJSONStore` writers over one temp root: this window's `MeetingStore`, and
// another copy committing through the same files.

@MainActor
private func libraryRoot(_ label: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("F885-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

/// Another copy of the app reading what is on disk and committing `change` of it.
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

private let renamedHere = "Standup, renamed here"
private let renamedThere = "Standup, renamed by the other copy"
private let finished = "We agreed to ship on Friday."

/// The meetings the banner's Keep My Edit sentence names as the person's own changes.
private func namedAsYourChanges(_ message: String) -> String {
    guard let start = message.range(of: "Keep My Edit saves your changes to "),
          let end = message.range(of: " over the other copy's", range: start.upperBound..<message.endIndex)
    else { return "" }
    return String(message[start.upperBound..<end.lowerBound])
}

/// The result a transcription writes, in the shape `AppModel.apply(result:)` gives it.
private func transcribed(_ record: inout MeetingRecord) {
    record.transcriptText = finished
    record.status = .completed
}

/// This window holds a Standup and a Review being transcribed; another copy renamed the Standup first, and
/// this window's own rename of it lost: the banner is up, asking about the Standup.
@MainActor
private func libraryWithTheBannerUp(_ label: String) throws -> (MeetingStore, URL, standup: UUID, review: UUID) {
    let root = try libraryRoot(label)
    let standup = UUID(), review = UUID()
    let store = MeetingStore(rootDirectory: root)
    store.upsert(MeetingRecord(id: standup, title: "Standup", status: .completed))
    store.upsert(MeetingRecord(id: review, title: "Review", status: .processing))
    try otherCopyCommits(in: root) { $0.map { var r = $0; if r.id == standup { r.title = renamedThere }; return r } }
    store.update(id: standup) { $0.title = renamedHere }
    let offer = try #require(store.conflictOffer, "fixture: the rename should have lost and been offered back")
    try #require(offer.delta.contains { $0.id == standup && $0.title == renamedHere })
    return (store, root, standup, review)
}

/// Makes the other copy save between this window's next two saves of the meeting index: the result's own
/// save loses because the other copy saved before it (`first`), and the re-save after the re-read loses
/// because it saved again in between (`second`).
@MainActor
private func otherCopySavesBeforeEachOfTheNextTwoSaves(of store: MeetingStore, in root: URL) throws -> (first: UUID, second: UUID) {
    let first = UUID(), second = UUID()
    try otherCopyCommits(in: root) { $0 + [MeetingRecord(id: first, title: "The other copy's first", status: .recorded)] }
    var saves = 0
    store.beforeIndexSaveForTesting = {
        saves += 1
        if saves == 2 {
            try? otherCopyCommits(in: root) { $0 + [MeetingRecord(id: second, title: "The other copy's second", status: .recorded)] }
        }
    }
    return (first, second)
}

// MARK: - F885

@MainActor
@Test("A result whose save loses twice is not offered as the person's change, and either answer saves it (F885)", arguments: [true, false])
func aResultWhoseSaveLosesTwiceIsSavedByEitherAnswer(keep: Bool) throws {
    let (store, root, standup, review) = try libraryWithTheBannerUp("twice-\(keep)")
    defer { try? FileManager.default.removeItem(at: root) }
    let theirs = try otherCopySavesBeforeEachOfTheNextTwoSaves(of: store, in: root)

    store.update(id: review, as: .result, transcribed)
    store.beforeIndexSaveForTesting = nil

    #expect(store.writeConflict == nil, "the second race was left raw")
    let offer = try #require(store.conflictOffer, "the person's own rename is still a question")
    #expect(!offer.delta.contains { $0.id == review }, "the result was offered as the person's change: \(offer.message)")
    #expect(!namedAsYourChanges(offer.message).contains("“Review”"), "\(offer.message)")
    #expect(offer.message.contains("“Review”"), "the banner does not say the transcript is waiting: \(offer.message)")
    #expect(offer.delta.contains { $0.id == standup && $0.title == renamedHere }, "the person's rename is no longer offered")

    if keep { store.keepConflictedEdit() } else { store.discardConflictedEdit() }

    #expect(store.conflictOffer == nil)
    #expect(store.writeConflict == nil)
    let saved = try #require(onDisk(root, review))
    #expect(saved.transcriptText == finished, keep ? "Keep lost the transcript" : "Use the Other Copy erased the transcript")
    #expect(saved.status == .completed)
    #expect(store.meeting(id: review)?.transcriptText == finished)
    #expect(onDisk(root, standup)?.title == (keep ? renamedHere : renamedThere))
    #expect(onDisk(root, theirs.first) != nil && onDisk(root, theirs.second) != nil, "an answer overwrote the other copy's meetings")
}

/// The answer's own save can lose too: the result goes back to waiting, out of the list, and the next
/// answer saves it — never offered as the person's change on the way.
@MainActor
@Test("A held result survives the answer's own lost save and is saved by the next answer (F885)")
func aHeldResultSurvivesALostAnswer() throws {
    let (store, root, _, review) = try libraryWithTheBannerUp("answer-lost")
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try otherCopySavesBeforeEachOfTheNextTwoSaves(of: store, in: root)
    store.update(id: review, as: .result, transcribed)
    store.beforeIndexSaveForTesting = nil
    try #require(store.conflictOffer.map { !$0.delta.contains { $0.id == review } } == true)

    // The other copy saves once more before the answer's save.
    try otherCopyCommits(in: root) { $0 + [MeetingRecord(title: "The other copy's third", status: .recorded)] }
    store.keepConflictedEdit()

    let offer = try #require(store.conflictOffer, "the lost answer re-offers what it was saving")
    #expect(!offer.delta.contains { $0.id == review }, "the result was offered as the person's change: \(offer.message)")
    #expect(offer.message.contains("“Review”"), "\(offer.message)")
    store.keepConflictedEdit()

    #expect(store.conflictOffer == nil)
    #expect(onDisk(root, review)?.transcriptText == finished, "the held result was lost with the answer's save")
}

/// A later result for a meeting whose result is held waits behind it, so they reach disk in the order they
/// finished — made now, the later one would be saved first and the answer would then make the earlier one
/// on top of it.
@MainActor
@Test("A later result for a meeting whose result is held is made after it (F885)")
func aLaterResultWaitsBehindTheHeldOne() throws {
    let (store, root, _, review) = try libraryWithTheBannerUp("order")
    defer { try? FileManager.default.removeItem(at: root) }
    _ = try otherCopySavesBeforeEachOfTheNextTwoSaves(of: store, in: root)
    // An earlier result that really changes the meeting, so its save is a change that can lose.
    store.update(id: review, as: .result) { $0.transcriptText = "An early draft."; $0.status = .processing }
    store.beforeIndexSaveForTesting = nil
    try #require(store.conflictOffer.map { !$0.delta.contains { $0.id == review } } == true,
                 "fixture: the earlier result is held, not offered")

    store.update(id: review, as: .result, transcribed)
    store.discardConflictedEdit()

    let saved = try #require(onDisk(root, review))
    #expect(saved.status == .completed, "the earlier result was made on top of the later one: \(saved.status)")
    #expect(saved.transcriptText == finished, "\(saved.transcriptText)")
}
