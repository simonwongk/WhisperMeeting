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

/// The regression guard for F25's *actual* bug site: the sync plan must be derived from every engine
/// case, never the selected engine. Filtering it to one engine (the pre-fix behaviour) drops a case
/// and fails here.
@Test("The installed-helper plan covers every dictation engine (F25)")
func installedHelperPlanCoversEveryEngine() {
    let root = makeTempDir()
    defer { try? FileManager.default.removeItem(at: root) }

    let plan = DictationHelperSync.installedHelperPlan(applicationSupport: root)

    #expect(Set(plan.map(\.engine)) == Set(DictationTranscriptionEngine.allCases))
    #expect(plan.count == DictationTranscriptionEngine.allCases.count)
    #expect(Set(plan.map(\.installedScript)).count == plan.count) // no two engines collide on a path
    for location in plan {
        // Paths resolve under the injected support root, and each carries a bundled resource name.
        #expect(location.installedScript.path.hasPrefix(root.path))
        #expect(location.pythonExecutable.path.hasPrefix(root.path))
        #expect(!location.resource.isEmpty)
    }
}

/// End-to-end through the tested plan: with every engine's runtime "installed" under a temp support
/// root and every helper stale, syncing the plan updates BOTH — the ticket's verification ("the
/// runtime copy matches the bundle after launch, without switching engines") expressed without a GUI
/// or the real install.
@Test("Syncing the whole plan updates every installed engine's helper (F25)")
func syncingTheWholePlanUpdatesEveryEngine() throws {
    let root = makeTempDir()
    defer { try? FileManager.default.removeItem(at: root) }
    let files = FileManager.default

    let plan = DictationHelperSync.installedHelperPlan(applicationSupport: root)
    var bundles: [String: Data] = [:]
    for location in plan {
        // Mark this engine's runtime installed (python marker) and drop a stale helper beside it.
        try files.createDirectory(
            at: location.pythonExecutable.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("python".utf8).write(to: location.pythonExecutable)
        try files.createDirectory(
            at: location.installedScript.deletingLastPathComponent(), withIntermediateDirectories: true)
        try Data("STALE \(location.resource)\n".utf8).write(to: location.installedScript)
        bundles[location.resource] = Data("FRESH \(location.resource)\n".utf8)
    }

    let helpers = plan.map { location in
        DictationHelperSync.Helper(
            name: location.resource,
            bundledData: bundles[location.resource],
            installedScript: location.installedScript,
            runtimeInstalled: files.fileExists(atPath: location.pythonExecutable.path)
        )
    }
    let outcomes = DictationHelperSync.sync(helpers, fileManager: files)

    #expect(outcomes.allSatisfy { if case .synced = $0 { return true } else { return false } })
    #expect(outcomes.count == plan.count)
    for location in plan { // every engine's helper now matches its bundle — none left stale
        #expect(try Data(contentsOf: location.installedScript) == bundles[location.resource])
    }
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
