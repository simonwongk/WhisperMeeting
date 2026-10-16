import Foundation
import Testing
@testable import WhisperCore

// F762 — a Qwen dictation reply cut short by F607's deadline or F431's 768-token cap looked complete:
// the helper's reply had no field for it, so the app pasted a fragment and logged nothing. The helper
// now sends `truncated` (Scripts/tests/test_qwen_dictate_server.py pins when), and the warm engine
// carries it out to the controller, which logs it. Absent — every older helper, and the Whisper
// helper — reads as not cut.

/// A helper that answers every request with `reply`, the way both real helpers frame theirs.
private func helper(replying reply: String, in directory: URL) throws -> URL {
    let script = directory.appendingPathComponent("reply.sh")
    try """
    printf '{"ready":true}\\n'
    while IFS= read -r request; do
      printf '%s\\n' '\(reply)'
    done
    """.write(to: script, atomically: true, encoding: .utf8)
    return script
}

@Test("A reply the helper says it cut short reaches the app as cut, and one without the field as not cut (F762)")
func aTruncatedReplyIsCarriedOutOfTheWarmEngine() async throws {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("F762-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    let replies: [(reply: String, truncated: Bool)] = [
        (#"{"text":"我们的这个 Rem Let 这个","language":null,"error":null,"noSpeechProb":null,"truncated":true}"#, true),
        (#"{"text":"all of it","language":null,"error":null,"noSpeechProb":null,"truncated":false}"#, false),
        (#"{"text":"an older helper","language":null,"error":null}"#, false),
    ]
    for (index, expected) in replies.enumerated() {
        let folder = tmp.appendingPathComponent("\(index)", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let engine = WarmWhisperDictationEngine(
            python: URL(fileURLWithPath: "/bin/sh"),
            script: try helper(replying: expected.reply, in: folder),
            modelDirectory: folder
        )
        defer { engine.shutdown() }
        let result = try await engine.transcribe(
            wavAt: folder.appendingPathComponent("clip.wav"), language: .automatic, initialPrompt: nil
        )
        #expect(result.truncated == expected.truncated, "\(expected.reply)")
    }
}

@Test("The truncated field decodes leniently: absent is nil, never a decode failure (F762)")
func theTruncatedFieldDecodesLeniently() throws {
    let absent = try DictationWireProtocol.decodeResponse(
        line: Data(#"{"text":"hi","language":null,"error":null}"#.utf8))
    #expect(absent.truncated == nil)
    let present = try DictationWireProtocol.decodeResponse(
        line: Data(#"{"text":"hi","language":null,"error":null,"truncated":true}"#.utf8))
    #expect(present.truncated == true)
}
