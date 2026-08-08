import Foundation

/// Provenance for a meeting whose audio was fetched from a link rather than recorded on this Mac (F183).
///
/// `kind` is a **String**, not a `Codable` enum, on purpose: an optional enum property does not decode
/// leniently — `decodeIfPresent` returns `nil` for an absent key but *throws* for an unknown value, so a
/// future `kind` written by a newer build would make the whole meetings index fail to decode on an
/// older one. A string with computed accessors closes that forward-compatibility hole permanently.
public struct MediaSource: Codable, Sendable, Equatable {
    public static let youTubeKind = "youtube"
    public static let webKind = "web"

    public let kind: String
    public let pageURL: String
    public let host: String
    public let videoID: String?
    public let uploader: String?
    public let uploadDate: Date?
    public let fetchedAt: Date

    public init(
        kind: String,
        pageURL: String,
        host: String,
        videoID: String? = nil,
        uploader: String? = nil,
        uploadDate: Date? = nil,
        fetchedAt: Date
    ) {
        self.kind = kind
        self.pageURL = pageURL
        self.host = host
        self.videoID = videoID
        self.uploader = uploader
        self.uploadDate = uploadDate
        self.fetchedAt = fetchedAt
    }

    public var isYouTube: Bool { kind == Self.youTubeKind }

    /// The sidecar filename written into the meeting folder *before* the download starts, so provenance
    /// survives a crash mid-download and an interrupted fetch is recoverable as a link import rather
    /// than an anonymous orphan folder (F183). Mirrors `source-tracks.json`.
    public static let sidecarFilename = "source.json"

    /// The tag auto-applied to a link import, already within `MeetingTags.maxLength` (F183): "YouTube"
    /// for a YouTube source, otherwise the host.
    public var suggestedTag: String {
        let raw = isYouTube ? "YouTube" : host
        return String(raw.prefix(MeetingTags.maxLength))
    }
}

/// What a pre-download probe (`yt-dlp --dump-single-json`) reports about a link (F183). Probing before
/// downloading is what makes the storage guard and the long-duration confirmation possible at all —
/// without it the app would start an unbounded fetch and only discover the size afterwards.
public struct MediaProbe: Sendable, Equatable {
    public let title: String?
    public let durationSeconds: Double?
    public let uploader: String?
    public let uploadDate: Date?
    /// yt-dlp's `filesize_approx` for the selected format, when it reports one.
    public let approximateBytes: Int64?
    public let isLive: Bool
    /// The video's own language, used to pin `--sub-langs` so an auto-**translated** caption track is
    /// never fetched (the original-language invariant).
    public let language: String?

    public init(
        title: String? = nil,
        durationSeconds: Double? = nil,
        uploader: String? = nil,
        uploadDate: Date? = nil,
        approximateBytes: Int64? = nil,
        isLive: Bool = false,
        language: String? = nil
    ) {
        self.title = title
        self.durationSeconds = durationSeconds
        self.uploader = uploader
        self.uploadDate = uploadDate
        self.approximateBytes = approximateBytes
        self.isLive = isLive
        self.language = language
    }
}
