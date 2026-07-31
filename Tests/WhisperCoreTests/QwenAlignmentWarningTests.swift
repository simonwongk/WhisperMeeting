import Foundation
import Testing
@testable import WhisperCore

/// F28 — the Qwen alignment warning is surfaced through the result (observable), not hidden in OSLog.
@Test("Qwen alignment warning is observable through the transcription result")
func qwenAlignmentWarningObservable() throws {
    let withWarning = try JSONDecoder().decode(
        QwenOutput.self,
        from: Data(#"{"text":"hello","language":"en","alignedItems":[],"alignmentWarning":"KeyError: text"}"#.utf8)
    )
    let result = QwenASRClient.makeResult(id: "m1", text: "hello", payload: withWarning)
    #expect(result.alignmentWarning?.contains("KeyError: text") == true)

    let clean = try JSONDecoder().decode(
        QwenOutput.self,
        from: Data(#"{"text":"hi","language":"en","alignedItems":[],"alignmentWarning":null}"#.utf8)
    )
    #expect(QwenASRClient.makeResult(id: "m2", text: "hi", payload: clean).alignmentWarning == nil)
}
