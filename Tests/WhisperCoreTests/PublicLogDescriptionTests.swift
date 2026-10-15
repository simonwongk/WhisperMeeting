import Foundation
import Testing
@testable import WhisperCore

// F154 — the one named entry point for error text destined for the unified system log: always
// path-redacted, so `.public` OSLog interpolations can never leak absolute paths.

@Test("Public log description strips absolute paths from a file-error description")
func publicLogDescriptionRedactsPaths() {
    let error = NSError(
        domain: NSCocoaErrorDomain,
        code: NSFileReadNoSuchFileError,
        userInfo: [
            NSLocalizedDescriptionKey:
                "The file couldn’t be opened because /Users/someone/Library/Application Support/WhisperMeet/Recordings/meeting.wav does not exist."
        ]
    )
    let redacted = DiagnosticsBundleBuilder.publicLogDescription(error)
    #expect(!redacted.contains("/Users/"))
    // F896: the words after the path go with it. "does not exist" used to survive because `.wav`
    // followed by a space ended the path there, and a name can go on past a known extension
    // ("notes.txt draft") — so the end of a bare path on a line is no longer trusted.
    #expect(redacted == "The file couldn’t be opened because <path>…", "\(redacted)")
}

@Test("Public log description leaves path-free error text untouched")
func publicLogDescriptionKeepsPlainText() {
    let error = NSError(
        domain: "Capture", code: 1,
        userInfo: [NSLocalizedDescriptionKey: "The capture session was interrupted (3/4 channels stopped)."]
    )
    #expect(
        DiagnosticsBundleBuilder.publicLogDescription(error)
            == "The capture session was interrupted (3/4 channels stopped)."
    )
}
