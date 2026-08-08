import Foundation

/// What the user should do about a failed link download (F183). Mirrors `TranscriptionFailureClassifier`.
/// The one action that matters most is `updateDownloader`: YouTube changes its extraction constantly and
/// `yt-dlp` goes stale on a scale of weeks, so the honest guidance is "update the downloader", not a
/// blind retry that fails identically.
public enum MediaDownloadFailureKind: Sendable, Equatable {
    case unavailable        // removed, private, or does not exist
    case ageRestricted      // needs sign-in to confirm age (out of scope in v1)
    case geoBlocked         // not available in the user's region
    case liveInProgress     // a live/premiere that hasn't finished
    case network            // transient connectivity failure — retry may work
    case updateDownloader   // yt-dlp is stale; extraction is broken until it is updated
    case unsupportedURL     // no extractor / not a media page
    case generic            // anything unclassified — a plain retry
}

public struct MediaDownloadFailureInfo: Sendable, Equatable {
    public let kind: MediaDownloadFailureKind
    public let explanation: String

    public init(kind: MediaDownloadFailureKind, explanation: String) {
        self.kind = kind
        self.explanation = explanation
    }
}

/// Pure mapping from `yt-dlp` stderr signatures to an actionable failure (F183). Deterministic; no
/// network, no process. The client scans stderr with this to pick the error it throws, and the UI shows
/// the explanation instead of a blind retry.
public enum MediaDownloadFailureClassifier {
    public static func classify(stderr: String) -> MediaDownloadFailureInfo {
        let text = stderr.lowercased()

        func contains(_ needles: [String]) -> Bool {
            needles.contains { text.contains($0) }
        }

        // A stale extractor is checked first: its symptoms (e.g. "unable to extract") otherwise look
        // like a generic failure, but the fix is specifically "update yt-dlp".
        if contains([
            "please update", "yt-dlp is out of date", "confirm you are on the latest version",
            "nsig extraction failed", "signature extraction failed", "unable to extract",
            "failed to extract any player response", "please report this issue",
        ]) {
            return .init(
                kind: .updateDownloader,
                explanation: "The downloader is out of date — this site changed how it serves audio. Update the downloader in Settings, then try again."
            )
        }
        if contains(["sign in to confirm your age", "confirm your age", "age-restricted", "age restricted"]) {
            return .init(
                kind: .ageRestricted,
                explanation: "This video is age-restricted and needs a signed-in account, which this app does not support. Download it another way, then import the file."
            )
        }
        if contains(["available in your country", "available in your region", "geo restrict", "geo-restrict", "blocked it in your country", "who has blocked it"]) {
            return .init(
                kind: .geoBlocked,
                explanation: "This video is blocked in your region, so it can't be downloaded here."
            )
        }
        if contains(["this live event", "is live", "premieres in", "will begin in", "live event will begin"]) {
            return .init(
                kind: .liveInProgress,
                explanation: "This is a live or upcoming stream. Try again once it has finished and a recording is available."
            )
        }
        if contains(["private video", "video unavailable", "has been removed", "no longer available", "does not exist", "account associated with this video has been terminated"]) {
            return .init(
                kind: .unavailable,
                explanation: "This video is private, removed, or unavailable, so there is nothing to download."
            )
        }
        if contains(["unsupported url", "no video formats found", "is not a valid url", "unable to download webpage: http error 404"]) {
            return .init(
                kind: .unsupportedURL,
                explanation: "That link doesn't point to a downloadable video or audio page."
            )
        }
        if contains(["unable to download", "connection timed out", "temporary failure in name resolution", "urlopen error", "network is unreachable", "http error 5", "read timed out", "connection reset"]) {
            return .init(
                kind: .network,
                explanation: "The download couldn't reach the site. Check your connection and try again."
            )
        }
        return .init(
            kind: .generic,
            explanation: "The download failed. Nothing was saved — try again."
        )
    }
}
