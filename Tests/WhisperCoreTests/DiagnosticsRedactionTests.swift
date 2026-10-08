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

// MARK: - F791: a path with a space or a non-ASCII name

// The F141 pattern recognised only ASCII components with no space, so it redacted the front of a
// path and left its tail: "/Users/jane/Movies/会议记录/季度规划会议.mov" became
// "<path>/会议记录/季度规划会议.mov", and a path under "Application Support" became
// "<path> Support<path> Meeting Q3.m4a". A file name can be a meeting title, and this text reaches
// the diagnostics bundle (F70) and `.public` log lines (F154, F391). CrashReportDigest had already
// been fixed for its own free text (F389); its other three consumers had not.

/// Every fragment of the fixtures' paths. None may survive redaction, and neither may a `/`.
private let f791Fragments = [
    "jane", "Movies", "会议记录", "季度规划会议", "Library", "Application", "Support", "WhisperMeet/",
    "Recordings", "Board", "Meeting", "Q3", "Desktop", "Acme", "Merger", "Call", "Volumes", "Client",
    "Share", "Documents", "Review", ".mov", ".m4a", ".wav", "%20",
]

/// The paths that went through the old pattern partly or wholly unredacted. Each is a file the
/// import path could name: a CJK title, a library path under "Application Support", a `~/` path,
/// an external volume and a `file:` URL.
private let f791Paths = [
    "/Users/jane/Movies/会议记录/季度规划会议.mov",
    "/Users/jane/Library/Application Support/WhisperMeet/Recordings/Board Meeting Q3.m4a",
    "~/Desktop/Acme Merger Call.wav",
    "/Volumes/Client Share/Acme/Q3 Board.wav",
    "file:///Users/jane/Documents/Acme%20Merger%20Call.wav",
]

private func f791Leaks(in text: String) -> [String] {
    (f791Fragments + ["/"]).filter { text.contains($0) }
}

@Test("A path with a space or a non-ASCII name leaves no segment in the bundle or the public log (F791)")
func redactionLeavesNoSegmentOfASpacedOrNonASCIIPath() {
    for path in f791Paths {
        let message = "Could not import \(path): the file is not playable."

        let meeting = DiagnosticsInput.Meeting(
            id: "m1", createdAtEpoch: 0, durationSeconds: 10, status: "failed",
            languageCode: "en", segmentCount: 0, markerCount: 0, recordingBytes: 100,
            errorMessage: message, transcriptText: "", summary: nil
        )
        let json = DiagnosticsBundleBuilder.json(DiagnosticsInput(meetings: [meeting], vocabulary: []))
        let error = NSError(domain: "Import", code: 1, userInfo: [NSLocalizedDescriptionKey: message])
        let log = DiagnosticsBundleBuilder.publicLogDescription(error)
        let diagnostic = ErrorPresentation.diagnostic(for: LocalWhisperError.processFailed(message))

        // The JSON escapes `/` as `\/`, so its leak check looks for the fragments only.
        #expect(f791Leaks(in: json).filter { $0 != "/" } == [], "bundle errorMessage from \(path): \(json)")
        #expect(f791Leaks(in: log) == [], "public log from \(path): \(log)")
        #expect(f791Leaks(in: diagnostic) == [], "diagnostic from \(path): \(diagnostic)")
        // A path that ends in a name it recognises is replaced alone, so the reason survives.
        #expect(log == "Could not import <path>: the file is not playable.", "\(log)")
    }
}

@Test("A path whose end cannot be recognised takes the rest of its line with it (F791)")
func redactionCutsAnUnrecognisedPathToTheEndOfItsLine() {
    // A folder has no extension, so nothing says whether "Review: permission denied" is the rest of
    // its name. Fail closed: everything from the path to the end of the line goes.
    #expect(
        DiagnosticsBundleBuilder.redactPaths("Could not create /Users/jane/Meetings/Q3 Board Review: permission denied")
            == "Could not create <path>…"
    )
    // A later `/` on the line means a name ending in a known extension may still be a folder in the
    // middle of a longer path, so that end is not trusted either.
    #expect(
        DiagnosticsBundleBuilder.redactPaths("/Users/jane/Board.wav notes/Q3 Merger Call is 3/4 done")
            == "<path>…"
    )
    // The cut stops at the line: the next line is judged on its own.
    #expect(
        DiagnosticsBundleBuilder.redactPaths("Could not create /Users/jane/Q3 Board Review\nRuntimeError: denied")
            == "Could not create <path>…\nRuntimeError: denied"
    )
}

@Test("A traceback keeps its line numbers and its final error while losing every path (F791)")
func redactionKeepsATracebackReadable() {
    let traceback = """
    Traceback (most recent call last):
      File "/Users/jane/Library/Application Support/WhisperMeet/Runtime/Qwen3ASR/venv/lib/python3.11/site-packages/mlx_audio/stt/generate.py", line 12, in <module>
      File "/Users/jane/Movies/会议记录/季度规划会议.py", line 3, in load
    RuntimeError: model missing
    """
    let redacted = DiagnosticsBundleBuilder.redactPaths(traceback)
    #expect(redacted == """
    Traceback (most recent call last):
      File "<path>", line 12, in <module>
      File "<path>", line 3, in load
    RuntimeError: model missing
    """, "\(redacted)")
}
