import Foundation
import Testing
@testable import WhisperMeet
@testable import WhisperCore

// F193, the reachable half. The store can recover a damaged library (see
// LibraryRecoveryActionTests), but nothing exposed it, so the only way to reach recovery was a test.
// Meanwhile `ReadOnlyLibraryNotice` tells the user to "resolve recovery" in four different places.
//
// The ticket's constraints are explicit: the rebuild "must never run automatically, never delete
// audio, and must preserve the quarantined bytes", and its verification wants "a test proving the
// rebuild is not reachable without explicit confirmation". These tests are that proof.
//
// The confirmation follows the shape already used for a long link import
// (`pendingLongMediaConfirmation` + a `confirmed:` flag the UI passes on the second call), so there
// is one confirmation idiom in this model rather than two.

@MainActor
private func makeModel(rootDirectory: URL) -> AppModel {
    let defaults = UserDefaults(suiteName: "LibraryRecoveryFlow.\(UUID().uuidString)")!
    return AppModel(
        store: MeetingStore(rootDirectory: rootDirectory),
        recorder: AudioCaptureEngine(),
        defaults: defaults
    )
}

/// A damaged library that still holds a record, its audio, and a generation worth restoring.
@MainActor
private func makeDamagedLibrary() throws -> (root: URL, meeting: MeetingRecord) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("WhisperMeetRecoveryFlow-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let id = UUID()
    let directory = root.appendingPathComponent("Recordings/\(id.uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    try Data("audio".utf8).write(to: directory.appendingPathComponent("meeting.wav"))

    let meeting = MeetingRecord(
        id: id,
        title: "Quarterly review",
        recordingPath: "Recordings/\(id.uuidString)/meeting.wav",
        status: .completed,
        transcriptText: "the original transcript"
    )
    let seed = MeetingStore(rootDirectory: root)
    seed.upsert(meeting)
    try #require(!seed.isDegraded, "the seed store must be writable, or nothing was persisted")

    try Data("truncated-primary".utf8).write(to: root.appendingPathComponent("meetings.json"))
    return (root, meeting)
}

@Test("A damaged library offers recovery, naming what each option would restore")
@MainActor
func damagedLibraryOffersRecovery() throws {
    let (root, _) = try makeDamagedLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let model = makeModel(rootDirectory: root)
    try #require(model.store.isDegraded)

    model.requestLibraryRecovery()

    let offered = try #require(model.pendingLibraryRecovery)
    #expect(!offered.isEmpty, "a damaged library with retained generations must offer them")
    // The user is reviewing, so at least one option has to say what it holds — F193 asks to "show
    // what would be recovered". `recordCount` is optional because a generation whose bytes cannot be
    // decoded still deserves to be listed rather than hidden, so this asserts a usable offer exists
    // rather than that every row is complete.
    #expect(offered.contains { $0.recordCount != nil })
}

@Test("Recovery is not reachable without explicit confirmation")
@MainActor
func recoveryRequiresConfirmation() throws {
    let (root, meeting) = try makeDamagedLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let model = makeModel(rootDirectory: root)

    model.requestLibraryRecovery()
    let generation = try #require(model.pendingLibraryRecovery?.first)

    // Snapshot first. This fixture loaded from the intact BACKUP, so it already sees the record —
    // asserting its absence would be wrong, and an earlier version of this test papered over that
    // with a disjunction whose last term repeated the assertion above it, making the whole
    // expectation unconditionally true. What actually matters is that nothing CHANGED.
    let before = model.store.meetings
    let healthBefore = model.store.health

    model.recoverLibrary(from: generation, confirmed: false)

    #expect(model.store.isDegraded, "an unconfirmed recovery must not restore")
    #expect(model.store.meetings == before, "an unconfirmed recovery must not touch the records")
    #expect(model.store.health == healthBefore, "nor the library's health")
    #expect(model.pendingLibraryRecovery != nil, "the offer stays open until confirmed or dismissed")
    // And the meeting on disk is still the pre-restore one.
    #expect(MeetingStore(rootDirectory: root).meeting(id: meeting.id)?.title == "Quarterly review")
}

@Test("A generation that was never offered cannot be restored, even confirmed")
@MainActor
func recoveryRefusesAGenerationTheUserNeverSaw() throws {
    let (root, meeting) = try makeDamagedLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let model = makeModel(rootDirectory: root)

    // Read a real generation from the store WITHOUT going through requestLibraryRecovery, so it was
    // never presented for review. F193 asks for a "user-reviewed" action; this makes that
    // structural rather than a convention a future caller could quietly break.
    let generation = try #require(try model.store.indexGenerations().first)
    #expect(model.pendingLibraryRecovery == nil)

    let before = model.store.meetings
    model.recoverLibrary(from: generation, confirmed: true)

    #expect(model.store.isDegraded, "a generation the user never reviewed must not be restored")
    #expect(model.store.meetings == before)
    #expect(MeetingStore(rootDirectory: root).meeting(id: meeting.id)?.title == "Quarterly review")
}

@Test("A confirmed recovery restores the library and makes it writable")
@MainActor
func confirmedRecoveryRestoresAndReopens() throws {
    let (root, meeting) = try makeDamagedLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let model = makeModel(rootDirectory: root)

    model.requestLibraryRecovery()
    let generation = try #require(model.pendingLibraryRecovery?.first)

    model.recoverLibrary(from: generation, confirmed: true)

    #expect(!model.store.isDegraded)
    #expect(model.store.meeting(id: meeting.id)?.title == "Quarterly review")
    #expect(model.pendingLibraryRecovery == nil, "the offer is cleared once it has been acted on")
    // And the library really is writable now, not just flagged as such.
    model.store.update(id: meeting.id) { $0.title = "Renamed after recovery" }
    #expect(MeetingStore(rootDirectory: root).meeting(id: meeting.id)?.title == "Renamed after recovery")
}

@Test("Recovery removes no audio")
@MainActor
func recoveryKeepsEveryRecording() throws {
    let (root, meeting) = try makeDamagedLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let model = makeModel(rootDirectory: root)
    let audio = root.appendingPathComponent(meeting.recordingPath)

    model.requestLibraryRecovery()
    let generation = try #require(model.pendingLibraryRecovery?.first)
    model.recoverLibrary(from: generation, confirmed: true)

    #expect(FileManager.default.fileExists(atPath: audio.path))
    #expect(try Data(contentsOf: audio) == Data("audio".utf8))
}

@Test("A healthy library is not offered recovery it does not need")
@MainActor
func healthyLibraryIsNotOfferedRecovery() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("WhisperMeetHealthy-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let model = makeModel(rootDirectory: root)
    try #require(!model.store.isDegraded)

    model.requestLibraryRecovery()

    // Restoring an older generation over a healthy library is a data-loss action dressed as a
    // repair, so it is not offered. The user is told why rather than shown an empty sheet.
    #expect(model.pendingLibraryRecovery == nil)
    #expect(model.alertMessage != nil)
}
