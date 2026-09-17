import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F191 slice E3 — the reviewed flow, in F193's shape.
//
// The model offers a plan, never restores on its own, and can only apply a plan it actually
// produced. That last property is structural rather than conventional, exactly as F193 made it: a
// caller cannot restore something the user never saw a description of.
//
// The busyness and read-only guards matter more here than for a backup. A backup only reads the
// library; a restore writes over it, so doing it during a recording would overwrite the index of a
// meeting in progress.

/// A valid index, because an unreadable one degrades the library and every restore is then
/// correctly refused. My first fixture wrote raw text into `meetings.json` and all six tests
/// failed — which was the read-only guard working, not the flow being broken.
private let indexAtBackup = #"[]"#
// ISO8601 `createdAt`, which is what `MeetingStore`'s decoder expects. A numeric one — valid for
// the plain `JSONDecoder()` other suites decode fixtures with — quarantines the index, and the
// diagnostic that found it printed `health=unreadable(quarantined: [...])`.
private let indexSinceThen = #"[{"id":"9E1C7A44-0000-4000-8000-000000000001","title":"Recorded since the backup","createdAt":"2026-09-17T10:00:00Z","duration":60,"recordingPath":"","status":"recorded","transcriptText":"","segments":[]}]"#

@MainActor
private func makeModel(root: URL, suite: String) -> AppModel {
    AppModel(
        store: MeetingStore(rootDirectory: root),
        // Stubbed, so `startRecording` reaches a running state without a real capture device —
        // the busyness guard is the thing under test, not ScreenCaptureKit.
        recorder: AudioCaptureEngine(
            stoppingCapture: {},
            finishingTracks: {},
            preservingPartialTracks: {},
            startingCapture: { _, _, _ in },
            directory: root
        ),
        defaults: UserDefaults(suiteName: suite)!,
        whisperExecutable: { URL(fileURLWithPath: "/tmp/whisper-stub") },
        qwenInstalled: { true }
    )
}

/// A library plus a backup of it, with the library drifted since.
@MainActor
private func makeFixture(_ label: String) throws -> (root: URL, model: AppModel, generation: URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("RestoreFlow-\(label)-\(UUID().uuidString)", isDirectory: true)
    let library = root.appendingPathComponent("Library", isDirectory: true)
    let destination = root.appendingPathComponent("Dest", isDirectory: true)
    try FileManager.default.createDirectory(at: library, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: destination, withIntermediateDirectories: true)
    try Data(indexAtBackup.utf8).write(to: library.appendingPathComponent("meetings.json"))

    let summary = try BackupCoordinator.backUp(source: library, destination: destination, now: 1, retain: 3)
    let generation = destination
        .appendingPathComponent(BackupCoordinator.managedSubfolder, isDirectory: true)
        .appendingPathComponent(summary.generation, isDirectory: true)
    try Data(indexSinceThen.utf8).write(to: library.appendingPathComponent("meetings.json"))

    let suite = "WhisperMeet.RestoreFlow.\(UUID().uuidString)"
    return (root, makeModel(root: library, suite: suite), generation)
}

@Test("Requesting a restore offers a plan and changes nothing")
@MainActor
func requestOffersAPlan() async throws {
    let (root, model, generation) = try makeFixture("offer")
    defer { try? FileManager.default.removeItem(at: root) }

    await model.requestLibraryRestore(from: generation)

    let pending = try #require(model.pendingLibraryRestore)
    #expect(pending.plan.wouldOverwrite.contains("meetings.json"))
    #expect(pending.plan.isSafeToApply)
    // Offering is not doing.
    #expect(try Data(contentsOf: model.store.rootDirectory.appendingPathComponent("meetings.json"))
        == Data(indexSinceThen.utf8))
}

@Test("An unconfirmed restore is a no-op and leaves the offer standing")
@MainActor
func unconfirmedRestoreDoesNothing() async throws {
    let (root, model, generation) = try makeFixture("unconfirmed")
    defer { try? FileManager.default.removeItem(at: root) }

    await model.requestLibraryRestore(from: generation)
    await model.performLibraryRestore(confirmed: false)

    #expect(model.pendingLibraryRestore != nil, "the user has not answered yet")
    #expect(try Data(contentsOf: model.store.rootDirectory.appendingPathComponent("meetings.json"))
        == Data(indexSinceThen.utf8))
}

@Test("A confirmed restore applies the plan and reloads the library")
@MainActor
func confirmedRestoreApplies() async throws {
    let (root, model, generation) = try makeFixture("confirmed")
    defer { try? FileManager.default.removeItem(at: root) }

    await model.requestLibraryRestore(from: generation)
    await model.performLibraryRestore(confirmed: true)

    #expect(try Data(contentsOf: model.store.rootDirectory.appendingPathComponent("meetings.json"))
        == Data(indexAtBackup.utf8))
    #expect(model.pendingLibraryRestore == nil)
    // The user is told where their previous library went, because they may want it back.
    #expect(model.alertMessage?.contains("previous library") == true)
}

