import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F464 — a damaged vocabulary.json or replacement-rules.json made the whole library read-only.
//
// `MeetingStore.health` was the worst of three loads and gated every mutator plus
// `recordingDirectory(for:)`, so a list of terms could refuse a recording. The ways in are ordinary:
// a torn write, a missing comma in a hand edit, or even a perfectly VALID hand edit, which the
// library's lineage check reads as a second writer (`.divergentGenerations`). And the only way out
// the app offered was Recover Library, which lists meeting-index generations: restoring one left
// the library exactly as read-only as before, because the damaged file was not the one restored.

/// The two lists that load beside the meeting index.
enum DamagedFile: String, CaseIterable, Sendable {
    case vocabulary, replacementRules

    var stem: String { self == .vocabulary ? "vocabulary" : "replacement-rules" }
}

/// The three ways a list file actually gets damaged.
enum ListDamage: String, CaseIterable, Sendable {
    /// The primary is cut short; its backup still reads (`.recoveredFromBackup`).
    case tornWrite
    /// A valid edit made outside the app, which drops one term the app had saved
    /// (`.divergentGenerations`).
    case handEdit
    /// Neither copy reads (`.unreadable`).
    case bothUnreadable
}

/// The term the app saved last and a hand edit drops, so a test can look for where it went.
let lastSavedTerm = "beta-term"

/// A library whose `file` has been damaged in the `damage` way, after two ordinary saves through a
/// real store — so its ledger, backup and history are exactly what the app writes.
@MainActor
func makeDamagedLibrary(_ file: DamagedFile, _ damage: ListDamage) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("DamagedList-\(file.rawValue)-\(damage.rawValue)-\(UUID().uuidString)",
                                isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let seed = MeetingStore(rootDirectory: root)
    switch file {
    case .vocabulary:
        seed.addVocabulary(["alpha-term"])
        seed.addVocabulary([lastSavedTerm])
    case .replacementRules:
        seed.addReplacementRule(heard: "alpha heard", preferred: "alpha-term")
        seed.addReplacementRule(heard: "beta heard", preferred: lastSavedTerm)
    }
    try #require(!seed.isDegraded, "the seed must have saved, or there is nothing to damage")

    let primary = root.appendingPathComponent("\(file.stem).json")
    let backup = root.appendingPathComponent("\(file.stem).backup.json")
    switch damage {
    case .tornWrite:
        try Data("[\"alpha-te".utf8).write(to: primary)
    case .handEdit:
        let edited = file == .vocabulary
            ? #"["alpha-term","gamma-by-hand"]"#
            : #"[{"heard":"alpha heard","preferred":"alpha-term"},{"heard":"gamma heard","preferred":"gamma-by-hand"}]"#
        try Data(edited.utf8).write(to: primary)
    case .bothUnreadable:
        try Data("broken-primary".utf8).write(to: primary)
        try Data("broken-backup".utf8).write(to: backup)
    }
    return root
}

@MainActor
@Test(
    "A damaged vocabulary or rules file leaves recording and the meeting library writable (F464)",
    arguments: DamagedFile.allCases, ListDamage.allCases
)
func damagedListLeavesTheLibraryWritable(file: DamagedFile, damage: ListDamage) throws {
    let root = try makeDamagedLibrary(file, damage)
    defer { try? FileManager.default.removeItem(at: root) }
    let primary = root.appendingPathComponent("\(file.stem).json")
    let damagedBytes = try Data(contentsOf: primary)
    let store = MeetingStore(rootDirectory: root)
    let defaults = try #require(UserDefaults(suiteName: "F464-\(UUID().uuidString)"))
    let model = AppModel(store: store, recorder: AudioCaptureEngine(), defaults: defaults)

    #expect(!store.isDegraded, "only the \(file.rawValue) list is damaged")
    #expect(model.libraryReadOnlyFootnote == nil)
    // What `startRecording` reaches for the new meeting's folder, and the store's own backstop.
    let id = UUID()
    #expect(throws: Never.self) { _ = try store.recordingDirectory(for: id) }
    store.upsert(MeetingRecord(
        id: id, title: "Recorded anyway",
        recordingPath: "Recordings/\(id.uuidString)/meeting.wav", status: .recorded
    ))
    #expect(MeetingStore(rootDirectory: root).meeting(id: id)?.title == "Recorded anyway")
    // And the damaged list was not written by any of that.
    #expect(try Data(contentsOf: primary) == damagedBytes)
}

