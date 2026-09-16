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

        /// Accepts any key, so an unrecognised case can be read rather than rejected.
        private struct AnyKey: CodingKey {
            let stringValue: String
            var intValue: Int? { nil }
            init?(stringValue: String) { self.stringValue = stringValue }
            init?(intValue: Int) { nil }
        }

        /// Lenient decode (F251), for the reason F188 established: this is an associated-value enum
        /// with synthesized `Codable`, so a case written by a NEWER build threw
        /// `DecodingError.typeMismatch` — "Invalid number of keys found, expected one." — and
        /// because `dictation-log.json` decodes as one `DictationLog` value, that single entry made
        /// the user's whole dictation history unreadable. (An earlier version of this comment said
        /// `dataCorrupted`; the message was right but the case was wrong, which would send someone
        /// debugging by error case looking for the wrong thing.)
        ///
        /// The wire format is deliberately unchanged. The obvious-looking fix — persisting the
        /// discriminant as a plain string, the way the sibling `refinement` field already does — was
        /// rejected: the existing shape is a single-key object (`{"pasted":{}}`,
        /// `{"failed":{"_0":"reason"}}`, verified against a real on-disk log), so changing it would
        /// make every entry already written unreadable. That is the same flag-day trap F188 records
        /// for the meeting index, where introducing the fence is itself the incompatible change.
        /// `outcomeWireShapeIsPinned` holds these bytes.
        ///
        /// An unknown case maps to `.failed`, carrying the case's own name. `.failed` is honest —
        /// the entry did not succeed as far as this build can tell — and keeping the name means the
        /// information is degraded rather than destroyed, unlike a fallback to `.empty`. A
        /// structurally empty object still throws: leniency is for values this build does not
        /// recognise, not for corruption.
        private static let knownCases: Set<String> = ["pasted", "clipboard", "empty", "failed"]

        public init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: AnyKey.self)
            // Sorted, so every message and every fallback below is deterministic. `allKeys` order is
            // not stable across processes, and an earlier version of this initialiser read
            // `allKeys.first`, which made the decode of `{"failed":{"_0":"reason","_1":7}}` return
            // the reason or "" at random between runs.
            let names = container.allKeys.map(\.stringValue).sorted()
            guard !names.isEmpty else {
                throw DecodingError.dataCorrupted(
                    .init(
                        codingPath: decoder.codingPath,
                        debugDescription: "an outcome object carries no case at all"
                    )
                )
            }
            let recognized = names.filter(Self.knownCases.contains)
            // Two known cases at once is corruption, not a version skew — no encoder writes it.
            guard recognized.count <= 1 else {
                throw DecodingError.dataCorrupted(
                    .init(
                        codingPath: decoder.codingPath,
                        debugDescription: "an outcome object carries two cases: \(recognized)"
                    )
                )
            }
            // An unrecognised SIBLING key is tolerated rather than rejected, which is the
            // forward-compatible direction and the one this leniency exists for: the likeliest next
            // change to this type is a hand-written encoder that adds a key beside the case (F250
            // prescribes exactly that shape), and refusing it would reintroduce the whole-log
            // failure this initialiser was written to close.
            switch recognized.first {
            case "pasted": self = .pasted
            case "clipboard": self = .clipboard
            case "empty": self = .empty
            case "failed":
                let key = AnyKey(stringValue: "failed")!
                let nested = try container.nestedContainer(keyedBy: AnyKey.self, forKey: key)
                // By NAME first. `_0` is the label the synthesized encoder writes for the single
                // associated value; falling back to the lowest-sorted key covers a future shape
                // without guessing nondeterministically, and a non-string payload lands on the
                // placeholder rather than an empty accusation.
                let byName = try? nested.decode(String.self, forKey: AnyKey(stringValue: "_0")!)
                let byOrder = nested.allKeys.map(\.stringValue).sorted().first
                    .flatMap { AnyKey(stringValue: $0) }
                    .flatMap { try? nested.decode(String.self, forKey: $0) }
                self = .failed(byName ?? byOrder ?? "the reason could not be read")
            default:
                self = .failed(
                    "Recorded by a newer version of WhisperMeet (\(names.joined(separator: ", ")))."
                )
            }
        }
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
