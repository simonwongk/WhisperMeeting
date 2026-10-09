import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F711 — the watched folder imports with no window open: nobody pressed anything, and the app may be
// running from the menu bar alone. Its refusals were set on `alertMessage`, which only a window's
// alert shows, so a user with no window open never learned that a recording was given up on
// (F554), that the whole waiting batch was being held (F454), or that a file was refused on its
// merits. They now go through `report(_:)`, which also offers the windowless channel (F257).
// `windowFacts` says there is no window and `deliverUserNotification` records the post, so nothing
// reaches the real Notification Centre.

@MainActor
private final class Posted {
    var bodies: [String] = []
}

@MainActor
private func makeModel(degraded: Bool = false) throws -> (AppModel, Posted) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("F711-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    if degraded {
        // Both index files unreadable: the library opens read-only, as F187/F321's tests set it up.
        try Data("broken-primary".utf8).write(to: root.appendingPathComponent("meetings.json"))
        try Data("broken-backup".utf8).write(to: root.appendingPathComponent("meetings.backup.json"))
    }
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(),
                         defaults: UserDefaults(suiteName: testSuiteName())!)
    // Pinned off, so adopting a file never starts a real transcription on a machine that has one.
    model.findWhisperExecutable = { nil }
    model.checkQwenInstalled = { false }
    // The menu-bar-only session: no library window at all.
    model.windowFacts = { (windows: [], appIsActive: false) }
    let posted = Posted()
    model.deliverUserNotification = { _, body in posted.bodies.append(body) }
    return (model, posted)
}

/// A real, parseable WAV in a folder of its own.
private func makeRecordingFile(named name: String = "call.wav") throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("F711Source-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let url = directory.appendingPathComponent(name)
    try WAVWriter.wavData(from: [Float](repeating: 0.05, count: 3_200), sampleRate: 16_000).write(to: url)
    return url
}

@MainActor
private func look(_ model: AppModel, ready: [URL] = []) async {
    model.watchedFolderLooked(snapshot: nil, ready: ready)
    await model.watchedFolderDelivery?.value
}

@MainActor
@Test("Giving up on a watched file reaches a user with no window open, once (F711)")
func giveUpReachesAUserWithNoWindow() async throws {
    let (model, posted) = try makeModel()
    defer { try? FileManager.default.removeItem(at: model.store.rootDirectory) }
    let file = try makeRecordingFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    // The disk is full on every try, so the queue gives up after its limit (F554).
    let outOfSpace = NSError(
        domain: NSCocoaErrorDomain, code: NSFileWriteOutOfSpaceError,
        userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(ENOSPC))]
    )
    model.copyRecordingIntoLibrary = { _, _ in throw outOfSpace }

    await look(model, ready: [file])
    for _ in 0..<(2 * AppModel.watchedFolderCopyAttemptLimit) where !model.pendingWatchedFiles.isEmpty {
        await look(model)
    }

    try #require(model.pendingWatchedFiles.isEmpty, "given up on within the limit")
    let giveUps = posted.bodies.filter { $0.contains("Not imported from your watched folder") }
    #expect(giveUps.count == 1, "\(posted.bodies)")
    #expect(giveUps.first?.contains("call.wav") == true)
    #expect(posted.bodies.count == 1, "the tries before it were held silently: \(posted.bodies)")
}

@MainActor
@Test("A waiting batch held because the library is read-only reaches a user with no window, once per cause (F711)")
func heldBatchReachesAUserWithNoWindow() async throws {
    let (model, posted) = try makeModel(degraded: true)
    defer { try? FileManager.default.removeItem(at: model.store.rootDirectory) }
    let file = try makeRecordingFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }

    await look(model, ready: [file])
    await look(model)
    await look(model)

    try #require(model.pendingWatchedFiles == [file], "held on the queue (F321)")
    #expect(posted.bodies.count == 1, "said once, not on every three-second look (F454): \(posted.bodies)")
    #expect(posted.bodies.first?.contains("read-only") == true, "\(posted.bodies)")
}

@MainActor
@Test("A watched file refused on its merits reaches a user with no window (F711)")
func refusedWatchedFileReachesAUserWithNoWindow() async throws {
    let (model, posted) = try makeModel()
    defer { try? FileManager.default.removeItem(at: model.store.rootDirectory) }
    let file = try makeRecordingFile()
    defer { try? FileManager.default.removeItem(at: file.deletingLastPathComponent()) }
    let denied = NSError(
        domain: NSCocoaErrorDomain, code: NSFileReadNoPermissionError,
        userInfo: [NSUnderlyingErrorKey: NSError(domain: NSPOSIXErrorDomain, code: Int(EACCES))]
    )
    model.copyRecordingIntoLibrary = { _, _ in throw denied }

    await look(model, ready: [file])

    #expect(model.pendingWatchedFiles.isEmpty, "a refusal on its merits is not retried (F554)")
    #expect(posted.bodies.count == 1, "\(posted.bodies)")
    #expect(posted.bodies.first?.contains("could not be imported") == true, "\(posted.bodies)")
}