// MARK: - The damaged list itself: read-only on its own, said plainly, and one control out

extension DamagedFile {
    var list: MeetingStore.EditableList { self == .vocabulary ? .vocabulary : .replacementRules }
    var other: MeetingStore.EditableList { self == .vocabulary ? .replacementRules : .vocabulary }
}

/// The list's contents as plain strings, whichever list it is.
@MainActor
private func contents(of file: DamagedFile, in store: MeetingStore) -> [String] {
    switch file {
    case .vocabulary: return store.vocabulary
    case .replacementRules: return store.replacementRules.map(\.preferred)
    }
}

@MainActor
private func add(_ term: String, to file: DamagedFile, in store: MeetingStore) {
    switch file {
    case .vocabulary: store.addVocabulary([term])
    case .replacementRules: store.addReplacementRule(heard: "\(term) heard", preferred: term)
    }
}

@MainActor
@Test(
    "A damaged list is read-only by itself, keeps its bytes, and says so beside the list and at launch (F464)",
    arguments: DamagedFile.allCases, ListDamage.allCases
)
func damagedListIsReadOnlyByItself(file: DamagedFile, damage: ListDamage) throws {
    let root = try makeDamagedLibrary(file, damage)
    defer { try? FileManager.default.removeItem(at: root) }
    let primary = root.appendingPathComponent("\(file.stem).json")
    let backup = root.appendingPathComponent("\(file.stem).backup.json")
    let primaryBefore = try Data(contentsOf: primary)
    let backupBefore = try Data(contentsOf: backup)

    let store = MeetingStore(rootDirectory: root)

    let health = store.health(of: file.list)
    switch damage {
    case .tornWrite: #expect(health == .recoveredFromBackup)
    case .handEdit:
        #expect(health == .divergentGenerations)
        #expect(contents(of: file, in: store).contains("gamma-by-hand"), "the hand edit is what is shown")
    case .bothUnreadable:
        guard case .unreadable = health else {
            Issue.record("expected .unreadable, got \(health)")
            return
        }
        #expect(contents(of: file, in: store).isEmpty)
    }
    #expect(store.isListReadOnly(file.list))
    #expect(!store.isListReadOnly(file.other), "the other list is not touched by this one's damage")

    let shown = contents(of: file, in: store)
    add("refused-term", to: file, in: store)
    #expect(contents(of: file, in: store) == shown)
    #expect(store.storageErrorMessage == DamagedListNotice.refused(file.list, health: health))
    #expect(try Data(contentsOf: primary) == primaryBefore)
    #expect(try Data(contentsOf: backup) == backupBefore)

    // One sentence, in both places the user can meet it.
    let notice = try #require(store.damagedListNotice(for: file.list))
    #expect(store.startupRecoveryMessages.contains(notice))
}

/// Every damaged byte the list's files held, wherever the store put it: quarantine copies beside
/// the file — `<stem>.unreadable-…` for the primary, `<stem>.backup.unreadable-…` for its backup —
/// and the list's retained history.
private func preservedBytes(of file: DamagedFile, in root: URL) throws -> [Data] {
    let names = try FileManager.default.contentsOfDirectory(atPath: root.path)
    let aside = try names.filter { $0.hasPrefix("\(file.stem).") && $0.contains(".unreadable-") }
        .map { try Data(contentsOf: root.appendingPathComponent($0)) }
    let history = root.appendingPathComponent("\(file.stem).history")
    let retained = try ((try? FileManager.default.contentsOfDirectory(atPath: history.path)) ?? [])
        .map { try Data(contentsOf: history.appendingPathComponent($0)) }
    return aside + retained
}

