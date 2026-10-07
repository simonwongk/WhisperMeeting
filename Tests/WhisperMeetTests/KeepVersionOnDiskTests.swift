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
    let defaults = try #require(UserDefaults(suiteName: "F833.\(UUID().uuidString)"))
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
