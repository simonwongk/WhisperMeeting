import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F611 — a backup is refused while a word list is read-only, and Suggest Vocabulary is not offered
// for a list that would refuse what it suggests.
//
// `backUpLibrary` refuses a read-only library (F187): a backup of a damaged index is copied over the
// last good off-library copies as retention prunes them. F464 narrowed "read-only" to the meeting
// index, so with `vocabulary.json` damaged the library is writable and a backup ran — capturing the
// damaged file every time and pruning, one run at a time, the generations that held a readable list.

private final class RunCounter: @unchecked Sendable {
    private let lock = NSLock()
    private var count = 0
    var runs: Int { lock.withLock { count } }
    func add() { lock.withLock { count += 1 } }
}

@MainActor
private func makeModel(damaging file: String, withBackup: Bool) throws -> (model: AppModel, root: URL, destination: URL, counter: RunCounter) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("F611-\(UUID().uuidString)", isDirectory: true)
    let library = root.appendingPathComponent("Library", isDirectory: true)
    let destination = root.appendingPathComponent("Dest", isDirectory: true)
    try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let seed = MeetingStore(rootDirectory: library)
    seed.upsert(MeetingRecord(id: UUID(), title: "A meeting", status: .recorded))
    seed.addVocabulary(["Kubernetes"])
    _ = seed.addReplacementRule(heard: "cube ernetes", preferred: "Kubernetes")
    seed.addVocabulary(["Terraform"])
    _ = seed.addReplacementRule(heard: "terra form", preferred: "Terraform")
    try Data("{ not a list".utf8).write(to: library.appendingPathComponent(file))
    if !withBackup {
        let stem = (file as NSString).deletingPathExtension
        try Data("{ nor this".utf8).write(to: library.appendingPathComponent("\(stem).backup.json"))
    }
    let defaults = try #require(UserDefaults(suiteName: testSuiteName()))
    let model = AppModel(store: MeetingStore(rootDirectory: library), recorder: AudioCaptureEngine(), defaults: defaults)
    let counter = RunCounter()
    model.runLibraryBackup = { source, destination, now, retain in
        counter.add()
        return try BackupCoordinator.backUp(source: source, destination: destination, now: now, retain: retain)
    }
    return (model, root, destination, counter)
}

@MainActor
@Test(
    "Back Up Library is refused while a word list is read-only, and nothing is written to the destination (F611)",
    arguments: [("vocabulary.json", true), ("vocabulary.json", false), ("replacement-rules.json", true)]
)
func aBackupIsRefusedWhileAListIsReadOnly(file: String, withBackup: Bool) async throws {
    let (model, root, destination, counter) = try makeModel(damaging: file, withBackup: withBackup)
    defer { try? FileManager.default.removeItem(at: root) }
    try #require(!model.store.isDegraded, "fixture: the meeting library must stay writable (F464)")
    let list: MeetingStore.EditableList = file == "vocabulary.json" ? .vocabulary : .replacementRules
    try #require(model.store.isListReadOnly(list), "fixture: \(file) did not open read-only")

    await model.backUpLibrary(to: destination, now: 5_000)

    #expect(counter.runs == 0, "a backup ran over a damaged \(file)")
    #expect(((try? FileManager.default.contentsOfDirectory(atPath: destination.path)) ?? []).isEmpty)
    let message = try #require(model.alertMessage, "the refusal said nothing")
    #expect(message.contains(file), "the refusal does not name the file: \(message)")
    #expect(message.contains(DamagedListNotice.actionTitle(for: list, health: model.store.health(of: list))),
            "the refusal does not name the way out: \(message)")
}

@MainActor
@Test("A refusal for a list with no readable copy says an earlier backup may hold the only readable one, and names Restore… (F611)")
func theRefusalForAListWithNoReadableCopyPointsAtOlderBackups() async throws {
    let (model, root, destination, _) = try makeModel(damaging: "vocabulary.json", withBackup: false)
    defer { try? FileManager.default.removeItem(at: root) }
    try #require(DamagedListNotice.actionTitle(for: .vocabulary, health: model.store.health(of: .vocabulary)) == "Start a New List",
                 "fixture: the list has no readable copy")

    await model.backUpLibrary(to: destination, now: 5_000)

    let message = try #require(model.alertMessage)
    #expect(message.contains("earlier backup"), "\(message)")
    #expect(message.contains("Restore… in Settings"), "\(message)")
}

@MainActor
@Test("A refusal for a list that still shows a readable copy does not send the user to Restore… (F611)")
func theRefusalForAReadableListKeepsItsOneWayOut() async throws {
    let (model, root, destination, _) = try makeModel(damaging: "vocabulary.json", withBackup: true)
    defer { try? FileManager.default.removeItem(at: root) }

    await model.backUpLibrary(to: destination, now: 5_000)

    let message = try #require(model.alertMessage)
    #expect(message.contains("Keep This List"), "\(message)")
    #expect(!message.contains("Restore…"), "\(message)")
}

@MainActor
@Test("Back Up Library still runs when both lists loaded cleanly (F611)")
func aBackupRunsWithHealthyLists() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("F611-ok-\(UUID().uuidString)", isDirectory: true)
    let library = root.appendingPathComponent("Library", isDirectory: true)
    let destination = root.appendingPathComponent("Dest", isDirectory: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MeetingStore(rootDirectory: library)
    store.addVocabulary(["Kubernetes"])
    let defaults = try #require(UserDefaults(suiteName: testSuiteName()))
    let model = AppModel(store: store, recorder: AudioCaptureEngine(), defaults: defaults)
    let counter = RunCounter()
    model.runLibraryBackup = { source, destination, now, retain in
        counter.add()
        return try BackupCoordinator.backUp(source: source, destination: destination, now: now, retain: retain)
    }

    await model.backUpLibrary(to: destination, now: 5_000)

    #expect(counter.runs == 1, "\(model.alertMessage ?? "")")
}

@Test("Suggest Vocabulary Terms is not offered for a vocabulary list that would refuse what it suggests (F611)")
func suggestVocabularyReadsTheListsReadOnlyState() throws {
    // The Improve menu cannot be rendered in this target (F174), so its source is asserted, comments
    // stripped (F285): the Suggest button is disabled while the vocabulary is read-only or the library
    // is, and the menu's footnote says why.
    let view = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/ContentView.swift")
    let start = try #require(view.range(of: "Label(\"Suggest Vocabulary Terms…\""))
    let after = String(view[start.upperBound...].prefix(400))
    let disabledAt = try #require(after.range(of: ".disabled("))
    let disabled = String(after[disabledAt.lowerBound...].prefix(200))
    #expect(disabled.contains("isSuggestingVocab"), "\(disabled)")
    #expect(disabled.contains("suggestVocabularyBlockedReason != nil"), "the Suggest button ignores the list's read-only state: \(disabled)")
    #expect(view.contains("if let suggestVocabularyBlockedReason"), "the Improve menu does not say why Suggest is unavailable")
}
