import Foundation
import Testing
@testable import WhisperCore

private func makeTempDirectory() throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("WhisperMeetQuarantineTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    return directory
}

@Test("Quarantine copies the exact bytes aside and leaves the original in place")
func quarantineCopiesRatherThanMoves() throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("meetings.json")
    let bytes = Data("broken-primary".utf8)
    try bytes.write(to: url)

    let name = try #require(try StoreQuarantine.preserve(fileAt: url, using: .default))

    #expect(name.hasPrefix("meetings.unreadable-"))
    #expect(name.hasSuffix(".json"))
    // Copy, never move: load() must still see the original, or it returns nil and re-opens rebuild.
    #expect(FileManager.default.fileExists(atPath: url.path))
    #expect(try Data(contentsOf: url) == bytes)
    #expect(try Data(contentsOf: directory.appendingPathComponent(name)) == bytes)
}

@Test("Quarantining identical bytes twice does not accumulate duplicates")
func quarantineIsIdempotentForIdenticalBytes() throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let url = directory.appendingPathComponent("meetings.json")
    try Data("broken".utf8).write(to: url)

    _ = try StoreQuarantine.preserve(fileAt: url, using: .default)
    _ = try StoreQuarantine.preserve(fileAt: url, using: .default)

    let quarantined = try FileManager.default
        .contentsOfDirectory(atPath: directory.path)
        .filter { $0.contains(".unreadable-") }
    #expect(quarantined.count == 1)
}

@Test("Quarantining a file that does not exist is a no-op")
func quarantineSkipsMissingFile() throws {
    let directory = try makeTempDirectory()
    defer { try? FileManager.default.removeItem(at: directory) }
    let name = try StoreQuarantine.preserve(
        fileAt: directory.appendingPathComponent("absent.json"),
        using: .default
    )
    #expect(name == nil)
}

@Test("Only a complete store permits mutation")
func onlyCompleteHealthAllowsMutation() {
    #expect(PersistedStoreHealth.complete.allowsMutation)
    #expect(!PersistedStoreHealth.recoveredFromBackup.allowsMutation)
    #expect(!PersistedStoreHealth.partiallySalvaged(parkedIdentifiers: ["a"]).allowsMutation)
    #expect(!PersistedStoreHealth.unreadable(quarantined: ["x.json"]).allowsMutation)
    #expect(!PersistedStoreHealth.suspectEmpty(recordingFolderCount: 10).allowsMutation)
    #expect(!PersistedStoreHealth.unavailable("disk").allowsMutation)
}
