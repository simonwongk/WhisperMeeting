import Foundation
import Testing
@testable import WhisperCore

// F976 — since F945 round 2 a recovery conversion's temp file is created without a lock on a volume that
// cannot lock (NFS mounted with `nolocks`, some SMB and WebDAV setups), and the sweep that clears what a
// quit or a crash left removed only a file whose lock it could take — which it never can there — so such
// a temp stayed for good. On such a volume the sweep now asks what it can instead of the lock: the process
// named in the file's name (F976 puts the owner in it), whether any process has the file open (F946's
// kernel probe), and whether the file has stopped growing. All three must say "abandoned"; the lock
// alone still decides where it works, and nothing else is asked there.

private let exitedProcess: pid_t = 99_999_999
private let hourAgo = Date().addingTimeInterval(-3_600)
/// What `flock(2)` answers on a volume without locking.
private let noLock: (Int32) -> Int32 = { _ in ENOTSUP }

private func makeFolder() throws -> URL {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("F976-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    return folder
}

/// A conversion temp file last written at `modified`.
private func plant(_ name: String, in folder: URL, modified: Date) throws -> URL {
    let url = folder.appendingPathComponent(name)
    try Data("abandoned".utf8).write(to: url)
    try FileManager.default.setAttributes([.modificationDate: modified], ofItemAtPath: url.path)
    return url
}

private func temporaryFiles(in folder: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: folder.path)) ?? [])
        .filter(InterruptedLinkImportExtraction.isTemporaryFile(named:))
        .sorted()
}

private func ownedName(by owner: pid_t) -> String {
    InterruptedLinkImportExtraction.temporaryFilename(forRun: UUID(), owner: owner)
}

@Test("On a volume without flock, a temp whose owner is gone, that nothing holds and that stopped growing is removed, as is one from a build that named no owner (F976)")
func withoutLocksAnAbandonedTempIsRemoved() throws {
    let folder = try makeFolder()
    defer { try? FileManager.default.removeItem(at: folder) }
    // A run of this build whose process has exited; the single name builds before F945 wrote; and the
    // per-run name builds between F945 and F976 wrote, which carries no owner.
    for name in [ownedName(by: exitedProcess), "recording.extracting.wav", "recording.extracting.\(UUID().uuidString).wav"] {
        _ = try plant(name, in: folder, modified: hourAgo)
    }
    try #require(temporaryFiles(in: folder).count == 3)

    InterruptedLinkImportExtraction.removeAbandonedTemporaryFiles(
        in: folder, tryLock: noLock, openState: { _ in .notHeld }, processExists: { _ in false }
    )

    #expect(temporaryFiles(in: folder).isEmpty, "left \(temporaryFiles(in: folder))")
}

@Test("On a volume without flock, a temp is kept while its owner lives, while any process holds it, while it still grows, and when the kernel cannot say (F976)")
func withoutLocksALiveHeldOrGrowingTempIsKept() throws {
    struct Case {
        let label: String
        let name: String
        let modified: Date
        let openState: RecordingFolderLiveness.OpenState
        let processExists: (pid_t) -> Bool
    }
    let cases = [
        // This process is never swept, whatever a probe says about it.
        Case(label: "owned by this process", name: ownedName(by: getpid()), modified: hourAgo, openState: .notHeld, processExists: { _ in false }),
        Case(label: "owned by launchd", name: ownedName(by: 1), modified: hourAgo, openState: .notHeld, processExists: OwnedTemporaryFolders.processExists),
        Case(label: "held open", name: ownedName(by: exitedProcess), modified: hourAgo, openState: .held, processExists: { _ in false }),
        Case(label: "kernel cannot say", name: ownedName(by: exitedProcess), modified: hourAgo, openState: .unknown, processExists: { _ in false }),
        Case(label: "still growing", name: ownedName(by: exitedProcess), modified: Date(), openState: .notHeld, processExists: { _ in false }),
        Case(label: "no owner, still growing", name: "recording.extracting.wav", modified: Date(), openState: .notHeld, processExists: { _ in false }),
    ]
    for item in cases {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = try plant(item.name, in: folder, modified: item.modified)

        InterruptedLinkImportExtraction.removeAbandonedTemporaryFiles(
            in: folder, tryLock: noLock, openState: { _ in item.openState }, processExists: item.processExists
        )

        #expect(temporaryFiles(in: folder) == [item.name], "\(item.label): removed")
    }
}

@Test("Where flock answers, the lock alone decides, and nothing else is asked (F976)")
func withLocksTheLockDecidesAlone() throws {
    final class Probes: @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        var asked: Int { lock.withLock { count } }
        func ask() { lock.withLock { count += 1 } }
    }
    // Free lock: removed, though it was written just now and its owner is this process.
    do {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        _ = try plant(ownedName(by: getpid()), in: folder, modified: Date())
        let probes = Probes()
        InterruptedLinkImportExtraction.removeAbandonedTemporaryFiles(
            in: folder, tryLock: { _ in 0 }, openState: { _ in probes.ask(); return .notHeld }
        )
        #expect(temporaryFiles(in: folder).isEmpty)
        #expect(probes.asked == 0, "the kernel was asked where the lock had answered")
    }
    // Held lock: kept, though it is old, its owner is gone and nothing holds it.
    do {
        let folder = try makeFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let name = ownedName(by: exitedProcess)
        _ = try plant(name, in: folder, modified: hourAgo)
        let probes = Probes()
        InterruptedLinkImportExtraction.removeAbandonedTemporaryFiles(
            in: folder, tryLock: { _ in EWOULDBLOCK }, openState: { _ in probes.ask(); return .notHeld }, processExists: { _ in false }
        )
        #expect(temporaryFiles(in: folder) == [name])
        #expect(probes.asked == 0, "the kernel was asked where the lock had answered")
    }
}

@Test("A conversion's temp file is named for the process that made it, and only a name of that exact shape names one (F976)")
func theTempFileNamesItsOwner() {
    let run = UUID()
    let name = InterruptedLinkImportExtraction.temporaryFilename(forRun: run)
    #expect(name == "recording.extracting.\(getpid())-\(run.uuidString).wav")
    #expect(InterruptedLinkImportExtraction.isTemporaryFile(named: name))
    #expect(InterruptedLinkImportExtraction.temporaryFileOwner(name) == getpid())
    #expect(InterruptedLinkImportExtraction.temporaryFileOwner(ownedName(by: exitedProcess)) == exitedProcess)
    let unnamed = [
        "recording.extracting.wav",
        "recording.extracting.\(run.uuidString).wav",
        "recording.extracting.0\(exitedProcess)-\(run.uuidString).wav",
        "recording.extracting.\(exitedProcess)-\(run.uuidString.lowercased()).wav",
        "recording.extracting.\(exitedProcess)-not-a-uuid.wav",
        "recording.extracting.-\(exitedProcess)-\(run.uuidString).wav",
    ]
    for name in unnamed {
        #expect(InterruptedLinkImportExtraction.temporaryFileOwner(name) == nil, "\(name)")
    }
}
