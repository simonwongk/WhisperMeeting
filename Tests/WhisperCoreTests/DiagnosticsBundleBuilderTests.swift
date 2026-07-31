import Foundation
import Testing
@testable import WhisperCore

/// F70 — the diagnostics bundle excludes sensitive content and is deterministic.
@Test("Diagnostics bundle excludes transcript/summary/vocabulary and is deterministic JSON")
func diagnosticsBundleExcludesSensitive() {
    let input = DiagnosticsInput(
        meetings: [
            DiagnosticsInput.Meeting(
                id: "m1", createdAtEpoch: 1000, durationSeconds: 120, status: "completed",
                languageCode: "en", segmentCount: 5, markerCount: 2, recordingBytes: 4096,
                errorMessage: nil, transcriptText: "SECRET-TRANSCRIPT", summary: "SECRET-SUMMARY"
            )
        ],
        vocabulary: ["AcmeCorp"]
    )

    let out = DiagnosticsBundleBuilder.json(input)

    // Nothing sensitive leaks.
    #expect(!out.contains("SECRET-TRANSCRIPT"))
    #expect(!out.contains("SECRET-SUMMARY"))
    #expect(!out.contains("AcmeCorp"))

    // Valid JSON.
    #expect((try? JSONSerialization.jsonObject(with: Data(out.utf8))) != nil)

    // Byte-identical across runs on identical input.
    #expect(DiagnosticsBundleBuilder.json(input) == out)

    // Safe structural fields are present.
    #expect(out.contains("\"segmentCount\""))
    #expect(out.contains("\"vocabularyTermCount\""))
    #expect(out.contains("m1"))
}

/// F111 — a meeting whose optional fields are all nil serialises to the documented defaults
/// (`languageCode` "", `recordingBytes` -1, `errorMessage` "", `hasError` false). This locks the
/// nil path the typed-local `??` bindings cover, so the emitted values cannot silently drift when
/// the overload is pinned to the non-optional form.
@Test("Diagnostics bundle encodes nil optionals as the documented defaults")
func diagnosticsBundleNilOptionalsUseDefaults() throws {
    let input = DiagnosticsInput(
        meetings: [
            DiagnosticsInput.Meeting(
                id: "m-nil", createdAtEpoch: 0, durationSeconds: 0, status: "failed",
                languageCode: nil, segmentCount: 0, markerCount: 0, recordingBytes: nil,
                errorMessage: nil, transcriptText: "", summary: nil
            )
        ],
        vocabulary: []
    )

    let out = DiagnosticsBundleBuilder.json(input)
    let root = try #require(
        try JSONSerialization.jsonObject(with: Data(out.utf8)) as? [String: Any]
    )
    let meetings = try #require(root["meetings"] as? [[String: Any]])
    let meeting = try #require(meetings.first)

    #expect(meeting["languageCode"] as? String == "")
    #expect(meeting["errorMessage"] as? String == "")
    #expect(meeting["hasError"] as? Bool == false)
    #expect(meeting["recordingBytes"] as? Int == -1)
}
