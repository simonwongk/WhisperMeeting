import Foundation

/// The facet fields of one meeting that `MeetingQuery` filters on. A small value so the query logic
/// stays pure and framework-free while the app builds it from a `MeetingRecord` (F59).
public struct MeetingFacets: Sendable {
    public let languageCode: String?
    public let status: String            // MeetingStatus rawValue
    public let durationSeconds: TimeInterval
    public let createdAt: Date
    public let textFields: [String]      // title, transcript, notes — for free-text search

    public init(
        languageCode: String?,
        status: String,
        durationSeconds: TimeInterval,
        createdAt: Date,
        textFields: [String]
    ) {
        self.languageCode = languageCode
        self.status = status
        self.durationSeconds = durationSeconds
        self.createdAt = createdAt
        self.textFields = textFields
    }
}

/// A parsed sidebar query: facet tokens (`lang:`, `status:`, `before:`/`after:YYYY-MM-DD`,
/// `min:`/`max:` durations) plus the remaining free text. Free text delegates to `TextSearch.matches`
/// so a query with no tokens is byte-identical to the old substring search (F59).
public struct MeetingQuery: Sendable, Equatable {
    public var language: String?
    public var status: String?
    public var before: Date?
    public var after: Date?
    public var minDuration: TimeInterval?
    public var maxDuration: TimeInterval?
    public var freeText: String

    public init(
        language: String? = nil,
        status: String? = nil,
        before: Date? = nil,
        after: Date? = nil,
        minDuration: TimeInterval? = nil,
        maxDuration: TimeInterval? = nil,
        freeText: String = ""
    ) {
        self.language = language
        self.status = status
        self.before = before
        self.after = after
        self.minDuration = minDuration
        self.maxDuration = maxDuration
        self.freeText = freeText
    }

    public static func parse(_ raw: String) -> MeetingQuery {
        var query = MeetingQuery()
        var freeWords: [String] = []
        for token in raw.split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" }).map(String.init) {
            let lower = token.lowercased()
            if lower.hasPrefix("lang:") {
                query.language = String(lower.dropFirst(5))
            } else if lower.hasPrefix("status:") {
                query.status = String(lower.dropFirst(7))
            } else if lower.hasPrefix("before:"), let date = Self.parseDate(String(token.dropFirst(7))) {
                query.before = date
            } else if lower.hasPrefix("after:"), let date = Self.parseDate(String(token.dropFirst(6))) {
                query.after = date
            } else if lower.hasPrefix("min:"), let duration = Self.parseDuration(String(token.dropFirst(4))) {
                query.minDuration = duration
            } else if lower.hasPrefix("max:"), let duration = Self.parseDuration(String(token.dropFirst(4))) {
                query.maxDuration = duration
            } else {
                freeWords.append(token) // unrecognized (incl. malformed tokens) stays free text
            }
        }
        query.freeText = freeWords.joined(separator: " ")
        return query
    }

    public func matches(_ facets: MeetingFacets) -> Bool {
        if let language, facets.languageCode?.lowercased() != language { return false }
        if let status, facets.status.lowercased() != status { return false }
        if let before, facets.createdAt >= before { return false } // created strictly before the day
        if let after, facets.createdAt < after { return false }     // created on/after the day
        if let minDuration, facets.durationSeconds < minDuration { return false }
        if let maxDuration, facets.durationSeconds > maxDuration { return false }
        if !freeText.isEmpty { return TextSearch.matches(freeText, in: facets.textFields) }
        return true
    }

    /// `YYYY-MM-DD` as start-of-day UTC. Deterministic (POSIX locale, UTC).
    static func parseDate(_ string: String) -> Date? {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(identifier: "UTC")
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.date(from: string)
    }

    /// `30m` / `1h` / `90s`, or a bare number treated as minutes.
    static func parseDuration(_ string: String) -> TimeInterval? {
        let lower = string.lowercased()
        if lower.hasSuffix("h"), let n = Double(lower.dropLast()) { return n * 3600 }
        if lower.hasSuffix("m"), let n = Double(lower.dropLast()) { return n * 60 }
        if lower.hasSuffix("s"), let n = Double(lower.dropLast()) { return n }
        if let n = Double(lower) { return n * 60 }
        return nil
    }
}
