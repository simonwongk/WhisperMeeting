import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F289 — `FolderRebuild.propose` (F191 slice E4, carrying F252) was tested and called by nothing.
// This is its door: the "Recover Library…" action, when a damaged library has no retained
// generation to restore, offers the folder rebuild instead of the dead-end message — and a second
// mutator that works while read-only applies the reviewed proposal through the ordinary
// append-only write, as `restoreIndexGeneration` does.
//
// Every test drives `AppModel`, never the core, because "nothing calls it" is the defect.

/// A library whose index is unreadable in both copies, with NO retained generation — F252's dead
/// end — and `count` finished recording folders with their audio and a notes.md title.
@MainActor
private func makeDeadEndLibrary(folders count: Int, label: String) throws -> (AppModel, URL, [UUID]) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("FolderRebuildEntry-\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("broken-primary".utf8).write(to: root.appendingPathComponent("meetings.json"))
    try Data("broken-backup".utf8).write(to: root.appendingPathComponent("meetings.backup.json"))
    var ids: [UUID] = []
    for index in 0..<count {
        let id = UUID()
        ids.append(id)
        let folder = root.appendingPathComponent("Recordings/\(id.uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try WAVWriter.wavData(from: [Float](repeating: 0.1, count: 48_000), sampleRate: 48_000)
            .write(to: folder.appendingPathComponent("meeting.wav"))
        try Data("# Standup \(index)\n\nbody\n".utf8).write(to: folder.appendingPathComponent("notes.md"))
    }
    let model = AppModel(
        store: MeetingStore(rootDirectory: root),
        recorder: AudioCaptureEngine(),
        defaults: UserDefaults(suiteName: "F289.\(label).\(UUID().uuidString)")!
    )
    try #require(model.store.isDegraded, "the fixture must be the read-only dead end")
    try #require(try model.store.indexGenerations().isEmpty, "the fixture must have nothing to restore")
    return (model, root, ids)
}

@MainActor
@Test("With nothing to restore, Recover Library offers the folder rebuild instead of a dead end (F289)")
func recoverLibraryOffersTheFolderRebuild() throws {
    let (model, root, ids) = try makeDeadEndLibrary(folders: 2, label: "offer")
    defer { try? FileManager.default.removeItem(at: root) }

    model.requestLibraryRecovery()

    let proposal = try #require(model.pendingFolderRebuild, "the proposal should be up for review")
    #expect(Set(proposal.meetings.map(\.id)) == Set(ids))
    #expect(proposal.meetings.map(\.title).sorted() == ["Standup 0", "Standup 1"])
    // The proposal is shown BEFORE anything is written: still read-only, still nothing indexed.
    #expect(model.store.isDegraded)
    #expect(model.store.meetings.isEmpty)
    #expect(model.pendingLibraryRecovery == nil)
    #expect(model.alertMessage == nil, "the old dead-end alert must not appear beside the offer: \(model.alertMessage ?? "")")
}

@MainActor
@Test("An unconfirmed rebuild writes nothing and leaves the offer standing (F289)")
func unconfirmedFolderRebuildIsANoOp() throws {
    let (model, root, _) = try makeDeadEndLibrary(folders: 1, label: "unconfirmed")
    defer { try? FileManager.default.removeItem(at: root) }
    model.requestLibraryRecovery()
    let before = try Data(contentsOf: root.appendingPathComponent("meetings.json"))

    model.rebuildLibraryFromFolders(confirmed: false)

    #expect(model.pendingFolderRebuild != nil)
    #expect(model.store.isDegraded)
    #expect(try Data(contentsOf: root.appendingPathComponent("meetings.json")) == before)
}

@MainActor
@Test("A confirmed rebuild installs the proposal, reloads, and the library is writable again (F289)")
func confirmedRebuildInstallsTheProposal() throws {
    let (model, root, ids) = try makeDeadEndLibrary(folders: 2, label: "confirmed")
    defer { try? FileManager.default.removeItem(at: root) }
    model.requestLibraryRecovery()
    let proposal = try #require(model.pendingFolderRebuild)

    model.rebuildLibraryFromFolders(confirmed: true)

    #expect(model.pendingFolderRebuild == nil)
    #expect(!model.store.isDegraded, "a successful rebuild must return the library to a writable state (F193's rule)")
    #expect(Set(model.store.meetings.map(\.id)) == Set(ids))
    #expect(model.store.meetings.map(\.title).sorted() == proposal.meetings.map(\.title).sorted())
    for meeting in model.store.meetings {
        #expect(meeting.status == .recorded)
        #expect(meeting.recoverySource == RecoveredRecording.Source.existingCapture.rawValue)
    }
    // Audio is never touched, and the damaged index is still on disk beside the new one: the
    // rebuild went through the append-only write, so it is itself undoable.
    for id in ids {
        #expect(FileManager.default.fileExists(
            atPath: root.appendingPathComponent("Recordings/\(id.uuidString)/meeting.wav").path
        ))
    }
    #expect(try !model.store.indexGenerations().isEmpty, "the write must be a retained generation like any other")
    // And the reloaded index is what is on disk, not what was in memory: a reopened store agrees.
    let reopened = MeetingStore(rootDirectory: root)
    #expect(!reopened.isDegraded)
    #expect(Set(reopened.meetings.map(\.id)) == Set(ids))
}

