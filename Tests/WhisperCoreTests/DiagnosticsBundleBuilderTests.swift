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
