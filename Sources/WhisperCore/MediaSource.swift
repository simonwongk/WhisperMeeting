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

    /// The tag auto-applied to a link import, already within `MeetingTags.maxLength` (F183): "YouTube"
    /// for a YouTube source, otherwise the host.
    public var suggestedTag: String {
        let raw = isYouTube ? "YouTube" : host
        return String(raw.prefix(MeetingTags.maxLength))
    }
}
