import Foundation
import Testing
@testable import WhisperCore

@Test("The refine helper lives beside the other summarizer helpers")
func refineHelperPath() {
    let root = URL(fileURLWithPath: "/tmp/AppSupport")
    #expect(SummarizerRuntime.refineHelperScript(applicationSupport: root).path
        .hasSuffix("WhisperMeet/Runtime/Summarizer/refine_server.py"))
}

@Test("isRefineHelperInstalled requires the base install AND refine_server.py")
func refineHelperInstallCheck() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("SummarizerRuntimeRefineTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let dir = SummarizerRuntime.managedDirectory(applicationSupport: root)
    try FileManager.default.createDirectory(
        at: dir.appendingPathComponent("venv/bin"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: dir.appendingPathComponent("model"), withIntermediateDirectories: true)
    let python = dir.appendingPathComponent("venv/bin/python")
    FileManager.default.createFile(atPath: python.path, contents: Data("#!/bin/sh\n".utf8),
                                   attributes: [.posixPermissions: 0o755])
    FileManager.default.createFile(
        atPath: dir.appendingPathComponent("summarize_local.py").path, contents: Data())
    FileManager.default.createFile(
        atPath: dir.appendingPathComponent("model/model.safetensors").path, contents: Data())
    #expect(SummarizerRuntime.isInstalled(applicationSupport: root))
    #expect(!SummarizerRuntime.isRefineHelperInstalled(applicationSupport: root))
    FileManager.default.createFile(
        atPath: dir.appendingPathComponent("refine_server.py").path, contents: Data())
    #expect(SummarizerRuntime.isRefineHelperInstalled(applicationSupport: root))
}
