import Foundation

/// Pure validation and normalization of a pasted media link before it is handed to the `yt-dlp`
/// subprocess (F183). Framework-free and exhaustively unit-tested, because the pasted string becomes a
/// subprocess argument: getting this wrong is a flag-injection vector, not just a bad-input bug.
public enum MediaSourceURL {
    public enum ValidationError: Error, Equatable {
        case empty
        case notHTTP          // only http/https are accepted (rejects file:, data:, javascript:, …)
        case flagInjection    // the URL begins with "-", so yt-dlp would read it as an option
    }

    /// The recognized shape of a valid link. `videoID` is populated for YouTube; `isPlaylist` lets the
    /// caller refuse playlist/channel URLs deliberately (v1 imports a single item).
    public struct Parsed: Equatable, Sendable {
        public let url: String
        public let kind: String
        public let host: String
        public let videoID: String?
        public let isPlaylist: Bool

        public init(url: String, kind: String, host: String, videoID: String?, isPlaylist: Bool) {
            self.url = url
            self.kind = kind
            self.host = host
            self.videoID = videoID
            self.isPlaylist = isPlaylist
        }

        public var isYouTube: Bool { kind == MediaSource.youTubeKind }
    }

    public static func validate(_ raw: String) throws -> Parsed {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw ValidationError.empty }
        // A leading "-" would be read by yt-dlp as an option even after the URL slot; refuse it
        // outright (and the client also passes `--` before the URL as defense in depth).
        guard !trimmed.hasPrefix("-") else { throw ValidationError.flagInjection }
        // Reject embedded control characters, NUL, and interior whitespace. A NUL is the sharp case:
        // Swift keeps it in the String, but it terminates the C string handed to the subprocess, so
        // yt-dlp would fetch a *different* URL than the one persisted and shown as provenance.
        guard !trimmed.unicodeScalars.contains(where: {
            $0.value < 0x20 || $0.value == 0x7F || CharacterSet.whitespacesAndNewlines.contains($0)
        }) else {
            throw ValidationError.notHTTP
        }

        guard let components = URLComponents(string: trimmed),
              let scheme = components.scheme?.lowercased(),
              scheme == "http" || scheme == "https",
              let rawHost = components.host, !rawHost.isEmpty else {
            throw ValidationError.notHTTP
        }
        let host = rawHost.lowercased()

        let youTube = isYouTubeHost(host)
        return Parsed(
            url: trimmed,
            kind: youTube ? MediaSource.youTubeKind : MediaSource.webKind,
            host: host,
            videoID: youTube ? youTubeVideoID(host: host, components: components) : nil,
            isPlaylist: isPlaylistOrChannel(host: host, components: components)
        )
    }

    static func isYouTubeHost(_ host: String) -> Bool {
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        return bare == "youtube.com"
            || bare == "m.youtube.com"
            || bare == "music.youtube.com"
            || bare == "youtu.be"
    }

    /// Extracts a YouTube video id from the common shapes: `watch?v=`, `youtu.be/<id>`, `/shorts/<id>`,
    /// `/embed/<id>`, `/live/<id>`. Returns nil when there is no single video (e.g. a channel page).
    static func youTubeVideoID(host: String, components: URLComponents) -> String? {
        let bare = host.hasPrefix("www.") ? String(host.dropFirst(4)) : host
        if bare == "youtu.be" {
            let id = components.path.split(separator: "/").first.map(String.init)
            return id.flatMap(nonEmpty)
        }
        if let v = components.queryItems?.first(where: { $0.name == "v" })?.value, !v.isEmpty {
            return v
        }
        let parts = components.path.split(separator: "/").map(String.init)
        for marker in ["shorts", "embed", "live", "v"] {
            if let index = parts.firstIndex(of: marker), index + 1 < parts.count {
                return nonEmpty(parts[index + 1])
            }
        }
        return nil
    }

    /// Whether the URL points at a playlist or channel rather than one video — a `list=` query, or a
    /// channel/playlist path. The caller refuses these in v1 (`--no-playlist` is also always passed).
    static func isPlaylistOrChannel(host: String, components: URLComponents) -> Bool {
        if components.queryItems?.contains(where: { $0.name == "list" }) == true { return true }
        let path = components.path.lowercased()
        let firstSegment = path.split(separator: "/").first.map(String.init) ?? ""
        return path.hasPrefix("/playlist")
            || path.hasPrefix("/channel/")
            || path.hasPrefix("/c/")
            || path.hasPrefix("/user/")
            || firstSegment.hasPrefix("@") // /@handle channel pages
    }

    private static func nonEmpty(_ value: String) -> String? {
        value.isEmpty ? nil : value
    }
}
