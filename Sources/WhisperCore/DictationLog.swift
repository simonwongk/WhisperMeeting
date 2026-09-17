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
        static let knownCaseNames: Set<String> = ["pasted", "clipboard", "empty", "failed"]

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
            let recognized = names.filter(Self.knownCaseNames.contains)
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

    /// The outcome's TRUE case name when this build does not recognise it — otherwise nil (F266).
    ///
    /// **Why the sibling key.** F251's lenient decode maps an unrecognised case to
    /// `.failed("Recorded by a newer version…")` so one entry cannot make the whole log unreadable.
    /// But `DictationLogStore.persist()` re-encodes the *entire* log on every `record()`, so after a
    /// downgrade plus a single dictation that stand-in was written back to disk as a genuine
    /// failure — permanently. `{"discarded":{}}` came back out as
    /// `{"failed":{"_0":"Recorded by a newer version of WhisperMeet (discarded)."}}`, and the newer
    /// build then showed a fabricated failure for that entry forever. That is the same
    /// "invent a case and falsify provenance" objection **F250** raises against enum-level leniency,
    /// and **F188**'s stated preference is a lossless round-trip.
    ///
    /// `outcome` deliberately keeps holding the nearest KNOWN case rather than the true one: a build
    /// without F251's decoder throws on an unrecognised case, and one such entry took the whole log
    /// with it. Putting the true name there would reintroduce exactly that for every older build —
    /// the flag-day trap F188 records, where introducing the fence is itself the incompatible change.
    ///
    /// **Nil for every case this build knows.** The field's presence is what marks `outcome` as a
    /// degraded stand-in; writing it always would make it redundant on ~100% of entries and remove
    /// that meaning, as well as changing the bytes of the common case for nothing. Captured during
    /// decode, because a re-encode has no other source for the name.
    public let outcomeKind: String?

    public init(
        id: UUID,
        date: Date,
        text: String,
        outcome: Outcome,
        rawText: String? = nil,
        refinement: String? = nil,
        outcomeKind: String? = nil
    ) {
        self.id = id
        self.date = date
        self.text = text
        self.outcome = outcome
        self.rawText = rawText
        self.refinement = refinement
        self.outcomeKind = outcomeKind
    }

    private enum CodingKeys: String, CodingKey {
        case id, date, text, outcome, rawText, refinement, outcomeKind
    }

    /// Accepts any key, to read the `outcome` object's own case name (F266).
    private struct AnyEntryKey: CodingKey {
        let stringValue: String
        var intValue: Int? { nil }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        date = try container.decode(Date.self, forKey: .date)
        text = try container.decode(String.self, forKey: .text)
        outcome = try container.decode(Outcome.self, forKey: .outcome)
        rawText = try container.decodeIfPresent(String.self, forKey: .rawText)
        refinement = try container.decodeIfPresent(String.self, forKey: .refinement)

        if let stated = try container.decodeIfPresent(String.self, forKey: .outcomeKind) {
            // A newer build wrote it, or this build wrote it on a previous save. Either way the
            // sibling is the truth and `outcome` is the stand-in.
            outcomeKind = stated
        } else {
            // No sibling: recover the name from the `outcome` object itself, which is the only
            // chance to do so — after this decode the original bytes are gone.
            outcomeKind = try Self.unknownCaseName(in: container)
        }
    }

    /// The `outcome` object's case name when it is one this build does not know, else nil.
    private static func unknownCaseName(
        in container: KeyedDecodingContainer<CodingKeys>
    ) throws -> String? {
        guard let nested = try? container.nestedContainer(
            keyedBy: AnyEntryKey.self,
            forKey: .outcome
        ) else {
            return nil
        }
        // Sorted for determinism: `allKeys` order is not stable across processes, and the same bug
        // was already fixed once inside `Outcome.init(from:)`.
        let names = nested.allKeys.map(\.stringValue).sorted()
        let unknown = names.filter { !Outcome.knownCaseNames.contains($0) }
        // Only when there is no known case at all. An unknown key *beside* a known one is the
        // tolerated forward-compatible shape `unknownSiblingKeyIsTolerated` pins — there the known
        // case is the real outcome and nothing is degraded.
        guard names.allSatisfy({ !Outcome.knownCaseNames.contains($0) }), !unknown.isEmpty else {
            return nil
        }
        return unknown.joined(separator: ", ")
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(id, forKey: .id)
        try container.encode(date, forKey: .date)
        try container.encode(text, forKey: .text)
        // The nearest known case, so a pre-F251 build can still read the entry.
        try container.encode(outcome, forKey: .outcome)
        try container.encodeIfPresent(rawText, forKey: .rawText)
        try container.encodeIfPresent(refinement, forKey: .refinement)
        // The truth, beside it. Old builds ignore an unrecognised key; F266-and-later builds prefer
        // it; nothing is ever rewritten into a lie.
        try container.encodeIfPresent(outcomeKind, forKey: .outcomeKind)
    }

    /// True when a transcript was actually produced and delivered.
    public var isSuccess: Bool {
        outcome == .pasted || outcome == .clipboard
    }

    /// Whether this entry's outcome came from a build that knows a case this one does not (F266).
    ///
    /// Lets the log say "recorded by a newer version" instead of showing a failure that never
    /// happened. The dictated `text` is intact either way, which is the part that matters.
    public var wasRecordedByANewerBuild: Bool { outcomeKind != nil }
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
