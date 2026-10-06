import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F540 — one sentence was said for every way the meeting library can open read-only: "WhisperMeet is
// open in read-only mode because it could not fully read your meeting library. … the unreadable index
// was copied aside." That is false for two of the states and silent about a third:
//
//   * the wipe shape (`.suspectEmpty`): the index read cleanly as `[]`, so nothing was unreadable and
//     nothing was copied aside, and no sentence mentioned the finished recordings that made the
//     empty index suspect;
//   * a stale-backup load (`.recoveredFromBackup`): the damaged index is left exactly as it was, and
//     the store's own paragraph beside it said "Nothing was written";
//   * two diverging versions (`.divergentGenerations`): docs/RECOVERY.md has a section for "the app
//     says two versions of the library were found", and no such message existed.
//
// These tests drive the app's own startup recovery over a real temp library in each state and judge
// what it says against two things that are not copies of the sentences: the health value the store
// actually holds, and what is actually on disk.

private enum Shape: String, CaseIterable, Sendable {
    /// The 2026-08-14 shape: a valid empty index beside finished recordings.
    case wiped
    /// The primary index is torn; the previous backup still reads.
    case staleBackup
    /// A valid index that matches no save WhisperMeet recorded, with the last recorded save still kept.
    case twoVersions
    /// Neither copy reads.
    case bothUnreadable
    /// Some records read and one does not.
    case partiallyReadable
}