@MainActor
@Test("A rebuild the model never offered is refused (F289)")
func unofferedFolderRebuildIsRefused() throws {
    // F193's structural guarantee, carried over: only a proposal this model produced and showed
    // can be applied. A caller cannot rebuild what the user never reviewed.
    let (model, root, _) = try makeDeadEndLibrary(folders: 1, label: "unoffered")
    defer { try? FileManager.default.removeItem(at: root) }

    model.rebuildLibraryFromFolders(confirmed: true)

    #expect(model.store.isDegraded)
    #expect(model.store.meetings.isEmpty)
}

@MainActor
@Test("A library with no recording folders still gets the honest dead-end message (F289)")
func nothingToRebuildSaysSo() throws {
    // A proposal of nothing must not present as a recovery the user should accept.
    let (model, root, _) = try makeDeadEndLibrary(folders: 0, label: "empty")
    defer { try? FileManager.default.removeItem(at: root) }

    model.requestLibraryRecovery()

    #expect(model.pendingFolderRebuild == nil)
    #expect(model.alertMessage?.contains("No earlier copy of the index was retained") == true)
}

@MainActor
@Test("A rebuild over a still-broken vocabulary leaves only the vocabulary read-only, and says so (F289, F464)")
func rebuildOverAStillBrokenLibraryDoesNotClaimSuccess() throws {
    // F187's honesty rule, as `recoverLibrary` keeps it: the meeting index can come back while
    // vocabulary.json is still corrupt, and the corrupt file must not be reported as repaired.
    // Since F464 that leaves the vocabulary read-only by itself rather than the whole library,
    // which is what this test asserted before — a rebuilt library that still refused recording.
    let (model, root, ids) = try makeDeadEndLibrary(folders: 1, label: "stillbroken")
    defer { try? FileManager.default.removeItem(at: root) }
    try Data("broken".utf8).write(to: root.appendingPathComponent("vocabulary.json"))
    try Data("broken".utf8).write(to: root.appendingPathComponent("vocabulary.backup.json"))
    model.requestLibraryRecovery()
    try #require(model.pendingFolderRebuild != nil)

    model.rebuildLibraryFromFolders(confirmed: true)

    #expect(!model.store.isDegraded)
    #expect(Set(model.store.meetings.map(\.id)) == Set(ids), "the index itself did come back")
    #expect(model.store.isListReadOnly(.vocabulary))
    // The rebuild's re-run of startup recovery reports these messages; the vocabulary's is there.
    let notice = try #require(model.store.damagedListNotice(for: .vocabulary))
    #expect(model.store.startupRecoveryMessages.contains(notice))
}

@MainActor
@Test("The view offers the rebuild, so the mechanism is reachable (F289)")
func viewWiresTheFolderRebuild() throws {
    // F306's method: asserted against `ContentView`'s source with comments stripped, because the
    // `WhisperMeet` target has no view harness and the tests above drive the model directly —
    // which is the right way to test it and structurally cannot notice that nothing calls it.
    // This ticket exists because F191 claimed a route that did not exist.
    let source = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/ContentView.swift")
    #expect(source.contains("model.pendingFolderRebuild"))
    #expect(source.contains("model.rebuildLibraryFromFolders(confirmed: true)"))
    #expect(source.contains("model.cancelFolderRebuild()"))
}
