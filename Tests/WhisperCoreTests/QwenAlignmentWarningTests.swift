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

    // A cleanly aligned payload (word timings that reconcile with the text) carries no warning. The
    // aligned items are required: a transcript that ends up with no timestamps is itself warned about
    // (F30), so "no warning" only holds when alignment actually succeeded.
    let clean = try JSONDecoder().decode(
        QwenOutput.self,
        from: Data(#"{"text":"hi","language":"en","alignedItems":[{"text":"hi","start":0.0,"end":0.3}],"alignmentWarning":null}"#.utf8)
    )
    #expect(QwenASRClient.makeResult(id: "m2", text: "hi", payload: clean).alignmentWarning == nil)
}