@Test("A restore the model never offered is refused")
@MainActor
func unofferedRestoreIsRefused() async throws {
    // F193's structural guarantee: "user-reviewed" enforced by the code rather than by convention.
    let (root, model, _) = try makeFixture("unoffered")
    defer { try? FileManager.default.removeItem(at: root) }

    await model.performLibraryRestore(confirmed: true)

    #expect(try Data(contentsOf: model.store.rootDirectory.appendingPathComponent("meetings.json"))
        == Data(indexSinceThen.utf8))
}

@Test("A restore is refused while a recording is running")
@MainActor
func restoreRefusedWhileRecording() async throws {
    // Sharper than the backup's guard. A backup only reads; a restore would overwrite the index of
    // a meeting that is being recorded right now.
    let (root, model, generation) = try makeFixture("busy")
    defer { try? FileManager.default.removeItem(at: root) }
    await model.startRecording()
    try #require(model.activeMeetingID != nil)

    await model.requestLibraryRestore(from: generation)

    #expect(model.pendingLibraryRestore == nil)
    #expect(model.alertMessage?.isEmpty == false)
}

@Test("A damaged generation is refused with its problems named")
@MainActor
func damagedGenerationIsExplained() async throws {
    let (root, model, generation) = try makeFixture("damaged")
    defer { try? FileManager.default.removeItem(at: root) }
    let target = generation.appendingPathComponent("meetings.json")
    var bytes = try Data(contentsOf: target)
    bytes[0] = bytes[0] ^ 0xFF          // same size: only the deep check sees it
    try bytes.write(to: target)

    await model.requestLibraryRestore(from: generation)

    // Offered for review — the user asked — but not safe, and the reason is theirs to read.
    let pending = try #require(model.pendingLibraryRestore)
    #expect(!pending.plan.isSafeToApply)
    #expect(!pending.plan.verification.problems.isEmpty)

    await model.performLibraryRestore(confirmed: true)
    // Confirming a damaged backup still does not restore it.
    #expect(try Data(contentsOf: model.store.rootDirectory.appendingPathComponent("meetings.json"))
        == Data(indexSinceThen.utf8))
    #expect(model.alertMessage?.isEmpty == false)
}

// MARK: - The confirmation copy (F191 slice E3)

@Test("The confirmation leads with what the backup does not contain")
@MainActor
func confirmationLeadsWithWhatIsMissing() async throws {
    // The only item on the list the user cannot undo by restoring again, which is why E1 computes
    // that set at all. Leading with the file counts would bury it.
    let (root, model, generation) = try makeFixture("copy")
    defer { try? FileManager.default.removeItem(at: root) }
    let newer = model.store.rootDirectory
        .appendingPathComponent("Recordings/recorded-since", isDirectory: true)
    try FileManager.default.createDirectory(at: newer, withIntermediateDirectories: true)
    try Data("audio".utf8).write(to: newer.appendingPathComponent("meeting.wav"))

    await model.requestLibraryRestore(from: generation)
    let pending = try #require(model.pendingLibraryRestore)
    let message = AppModel.restoreConfirmationMessage(pending)

    #expect(message.hasPrefix("1 file(s) in your library are not in this backup"))
    #expect(message.contains("copied aside first and kept"))
}

@Test("A clean restore's confirmation does not invent a missing-files warning")
@MainActor
func cleanConfirmationOmitsTheWarning() async throws {
    let (root, model, generation) = try makeFixture("clean")
    defer { try? FileManager.default.removeItem(at: root) }

    await model.requestLibraryRestore(from: generation)
    let pending = try #require(model.pendingLibraryRestore)
    let message = AppModel.restoreConfirmationMessage(pending)

    #expect(!message.contains("not in this backup"))
    #expect(message.contains("will be replaced"))
}

@Test("An unverifiable backup's confirmation says so, and a damaged one refuses")
@MainActor
func confirmationDistinguishesUnverifiableFromDamaged() async throws {
    let (root, model, generation) = try makeFixture("states")
    defer { try? FileManager.default.removeItem(at: root) }

    // Unverifiable: no manifest, because an older build wrote it.
    try FileManager.default.removeItem(at: generation.appendingPathComponent(BackupManifest.fileName))
    await model.requestLibraryRestore(from: generation)
    var pending = try #require(model.pendingLibraryRestore)
    #expect(AppModel.restoreConfirmationMessage(pending).contains("could not confirm it is intact"))
    model.cancelLibraryRestore()

    // Damaged: the manifest is there and the bytes disagree with it.
    let (root2, model2, generation2) = try makeFixture("damaged-copy")
    defer { try? FileManager.default.removeItem(at: root2) }
    let target = generation2.appendingPathComponent("meetings.json")
    var bytes = try Data(contentsOf: target)
    bytes[0] = bytes[0] ^ 0xFF
    try bytes.write(to: target)
    await model2.requestLibraryRestore(from: generation2)
    pending = try #require(model2.pendingLibraryRestore)
    #expect(AppModel.restoreConfirmationMessage(pending).contains("cannot be restored"))
}