private func temporaryLibrary(_ label: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("F540-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

/// A recording that finished: a WAV that holds the audio it declares, as F187's fixtures write it.
private func finishedRecordingFolder(in root: URL) throws {
    let folder = root.appendingPathComponent("Recordings/\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let dataByteCount: UInt32 = 48_000 * 2
    var wav = WAVWriter.header(sampleRate: 48_000, dataByteCount: dataByteCount)
    wav.append(Data(count: Int(dataByteCount)))
    try wav.write(to: folder.appendingPathComponent("meeting.wav"))
    try Data(#"{"systemAudio":{},"microphoneAudio":{}}"#.utf8).write(to: folder.appendingPathComponent("source-tracks.json"))
}

/// A library saved twice through a real store, so its ledger, backup and history are what the app writes.
@MainActor
private func savedLibrary(_ label: String, titles: [String]) throws -> URL {
    let root = try temporaryLibrary(label)
    let seed = MeetingStore(rootDirectory: root)
    for title in titles {
        let id = UUID()
        seed.upsert(MeetingRecord(id: id, title: title, recordingPath: "Recordings/\(id.uuidString)/meeting.wav",
                                  status: .recorded))
    }
    try #require(!seed.isDegraded, "the seed must have saved, or there is nothing to damage")
    return root
}

@MainActor
private func makeLibrary(_ shape: Shape) throws -> URL {
    switch shape {
    case .wiped:
        let root = try temporaryLibrary("wiped")
        try Data("[]".utf8).write(to: root.appendingPathComponent("meetings.json"))
        try Data("[]".utf8).write(to: root.appendingPathComponent("meetings.backup.json"))
        try finishedRecordingFolder(in: root)
        try finishedRecordingFolder(in: root)
        return root
    case .staleBackup:
        let root = try savedLibrary("stale", titles: ["first", "second"])
        try Data("truncated-primary".utf8).write(to: root.appendingPathComponent("meetings.json"))
        return root
    case .twoVersions:
        let root = try savedLibrary("two", titles: ["first", "second"])
        // A valid index from another library: decodable, and in no lineage this library recorded.
        let rival = try savedLibrary("rival", titles: ["the rival's meeting"])
        defer { try? FileManager.default.removeItem(at: rival) }
        try Data(contentsOf: rival.appendingPathComponent("meetings.json"))
            .write(to: root.appendingPathComponent("meetings.json"))
        return root
    case .bothUnreadable:
        let root = try temporaryLibrary("unreadable")
        try Data("broken-primary".utf8).write(to: root.appendingPathComponent("meetings.json"))
        try Data("broken-backup".utf8).write(to: root.appendingPathComponent("meetings.backup.json"))
        return root
    case .partiallyReadable:
        let root = try temporaryLibrary("partial")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        let good = try encoder.encode(MeetingRecord(id: UUID(), title: "readable", status: .recorded))
        var bytes = Data("[".utf8)
        bytes.append(good)
        bytes.append(Data(#",{"id":42}]"#.utf8))
        try bytes.write(to: root.appendingPathComponent("meetings.json"))
        try bytes.write(to: root.appendingPathComponent("meetings.backup.json"))
        return root
    }
}

/// What the app reports at launch for this shape, and the store's own verdict.
@MainActor
private func launch(_ shape: Shape) async throws -> (model: AppModel, root: URL, message: String) {
    let root = try makeLibrary(shape)
    let defaults = try #require(UserDefaults(suiteName: "F540.\(UUID().uuidString)"))
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(), defaults: defaults)
    // Nothing for the launch reclaims to find: they look in this library's own Runtime (F655).
    await model.performStartupRecovery()
    let message = try #require(model.alertMessage, "a read-only library said nothing at launch")
    return (model, root, message)
}

private func quarantineCopies(in root: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: root.path)) ?? []).filter { $0.contains(".unreadable-") }
}

/// Whether a message says a copy WAS made. "nothing was copied aside" says the opposite and is the
/// words the honest sentences use, so it is taken out before looking — a text dependence this test
/// states rather than hides.
private func claimsACopy(_ message: String) -> Bool {
    message.replacingOccurrences(of: "nothing was copied aside", with: "").contains("copied aside")
}

@MainActor
@Test("Each way the library can open read-only says something different at launch (F540)")
func everyReadOnlyShapeSaysItsOwnThing() async throws {
    var messages: [String: String] = [:]
    for shape in Shape.allCases {
        let (model, root, message) = try await launch(shape)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(model.store.isDegraded, "\(shape): the fixture did not produce a read-only library")
        messages[shape.rawValue] = message
    }
    #expect(Set(messages.values).count == Shape.allCases.count,
            "two shapes were told the same thing: \(messages)")
}

@MainActor
@Test("The launch message never claims a copy was set aside that was not (F540)")
func theLaunchMessageClaimsOnlyTheCopiesThatExist() async throws {
    for shape in Shape.allCases {
        let (_, root, message) = try await launch(shape)
        defer { try? FileManager.default.removeItem(at: root) }
        let copies = quarantineCopies(in: root)
        if claimsACopy(message) {
            #expect(!copies.isEmpty, "\(shape): says a copy was set aside, and none is on disk. \(message)")
        }
    }
}

@MainActor
@Test("An empty index beside finished recordings says so, with how many, and that nothing was copied (F540)")
func theWipeShapeNamesTheRecordings() async throws {
    let (model, root, message) = try await launch(.wiped)
    defer { try? FileManager.default.removeItem(at: root) }

    guard case let .suspectEmpty(count) = model.store.health else {
        Issue.record("expected the wipe shape, the store reads \(model.store.health)")
        return
    }
    try #require(count == 2)
    #expect(message.contains("\(count)"), "the message does not say how many recordings made the empty index suspect: \(message)")
    #expect(quarantineCopies(in: root).isEmpty, "the index read cleanly, so there is nothing to copy aside")
    #expect(!message.contains("unreadable index"), "an index that read cleanly is not unreadable: \(message)")
}

@MainActor
@Test("A load from the previous backup does not say both 'nothing was written' and 'copied aside' (F540)")
func theStaleBackupShapeDoesNotContradictItself() async throws {
    let (model, root, message) = try await launch(.staleBackup)
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(model.store.health == .recoveredFromBackup)
    #expect(quarantineCopies(in: root).isEmpty, "this load leaves the damaged index in place and copies nothing")
    #expect(!claimsACopy(message), "the damaged index was not copied aside: \(message)")
}

@MainActor
@Test("Two diverging versions of the library are announced as such, which is what RECOVERY.md promises (F540)")
func theDivergentShapeSaysTwoVersionsWereFound() async throws {
    let (model, root, message) = try await launch(.twoVersions)
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(model.store.health == .divergentGenerations)
    #expect(message.contains("Two versions of the meeting library were found"), "\(message)")
    // The recovery document keys a whole section on that sentence.
    let doc = try String(contentsOf: SourceAssertion.url("docs/RECOVERY.md"), encoding: .utf8)
    #expect(doc.contains("If the app says two versions of the library were found"))
}

// MARK: - The sentence is the production path's own

@MainActor
@Test("What launch says is the health-keyed sentence for the state the store is actually in (F540)")
func launchSaysTheSentenceForTheStoresHealth() async throws {
    for shape in Shape.allCases {
        let (model, root, message) = try await launch(shape)
        defer { try? FileManager.default.removeItem(at: root) }
        #expect(message.contains(ReadOnlyLibraryNotice.startup(for: model.store.health)),
                "\(shape): launch did not say what startup(for: \(model.store.health)) says: \(message)")
    }
}

/// One health value of every case, with the variants that read differently.
private let everyHealth: [PersistedStoreHealth] = [
    .recoveredFromBackup,
    .partiallySalvaged(parkedIdentifiers: ["a", "b"]),
    .unreadable(quarantined: ["meetings.unreadable-1.json", "meetings.backup.unreadable-1.json"]),
    .unreadable(quarantined: ["meetings.unreadable-1.json"]),
    .unreadable(quarantined: []),
    .suspectEmpty(recordingFolderCount: 1),
    .suspectEmpty(recordingFolderCount: 3),
    .divergentGenerations,
    .unavailable("The file could not be opened."),
]

@Test("Every standing surface says what was found, so none of them is the generic sentence (F540)")
func everySurfaceIsBuiltFromWhatWasFound() {
    for health in everyHealth {
        let found = ReadOnlyLibraryNotice.found(health)
        #expect(!found.isEmpty)
        #expect(ReadOnlyLibraryNotice.banner(for: health).contains(found), "\(health): the banner")
        #expect(ReadOnlyLibraryNotice.librarySectionNotice(for: health).contains(found), "\(health): the Settings section")
        #expect(ReadOnlyLibraryNotice.banner(for: health).contains(ReadOnlyLibraryNotice.recoverLibraryPath)
                || ReadOnlyLibraryNotice.banner(for: health).contains("Recovery in the documentation"),
                "\(health): the banner names no way out")
    }
    // Different states are told apart; the three that share a way out still say what they found.
    let founds = everyHealth.map(ReadOnlyLibraryNotice.found)
    #expect(Set(founds).count == everyHealth.count, "two states were told the same thing")
}

