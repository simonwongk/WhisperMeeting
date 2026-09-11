import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

/// F207 — the Qwen meeting helper is intentionally syncable even when it is the missing/stale file,
/// but only after the rest of the local runtime is proven complete. This keeps an interrupted install
/// from gaining a misleading standalone script while letting a normal app launch repair F155.

@MainActor
@Test("A complete Qwen runtime atomically receives the bundled meeting helper (F207)")
func completeQwenRuntimeReceivesBundledMeetingHelper() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("QwenMeetingHelperSyncTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let files = FileManager.default
    let bundled = Data("fresh majority-script aligner helper\n".utf8)

    // An incomplete runtime is not touched, even when the bundled app has a newer helper.
    var helper = DictationController.qwenMeetingHelper(
        bundledData: bundled, applicationSupport: root, fileManager: files
    )
    #expect(helper.runtimeInstalled == false)
    #expect(DictationHelperSync.sync([helper], fileManager: files) == [.runtimeAbsent("qwen_transcribe")])
    #expect(!files.fileExists(atPath: helper.installedScript.path))

    let python = QwenASRRuntime.pythonExecutable(applicationSupport: root)
    let model = QwenASRRuntime.modelDirectory(applicationSupport: root)
        .appendingPathComponent("model.safetensors")
    let aligner = QwenASRRuntime.alignerDirectory(applicationSupport: root)
        .appendingPathComponent("model.safetensors")
    try files.createDirectory(at: python.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("python".utf8).write(to: python)
    try files.setAttributes([.posixPermissions: 0o755], ofItemAtPath: python.path)
    try files.createDirectory(at: model.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("model".utf8).write(to: model)
    try files.createDirectory(at: aligner.deletingLastPathComponent(), withIntermediateDirectories: true)
    try Data("aligner".utf8).write(to: aligner)

    helper = DictationController.qwenMeetingHelper(
        bundledData: bundled, applicationSupport: root, fileManager: files
    )
    #expect(helper.runtimeInstalled == true)
    try files.createDirectory(
        at: helper.installedScript.deletingLastPathComponent(), withIntermediateDirectories: true
    )
    try Data("old any-CJK aligner helper\n".utf8).write(to: helper.installedScript)

    #expect(DictationHelperSync.sync([helper], fileManager: files) == [.synced("qwen_transcribe")])
    #expect(try Data(contentsOf: helper.installedScript) == bundled)
}
