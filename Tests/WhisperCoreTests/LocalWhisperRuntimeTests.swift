import Testing
import Foundation
@testable import WhisperCore

@Test("mlxModelCached reflects a complete MLX snapshot, not just the repo directory")
func mlxModelCachedChecksSnapshot() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("MLXCacheCheck-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let repo = "mlx-community/whisper-large-v3-turbo"
    let snapshot = LocalWhisperRuntime.modelDirectory(applicationSupport: root)
        .appendingPathComponent("hf/hub/models--mlx-community--whisper-large-v3-turbo/snapshots/abc123", isDirectory: true)

    // Nothing downloaded yet.
    #expect(!LocalWhisperRuntime.mlxModelCached(applicationSupport: root, mlxRepo: repo))

    // Directory tree exists (as huggingface_hub creates it at the start of a download) but the
    // weights haven't landed — must still read as not cached.
    try FileManager.default.createDirectory(at: snapshot, withIntermediateDirectories: true)
    try Data().write(to: snapshot.appendingPathComponent("config.json"))
    #expect(!LocalWhisperRuntime.mlxModelCached(applicationSupport: root, mlxRepo: repo))

    // Complete snapshot: weights + config present.
    try Data().write(to: snapshot.appendingPathComponent("weights.safetensors"))
    #expect(LocalWhisperRuntime.mlxModelCached(applicationSupport: root, mlxRepo: repo))
}
