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
        // F896: the reason after the path goes with it. A name can go on past a known extension
        // ("notes.txt draft", "Q3.wav, final"), so only a closing quote or the end of the line now
        // ends a path there — this message has neither after the name.
        #expect(log == "Could not import <path>…", "\(log)")
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

// MARK: - F791 review: two ways a path still got past the scanner

@Test("A known extension followed by punctuation does not end a path that goes on (F791)")
func redactionPunctuationAfterAnExtensionStillChecksForALaterSlash() {
    // The whitespace case already refused to end at an extension with a later `/` on the line; the
    // punctuation case did not, so a folder whose name holds ".wav," leaked every name after it.
    // F896 widened the cut: punctuation and whitespace after an extension no longer end a path at
    // all, so the trailing words go too. What these pin is still that no later name leaks.
    #expect(DiagnosticsBundleBuilder.redactPaths("open /Users/jane/Q3.wav, notes/Board Meeting Q3.wav: denied")
            == "open <path>…")
    #expect(DiagnosticsBundleBuilder.redactPaths("open /Users/jane/Q3.wav: Board Meeting Q3/x.wav: denied")
            == "open <path>…")
    #expect(DiagnosticsBundleBuilder.redactPaths("open /Users/jane/Q3 (draft.txt)/Board Meeting.wav failed")
            == "open <path>…")
}

@Test("An absolute path whose first folder has a space, or with one slash, is a path too (F791)")
func redactionCatchesAbsolutePathsTheTwoComponentRuleMissed() {
    // A path started only at a `/` followed by a space-free component and another `/`, so these
    // were never seen at all, by this scanner or by the F141 pattern before it.
    // (F896: ": denied" no longer survives either — see redactionEndsAPathOnlyAtAQuoteOrTheLineEnd.)
    #expect(DiagnosticsBundleBuilder.redactPaths("Could not open /My Files/Board Q3/x.wav: denied")
            == "Could not open <path>…")
    #expect(DiagnosticsBundleBuilder.redactPaths("Could not open /Board Q3 Review.wav: denied")
            == "Could not open <path>…")
    // Still not paths: a `/` inside a word, and one followed by a space.
    for text in ["ratio 3/4 and read/write ok", "50%| 5/10 [00:01<00:01, 3.2it/s]", "and/or", "a / b"] {
        #expect(DiagnosticsBundleBuilder.redactPaths(text) == text)
    }
}

// MARK: - F896: a name that contains a known extension mid-name

@Test("A known extension ends a path only before a closing quote or the end of the line, so a name that goes on past one leaks nothing (F896)")
func redactionEndsAPathOnlyAtAQuoteOrTheLineEnd() {
    // F791 ended a path at a known extension followed by whitespace or punctuation; a name can hold
    // either ("notes.txt draft", "Q3.wav, final"), so the rest of the name reached the log.
    #expect(DiagnosticsBundleBuilder.redactPaths("Could not open /Users/jane/notes.txt draft: denied")
            == "Could not open <path>…")
    #expect(DiagnosticsBundleBuilder.redactPaths("Could not open /Users/jane/Q3.wav, final: denied")
            == "Could not open <path>…")
    #expect(DiagnosticsBundleBuilder.redactPaths("Could not open /Users/jane/Q3.wav.")
            == "Could not open <path>")
    // What still ends a path: a closing quote — a traceback's or Foundation's quoted path, also as
    // the escaped quote of a `String(describing:)` payload — and the end of the line.
    #expect(DiagnosticsBundleBuilder.redactPaths(#"  File "/Users/jane/notes.txt draft.py", line 3"#)
            == #"  File "<path>", line 3"#)
    #expect(DiagnosticsBundleBuilder.redactPaths(#"Error: \"/Users/jane/Q3.wav\" is missing"#)
            == #"Error: \"<path>\" is missing"#)
    #expect(DiagnosticsBundleBuilder.redactPaths("open /Users/jane/Q3.wav") == "open <path>")
}

@Test("A path after a backtick or an arrow is a path, and a backticked path ends at its backtick (F896)")
func redactionSeesAPathAfterABacktickOrAnArrow() {
    // Neither was a word break, so an absolute path whose first folder holds a space was not seen at
    // all after one (the F896 review's probes), and a backticked path lost its opening backtick.
    #expect(DiagnosticsBundleBuilder.redactPaths("see `/My Files/Q3.wav` now") == "see `<path>` now")
    #expect(DiagnosticsBundleBuilder.redactPaths("see `/Users/jane/Q3.wav` now") == "see `<path>` now")
    #expect(DiagnosticsBundleBuilder.redactPaths("stage →/My Files/Q3.wav now") == "stage →<path>…")
}
