import Foundation
import Testing
@testable import WhisperCore

// F183 — map real yt-dlp stderr signatures to an actionable failure. The one that matters most is
// updateDownloader (a stale extractor), which must not be reported as a blind retry.

@Test("A stale-extractor signature maps to updateDownloader (F183)")
func staleExtractorNeedsUpdate() {
    let cases = [
        "ERROR: unable to extract player response; please report this issue on ...",
        "WARNING: Signature extraction failed: nsig extraction failed. Please update yt-dlp.",
    ]
    for stderr in cases {
        #expect(MediaDownloadFailureClassifier.classify(stderr: stderr).kind == .updateDownloader)
    }
}

@Test("Private/age/geo/live/network signatures each map to their kind (F183)")
func mapsCommonSignatures() {
    #expect(MediaDownloadFailureClassifier.classify(stderr: "ERROR: Private video. Sign in if you've been granted access").kind == .unavailable)
    #expect(MediaDownloadFailureClassifier.classify(stderr: "ERROR: Sign in to confirm your age").kind == .ageRestricted)
    #expect(MediaDownloadFailureClassifier.classify(stderr: "ERROR: The uploader has not made this video available in your country").kind == .geoBlocked)
    #expect(MediaDownloadFailureClassifier.classify(stderr: "ERROR: This live event will begin in 3 hours").kind == .liveInProgress)
    #expect(MediaDownloadFailureClassifier.classify(stderr: "ERROR: unable to download video data: Connection timed out").kind == .network)
}

@Test("An unrecognized error is generic, not a false specific claim (F183)")
func unknownIsGeneric() {
    #expect(MediaDownloadFailureClassifier.classify(stderr: "ERROR: something entirely new happened").kind == .generic)
    #expect(!MediaDownloadFailureClassifier.classify(stderr: "ERROR: something entirely new").explanation.isEmpty)
}
