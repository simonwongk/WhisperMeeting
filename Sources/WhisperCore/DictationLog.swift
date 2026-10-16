import Foundation

/// How long one dictation took, and how busy the GPU was before it (F892) — the four figures F890
/// and F891 needed to tell a slow dictation's cause, and nothing more: the clip's length, the
/// recognizer's time, the refiner's time and the GPU share. Each is optional: a figure that was not
/// measured is absent, never zero.
///
/// The unified log carries the same figures in the "transcribed in" line, but this Mac keeps that
/// log for about a day, so a slow dictation reported two days later had nothing to find. These go
/// into the dictation history (`dictation-log.json`), which keeps the most recent dictations (100
/// by default, `DictationLog.limit`).
///
/// **Every figure passes one rule, however it is set.** A figure that cannot be a measurement —
/// negative, not finite, or a percentage outside 0…100 — is dropped rather than stored: JSON has no
/// NaN or infinity, so storing one would fail the whole history's save, and since the entry stays in
/// the in-memory log, every later save too, for the rest of the session. `init` applies the rule and
/// so does each property's `didSet` (a review found a NaN set after `init` reaching the store).
public struct DictationTimings: Sendable, Equatable {
    /// The recording's length.
    public var clipSeconds: Double? { didSet { clipSeconds = Self.measured(clipSeconds) } }
    /// From the release to the recognizer's reply — the figure the "transcribed in" log line prints:
    /// the speech checks, any wait for a refiner being released, any wait behind a press-down touch
    /// on the engine's queue, and recognition. For a dictation whose recognition failed, from the
    /// release to the failure.
    public var transcribeSeconds: Double? { didSet { transcribeSeconds = Self.measured(transcribeSeconds) } }
    /// The refiner's own pass, from asking it to its answer; nil when it was not asked.
    public var refineSeconds: Double? { didSet { refineSeconds = Self.measured(refineSeconds) } }
    /// The accelerator's "Device Utilization %" read just before the recognizer was asked (F890);
    /// nil when it could not be read.
    public var gpuBusyPercent: Int? { didSet { gpuBusyPercent = Self.percentage(gpuBusyPercent) } }

    /// Observers do not run during `init`, so it applies the same rule itself.
    public init(
        clipSeconds: Double? = nil,
        transcribeSeconds: Double? = nil,
        refineSeconds: Double? = nil,
        gpuBusyPercent: Int? = nil
    ) {
        self.clipSeconds = Self.measured(clipSeconds)
        self.transcribeSeconds = Self.measured(transcribeSeconds)
        self.refineSeconds = Self.measured(refineSeconds)
        self.gpuBusyPercent = Self.percentage(gpuBusyPercent)
    }

    private static func measured(_ seconds: Double?) -> Double? {
        guard let seconds, seconds.isFinite, seconds >= 0 else { return nil }
        return seconds
    }

