import Foundation
import Testing
@testable import WhisperCore

// F141 — the diagnostics bundle promises no absolute paths, but a raw errorMessage can carry them
// (Qwen traceback, afconvert stderr, recovery text). They must be redacted before export.
@Test("Diagnostics JSON redacts absolute paths from error messages (F141)")
func diagnosticsRedactsAbsolutePaths() {
    let meeting = DiagnosticsInput.Meeting(
        id: "m1", createdAtEpoch: 0, durationSeconds: 10, status: "failed",
        languageCode: "en", segmentCount: 0, markerCount: 0, recordingBytes: 100,
        errorMessage: "Qwen failed loading /Users/simon/Library/Application Support/WhisperMeet/Runtime/x.py at line 5",
        transcriptText: "", summary: nil
    )
    let json = DiagnosticsBundleBuilder.json(DiagnosticsInput(meetings: [meeting], vocabulary: []))

    #expect(!json.contains("/Users/simon"))          // no home/absolute path leaks
    #expect(!json.contains("/Library/Application Support"))
    #expect(json.contains("Qwen failed loading"))    // the non-path message text is preserved
}

@Test("Path redaction leaves non-path text intact (F141)")
func redactPathsKeepsPlainText() {
    #expect(DiagnosticsBundleBuilder.redactPaths("ratio 3/4 and read/write ok") == "ratio 3/4 and read/write ok")
    #expect(DiagnosticsBundleBuilder.redactPaths("at /var/folders/tmp/abc.wav done").contains("/var/folders") == false)
}
