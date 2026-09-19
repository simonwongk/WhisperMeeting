import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F318 — the AppModel side of the watched folder: off by default, nothing before startup recovery,
// and a finished file that arrives while the app is busy waits instead of being lost.
// F321/F323 — and the queue is transactional: a batch the importer will not take stays on it, and
// turning the feature on starts a fresh baseline instead of replaying a month of arrivals.

@MainActor
private func makeModel() throws -> (AppModel, UserDefaults) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("WatchedFolder-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let defaults = UserDefaults(suiteName: "F318.\(UUID().uuidString)")!
    return (AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(), defaults: defaults), defaults)
}

/// A store whose index files are both unreadable: every write is refused, which is the state
/// `performStartupRecovery` leaves behind while still restarting the watcher (F187, F321).
@MainActor
private func makeDegradedModel() throws -> (AppModel, URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("WatchedFolderDegraded-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    try Data("broken-primary".utf8).write(to: root.appendingPathComponent("meetings.json"))
    try Data("broken-backup".utf8).write(to: root.appendingPathComponent("meetings.backup.json"))
    let defaults = UserDefaults(suiteName: "F321.\(UUID().uuidString)")!
    return (AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(), defaults: defaults), root)
}

/// A real, parseable WAV on disk: the import path measures its duration before adopting it (F326).
private func makeRecordingFile(named name: String = "call.wav") throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("WatchedFolderSource-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent(name)
    try WAVWriter.wavData(from: [Float](repeating: 0.05, count: 3_200), sampleRate: 16_000).write(to: url)
    return url
}

private func version(_ size: Int64) -> WatchedFolderInbox.Version {
    WatchedFolderInbox.Version(size: size, modified: Date(timeIntervalSince1970: 1_000))
}

@MainActor
@Test("The watched folder is off until the user turns it on and picks a folder (F318)")
func watchedFolderIsOptIn() throws {
    let (model, _) = try makeModel()
    #expect(!model.watchedFolderEnabled)
    #expect(model.watchedFolderPath == nil)
}

@MainActor
@Test("A finished file that arrives during a recording waits, and is imported afterwards (F318)")
func busyAppKeepsTheFileForLater() async throws {
    let (model, defaults) = try makeModel()
    model.watchedFolderPath = "/inbox"
    let file = URL(fileURLWithPath: "/inbox/call.m4a")
    model.setRecordingStateForTesting(.recording(startedAt: Date()))
    model.watchedFolderLooked(snapshot: ["/inbox/call.m4a": version(10)], ready: [file])
    #expect(model.pendingWatchedFiles == [file], "handed over once by the inbox, so it must not be dropped")
    #expect(AppModel.watchedFolderKnownFiles(for: "/inbox", in: defaults)?.isEmpty == true,
            "quitting now must leave the waiting file new for the next launch")

    model.setRecordingStateForTesting(.idle)
    model.watchedFolderLooked(snapshot: ["/inbox/call.m4a": version(10)], ready: [])
    #expect(model.pendingWatchedFiles.isEmpty, "taken for import on the first free look")
    await model.watchedFolderDelivery?.value
}

@MainActor
@Test("Each folder's record survives a relaunch, and belongs only to the folder it was written for (F320)")
func recordSurvivesARelaunch() throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("WatchedFolderRelaunch-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let defaults = UserDefaults(suiteName: "F318.relaunch.\(UUID().uuidString)")!
    let first = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(), defaults: defaults)
    first.watchedFolderPath = "/inbox"
    first.watchedFolderLooked(snapshot: ["/inbox/old.m4a": version(7)], ready: [])
    // Writing a second folder's record must not erase the first: the whole point of the per-folder
    // shape, and `defaults.set([path: value], forKey:)` replaced the entire dictionary.
    AppModel.setWatchedFolderKnownFiles(["/other/tape.m4a": version(3)], for: "/other", in: defaults)

    // A second launch loads the saved path in `init` — which is exactly what used to wipe the record.
    _ = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(), defaults: defaults)
    #expect(AppModel.watchedFolderKnownFiles(for: "/inbox", in: defaults) == ["/inbox/old.m4a": version(7)])
    #expect(AppModel.watchedFolderKnownFiles(for: "/other", in: defaults) == ["/other/tape.m4a": version(3)])
    #expect(AppModel.watchedFolderKnownFiles(for: "/somewhere/else", in: defaults) == nil)
}

