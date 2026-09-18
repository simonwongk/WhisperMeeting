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

@Test("A 403 on the media itself points at the downloader, not the user's connection (F184)")
func forbiddenMediaPointsAtTheDownloader() {
    // Real stderr, 2026-09-18: yt-dlp 2026.07.04 on a video that 2026.08.19 downloads fine. The
    // probe succeeded and the page loaded, so "check your connection" sent the user the wrong way.
    let stderr = """
    [youtube] aqz-KE-bpKQ: Downloading android vr player API JSON
    [info] aqz-KE-bpKQ: Downloading 1 format(s): 258
    ERROR: unable to download video data: HTTP Error 403: Forbidden
    """
    let info = MediaDownloadFailureClassifier.classify(stderr: stderr)
    #expect(info.kind == .updateDownloader)
    #expect(info.explanation.contains("Update the downloader"))
    #expect(info.explanation.contains("try again"), "a transient 403 does succeed on retry, so say so")
    // A 5xx or a timeout is still the network.
    #expect(MediaDownloadFailureClassifier.classify(stderr: "ERROR: unable to download video data: HTTP Error 503").kind == .network)
}
