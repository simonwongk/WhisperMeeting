import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

/// F512 — the summary helper's stall timeout relies on heartbeat lines only the new helper prints, so
/// an existing install has to receive it at launch the way the refine and Qwen meeting helpers do —
/// and, like the Qwen one (F207), only into a runtime that is otherwise complete.

@MainActor
@Test("A complete summarizer runtime receives the bundled summary helper, a partial one does not (F512)")
func completeSummarizerRuntimeReceivesBundledHelper() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("SummarizeHelperSyncTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let files = FileManager.default
    let bundled = Data("helper that reports every prompt chunk\n".utf8)

    let python = SummarizerRuntime.pythonExecutable(applicationSupport: root)
    try files.createDirectory(at: python.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("python".utf8).write(to: python)
    try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)

    // An interpreter with no model is an interrupted install: no helper is planted in it.
    var helper = DictationController.summarizeHelper(bundledData: bundled, applicationSupport: root, fileManager: files)
    #expect(helper.installedScript == SummarizerRuntime.helperScript(applicationSupport: root))
    #expect(DictationHelperSync.sync([helper], fileManager: files) == [.runtimeAbsent("summarize_local")])
    #expect(!files.fileExists(atPath: helper.installedScript.path))

    let model = SummarizerRuntime.modelDirectory(applicationSupport: root).appendingPathComponent("model.safetensors")
    try files.createDirectory(at: model.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("weights".utf8).write(to: model)
    try Data("old helper that is silent until it generates\n".utf8).write(to: helper.installedScript)

    helper = DictationController.summarizeHelper(bundledData: bundled, applicationSupport: root, fileManager: files)
    #expect(DictationHelperSync.sync([helper], fileManager: files) == [.synced("summarize_local")])
    #expect(try Data(contentsOf: helper.installedScript) == bundled)
    #expect(SummarizerRuntime.isInstalled(applicationSupport: root))
}

// The heartbeat the stall timeout relies on reaches an existing install only through the launch
// helper sync — `setup-local-summarizer.sh` is otherwise the only thing that writes the helper. The
// sync runs from a controller this target cannot start, so the source is asserted, comments
// stripped (F306, F285).
@Test("The launch helper sync includes the summary helper (F512)")
func launchSyncIncludesTheSummaryHelper() throws {
    let dictation = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/Dictation/DictationController.swift")
    let helperIsSynced = dictation.contains("helpers.append(Self.bundledSummarizeHelper(fileManager: files))")
    #expect(helperIsSynced)
}
