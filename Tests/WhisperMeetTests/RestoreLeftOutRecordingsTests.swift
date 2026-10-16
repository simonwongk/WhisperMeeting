import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F699 — what a restore says about the recordings made since the backup, and what then happens to
// them.
//
// A restore only copies, so a recording folder the backup lacks stays on disk. The confirmation and
// the alert said "the restored index will not list them", and counted FILES. Both were wrong: the
// launch's orphan sweep (`MeetingStore.orphanedRecordings`) lists every UUID-named folder the index
// does not reference, so those recordings came back as recovered meetings at the next launch — or
// straight away, when the library was read-only and the restore re-ran startup recovery.
//
// The user chose (A) on 2026-10-16: keep the re-listing, and make the copy say it — counting
// recordings rather than files, and saying they come back as recovered recordings, without their
// titles, notes or transcripts. These tests pin the count against recordings and check the copy
// against the behaviour on both paths.

/// A library backed up with one meeting, then given one new recording of three files, and one extra
/// file inside the backed-up meeting's folder.
@MainActor
private func makeLibrary(
    _ label: String,
    damaged: Bool = false
) throws -> (root: URL, model: AppModel, generation: URL, kept: UUID, newer: UUID) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("RestoreLeftOut-\(label)-\(UUID().uuidString)", isDirectory: true)
    let library = root.appendingPathComponent("Library", isDirectory: true)
    let destination = root.appendingPathComponent("Dest", isDirectory: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    let kept = UUID()
    let keptFolder = library.appendingPathComponent("Recordings/\(kept.uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: keptFolder, withIntermediateDirectories: true)
    try WAVWriter.wavData(from: [Float](repeating: 0.1, count: 16_000), sampleRate: 16_000)
        .write(to: keptFolder.appendingPathComponent("meeting.wav"))
    do {
        let writer = MeetingStore(rootDirectory: library, transcriptWriteDebounce: 3_600)
        writer.upsert(MeetingRecord(
            id: kept, title: "At the backup", recordingPath: "Recordings/\(kept.uuidString)/meeting.wav",
            status: .completed, transcriptText: "What was said.", languageCode: "en"
        ))
    }
    let summary = try BackupCoordinator.backUp(source: library, destination: destination, now: 1, retain: 3)
    let generation = destination
        .appendingPathComponent(BackupCoordinator.managedSubfolder, isDirectory: true)
        .appendingPathComponent(summary.generation, isDirectory: true)

    // Since the backup: one finished recording — three files, one recording — that the backup lacks.
    let newer = UUID()
    let newerFolder = library.appendingPathComponent("Recordings/\(newer.uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: newerFolder, withIntermediateDirectories: true)
    try WAVWriter.wavData(from: [Float](repeating: 0.2, count: 32_000), sampleRate: 16_000)
        .write(to: newerFolder.appendingPathComponent("meeting.wav"))
    try Data(count: 64).write(to: newerFolder.appendingPathComponent("system-audio.f32"))
    try Data(count: 64).write(to: newerFolder.appendingPathComponent("microphone-audio.f32"))
    // And one file the backup lacks inside a folder it has: not a recording that comes back.
    try Data("later".utf8).write(to: keptFolder.appendingPathComponent("added-later.txt"))

    if damaged {
        try Data("not an index".utf8).write(to: library.appendingPathComponent("meetings.json"))
        try? FileManager.default.removeItem(at: library.appendingPathComponent("meetings.backup.json"))
    }
    let model = AppModel(
        store: MeetingStore(rootDirectory: library),
        recorder: AudioCaptureEngine(),
        defaults: UserDefaults(suiteName: testSuiteName())!
    )
    stubInstallRecovery(model)
    return (root, model, generation, kept, newer)
}

/// Startup recovery runs in these tests; nothing in it may spawn an installer.
@MainActor
private func stubInstallRecovery(_ model: AppModel) {
    model.runWhisperInstallRecovery = { _ in 0 }
    model.runQwenInstallRecovery = { _ in 0 }
    model.runSummarizerInstallRecovery = { _ in 0 }
    model.runDiarizationInstallRecovery = { _ in 0 }
}

@Test("A restore's plan counts the recordings the backup lacks, not their files (F699)")
@MainActor
func restorePlanCountsRecordingsNotFiles() async throws {
    let (root, model, generation, kept, newer) = try makeLibrary("count")
    defer { try? FileManager.default.removeItem(at: root) }

    await model.requestLibraryRestore(from: generation)
    let pending = try #require(model.pendingLibraryRestore)
    try #require(pending.plan.notInBackup.count == 4, "precondition: \(pending.plan.notInBackup)")

    let expectedRecordings: [String] = [newer.uuidString]
    let expectedOthers: [String] = ["Recordings/\(kept.uuidString)/added-later.txt"]
    #expect(pending.plan.recordingsNotInBackup == expectedRecordings)
    #expect(pending.plan.otherFilesNotInBackup == expectedOthers)

    let message = AppModel.restoreConfirmationMessage(pending)
    #expect(message.hasPrefix("1 recording in your library is not in this backup."), "\(message)")
    #expect(message.contains("come back as a recovered recording, without its title, notes or transcript, the next time WhisperMeet opens"), "\(message)")
    #expect(message.contains("1 other file(s) in your library are not in this backup. They will be left on disk."), "\(message)")
    #expect(!message.contains("will not list them"), "the promise the launch broke is gone")
    #expect(!message.contains("4 file(s) in your library"), "files are not recordings")
}

@Test("After a restore, the recording the backup lacked comes back at the next launch, as the alert says (F699)")
@MainActor
func leftOutRecordingComesBackAtNextLaunch() async throws {
    let (root, model, generation, kept, newer) = try makeLibrary("relaunch")
    defer { try? FileManager.default.removeItem(at: root) }
    try #require(!model.store.isDegraded)

    await model.requestLibraryRestore(from: generation)
    try #require(model.pendingLibraryRestore != nil, "refused: \(model.alertMessage ?? "no message")")
    await model.performLibraryRestore(confirmed: true)?.value

    let alert = model.alertMessage ?? ""
    #expect(alert.contains("1 recording made since that backup is not in it."), "\(alert)")
    #expect(alert.contains("come back as a recovered recording, without its title, notes or transcript, the next time WhisperMeet opens"), "\(alert)")
    #expect(!alert.contains("not listed in the restored index"), "\(alert)")
    // True of this session: the restored index does not list it yet.
    #expect(model.store.meetings.map(\.id) == [kept])

    // The next launch.
    let relaunched = AppModel(
        store: MeetingStore(rootDirectory: model.store.rootDirectory),
        recorder: AudioCaptureEngine(),
        defaults: UserDefaults(suiteName: testSuiteName())!
    )
    stubInstallRecovery(relaunched)
    await relaunched.performStartupRecovery()
    let ids = Set(relaunched.store.meetings.map(\.id))
    #expect(ids == [kept, newer], "the copy promised the recording back: \(ids)")
    let back = try #require(relaunched.store.meetings.first { $0.id == newer })
    #expect(back.transcriptText.isEmpty, "a recovered recording, without the transcript it had")
    // Nothing the restore left on disk was removed.
    let folder = relaunched.store.rootDirectory.appendingPathComponent("Recordings/\(newer.uuidString)")
    for name in ["meeting.wav", "system-audio.f32", "microphone-audio.f32"] {
        #expect(FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path), "\(name)")
    }
}

@Test("A restore that repairs a read-only library says the left-out recording is being added back now, and it is (F699)")
@MainActor
func readOnlyRestoreAddsTheLeftOutRecordingBackNow() async throws {
    let (root, model, generation, kept, newer) = try makeLibrary("readonly", damaged: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try #require(model.store.isDegraded, "precondition: the damaged library opens read-only")

    await model.requestLibraryRestore(from: generation)
    let pending = try #require(model.pendingLibraryRestore, "refused: \(model.alertMessage ?? "no message")")
    let message = AppModel.restoreConfirmationMessage(pending, libraryIsReadOnly: true)
    #expect(message.contains("come back as a recovered recording, without its title, notes or transcript, as soon as the restored library opens"), "\(message)")
    await model.performLibraryRestore(confirmed: true)?.value
    try #require(!model.store.isDegraded, "still read-only after the restore: \(model.store.health)")

    let alert = model.alertMessage ?? ""
    #expect(alert.contains("1 recording made since that backup is not in it."), "\(alert)")
    #expect(alert.contains("being added back now as a recovered recording, without its title, notes or transcript"), "\(alert)")

    // The restore starts the re-run and does not await it, so the listing is this wait's own subject.
    let deadline = Date().addingTimeInterval(30)
    while !model.store.meetings.contains(where: { $0.id == newer }), Date() < deadline {
        try await Task.sleep(for: .milliseconds(10))
    }
    #expect(Set(model.store.meetings.map(\.id)) == [kept, newer])
}

@Test("The restore dialog tells the confirmation whether the library is read-only (F699)")
func restoreDialogPassesTheReadOnlyState() throws {
    // The view cannot be rendered here (F174), so what it calls is checked as source, comments
    // stripped (F285). Without the argument the read-only dialog would promise "the next time
    // WhisperMeet opens" for recordings the restore lists again at once.
    let source = SourceAssertion.stripComments(
        try String(contentsOf: SourceAssertion.url("Sources/WhisperMeet/ContentView.swift"), encoding: .utf8)
    )
    let compact = source.filter { !$0.isWhitespace }
    #expect(compact.contains("AppModel.restoreConfirmationMessage(pending,libraryIsReadOnly:model.store.isDegraded)"))
}
