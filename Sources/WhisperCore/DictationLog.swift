import Foundation

/// One recorded dictation attempt: what was transcribed and what happened to it.
public struct DictationLogEntry: Codable, Sendable, Equatable, Identifiable {
    public enum Outcome: Codable, Sendable, Equatable {
        /// Auto-pasted into the focused field.
        case pasted
        /// Left on the clipboard (fallback when paste wasn't possible).
        case clipboard
        /// Nothing intelligible captured.
        case empty
        /// Failed, with a human-readable reason.
        case failed(String)
    }

    public let id: UUID
    public let date: Date
    public let text: String
    public let outcome: Outcome
    /// The pre-refinement transcript, recorded only when an F200 refine attempt changed the
    /// delivered text. Optional + append-only per the persisted-schema rules.
    public let rawText: String?
    /// `DictationRefinement.rawValue` for the attempt, or nil when refinement was off/not
    /// attempted. A plain String on the wire (never the enum) so unknown future values decode
    /// leniently in older builds.
    public let refinement: String?

    public init(
        id: UUID,
        date: Date,
        text: String,
        outcome: Outcome,
        rawText: String? = nil,
        refinement: String? = nil
    ) {
        self.id = id
        self.date = date
        self.text = text
        self.outcome = outcome
        self.rawText = rawText
        self.refinement = refinement
    }

    /// True when a transcript was actually produced and delivered.
    public var isSuccess: Bool {
        outcome == .pasted || outcome == .clipboard
    }
}

/// A capped, most-recent-first history of dictation attempts.
public struct DictationLog: Codable, Sendable, Equatable {
    public private(set) var entries: [DictationLogEntry]
    public var limit: Int

    public init(entries: [DictationLogEntry] = [], limit: Int = 100) {
        self.entries = entries
        self.limit = limit
    }

    /// Returns a new log with `entry` prepended (most recent first), capped to `limit`.
    public func adding(_ entry: DictationLogEntry) -> DictationLog {
        var updated = [entry] + entries
        if updated.count > limit {
            updated.removeLast(updated.count - limit)
        }
        return DictationLog(entries: updated, limit: limit)
    }

    /// Returns a new, empty log preserving `limit`.
    public func cleared() -> DictationLog {
        DictationLog(entries: [], limit: limit)
    }
}
