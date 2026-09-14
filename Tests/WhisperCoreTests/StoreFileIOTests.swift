import Foundation
import Testing
@testable import WhisperCore

// F190 Task 3 — the fault-injection seam. Genuinely red without it: `BackupJSONStore` has no `io`
// parameter, so no test can fail one specific filesystem effect.
//
// Why a seam at all, rather than the `fileManager` parameter that already exists: that parameter is
// used only for `createDirectory` and `fileExists` while every byte read and write bypasses it, so
// faulting it cannot reach a write. And why phases rather than URLs: `rename` serves both `install`
// and `rotateBackup`, `writeAtomically` serves both `stage` and `commit`. A test that matched on a
// URL suffix could not tell those apart, which is exactly the objection that sank a coarser seam in
// review. The phase is passed by the production code.

/// Wraps `.live` and injects only the *error*, so real bytes land in a real temp directory and each
/// case can then assert the true on-disk state afterwards.
///
/// Deliberately module-scoped while every other helper in this file is `private`:
/// `BackupJSONStoreTransactionTests` and `BackupJSONStoreRecoveryTests` both drive the write
/// protocol through it. A tidy-up that tightens this to `private` breaks both suites.
final class ScriptedStoreIO: @unchecked Sendable {
    private let lock = NSLock()
    private let failingPhase: StoreWritePhase?
    private let occurrence: Int
    private let error: Error
    private var counts: [StoreWritePhase: Int] = [:]
    private var completed: [StoreWritePhase] = []

    init(
        failing phase: StoreWritePhase? = nil,
        occurrence: Int = 1,
        with error: Error = CocoaError(.fileWriteUnknown)
    ) {
        self.failingPhase = phase
        self.occurrence = occurrence
        self.error = error
    }

    var completedPhases: [StoreWritePhase] { lock.withLock { completed } }
    func count(of phase: StoreWritePhase) -> Int { lock.withLock { counts[phase] ?? 0 } }

    /// Throws for the nth occurrence of the scripted phase, otherwise records it as completed.
    private func arrive(_ phase: StoreWritePhase) throws {
        try lock.withLock {
            counts[phase, default: 0] += 1
            if phase == failingPhase, counts[phase] == occurrence { throw error }
            completed.append(phase)
        }
    }

    var io: StoreFileIO {
        var scripted = StoreFileIO.live
        let live = StoreFileIO.live
        scripted.read = { [self] url, phase in try arrive(phase); return try live.read(url, phase) }
        scripted.writeAtomically = { [self] data, url, phase in
            try arrive(phase)
            try live.writeAtomically(data, url, phase)
        }
        scripted.copyItem = { [self] source, destination, phase in
            try arrive(phase)
            try live.copyItem(source, destination, phase)
        }
        scripted.rename = { [self] source, destination, phase in
            try arrive(phase)
            try live.rename(source, destination, phase)
        }
        scripted.remove = { [self] url, phase in try arrive(phase); try live.remove(url, phase) }
        scripted.createDirectory = { [self] url, phase in
            try arrive(phase)
            try live.createDirectory(url, phase)
        }
        scripted.contentsOfDirectory = { [self] url, phase in
            try arrive(phase)
            return try live.contentsOfDirectory(url, phase)
        }
        return scripted
    }
}

/// A minimal payload of this file's own. `BackupJSONStoreTests` keeps its `SavedMeeting` private,
/// and reaching across for it would couple two files that only happen to need a Codable value.
private struct StoredNote: Codable, Equatable {
    let title: String
}

private func makeStoreDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("StoreFileIOTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

@Test("A faulted install leaves the previous primary intact and surfaces the error (F190)")
func faultingTheInstallPhaseSurfacesAndLeavesThePrimaryIntact() throws {
    let directory = try makeStoreDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let primaryURL = directory.appendingPathComponent("meetings.json")
    let backupURL = directory.appendingPathComponent("meetings.backup.json")

    let seeded = BackupJSONStore<[StoredNote]>(primaryURL: primaryURL, backupURL: backupURL)
    try seeded.save([StoredNote(title: "First")])
    let bytesBefore = try Data(contentsOf: primaryURL)

    let scripted = ScriptedStoreIO(failing: .install)
    let store = BackupJSONStore<[StoredNote]>(
        primaryURL: primaryURL, backupURL: backupURL, io: scripted.io
    )

    #expect(throws: CocoaError.self) { try store.save([StoredNote(title: "Second")]) }

    // The error reached the caller, and the primary still holds exactly what it held before. That
    // pairing is the point: a write protocol that fails loudly but has already replaced the file is
    // the shape that lost the library.
    #expect(try Data(contentsOf: primaryURL) == bytesBefore)
    #expect(scripted.completedPhases.contains(.rotateBackup), "the rotation should have run first")
    #expect(!scripted.completedPhases.contains(.install))
}

@Test("The faulted phase is the only one that fails, and it fails on the occurrence asked for (F190)")
func faultInjectionTargetsOnePhaseAndOneOccurrence() throws {
    let directory = try makeStoreDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let primaryURL = directory.appendingPathComponent("meetings.json")
    let backupURL = directory.appendingPathComponent("meetings.backup.json")

    // Fail the SECOND install. The first save must therefore succeed completely, which is what
    // proves the double is delegating to `.live` rather than merely not throwing.
    //
    // `.install` and not `.rotateBackup`: install is exactly one rename per save, whereas the
    // rotation is a copy plus a rename, so occurrence N of `.rotateBackup` does not correspond to
    // save N. Targeting a phase whose count per save is not 1 is how an occurrence-based fault lands
    // somewhere other than where the test says it does.
    let scripted = ScriptedStoreIO(failing: .install, occurrence: 2)
    let store = BackupJSONStore<[StoredNote]>(
        primaryURL: primaryURL, backupURL: backupURL, io: scripted.io
    )

    try store.save([StoredNote(title: "First")])
    #expect(try #require(try store.load()).value == [StoredNote(title: "First")])

    #expect(throws: CocoaError.self) { try store.save([StoredNote(title: "Second")]) }
    #expect(scripted.count(of: .install) == 2)
    // The first save's bytes survive: the failure stopped the second save before it installed.
    #expect(try #require(try store.load()).value == [StoredNote(title: "First")])
}

@Test("The live seam reports a file's identity and directory-ness without opening it (F190)")
func liveSeamReportsIdentityAndDirectoryNess() throws {
    let directory = try makeStoreDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let file = directory.appendingPathComponent("payload.json")
    try Data("[]".utf8).write(to: file, options: .atomic)

    #expect(StoreFileIO.live.isDirectory(directory) == true)
    #expect(StoreFileIO.live.isDirectory(file) == false)
    #expect(StoreFileIO.live.isDirectory(directory.appendingPathComponent("absent")) == nil)

    let identity = try #require(StoreFileIO.live.identity(file))
    #expect(identity.size == 2)
    #expect(StoreFileIO.live.identity(directory.appendingPathComponent("absent")) == nil)

    // An atomic replace moves the inode — the property F211's decode-skip rests on.
    try Data("[1]".utf8).write(to: file, options: .atomic)
    #expect(try #require(StoreFileIO.live.identity(file)).inode != identity.inode)
}
