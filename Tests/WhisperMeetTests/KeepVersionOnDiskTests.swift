import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F833 — the in-app way to keep the index on disk when two versions of the library are found.
//
// F540 built the message ("Two versions of the meeting library were found") and named both ways out:
// Recover Library… for the last save WhisperMeet recorded, and, for the index in place, a Terminal
// step in docs/RECOVERY.md — quit the app and remove `meetings.ledger.json`. Decided 2026-10-07 by the
// user (asked by whisper-dfd4, two options): add an in-app "Keep the version on disk" button that moves
// `meetings.ledger.json` aside — kept, never deleted — and reloads.

@MainActor
private func savedLibrary(_ label: String, titles: [String]) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("F833-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let seed = MeetingStore(rootDirectory: root)
    for title in titles {
        seed.upsert(MeetingRecord(id: UUID(), title: title, status: .completed))
    }
    try #require(!seed.isDegraded, "the seed must have saved")
    return root
}

/// F540's two-versions shape: this library's own saves, then a valid index from another library
/// copied over `meetings.json` — decodable, and in no lineage this library recorded.
@MainActor
private func divergentLibrary() throws -> URL {
    let root = try savedLibrary("two", titles: ["first", "second"])
    let rival = try savedLibrary("rival", titles: ["the rival's meeting"])
    defer { try? FileManager.default.removeItem(at: rival) }
    try Data(contentsOf: rival.appendingPathComponent("meetings.json"))
        .write(to: root.appendingPathComponent("meetings.json"))
    return root
}

@MainActor
private func makeModel(_ root: URL) throws -> AppModel {
    let defaults = try #require(UserDefaults(suiteName: testSuiteName()))
    return AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(), defaults: defaults)
}

private func names(in directory: URL) -> [String] {
    (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
}

@MainActor
@Test("Keep the Version on Disk sets the ledger aside unchanged, and the library opens writable on the index in place (F833)")
func keepingTheVersionOnDiskReopensTheLibrary() throws {
    let root = try divergentLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let ledger = root.appendingPathComponent("meetings.ledger.json")
    let ledgerBytes = try Data(contentsOf: ledger)
    let indexBytes = try Data(contentsOf: root.appendingPathComponent("meetings.json"))
    let history = root.appendingPathComponent("meetings.history", isDirectory: true)
    let historyBefore = Set(names(in: history))
    let model = try makeModel(root)
    try #require(model.store.health == .divergentGenerations, "the fixture is not two versions: \(model.store.health)")

    model.keepLibraryVersionOnDisk()

    #expect(!model.store.isDegraded, "still read-only: \(model.store.health)")
    #expect(model.store.meetings.map(\.title) == ["the rival's meeting"], "not the version that was on disk")
    #expect(try Data(contentsOf: root.appendingPathComponent("meetings.json")) == indexBytes,
            "choosing the version on disk changed it")
    #expect(!FileManager.default.fileExists(atPath: ledger.path), "the ledger is still in place")
    let keptAs = names(in: root).filter { $0.hasPrefix("meetings.ledger.set-aside-") }
    try #require(keptAs.count == 1, "the ledger was not kept beside the library: \(names(in: root).sorted())")
    #expect(try Data(contentsOf: root.appendingPathComponent(keptAs[0])) == ledgerBytes, "the kept ledger is not the one set aside")
    // The other version — the last save WhisperMeet recorded — is still in the history.
    #expect(Set(names(in: history)).isSuperset(of: historyBefore), "a generation left the history")
    // Says where the ledger went, since it is kept for the user.
    #expect(model.alertMessage?.contains(keptAs[0]) == true, "\(model.alertMessage ?? "nothing was said")")

    // And the library takes edits again, on disk.
    let id = try #require(model.store.meetings.first?.id)
    model.store.update(id: id) { $0.title = "renamed after choosing" }
    #expect(MeetingStore(rootDirectory: root).meeting(id: id)?.title == "renamed after choosing")
}

