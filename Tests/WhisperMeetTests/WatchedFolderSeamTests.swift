import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F327 — the seam, over a real temp directory. `WatchedFolderInbox` is well tested as a pure rule
// and `WatchedFolderMonitor` had no tests at all, so nothing drove the one path a relaunch takes:
// listing → inbox → persisted defaults → a *second* inbox built from those defaults. Both defects
// F318's author found on a real run lived there, and so did F320 and F323.

/// One run of the app watching one folder: a fresh inbox built from what the last run persisted.
@MainActor
private final class WatchingRun {
    private var inbox: WatchedFolderInbox
    private let folder: URL
    private let defaults: UserDefaults

    init(folder: URL, defaults: UserDefaults) {
        self.folder = folder
        self.defaults = defaults
        inbox = WatchedFolderInbox(known: AppModel.watchedFolderKnownFiles(for: folder.path, in: defaults))
    }

    /// One look, exactly as `WatchedFolderMonitor` takes it, persisted exactly as `AppModel` does.
    @discardableResult
    func look() -> [String] {
        guard case .success(let entries) = WatchedFolderMonitor.listing(at: folder) else {
            Issue.record("the folder could not be listed")
            return []
        }
        let ready = inbox.ready(in: entries)
        if let snapshot = inbox.snapshot {
            AppModel.setWatchedFolderKnownFiles(snapshot, for: folder.path, in: defaults)
        }
        return ready.map(\.lastPathComponent).sorted()
    }

    /// Looks until a file could have settled, collecting everything handed over.
    func settle(looks: Int = 4) -> [String] {
        var seen: [String] = []
        for _ in 0..<looks { seen += look() }
        return seen.sorted()
    }
}

private func makeWatchedFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("F327-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

/// A real, parseable WAV — the import path measures duration with `AVURLAsset`, so a placeholder
/// would be refused on its merits instead of exercising the rule under test.
private func recording(seconds: Double = 0.2) -> Data {
    WAVWriter.wavData(from: [Float](repeating: 0.05, count: Int(seconds * 16_000)), sampleRate: 16_000)
}

@MainActor
@Test("Across a relaunch nothing is imported twice and nothing is dropped (F327)")
func watchedFolderSurvivesARelaunch() throws {
    let folder = try makeWatchedFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let defaults = try #require(UserDefaults(suiteName: "F327.\(UUID().uuidString)"))
    try recording().write(to: folder.appendingPathComponent("already-here.wav"))

    let first = WatchingRun(folder: folder, defaults: defaults)
    #expect(first.look().isEmpty, "what is already there when watching starts is never imported")

    // A writer that appends, the way a recorder or a sync client does.
    let growing = folder.appendingPathComponent("call.wav")
    try recording(seconds: 0.1).write(to: growing)
    #expect(first.look().isEmpty, "first sight")
    try recording(seconds: 0.4).write(to: growing)
    #expect(first.look().isEmpty, "still changing")
    #expect(first.look().isEmpty, "unchanged once is not enough")
    #expect(first.look() == ["call.wav"], "settled")

    // Quit, relaunch from the same defaults.
    let second = WatchingRun(folder: folder, defaults: defaults)
    #expect(second.settle().isEmpty, "everything here is already accounted for")
}

@MainActor
@Test("A recording copied in while the app was closed is imported at the next launch, old date and all (F320)")
func fileCopiedInWhileClosedIsImportedOnRelaunch() throws {
    let folder = try makeWatchedFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let defaults = try #require(UserDefaults(suiteName: "F320.\(UUID().uuidString)"))
    try recording().write(to: folder.appendingPathComponent("already-here.wav"))
    let first = WatchingRun(folder: folder, defaults: defaults)
    #expect(first.look().isEmpty)

    // The app is closed. The user copies in a recording they already had: a Finder copy, `cp -p`,
    // `ditto`, unzip, AirDrop and a Time Machine restore all preserve the modification date, so the
    // file is *older* than everything already in the folder.
    let restored = folder.appendingPathComponent("from-2019.wav")
    try recording().write(to: restored)
    try FileManager.default.setAttributes(
        [.modificationDate: Date(timeIntervalSince1970: 1_550_000_000)], ofItemAtPath: restored.path
    )

    let second = WatchingRun(folder: folder, defaults: defaults)
    #expect(second.settle() == ["from-2019.wav"])
    // And exactly once: a third launch must not offer it again.
    let third = WatchingRun(folder: folder, defaults: defaults)
    #expect(third.settle().isEmpty)
}

@MainActor
@Test("A file that is still settling when the app quits is still new at the next launch (F320)")
func fileStillSettlingAtQuitIsNewNextLaunch() throws {
    let folder = try makeWatchedFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    let defaults = try #require(UserDefaults(suiteName: "F320.settle.\(UUID().uuidString)"))
    let first = WatchingRun(folder: folder, defaults: defaults)
    #expect(first.look().isEmpty)
    let arriving = folder.appendingPathComponent("mid-copy.wav")
    try recording().write(to: arriving)
    #expect(first.look().isEmpty, "seen, not yet settled")
    // The app quits here — one look after the file appeared, which is the real run that found this.

    let second = WatchingRun(folder: folder, defaults: defaults)
    #expect(second.settle() == ["mid-copy.wav"])
}

@MainActor
@Test("An unreadable or missing folder is reported, not read as empty (F325)")
func unreadableFolderIsReported() throws {
    let folder = try makeWatchedFolder()
    let file = folder.appendingPathComponent("call.wav")
    try recording().write(to: file)
    guard case .success(let entries) = WatchedFolderMonitor.listing(at: folder) else {
        Issue.record("a readable folder must list")
        return
    }
    #expect(entries.map(\.url.lastPathComponent) == ["call.wav"])

    // A file that still exists but is not a folder: a watched folder pointed at a file reads as
    // unreadable, not as missing.
    let notAFolder = try makeWatchedFolder().appendingPathComponent("chosen.wav")
    try recording().write(to: notAFolder)
    defer { try? FileManager.default.removeItem(at: notAFolder.deletingLastPathComponent()) }
    #expect(WatchedFolderMonitor.listing(at: notAFolder) == .failure(.unreadable))

    try FileManager.default.removeItem(at: folder)
    #expect(WatchedFolderMonitor.listing(at: folder) == .failure(.missing))
    #expect(AppModel.watchedFolderMessage(for: .missing).contains("cannot be found"))
    #expect(AppModel.watchedFolderMessage(for: .unreadable).contains("cannot read"))
}

@MainActor
@Test("A folder that cannot be read leaves the saved record alone (F325)")
func unreadableFolderDoesNotWipeTheRecord() throws {
    let folder = try makeWatchedFolder()
    let defaults = try #require(UserDefaults(suiteName: "F325.\(UUID().uuidString)"))
    try recording().write(to: folder.appendingPathComponent("already-here.wav"))
    let run = WatchingRun(folder: folder, defaults: defaults)
    #expect(run.look().isEmpty)
    let recorded = try #require(AppModel.watchedFolderKnownFiles(for: folder.path, in: defaults))
    #expect(recorded.count == 1)

    // The volume goes away. Nothing may be written from a look that read nothing, or granting
    // access again would import the whole folder as new.
    try FileManager.default.removeItem(at: folder)
    #expect(WatchedFolderMonitor.listing(at: folder) == .failure(.missing))
    #expect(AppModel.watchedFolderKnownFiles(for: folder.path, in: defaults)?.count == 1)
}
