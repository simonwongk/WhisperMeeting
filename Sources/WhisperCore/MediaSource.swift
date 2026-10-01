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

    /// Reads the sidecar back, or nil when it is absent, unreadable or not a `MediaSource` (F308).
    ///
    /// Until F308 the sidecar had a writer and no reader, so the crash it was written for recovered
    /// the audio and lost the link. Nil rather than a throw, as `RecordingSessionSidecar.read` is:
    /// the writer is `try?` — a provenance write must never fail a download that is working — so
    /// its absence is a normal state and a recovery must not be failed by it.
    ///
    /// A default `JSONDecoder`, because `importFromURL` writes with a default `JSONEncoder`. The
    /// pair is pinned by a test that writes the way the import does.
    public static func read(in directory: URL) -> MediaSource? {
        guard let data = try? Data(contentsOf: directory.appendingPathComponent(sidecarFilename))
        else { return nil }
        return try? JSONDecoder().decode(MediaSource.self, from: data)
    }

    /// The tag auto-applied to a link import, already within `MeetingTags.maxLength` (F183): "YouTube"
    /// for a YouTube source, otherwise the host.
    public var suggestedTag: String {
        let raw = isYouTube ? "YouTube" : host
        return String(raw.prefix(MeetingTags.maxLength))
    }

    /// A link the meeting header may open, and the label it is shown under (F497).
    public struct ProvenanceLink: Equatable, Sendable {
        public let label: String
        public let url: URL
    }

    /// The stored `pageURL` re-checked the way an import checks it, or nil when it would not have
    /// been imported (F497).
    ///
    /// `MediaSourceURL.validate` runs at import, but `pageURL` is read back from data this build did
    /// not necessarily write — the index after Restore Library, or `source.json` read by recovery
    /// (`read(in:)` validates nothing, and must not: provenance never fails a recovery, F308). So a
    /// `file:`, `smb:` or `javascript:` URL could reach the header's Link under a stored "youtube.com".
    /// Re-running the import's check here keeps one rule for what is a link, and the label is the host
    /// of the URL that would be opened rather than the separately stored `host`, so the two cannot
    /// disagree. For a record the import wrote they are the same string (`host` is `parsed.host`).
    ///
    /// The scheme is checked again on the `URL` itself, because that — not the string `validate`
    /// parsed — is what is handed to the system to open.
    public var provenanceLink: ProvenanceLink? {
        guard let parsed = try? MediaSourceURL.validate(pageURL),
              let url = URL(string: parsed.url),
              let scheme = url.scheme?.lowercased(),
              scheme == "http" || scheme == "https" else { return nil }
        return ProvenanceLink(label: parsed.host, url: url)
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