/// The manual step done while the app was still open: the ledger is already gone when the button is
/// pressed. There is nothing left to move, and the library should still open.
@MainActor
@Test("Keep the Version on Disk still reopens the library when the ledger was already removed by hand (F833)")
func keepingTheVersionOnDiskWithTheLedgerAlreadyGone() throws {
    let root = try divergentLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let model = try makeModel(root)
    try #require(model.store.health == .divergentGenerations)
    try FileManager.default.removeItem(at: root.appendingPathComponent("meetings.ledger.json"))

    model.keepLibraryVersionOnDisk()

    #expect(!model.store.isDegraded, "still read-only: \(model.store.health)")
    #expect(model.store.meetings.map(\.title) == ["the rival's meeting"])
    #expect(model.alertMessage?.contains("already gone") == true, "\(model.alertMessage ?? "nothing was said")")
}

/// A recording that finished, as F187's and F540's fixtures write it — what makes an empty index the
/// 2026-08-14 wipe shape rather than a new library.
private func finishedRecordingFolder(in root: URL) throws {
    let folder = root.appendingPathComponent("Recordings/\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let dataByteCount: UInt32 = 48_000 * 2
    var wav = WAVWriter.header(sampleRate: 48_000, dataByteCount: dataByteCount)
    wav.append(Data(count: Int(dataByteCount)))
    try wav.write(to: folder.appendingPathComponent("meeting.wav"))
    try Data(#"{"systemAudio":{},"microphoneAudio":{}}"#.utf8).write(to: folder.appendingPathComponent("source-tracks.json"))
}

@MainActor
private func countsInRecoveryList(_ store: MeetingStore) throws -> [Int?] {
    try store.indexGenerations().map(\.recordCount)
}

/// The lane review's F833 follow-up (probe P5): an empty index no save recorded — the 2026-08-14 wipe
/// shape, written by something else — loads as two versions, so the button was offered. Keeping that
/// version cannot open the library (an empty index beside finished recordings stays read-only), and
/// setting the ledger aside took the meeting counts out of the Recover Library list the user then
/// needs: `[2, 1]` → `[nil, nil]`.
@MainActor
@Test("Keep the Version on Disk refuses an empty version beside finished recordings, changes nothing, and points to Recover Library (F833)")
func keepingAnEmptyVersionOnDiskIsRefused() throws {
    let root = try savedLibrary("wiped", titles: ["first", "second"])
    defer { try? FileManager.default.removeItem(at: root) }
    try finishedRecordingFolder(in: root)
    try Data("[]".utf8).write(to: root.appendingPathComponent("meetings.json"))
    let ledger = root.appendingPathComponent("meetings.ledger.json")
    let ledgerBytes = try Data(contentsOf: ledger)
    let model = try makeModel(root)
    try #require(model.store.health == .divergentGenerations, "the fixture is not two versions: \(model.store.health)")
    let countsBefore = try countsInRecoveryList(model.store)
    try #require(countsBefore.contains { $0 != nil }, "precondition: the recovery list has counts")
    let identityBefore = try #require(StoreFileIdentity(path: ledger.path))

    model.keepLibraryVersionOnDisk()

    #expect(try Data(contentsOf: ledger) == ledgerBytes, "the ledger was moved for a version that cannot be kept")
    // Refused before anything moved, not moved and put back: a rename changes the file's ctime.
    #expect(StoreFileIdentity(path: ledger.path) == identityBefore, "the ledger was touched")
    #expect(names(in: root).filter { $0.hasPrefix("meetings.ledger.set-aside-") }.isEmpty)
    #expect(model.store.health == .divergentGenerations)
    #expect(try countsInRecoveryList(model.store) == countsBefore, "the recovery list lost its counts")
    #expect(model.alertMessage?.contains("Recover Library") == true, "\(model.alertMessage ?? "nothing was said")")
}

/// The fallback behind the refusal above, for an index that changed on disk after it was read: if the
/// reload is still read-only, the ledger goes back where it was, so nothing has changed.
@MainActor
@Test("If keeping the version on disk would still leave the library read-only, the ledger is put back (F833)")
func aKeepThatCannotOpenTheLibraryPutsTheLedgerBack() throws {
    let root = try divergentLibrary()
    defer { try? FileManager.default.removeItem(at: root) }
    let ledger = root.appendingPathComponent("meetings.ledger.json")
    let ledgerBytes = try Data(contentsOf: ledger)
    let model = try makeModel(root)
    try #require(model.store.health == .divergentGenerations)
    // Read as the rival's one meeting; on disk, since then, the wipe shape.
    try finishedRecordingFolder(in: root)
    try Data("[]".utf8).write(to: root.appendingPathComponent("meetings.json"))

    model.keepLibraryVersionOnDisk()

    #expect(try Data(contentsOf: ledger) == ledgerBytes, "the ledger was not put back")
    #expect(names(in: root).filter { $0.hasPrefix("meetings.ledger.set-aside-") }.isEmpty)
    #expect(model.store.isDegraded)
    #expect(model.alertMessage?.contains("Recover Library") == true, "\(model.alertMessage ?? "nothing was said")")
}

@MainActor
@Test("Keep the Version on Disk does nothing to a library that has only one version (F833)")
func keepingTheVersionOnDiskLeavesAHealthyLibraryAlone() throws {
    let root = try savedLibrary("healthy", titles: ["only"])
    defer { try? FileManager.default.removeItem(at: root) }
    let ledger = root.appendingPathComponent("meetings.ledger.json")
    let ledgerBytes = try Data(contentsOf: ledger)
    let model = try makeModel(root)
    try #require(!model.store.isDegraded)

    model.keepLibraryVersionOnDisk()

    #expect(try Data(contentsOf: ledger) == ledgerBytes, "a healthy library's ledger was moved")
    #expect(names(in: root).filter { $0.hasPrefix("meetings.ledger.set-aside-") }.isEmpty)
}

// The button is the reachability, and the view cannot be rendered here (F174): asserted against
// ContentView's comment-stripped source, as F540 asserts the Recover Library button.
@Test("The Meeting library section offers Keep the Version on Disk, only for two versions, beside Recover Library (F833)")
func theKeepVersionButtonIsWiredIntoTheMeetingLibrarySection() throws {
    let source = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/ContentView.swift")
    let header = try #require(source.range(of: "Section(header: Label(\"Meeting library\""))
    let rest = source[header.upperBound...]
    let section = rest[..<(rest.range(of: "Section(header:")?.lowerBound ?? rest.endIndex)]
    // Titled by the constant the sentences use, so the label they name is the label on screen.
    let button = try #require(section.range(of: "Button(ReadOnlyLibraryNotice.keepVersionOnDiskButton)"),
                              "the Meeting library section has no Keep the Version on Disk button")
    #expect(section[button.upperBound...].prefix(120).contains("model.keepLibraryVersionOnDisk()"),
            "the button does not call the model")
    // Gated on the state it resolves, so it is never a way to drop the ledger of a healthy library.
    let gate = try #require(section.range(of: "if model.store.health == .divergentGenerations"))
    #expect(gate.upperBound <= button.lowerBound)
    // And the sentences that send the user there name the button, not a Terminal step.
    for sentence in [
        ReadOnlyLibraryNotice.startup(for: .divergentGenerations),
        ReadOnlyLibraryNotice.banner(for: .divergentGenerations),
        ReadOnlyLibraryNotice.librarySectionNotice(for: .divergentGenerations),
    ] {
        #expect(sentence.contains(ReadOnlyLibraryNotice.keepVersionOnDiskButton), "\(sentence)")
    }
}