@Test("A state that copied nothing never says it copied something (F540)")
func theSurfacesDoNotInventCopies() {
    let copiedNothing: [PersistedStoreHealth] = [
        .recoveredFromBackup, .suspectEmpty(recordingFolderCount: 2), .unreadable(quarantined: []),
        .divergentGenerations, .unavailable("The file could not be opened."),
    ]
    for health in copiedNothing {
        for (surface, text) in [
            ("found", ReadOnlyLibraryNotice.found(health)),
            ("startup", ReadOnlyLibraryNotice.startup(for: health)),
            ("banner", ReadOnlyLibraryNotice.banner(for: health)),
            ("section", ReadOnlyLibraryNotice.librarySectionNotice(for: health)),
        ] {
            #expect(!claimsACopy(text), "\(health) \(surface): \(text)")
        }
    }
}

@Test("The wipe shape's sentences carry the recording count from the health value (F540)")
func theWipeShapeCountComesFromTheHealthValue() {
    for count in [1, 2, 17] {
        let health = PersistedStoreHealth.suspectEmpty(recordingFolderCount: count)
        #expect(ReadOnlyLibraryNotice.found(health).contains("\(count) finished recording"))
        #expect(ReadOnlyLibraryNotice.startup(for: health).contains("\(count) finished recording"))
        #expect(ReadOnlyLibraryNotice.banner(for: health).contains("\(count) finished recording"))
    }
}

// The banner told the user to open "Settings → Library", and the section is titled "Meeting library".
// The path is checked against ContentView's own section header and the button it names.
@Test("The way out the banner names is a Settings section and button that exist (F540)")
func theBannersPathNamesARealControl() throws {
    let parts = ReadOnlyLibraryNotice.recoverLibraryPath.components(separatedBy: " → ")
    try #require(parts.count == 3 && parts[0] == "Settings", "\(parts)")
    let source = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/ContentView.swift")
    let header = try #require(source.range(of: "Section(header: Label(\"\(parts[1])\""),
                              "Settings has no section titled \(parts[1])")
    let rest = source[header.upperBound...]
    let section = rest[..<(rest.range(of: "Section(header:")?.lowerBound ?? rest.endIndex)]
    #expect(section.contains("Button(\"\(parts[2])\")"), "the \(parts[1]) section has no \(parts[2]) button")
}

@Test("The banner and the Settings section are drawn from the store's health, not a constant (F540)")
func theStandingSurfacesAskForTheHealthKeyedSentence() throws {
    let source = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/ContentView.swift")
    #expect(source.contains("Text(ReadOnlyLibraryNotice.banner(for: model.store.health))"))
    #expect(source.contains("Text(ReadOnlyLibraryNotice.librarySectionNotice(for: model.store.health))"))
}

// MARK: - After a recovery that leaves it read-only

@MainActor
@Test("Restoring an empty copy beside finished recordings says what the library is now, not 'could not read' (F540)")
func restoringAnEmptyCopySaysTheWipeShape() async throws {
    // The rehearsal in docs/RECOVERY.md walks into this on purpose: the newest copy is the empty one,
    // and restoring it leaves the library read-only.
    let root = try savedLibrary("restore-empty", titles: ["first"])
    defer { try? FileManager.default.removeItem(at: root) }
    let seed = MeetingStore(rootDirectory: root)
    seed.delete(id: try #require(seed.meetings.first?.id))   // saves `[]` as the newest generation
    try finishedRecordingFolder(in: root)
    try Data("broken-primary".utf8).write(to: root.appendingPathComponent("meetings.json"))
    try Data("broken-backup".utf8).write(to: root.appendingPathComponent("meetings.backup.json"))

    let defaults = try #require(UserDefaults(suiteName: "F540restore.\(UUID().uuidString)"))
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(), defaults: defaults)
    try #require(model.store.isDegraded)
    model.requestLibraryRecovery()
    let offered = try #require(model.pendingLibraryRecovery, "\(model.alertMessage ?? "no message")")
    let newest = try #require(offered.max { $0.sequence < $1.sequence })

    model.recoverLibrary(from: newest, confirmed: true)

    guard case let .suspectEmpty(count) = model.store.health else {
        Issue.record("restoring the empty copy should leave the wipe shape, the store reads \(model.store.health)")
        return
    }
    #expect(model.alertMessage == ReadOnlyLibraryNotice.stillReadOnly(
        afterWriting: "The meeting index was restored", model.store.health))
    #expect(model.alertMessage?.contains("\(count) finished recording") == true, "\(model.alertMessage ?? "nil")")
    #expect(model.alertMessage?.contains("could not fully read") == false)
    // The resumed startup sweep would run in a Task of its own after this test; there is none to
    // resume, because the library is still read-only.
}
