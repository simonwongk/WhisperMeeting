import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F844, F881 — read-only sentences that F540 and F833 left untrue for one shape each.
//
// F540 made every read-only sentence say what was found, built from the store's health. Health alone
// cannot say two things the sentences need:
// - F844: a `meetings.json` that is MISSING (only its backup is there) loads `.recoveredFromBackup` like a
//   damaged one, and was described as "damaged … left as it was" — about a file that does not exist. And
//   Verify Library declined, in every read-only state, with "cannot report on an index it could not read",
//   including the empty-index and two-versions states, where the index read fine.
// - F881: two versions where the version on disk is an empty list beside finished recordings — the
//   2026-08-14 shape — still named Keep the Version on Disk, which refuses exactly that shape (F833).
//
// Driven through the app's own launch and Verify Library over real temp libraries.

private func temporaryLibrary(_ label: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("F844-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

/// A library saved through a real store, one meeting per title — its ledger, backup and history are the
/// app's own.
@MainActor
private func savedLibrary(_ label: String, titles: [String]) throws -> URL {
    let root = try temporaryLibrary(label)
    let seed = MeetingStore(rootDirectory: root)
    for title in titles {
        seed.upsert(MeetingRecord(id: UUID(), title: title, status: .completed))
    }
    try #require(!seed.isDegraded, "the seed must have saved")
    return root
}

/// A recording that finished — what makes an empty index the wipe shape rather than a new library.
private func finishedRecordingFolder(in root: URL) throws {
    let folder = root.appendingPathComponent("Recordings/\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let dataByteCount: UInt32 = 48_000 * 2
    var wav = WAVWriter.header(sampleRate: 48_000, dataByteCount: dataByteCount)
    wav.append(Data(count: Int(dataByteCount)))
    try wav.write(to: folder.appendingPathComponent("meeting.wav"))
    try Data(#"{"systemAudio":{},"microphoneAudio":{}}"#.utf8).write(to: folder.appendingPathComponent("source-tracks.json"))
}

enum ReadOnlyShape: String, CaseIterable, Sendable {
    /// `meetings.json` is gone; its backup reads (F844).
    case indexMissing
    /// An empty index no save recorded, beside finished recordings, with the last recorded save kept:
    /// two versions, one of them the wipe shape (F881).
    case emptyVersionOnDisk
    /// The wipe shape on its own (`.suspectEmpty`): the index read cleanly.
    case wiped
    /// A valid index from another library over this one's: two versions, both with meetings.
    case twoVersions
}

@MainActor
private func makeLibrary(_ shape: ReadOnlyShape) throws -> URL {
    switch shape {
    case .indexMissing:
        let root = try savedLibrary("missing", titles: ["first", "second"])
        try FileManager.default.removeItem(at: root.appendingPathComponent("meetings.json"))
        return root
    case .emptyVersionOnDisk:
        let root = try savedLibrary("empty-version", titles: ["first", "second"])
        try finishedRecordingFolder(in: root)
        try Data("[]".utf8).write(to: root.appendingPathComponent("meetings.json"))
        return root
    case .wiped:
        let root = try temporaryLibrary("wiped")
        try Data("[]".utf8).write(to: root.appendingPathComponent("meetings.json"))
        try Data("[]".utf8).write(to: root.appendingPathComponent("meetings.backup.json"))
        try finishedRecordingFolder(in: root)
        return root
    case .twoVersions:
        let root = try savedLibrary("two", titles: ["first", "second"])
        let rival = try savedLibrary("rival", titles: ["the rival's meeting"])
        defer { try? FileManager.default.removeItem(at: rival) }
        try Data(contentsOf: rival.appendingPathComponent("meetings.json"))
            .write(to: root.appendingPathComponent("meetings.json"))
        return root
    }
}

/// The app opened on `shape`: its model, and what it said at launch.
@MainActor
private func launch(_ shape: ReadOnlyShape) async throws -> (model: AppModel, root: URL, message: String) {
    let root = try makeLibrary(shape)
    let defaults = try #require(UserDefaults(suiteName: testSuiteName()))
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(), defaults: defaults)
    await model.performStartupRecovery()
    let message = try #require(model.alertMessage, "a read-only library said nothing at launch")
    return (model, root, message)
}

@MainActor
@Test("A missing meeting index opened from its backup is called missing, not damaged (F844)")
func aMissingIndexIsNotCalledDamaged() async throws {
    let (model, root, message) = try await launch(.indexMissing)
    defer { try? FileManager.default.removeItem(at: root) }
    try #require(model.store.health == .recoveredFromBackup, "fixture: \(model.store.health)")
    try #require(!FileManager.default.fileExists(atPath: root.appendingPathComponent("meetings.json").path))

    #expect(!message.contains("damaged"), "a file that does not exist is called damaged: \(message)")
    #expect(!message.contains("left as it was"), "\(message)")
    #expect(message.contains("missing"), "\(message)")
}

@MainActor
@Test("Two versions whose version on disk is the empty wipe shape name Recover Library, not Keep the Version on Disk (F881)")
func anEmptyVersionOnDiskIsNotOfferedToKeep() async throws {
    let (model, root, message) = try await launch(.emptyVersionOnDisk)
    defer { try? FileManager.default.removeItem(at: root) }
    try #require(model.store.health == .divergentGenerations, "fixture: \(model.store.health)")

    #expect(!message.contains(ReadOnlyLibraryNotice.keepVersionOnDiskButton), "the launch names a button that refuses this shape: \(message)")
    #expect(message.contains("Recover Library"), "\(message)")
}

@MainActor
@Test("Verify Library, declined on a read-only library, says what was found rather than that the index could not be read (F844)", arguments: [ReadOnlyShape.wiped, .twoVersions, .indexMissing, .emptyVersionOnDisk])
func verifyLibraryDeclinesWithTheRealReason(_ shape: ReadOnlyShape) async throws {
    let (model, root, _) = try await launch(shape)
    defer { try? FileManager.default.removeItem(at: root) }
    try #require(model.store.isDegraded, "fixture: \(model.store.health)")
    model.alertMessage = nil

    model.verifyLibrary()

    let said = try #require(model.alertMessage)
    #expect(!said.contains("could not read"), "\(shape): the index read fine, or is missing: \(said)")
    #expect(said.contains("nothing was checked"), "\(said)")
    // What was found, in the words every other surface uses for this library.
    #expect(said.contains(ReadOnlyLibraryNotice.found(model.store.health, onDisk: model.store.indexOnDisk)), "\(said)")
}

// MARK: - The standing surfaces, from the store's own state

/// The banner and the Settings sentence are built by `ContentView` from `model.store.health` and
/// `model.store.indexOnDisk` (asserted on its source below); these build them the same way from a store
/// that loaded each shape.
@MainActor
@Test("The banner and Settings call a missing index missing, and offer no button for an empty version on disk (F844, F881)")
func theStandingSurfacesDescribeWhatWasOnDisk() async throws {
    let (missing, missingRoot, _) = try await launch(.indexMissing)
    defer { try? FileManager.default.removeItem(at: missingRoot) }
    #expect(missing.store.indexOnDisk == .missing)
    for text in [
        ReadOnlyLibraryNotice.banner(for: missing.store.health, onDisk: missing.store.indexOnDisk),
        ReadOnlyLibraryNotice.librarySectionNotice(for: missing.store.health, onDisk: missing.store.indexOnDisk),
    ] {
        #expect(text.contains("missing") && !text.contains("damaged"), "\(text)")
    }

    let (empty, emptyRoot, _) = try await launch(.emptyVersionOnDisk)
    defer { try? FileManager.default.removeItem(at: emptyRoot) }
    #expect(empty.store.indexOnDisk == .emptyBesideRecordings(recordingFolderCount: 1))
    #expect(!empty.store.offersKeepVersionOnDisk, "Settings offers a button that refuses this shape")
    for text in [
        ReadOnlyLibraryNotice.banner(for: empty.store.health, onDisk: empty.store.indexOnDisk),
        ReadOnlyLibraryNotice.librarySectionNotice(for: empty.store.health, onDisk: empty.store.indexOnDisk),
    ] {
        #expect(!text.contains(ReadOnlyLibraryNotice.keepVersionOnDiskButton), "\(text)")
        #expect(text.contains("Recover Library"), "\(text)")
        #expect(text.contains("1 finished recording"), "\(text)")
    }

    // Two versions that are both meetings still offer both ways out.
    let (two, twoRoot, message) = try await launch(.twoVersions)
    defer { try? FileManager.default.removeItem(at: twoRoot) }
    #expect(two.store.indexOnDisk == .asHealthSays)
    #expect(two.store.offersKeepVersionOnDisk)
    #expect(message.contains(ReadOnlyLibraryNotice.keepVersionOnDiskButton), "\(message)")
}

/// A recovery that writes an index and reloads must not keep the last load's file description: the
/// detail goes with the health it came with.
@MainActor
@Test("What was on disk is forgotten with the health when a recovery reloads (F844)")
func theIndexDetailIsResetByARecovery() async throws {
    let (model, root, _) = try await launch(.indexMissing)
    defer { try? FileManager.default.removeItem(at: root) }
    try #require(model.store.indexOnDisk == .missing)
    model.requestLibraryRecovery()
    let offered = try #require(model.pendingLibraryRecovery, "\(model.alertMessage ?? "no message")")
    let newest = try #require(offered.max { $0.sequence < $1.sequence })

    model.recoverLibrary(from: newest, confirmed: true)

    #expect(model.store.health == .complete, "\(model.store.health)")
    #expect(model.store.indexOnDisk == .asHealthSays)
}

@Test("The Settings section shows Keep the Version on Disk only when the store offers it, and both sentences get what was on disk (F881, F844)")
func theMeetingLibrarySectionAsksTheStore() throws {
    let source = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/ContentView.swift")
    #expect(source.contains("if model.store.offersKeepVersionOnDisk {"))
    #expect(!source.contains("model.store.health == .divergentGenerations"), "a gate on the health alone is back")
    #expect(source.contains("ReadOnlyLibraryNotice.banner(for: model.store.health, onDisk: model.store.indexOnDisk)"))
    #expect(source.contains("ReadOnlyLibraryNotice.librarySectionNotice(for: model.store.health, onDisk: model.store.indexOnDisk)"))
}
