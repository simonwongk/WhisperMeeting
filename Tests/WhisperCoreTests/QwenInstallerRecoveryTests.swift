import Foundation
import Testing

@Test("Qwen installer recovery restores a complete backup and removes abandoned artifacts")
func qwenInstallerRecovery() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("WhisperMeetQwenInstallerTests-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)

    let target = root.appendingPathComponent("Qwen3ASR", isDirectory: true)
    let validBackup = root.appendingPathComponent(".Qwen3ASR-backup-111", isDirectory: true)
    let incompleteBackup = root.appendingPathComponent(".Qwen3ASR-backup-222", isDirectory: true)
    let abandonedStage = root.appendingPathComponent(".Qwen3ASR-install-333", isDirectory: true)
    try makeCompleteRuntime(at: validBackup)
    try FileManager.default.createDirectory(at: incompleteBackup, withIntermediateDirectories: true)
    try FileManager.default.createDirectory(at: abandonedStage, withIntermediateDirectories: true)
    try Data("old runtime".utf8).write(to: validBackup.appendingPathComponent("marker"))

    let first = try runRecovery(target: target)
    #expect(first.status == 0, Comment(rawValue: first.output))
    #expect(
        try String(contentsOf: target.appendingPathComponent("marker"), encoding: .utf8)
            == "old runtime"
    )
    #expect(!FileManager.default.fileExists(atPath: incompleteBackup.path))
    #expect(!FileManager.default.fileExists(atPath: abandonedStage.path))

    let staleBackup = root.appendingPathComponent(".Qwen3ASR-backup-444", isDirectory: true)
    let secondStage = root.appendingPathComponent(".Qwen3ASR-install-555", isDirectory: true)
    try makeCompleteRuntime(at: staleBackup)
    try FileManager.default.createDirectory(at: secondStage, withIntermediateDirectories: true)

    let second = try runRecovery(target: target)
    #expect(second.status == 0, Comment(rawValue: second.output))
    #expect(!FileManager.default.fileExists(atPath: staleBackup.path))
    #expect(!FileManager.default.fileExists(atPath: secondStage.path))
    #expect(!FileManager.default.fileExists(
        atPath: root.appendingPathComponent(".Qwen3ASR-install.lock").path
    ))
}

private func makeCompleteRuntime(at directory: URL) throws {
    let python = directory.appendingPathComponent("venv/bin/python")
    let helper = directory.appendingPathComponent("qwen_transcribe.py")
    let model = directory.appendingPathComponent("model/model.safetensors")
    let aligner = directory.appendingPathComponent("aligner/model.safetensors")
    for parent in [
        python.deletingLastPathComponent(),
        model.deletingLastPathComponent(),
        aligner.deletingLastPathComponent(),
    ] {
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
    }
    try Data("#!/bin/zsh\n".utf8).write(to: python)
    try FileManager.default.setAttributes(
        [.posixPermissions: 0o755],
        ofItemAtPath: python.path
    )
    try Data("helper".utf8).write(to: helper)
    try Data("model".utf8).write(to: model)
    try Data("aligner".utf8).write(to: aligner)
}

private func runRecovery(target: URL) throws -> (status: Int32, output: String) {
    let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let script = repository.appendingPathComponent("Scripts/setup-qwen-asr.sh")
    let pipe = Pipe()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/bin/zsh")
    process.arguments = [script.path, target.path]
    var environment = ProcessInfo.processInfo.environment
    environment["QWEN_INSTALL_RECOVERY_ONLY"] = "1"
    process.environment = environment
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (
        process.terminationStatus,
        String(decoding: data, as: UTF8.self)
    )
}
