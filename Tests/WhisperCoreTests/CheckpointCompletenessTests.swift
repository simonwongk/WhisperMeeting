import Foundation
import Testing
@testable import WhisperCore

// F900 — openai-whisper writes its checkpoint in place as it downloads (`open(download_target, "wb")`,
// `whisper/__init__.py:73` in the pinned 20250625), so a download F860 stops, or a quit, leaves a
// partial `large-v3-turbo.pt` under the checkpoint's own name. `checkpointCached` checked presence
// only, so the Intel model row read "Selected model ready" until the next dictation re-downloaded it.
//
// Full-size fixtures are sparse files: `truncate` sets the length without writing 1.6 GB.

private func temporaryDirectory(_ name: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("\(name)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Writes `byteCount` bytes (sparse beyond the first) as `model`'s checkpoint under `support`.
private func writeCheckpoint(_ model: WhisperModel, byteCount: Int64, in support: URL) throws -> URL {
    let models = LocalWhisperRuntime.modelDirectory(applicationSupport: support)
    try FileManager.default.createDirectory(at: models, withIntermediateDirectories: true)
    let url = models.appendingPathComponent(LocalWhisperRuntime.checkpointFileName(for: model))
    try Data([0x80]).write(to: url) // a pickle's first byte, so even the 1-byte case is a real file
    let handle = try FileHandle(forWritingTo: url)
    try handle.truncate(atOffset: UInt64(byteCount))
    try handle.close()
    return url
}

@Test("A checkpoint cut short by a stopped download is not cached; a whole one is (F900)")
func aPartialCheckpointIsNotCached() throws {
    let support = try temporaryDirectory("F900-partial")
    defer { try? FileManager.default.removeItem(at: support) }
    let whole = LocalWhisperRuntime.checkpointByteCount(for: .turbo)

    // 3 % of the way, and one byte short: both are what a stopped download leaves.
    for partial: Int64 in [whole * 3 / 100, whole - 1] {
        _ = try writeCheckpoint(.turbo, byteCount: partial, in: support)
        #expect(!LocalWhisperRuntime.checkpointCached(.turbo, applicationSupport: support),
                "a \(partial)-byte checkpoint read as ready")
    }
    _ = try writeCheckpoint(.turbo, byteCount: whole, in: support)
    #expect(LocalWhisperRuntime.checkpointCached(.turbo, applicationSupport: support))
}

@Test("A checkpoint longer than the real one is not cached either (F900)")
func anOversizedCheckpointIsNotCached() throws {
    let support = try temporaryDirectory("F900-oversized")
    defer { try? FileManager.default.removeItem(at: support) }
    _ = try writeCheckpoint(.turbo, byteCount: LocalWhisperRuntime.checkpointByteCount(for: .turbo) + 1, in: support)
    #expect(!LocalWhisperRuntime.checkpointCached(.turbo, applicationSupport: support))
}

@Test("Each model is measured against its own checkpoint's size (F900)")
func eachModelHasItsOwnSize() throws {
    let support = try temporaryDirectory("F900-models")
    defer { try? FileManager.default.removeItem(at: support) }
    // The two sizes as read from the CDN on 2026-10-12 (and of the checkpoints installed on the
    // developer's Mac): pinned here so a slip in the table cannot pass unseen.
    #expect(LocalWhisperRuntime.checkpointByteCount(for: .turbo) == 1_617_941_637)
    #expect(LocalWhisperRuntime.checkpointByteCount(for: .large) == 3_087_371_615)

    _ = try writeCheckpoint(.large, byteCount: LocalWhisperRuntime.checkpointByteCount(for: .turbo), in: support)
    #expect(!LocalWhisperRuntime.checkpointCached(.large, applicationSupport: support))
    _ = try writeCheckpoint(.large, byteCount: LocalWhisperRuntime.checkpointByteCount(for: .large), in: support)
    #expect(LocalWhisperRuntime.checkpointCached(.large, applicationSupport: support))
    #expect(!LocalWhisperRuntime.checkpointCached(.turbo, applicationSupport: support))
}

@Test("A directory under the checkpoint's name is not a checkpoint; a symlink to a whole one is (F900)")
func onlyARegularFileCounts() throws {
    let support = try temporaryDirectory("F900-kinds")
    defer { try? FileManager.default.removeItem(at: support) }
    let models = LocalWhisperRuntime.modelDirectory(applicationSupport: support)
    let name = LocalWhisperRuntime.checkpointFileName(for: .turbo)
    try FileManager.default.createDirectory(at: models.appendingPathComponent(name), withIntermediateDirectories: true)
    #expect(!LocalWhisperRuntime.checkpointCached(.turbo, applicationSupport: support))
    try FileManager.default.removeItem(at: models.appendingPathComponent(name))

    let elsewhere = try temporaryDirectory("F900-elsewhere")
    defer { try? FileManager.default.removeItem(at: elsewhere) }
    let real = try writeCheckpoint(.turbo, byteCount: LocalWhisperRuntime.checkpointByteCount(for: .turbo), in: elsewhere)
    try FileManager.default.createSymbolicLink(at: models.appendingPathComponent(name), withDestinationURL: real)
    #expect(LocalWhisperRuntime.checkpointCached(.turbo, applicationSupport: support))
}
