import Foundation
import Testing
@testable import WhisperCore

// F624 — F511 caps what a failed transcription says to the last lines of its helper's log; the rest
// was lost. Given `failureLogURL`, each client writes the whole log it kept there before it throws,
// on both failure shapes: a non-zero exit, and openai-whisper's usual one, exit 0 with no output.

private func scratch(_ label: String) throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent("\(label)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func executable(_ url: URL, _ script: String) throws {
    try Data(script.utf8).write(to: url)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
}

/// About 60 KB: a first line, a wall of progress noise, and the one line that matters at the end.
private let noisyFailure = """
print 'FIRST LINE of the log'
for i in {1..2000}; do print 'Downloading: 3%|##      | 30M/1.0G'; done
print 'Skipping meeting.wav due to RuntimeError: out of memory'
"""

@Test("Whisper's exit-0-no-output failure writes its whole log beside the meeting, and still says only the tail (F624)")
func whisperMissingOutputWritesTheWholeLog() async throws {
    let dir = try scratch("F624-whisper"); defer { try? FileManager.default.removeItem(at: dir) }
    let whisper = dir.appendingPathComponent("whisper")
    try executable(whisper, "#!/bin/zsh\n\(noisyFailure)\nexit 0\n")
    let audio = dir.appendingPathComponent("meeting.wav")
    try shortReadableWAV().write(to: audio)
    let logURL = dir.appendingPathComponent(TranscriptionFailureLog.fileName)
    var client = LocalWhisperClient(executableURL: whisper, modelDirectory: dir.appendingPathComponent("models"),
                                    scratchDirectory: dir.appendingPathComponent("runs")) // F937
    client.failureLogURL = logURL

    do {
        _ = try await client.transcribe(recordingAt: audio)
        Issue.record("expected the missing-output failure")
    } catch let LocalWhisperError.processFailed(message) {
        #expect(message.count < 4_500, "the message is still the capped summary")
        #expect(!message.contains("FIRST LINE"))
    }
    let log = try String(contentsOf: logURL, encoding: .utf8)
    #expect(log.hasPrefix("FIRST LINE of the log"), "the log is not whole")
    #expect(log.hasSuffix("out of memory"))
    #expect(log.count > 50_000)
}

@Test("Whisper's non-zero exit writes its whole log, and with no log URL nothing is written (F624)")
func whisperNonZeroExitWritesTheWholeLog() async throws {
    let dir = try scratch("F624-exit"); defer { try? FileManager.default.removeItem(at: dir) }
    let whisper = dir.appendingPathComponent("whisper")
    try executable(whisper, "#!/bin/zsh\n\(noisyFailure)\nexit 3\n")
    let audio = dir.appendingPathComponent("meeting.wav")
    try shortReadableWAV().write(to: audio)
    let logURL = dir.appendingPathComponent(TranscriptionFailureLog.fileName)
    var client = LocalWhisperClient(executableURL: whisper, modelDirectory: dir.appendingPathComponent("models"),
                                    scratchDirectory: dir.appendingPathComponent("runs")) // F937

    await #expect(throws: LocalWhisperError.self) { try await client.transcribe(recordingAt: audio) }
    #expect(!FileManager.default.fileExists(atPath: logURL.path), "a log was written with no URL given")

    client.failureLogURL = logURL
    await #expect(throws: LocalWhisperError.self) { try await client.transcribe(recordingAt: audio) }
    let log = try String(contentsOf: logURL, encoding: .utf8)
    #expect(log.hasPrefix("FIRST LINE of the log") && log.hasSuffix("out of memory"))
}

@Test("Qwen's failures write the whole helper log too (F624)")
func qwenFailureWritesTheWholeLog() async throws {
    let dir = try scratch("F624-qwen"); defer { try? FileManager.default.removeItem(at: dir) }
    let python = dir.appendingPathComponent("python")
    try executable(python, "#!/bin/zsh\n\(noisyFailure)\nexit 0\n")
    let helper = dir.appendingPathComponent("qwen_transcribe.py")
    try Data("helper".utf8).write(to: helper)
    for model in ["model", "aligner"] {
        let folder = dir.appendingPathComponent(model, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        try Data("weights".utf8).write(to: folder.appendingPathComponent("model.safetensors"))
    }
    let audio = dir.appendingPathComponent("meeting.wav")
    try shortReadableWAV().write(to: audio)
    let logURL = dir.appendingPathComponent(TranscriptionFailureLog.fileName)
    var client = QwenASRClient(pythonExecutableURL: python, helperScriptURL: helper,
                               modelDirectory: dir.appendingPathComponent("model"),
                               alignerDirectory: dir.appendingPathComponent("aligner"))
    client.failureLogURL = logURL

    await #expect(throws: QwenASRError.self) { try await client.transcribe(recordingAt: audio) }

    let log = try String(contentsOf: logURL, encoding: .utf8)
    #expect(log.hasPrefix("FIRST LINE of the log") && log.hasSuffix("out of memory"))
}

@Test("An empty log or no URL writes nothing; a new log replaces the old (F624)")
func failureLogWriteRules() throws {
    let dir = try scratch("F624-write"); defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent(TranscriptionFailureLog.fileName)
    #expect(!TranscriptionFailureLog.write("", to: url))
    #expect(!TranscriptionFailureLog.write("log", to: nil))
    #expect(!FileManager.default.fileExists(atPath: url.path))
    #expect(TranscriptionFailureLog.write("first", to: url))
    #expect(TranscriptionFailureLog.write("second", to: url))
    #expect(try String(contentsOf: url, encoding: .utf8) == "second")
}
