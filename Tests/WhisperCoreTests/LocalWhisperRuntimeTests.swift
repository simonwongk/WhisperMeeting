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

// F509: a Homebrew or pipx `whisper` older than openai-whisper 20250625 has no
// `--carry_initial_prompt` flag, and `findExecutable()` accepts it with no version check at all.

@Test("supportsCarryInitialPrompt is true for a --help that lists the flag")
func supportsCarryInitialPromptTrueWhenHelpListsFlag() throws {
    let executable = try makeStubWhisper(helpText: "usage: whisper [-h] ... --carry_initial_prompt CARRY_INITIAL_PROMPT")
    defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
    #expect(LocalWhisperRuntime.supportsCarryInitialPrompt(at: executable))
}

@Test("supportsCarryInitialPrompt is false for a --help that predates the flag")
func supportsCarryInitialPromptFalseForOlderRuntime() throws {
    // A real, shortened excerpt of what a pre-20250625 openai-whisper --help prints: every other
    // flag `commandArguments` uses, but not this one.
    let executable = try makeStubWhisper(helpText: """
    usage: whisper [-h] [--model MODEL] [--model_dir MODEL_DIR] [--output_dir OUTPUT_DIR]
                    [--output_format {txt,vtt,srt,tsv,json,all}] [--task {transcribe,translate}]
                    [--language ...] [--temperature TEMPERATURE] [--fp16 FP16]
                    audio [audio ...]
    """)
    defer { try? FileManager.default.removeItem(at: executable.deletingLastPathComponent()) }
    #expect(!LocalWhisperRuntime.supportsCarryInitialPrompt(at: executable))
}

@Test("supportsCarryInitialPrompt is false for a missing executable")
func supportsCarryInitialPromptFalseWhenMissing() {
    let missing = FileManager.default.temporaryDirectory
        .appendingPathComponent("LocalWhisperRuntimeTests-missing-\(UUID().uuidString)")
    #expect(!LocalWhisperRuntime.supportsCarryInitialPrompt(at: missing))
}

private func makeStubWhisper(helpText: String) throws -> URL {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("LocalWhisperRuntimeTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    let executable = directory.appendingPathComponent("whisper")
    let script = "#!/bin/zsh\ncat <<'HELP'\n\(helpText)\nHELP\nexit 0\n"
    try Data(script.utf8).write(to: executable)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: executable.path)
    return executable
}
