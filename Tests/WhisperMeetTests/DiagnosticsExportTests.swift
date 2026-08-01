import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F86 — the diagnostics export maps a live meeting into the privacy-safe DiagnosticsInput (delivers
// F70). The risk this guards is a mapping that routes any sensitive value — transcript, summary,
// vocabulary term, title, or an absolute path — into a STRUCTURAL field the bundle emits. Structural
// metadata must be present and correct; no sensitive value may appear in the emitted JSON.
@Test("Diagnostics export emits structural metadata but never transcript, summary, vocabulary, title, or paths (F86)")
func diagnosticsExportExcludesSensitiveData() throws {
    let meeting = MeetingRecord(
        title: "SENTINEL_TITLE",
        duration: 92,
        recordingPath: "/Users/simon/Library/Application Support/WhisperMeet/SENTINEL_PATH/meeting.wav",
        status: .completed,
        transcriptText: "SENTINEL_TRANSCRIPT",
        languageCode: "en",
        segments: [TranscriptSegment(speaker: nil, start: 0, end: 1, text: "one")],
        errorMessage: nil,
        summary: MeetingSummary(
            summary: "SENTINEL_SUMMARY",
            keyPoints: ["SENTINEL_KEYPOINT"],
            actionItems: ["SENTINEL_ACTION"]
        ),
        markers: [RecordingMarker(offset: 5), RecordingMarker(offset: 10)]
    )

    let input = DiagnosticsExport.input(
        meetings: [meeting],
        vocabulary: ["SENTINEL_VOCAB"],
        recordingBytes: { _ in 4096 }
    )
    let json = DiagnosticsBundleBuilder.json(input)

    // Structural metadata present and correct.
    let root = try JSONSerialization.jsonObject(with: Data(json.utf8)) as! [String: Any]
    #expect(root["meetingCount"] as? Int == 1)
    #expect(root["vocabularyTermCount"] as? Int == 1)
    let entry = try #require((root["meetings"] as? [[String: Any]])?.first)
    #expect(entry["id"] as? String == meeting.id.uuidString)
    #expect(entry["status"] as? String == "completed")
    #expect(entry["segmentCount"] as? Int == 1)
    #expect(entry["markerCount"] as? Int == 2)
    #expect((entry["recordingBytes"] as? NSNumber)?.int64Value == 4096)

    // No sensitive value leaks into the emitted JSON.
    for sentinel in ["SENTINEL_TRANSCRIPT", "SENTINEL_SUMMARY", "SENTINEL_KEYPOINT",
                     "SENTINEL_ACTION", "SENTINEL_VOCAB", "SENTINEL_TITLE", "SENTINEL_PATH"] {
        #expect(!json.contains(sentinel), "\(sentinel) leaked into the diagnostics JSON")
    }
}