    private static func percentage(_ percent: Int?) -> Int? {
        percent.flatMap { (0...100).contains($0) ? $0 : nil }
    }
}

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
    /// The recognizer's transcript, before F200 refinement and the user's replacement rules (F821),
    /// recorded only when either changed the delivered text. Optional + append-only per the
    /// persisted-schema rules; F821 changed when it is written, not its shape.
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

    /// `DictationTimings`, stored flat (F892): append-only and optional per the persisted-schema
    /// rules, each omitted from the wire when it was not measured. A build from before F892 decodes
    /// the entry and ignores them (its keyed decoder reads only the keys it names).
    public let clipSeconds: Double?
    public let transcribeSeconds: Double?
    public let refineSeconds: Double?
    public let gpuBusyPercent: Int?

    /// True when the recognizer cut this dictation short (F1016: F762's and F1015's `truncated`), so
    /// the end of what was said may be missing. The user's decision of 2026-10-16: it is pasted as
    /// before, the pill says so, and the history marks it. Append-only and optional per the
    /// persisted-schema rules, written only when true — so every other entry keeps its bytes — and
    /// read leniently: a value of the wrong type costs this flag, never the entry.
    public let truncated: Bool?

    public init(
        id: UUID,
        date: Date,
        text: String,
        outcome: Outcome,
        rawText: String? = nil,
        refinement: String? = nil,
        outcomeKind: String? = nil,
        timings: DictationTimings = DictationTimings(),
        truncated: Bool? = nil
    ) {
        self.id = id
        self.date = date
        self.text = text
        self.outcome = outcome
        self.rawText = rawText
        self.refinement = refinement
        self.outcomeKind = outcomeKind
        self.clipSeconds = timings.clipSeconds
        self.transcribeSeconds = timings.transcribeSeconds
        self.refineSeconds = timings.refineSeconds
        self.gpuBusyPercent = timings.gpuBusyPercent
        self.truncated = truncated
    }

    /// The four figures together (F892).
    public var timings: DictationTimings {
        DictationTimings(
            clipSeconds: clipSeconds,
            transcribeSeconds: transcribeSeconds,
            refineSeconds: refineSeconds,
            gpuBusyPercent: gpuBusyPercent
        )
    }

    private enum CodingKeys: String, CodingKey {
        case id, date, text, outcome, rawText, refinement, outcomeKind
        case clipSeconds, transcribeSeconds, refineSeconds, gpuBusyPercent
        case truncated
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
        // F892: leniently, and through `DictationTimings`' own rule. A figure is a diagnostic, so one
        // that is the wrong type or cannot be a measurement costs that figure — never the entry,
        // which would cost the whole history (it decodes as one value).
        let timings = DictationTimings(
            clipSeconds: try? container.decodeIfPresent(Double.self, forKey: .clipSeconds),
            transcribeSeconds: try? container.decodeIfPresent(Double.self, forKey: .transcribeSeconds),
            refineSeconds: try? container.decodeIfPresent(Double.self, forKey: .refineSeconds),
            gpuBusyPercent: try? container.decodeIfPresent(Int.self, forKey: .gpuBusyPercent)
        )
        clipSeconds = timings.clipSeconds
        transcribeSeconds = timings.transcribeSeconds
        refineSeconds = timings.refineSeconds
        gpuBusyPercent = timings.gpuBusyPercent
        // F1016: leniently, like the timings — a flag is a note on the entry, never a reason to lose it.
        truncated = (try? container.decodeIfPresent(Bool.self, forKey: .truncated)) ?? nil

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
        // F892. Absent when unmeasured, so an entry without them keeps its pre-F892 bytes.
        try container.encodeIfPresent(clipSeconds, forKey: .clipSeconds)
        try container.encodeIfPresent(transcribeSeconds, forKey: .transcribeSeconds)
        try container.encodeIfPresent(refineSeconds, forKey: .refineSeconds)
        try container.encodeIfPresent(gpuBusyPercent, forKey: .gpuBusyPercent)
        // F1016. Absent unless the dictation was cut short, so an ordinary entry keeps its bytes.
        try container.encodeIfPresent(truncated, forKey: .truncated)
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

    public init(entries: [DictationLogEntry] = [], limit: Int = DictationLog.defaultLimit) {
        self.entries = entries
        self.limit = limit
    }

    /// The cap this build writes, and the one it applies when the stored `limit` is negative (F462).
    public static let defaultLimit = 100

    /// The cap `adding` applies: `limit`, or `defaultLimit` when `limit` is negative (F462).
    ///
    /// `limit` is a plain persisted `Int`, so `"limit": -1` — a hand edit, a bad restore, or a later
    /// build's sentinel — decodes cleanly, and `removeLast(count - limit)` then trapped on the next
    /// dictation ("Can't remove more items from a collection than it contains"; `Int.min` overflowed
    /// the subtraction first). I chose the default cap over clamping to 0 or 1: both of those delete
    /// the user's history on the next dictation, and a number nobody chose is no reason to. Zero keeps
    /// its old meaning, keep nothing, because it never trapped. The stored value is written back as
    /// found; this only decides what is applied. What it keeps is "up to 100", not "everything": a
    /// history longer than 100 entries is trimmed to 100 on the next dictation, so if a later build
    /// meant -1 as "unlimited", this build still trims to the default cap.
    public var effectiveLimit: Int { limit >= 0 ? limit : Self.defaultLimit }

    /// Returns a new log with `entry` prepended (most recent first), capped to `effectiveLimit`.
    public func adding(_ entry: DictationLogEntry) -> DictationLog {
        var updated = [entry] + entries
        let cap = effectiveLimit
        if updated.count > cap {
            updated.removeLast(updated.count - cap)
        }
        return DictationLog(entries: updated, limit: limit)
    }

    /// Returns a new, empty log preserving `limit`.
    public func cleared() -> DictationLog {
        DictationLog(entries: [], limit: limit)
    }
}
