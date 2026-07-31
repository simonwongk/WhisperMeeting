import Foundation
import Testing
@testable import WhisperCore

/// F25 — the installed dictation helpers must be synced for **every** engine on launch, not only the
/// selected one, using atomic, content-gated writes that are safe against a concurrent writer of the
/// shared runtime directory.
private func makeTempDir() -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("dictation-helper-sync-\(UUID().uuidString)", isDirectory: true)
    try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// The headline F25 assertion: given both engines' helpers, sync updates BOTH — the exact failure the
/// old selected-engine-only sync produced (the non-selected engine's helper stayed stale on disk).
@Test("Both engines' helpers are synced, not just one (F25)")
func dictationHelperSyncUpdatesEveryEngine() throws {
    let root = makeTempDir()
    defer { try? FileManager.default.removeItem(at: root) }

    let whisperScript = root.appendingPathComponent("Runtime/whisper_dictate_server.py")
    let qwenScript = root.appendingPathComponent("Runtime/Qwen3ASR/qwen_dictate_server.py")
    let whisperBundle = Data("print('whisper helper v2')\n".utf8)
    let qwenBundle = Data("print('qwen helper v2')\n".utf8)

    // Neither installed helper exists yet; both runtimes are installed.
    let outcomes = DictationHelperSync.sync([
        .init(name: "whisper_dictate_server", bundledData: whisperBundle,
              installedScript: whisperScript, runtimeInstalled: true),
        .init(name: "qwen_dictate_server", bundledData: qwenBundle,
              installedScript: qwenScript, runtimeInstalled: true),
    ])

    #expect(outcomes == [.synced("whisper_dictate_server"), .synced("qwen_dictate_server")])
    // Both files landed with exactly the bundle bytes — this is the assertion the pre-F25 code failed
    // for whichever engine was not selected.
    #expect(try Data(contentsOf: whisperScript) == whisperBundle)
    #expect(try Data(contentsOf: qwenScript) == qwenBundle)
}

/// A stale helper (older bytes on disk) is overwritten, and — because `.atomic` replaces the file
/// wholesale — a shorter bundle fully replaces a longer stale copy with no trailing remnant.
@Test("A stale helper is atomically and completely replaced (F25)")
func dictationHelperSyncReplacesStaleCompletely() throws {
    let root = makeTempDir()
    defer { try? FileManager.default.removeItem(at: root) }

    let script = root.appendingPathComponent("Runtime/whisper_dictate_server.py")
    try FileManager.default.createDirectory(
        at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
    // Stale on-disk copy is LONGER than the new bundle, so a partial (non-atomic) overwrite would
    // leave trailing bytes.
    try Data("OLD HELPER — much longer stale content that must be fully gone\n".utf8).write(to: script)
    let bundle = Data("new\n".utf8)

    let outcomes = DictationHelperSync.sync([
        .init(name: "whisper_dictate_server", bundledData: bundle,
              installedScript: script, runtimeInstalled: true),
    ])

    #expect(outcomes == [.synced("whisper_dictate_server")])
    #expect(try Data(contentsOf: script) == bundle) // exact bytes, no remnant of the longer stale copy
}

/// Content-gating: when the installed helper already matches the bundle, sync is a no-op — it reports
/// `upToDate` and does not rewrite. This is what makes repeated / overlapping syncs converge cheaply.
@Test("A helper already matching the bundle is left untouched (F25)")
func dictationHelperSyncIsIdempotent() throws {
    let root = makeTempDir()
    defer { try? FileManager.default.removeItem(at: root) }

    let script = root.appendingPathComponent("Runtime/whisper_dictate_server.py")
    try FileManager.default.createDirectory(
        at: script.deletingLastPathComponent(), withIntermediateDirectories: true)
    let bundle = Data("print('already current')\n".utf8)
    try bundle.write(to: script)

    let outcomes = DictationHelperSync.sync([
        .init(name: "whisper_dictate_server", bundledData: bundle,
              installedScript: script, runtimeInstalled: true),
    ])

    #expect(outcomes == [.upToDate("whisper_dictate_server")])
    #expect(try Data(contentsOf: script) == bundle)
}

/// An engine whose runtime is not installed is skipped — nothing is written into a runtime that does
/// not exist yet.
@Test("A helper whose runtime is absent is skipped, not created (F25)")
func dictationHelperSyncSkipsAbsentRuntime() {
    let root = makeTempDir()
    defer { try? FileManager.default.removeItem(at: root) }

    let script = root.appendingPathComponent("Runtime/Qwen3ASR/qwen_dictate_server.py")

    let outcomes = DictationHelperSync.sync([
        .init(name: "qwen_dictate_server", bundledData: Data("helper\n".utf8),
              installedScript: script, runtimeInstalled: false),
    ])

    #expect(outcomes == [.runtimeAbsent("qwen_dictate_server")])
    #expect(!FileManager.default.fileExists(atPath: script.path)) // never created
}

/// A missing bundled copy (a broken build) is reported, not silently written as empty.
@Test("A missing bundled helper is reported without writing (F25)")
func dictationHelperSyncReportsMissingBundle() {
    let root = makeTempDir()
    defer { try? FileManager.default.removeItem(at: root) }

    let script = root.appendingPathComponent("Runtime/whisper_dictate_server.py")

    let outcomes = DictationHelperSync.sync([
        .init(name: "whisper_dictate_server", bundledData: nil,
              installedScript: script, runtimeInstalled: true),
    ])

    #expect(outcomes == [.bundleMissing("whisper_dictate_server")])
    #expect(!FileManager.default.fileExists(atPath: script.path))
}