@MainActor
@Test(
    "Keeping the list shown makes it writable again and loses nothing the damage left (F464)",
    arguments: DamagedFile.allCases, ListDamage.allCases
)
func keepingTheShownListMakesItWritable(file: DamagedFile, damage: ListDamage) throws {
    let root = try makeDamagedLibrary(file, damage)
    defer { try? FileManager.default.removeItem(at: root) }
    let damagedPrimary = try Data(contentsOf: root.appendingPathComponent("\(file.stem).json"))
    let damagedBackup = try Data(contentsOf: root.appendingPathComponent("\(file.stem).backup.json"))
    let store = MeetingStore(rootDirectory: root)
    let shown = contents(of: file, in: store)

    store.keepLoadedList(file.list)

    #expect(!store.isListReadOnly(file.list))
    #expect(store.damagedListNotice(for: file.list) == nil)
    #expect(contents(of: file, in: store) == shown, "keeping changes nothing on screen")

    // Nothing the damage left is lost.
    let preserved = try preservedBytes(of: file, in: root)
    switch damage {
    case .tornWrite:
        #expect(preserved.contains(damagedPrimary), "the cut-short file was replaced without a copy")
    case .bothUnreadable:
        #expect(preserved.contains(damagedPrimary))
        #expect(preserved.contains(damagedBackup))
    case .handEdit:
        // The hand edit is what was kept; its rival is the list this app saved last.
        #expect(preserved.contains { String(decoding: $0, as: UTF8.self).contains(lastSavedTerm) },
                "the list the app last saved is gone")
    }

    // And writable for real, on disk.
    add("after-keep", to: file, in: store)
    let reopened = MeetingStore(rootDirectory: root)
    #expect(reopened.health(of: file.list) == .complete)
    #expect(Set(contents(of: file, in: reopened)) == Set(shown + ["after-keep"]))
}

@MainActor
@Test("While the meeting library is read-only, a damaged list defers to it (F464)")
func damagedListDefersToAReadOnlyLibrary() throws {
    let root = try makeDamagedLibrary(.vocabulary, .tornWrite)
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("broken-primary".utf8).write(to: root.appendingPathComponent("meetings.json"))
    try Data("broken-backup".utf8).write(to: root.appendingPathComponent("meetings.backup.json"))

    let store = MeetingStore(rootDirectory: root)
    try #require(store.isDegraded)

    // No second notice promising that recording works while it does not.
    #expect(store.damagedListNotice(for: .vocabulary) == nil)
    store.keepLoadedList(.vocabulary)
    #expect(store.isListReadOnly(.vocabulary), "nothing is changed until the library is recovered")
    #expect(store.storageErrorMessage == ReadOnlyLibraryNotice.mutationRefused)
    // The launch alert still names the list, without the tail.
    let quiet = try #require(DamagedListNotice.notice(
        for: .vocabulary, health: store.health(of: .vocabulary), libraryIsWritable: false
    ))
    #expect(store.startupRecoveryMessages.contains(quiet))
}

/// F306's method: the view cannot be rendered here, and the tests above drive the store directly,
/// which is the right way to test it and structurally cannot notice that nothing calls it.
@Test("Each list's notice sits beside the control that clears it (F464)")
func damagedListNoticesAreWiredBesideTheirControl() throws {
    let lines = try SourceAssertion.uncommentedLines("Sources/WhisperMeet/ContentView.swift")
    for list in [".vocabulary", ".replacementRules"] {
        let notice = try #require(
            lines.firstIndex { $0.text.contains("store.damagedListNotice(for: \(list))") },
            "the \(list) notice is not shown anywhere"
        )
        let control = try #require(
            lines.firstIndex { $0.text.contains("store.keepLoadedList(\(list))") },
            "nothing offers the way out for \(list)"
        )
        #expect(control > notice && control - notice <= 5,
                "the \(list) control is not beside its notice (lines \(notice + 1) and \(control + 1))")
    }
}
