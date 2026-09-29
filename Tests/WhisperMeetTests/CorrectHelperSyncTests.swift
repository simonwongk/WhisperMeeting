import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

/// F643 — `correct_local.py` is the one runtime helper `ensureHelperInstalled()` did not sync: the
/// dictation servers, `refine_server.py`, `summarize_local.py` and `qwen_transcribe.py` all ride the
/// F25 launch sync so a shipped fix reaches an existing install without a Repair, but the F165
/// correction helper had no `Helper` entry at all. Same shape as F512's summary-helper fix: same
/// runtime prerequisites (interpreter + model present, so an interrupted install never gains a lone
/// script) as `summarizeHelper`, since correction shares the summarizer's runtime.

@MainActor
@Test("A complete summarizer runtime receives the bundled correction helper, a partial one does not (F643)")
func completeSummarizerRuntimeReceivesBundledCorrectionHelper() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("CorrectHelperSyncTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let files = FileManager.default
    let bundled = Data("helper that pre-flights context and refuses truncated output\n".utf8)

    let python = SummarizerRuntime.pythonExecutable(applicationSupport: root)
    try files.createDirectory(at: python.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("python".utf8).write(to: python)
    try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)

    // An interpreter with no model is an interrupted install: no helper is planted in it.
    var helper = DictationController.correctHelper(bundledData: bundled, applicationSupport: root, fileManager: files)
    #expect(helper.installedScript == SummarizerRuntime.correctionHelperScript(applicationSupport: root))
    #expect(DictationHelperSync.sync([helper], fileManager: files) == [.runtimeAbsent("correct_local")])
    #expect(!files.fileExists(atPath: helper.installedScript.path))

    let model = SummarizerRuntime.modelDirectory(applicationSupport: root).appendingPathComponent("model.safetensors")
    try files.createDirectory(at: model.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("weights".utf8).write(to: model)
    try Data("old helper that returns [] on a degraded pass\n".utf8).write(to: helper.installedScript)

    helper = DictationController.correctHelper(bundledData: bundled, applicationSupport: root, fileManager: files)
    #expect(DictationHelperSync.sync([helper], fileManager: files) == [.synced("correct_local")])
    #expect(try Data(contentsOf: helper.installedScript) == bundled)
    // An unchanged copy is not rewritten, so a launch on an already-current install does nothing.
    #expect(DictationHelperSync.sync([helper], fileManager: files) == [.upToDate("correct_local")])
}

// Mirrors `launchSyncIncludesTheSummaryHelper` (F512): the sync runs from a controller this target
// cannot start, so the launch list is asserted against the source, comments stripped (F306, F285).
@Test("The launch helper sync includes the correction helper (F643)")
func launchSyncIncludesTheCorrectionHelper() throws {
    let dictation = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/Dictation/DictationController.swift")
    let helperIsSynced = dictation.contains("helpers.append(Self.bundledCorrectHelper(fileManager: files))")
    #expect(helperIsSynced)
}