@MainActor
@Test("Turning the watched folder on starts a fresh baseline, so nothing added while it was off imports (F323)")
func turningTheFolderOnRebaselines() throws {
    let (model, defaults) = try makeModel()
    model.watchedFolderPath = "/inbox"
    AppModel.setWatchedFolderKnownFiles(["/inbox/a-month-ago.m4a": version(9)], for: "/inbox", in: defaults)

    model.watchedFolderEnabled = true

    #expect(AppModel.watchedFolderKnownFiles(for: "/inbox", in: defaults) == nil,
            "a month-old record would make every file added meanwhile new")
}

@MainActor
@Test("Choosing a different folder baselines that one, and launching with the feature already on does not (F323)")
func choosingAFolderRebaselinesAndALaunchDoesNot() throws {
    let (model, defaults) = try makeModel()
    model.watchedFolderEnabled = true
    AppModel.setWatchedFolderKnownFiles(["/inbox/one.m4a": version(1)], for: "/inbox", in: defaults)
    AppModel.setWatchedFolderKnownFiles(["/other/two.m4a": version(2)], for: "/other", in: defaults)

    model.watchedFolderPath = "/other"
    #expect(AppModel.watchedFolderKnownFiles(for: "/other", in: defaults) == nil, "a newly chosen folder is baselined")
    #expect(AppModel.watchedFolderKnownFiles(for: "/inbox", in: defaults)?.count == 1, "and only that one")

    // A relaunch with the feature already on must NOT discard the record: `@Published` assignments
    // in `init` go through the setter, which is how the first version forgot its date every launch.
    AppModel.setWatchedFolderKnownFiles(["/other/two.m4a": version(2)], for: "/other", in: defaults)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("WatchedFolderLaunch-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    _ = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(), defaults: defaults)
    #expect(AppModel.watchedFolderKnownFiles(for: "/other", in: defaults)?.count == 1)
}

@MainActor
@Test("A batch the degraded library refuses stays on the queue instead of vanishing (F321)")
func refusedBatchStaysOnTheQueue() async throws {
    let (model, root) = try makeDegradedModel()
    defer { try? FileManager.default.removeItem(at: root) }
    let file = try makeRecordingFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

    model.watchedFolderLooked(snapshot: nil, ready: [file])
    await model.watchedFolderDelivery?.value

    #expect(model.store.meetings.isEmpty)
    #expect(model.pendingWatchedFiles == [file], "the inbox hands each file over once — losing it here loses it for good")
    #expect(model.inFlightWatchedFiles.isEmpty)
    #expect(FileManager.default.fileExists(atPath: file.path), "the user's own file is untouched")
}

@MainActor
@Test("A file the queue accepted becomes exactly one meeting and leaves the queue (F321)")
func acceptedBatchBecomesAMeeting() async throws {
    let (model, _) = try makeModel()
    let file = try makeRecordingFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

    model.watchedFolderLooked(snapshot: nil, ready: [file])
    // A second look while the first import is in flight must not start a second one.
    model.watchedFolderLooked(snapshot: nil, ready: [file])
    await model.watchedFolderDelivery?.value

    #expect(model.store.meetings.count == 1)
    #expect(model.pendingWatchedFiles.isEmpty)
}

@MainActor
@Test("A truncated file is not adopted as a zero-duration meeting (F326)")
func truncatedImportIsNotAdopted() async throws {
    let (model, _) = try makeModel()
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("F326-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    // An MP4 whose `moov` atom never arrived: `AVURLAsset` cannot parse it, `loadDuration` returns 0.
    let truncated = directory.appendingPathComponent("half-written.mp4")
    try Data(repeating: 0x00, count: 4_096).write(to: truncated)

    model.watchedFolderLooked(snapshot: nil, ready: [truncated])
    await model.watchedFolderDelivery?.value

    #expect(model.store.meetings.isEmpty, "a prefix of a recording must not be filed as a complete one")
    #expect(model.pendingWatchedFiles.isEmpty, "and must not be retried every three seconds either")
    #expect(!model.isImporting)
}

@Test("Settings offers the folder, reports an unreadable one, and startup recovery starts the watcher (F318, F325)")
func watchedFolderIsReachable() throws {
    func source(_ path: String) throws -> String {
        try String(contentsOf: URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent(path), encoding: .utf8)
    }
    let view = try source("Sources/WhisperMeet/ContentView.swift")
    #expect(view.contains("isOn: $model.watchedFolderEnabled"))
    #expect(view.contains("model.watchedFolderPath = url.path"))
    #expect(view.contains("model.watchedFolderProblem"))
    let model = try source("Sources/WhisperMeet/AppModel.swift")
    #expect(model.contains("defer { restartWatchedFolder() }"))
}
