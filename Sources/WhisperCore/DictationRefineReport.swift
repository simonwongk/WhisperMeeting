import Foundation

/// Buckets the dictation log's refine outcomes by word count (F214).
///
/// F212 brought every bench case inside its budget on an idle Mac. The user's runs with ~10 GB of
/// swap in use, and a resident refiner whose pages were swapped out is not warm — so the only thing
/// that settles the real rate is the log after a week of ordinary use. The week is theirs to
/// produce; this is the analysis, written first so the answer costs one command rather than a
/// session, and so the bucketing is reviewed before any number depends on it.
///
/// **Beside `DictationRefinePolicy` on purpose.** The buckets use `effectiveWordCount`, the app's
/// own counter — majority-CJK text as ceil(characters / 2), because there are no word spaces — and
/// that is the function the 60-word skip threshold consults. A second copy of that rule elsewhere
/// would be a port, and a port that diverges gives a wrong verdict rather than none (F291).
public struct DictationRefineReport {
    /// F212's baseline is quoted per bucket, so the comparison the ticket actually asks for does not
    /// require going to find what it is against.
    public enum Bucket: String, CaseIterable, Sendable {
        case upTo20, from21To40, from41To60, over60

        var label: String {
            switch self {
            case .upTo20: return "1–20"
            case .from21To40: return "21–40"
            case .from41To60: return "41–60"
            case .over60: return "61+"
            }
        }

        /// What F212 measured on the bench, for the two buckets it reported.
        var baseline: String? {
            switch self {
            case .from21To40: return "11 of 18 rawTimeout"
            case .from41To60: return "17 of 18 rawTimeout"
            default: return nil
            }
        }

        static func containing(words: Int) -> Bucket {
            switch words {
            case ..<21: return .upTo20
            case ..<41: return .from21To40
            case ..<61: return .from41To60
            default: return .over60
            }
        }
    }

    public struct Tally: Sendable {
        /// Every entry that recorded a refinement outcome, whatever it was.
        public var total = 0
        /// Outcomes where the model actually ran: `refined`, `rawTimeout`, `rawRejected`,
        /// `rawError`. `skipped` and `rawBusy` are excluded because the policy declined or the
        /// engine was occupied — neither is evidence about decode speed, and counting them would
        /// dilute the rate downward, which is the flattering direction.
        public var attempted = 0
        public var timedOut = 0
        /// A value this build does not know, kept visible: skipping it understates the sample and
        /// classifying it invents data.
        public var unrecognised = 0

        /// Nil when nothing was attempted. A rate computed from no attempts reads as "no timeouts",
        /// which is the opposite of "nothing measured" — F290's mistake in its original home.
        public var timeoutRate: Double? {
            attempted == 0 ? nil : Double(timedOut) / Double(attempted)
        }
    }

    public private(set) var buckets: [Bucket: Tally] = [:]
    /// Entries carrying a refinement outcome. Entries with none are not data: refinement was off or
    /// never attempted, and including them would inflate the sample by however long it was disabled.
    public private(set) var totalConsidered = 0
    /// Entries dated before `since`, whatever they recorded. Kept and reported rather than dropped
    /// quietly: a filter that shrinks the sample without saying so is how a flattering number gets
    /// made, and the reader cannot tell a narrowed table from a complete one by looking at it.
    public private(set) var excludedAsEarlier = 0

    /// - Parameter since: count only entries dated at or after this. F214's question is about one
    ///   build, and a capped log spans whatever it happens to span — on the machine it was written
    ///   for, 2026-09-10 to 09-17, with F212 reaching the runtime on the evening of the 11th.
    public init(log: DictationLog, since: Date? = nil) {
        for entry in log.entries {
            if let since, entry.date < since {
                excludedAsEarlier += 1
                continue
            }
            guard let raw = entry.refinement else { continue }
            totalConsidered += 1

            // The count must be of the text the POLICY saw, which is the raw transcript. `rawText`
            // is recorded only when refinement changed the delivered text, so a refined entry's
            // input is there and everything else's input is `text`. Counting the delivered words
            // would move every refined entry into whichever bucket the cleanup left it in, and
            // filler removal shortens.
            let input = entry.rawText ?? entry.text
            let bucket = Bucket.containing(
                words: DictationRefinePolicy.effectiveWordCount(of: input)
            )
            var tally = buckets[bucket] ?? Tally()
            tally.total += 1
            switch DictationRefinement(rawValue: raw) {
            case .refined, .rawRejected, .rawError:
                tally.attempted += 1
            case .rawTimeout:
                tally.attempted += 1
                tally.timedOut += 1
            case .skipped, .rawBusy:
                break
            case nil:
                tally.unrecognised += 1
            }
            buckets[bucket] = tally
        }
    }

    public func bucket(_ bucket: Bucket) -> Tally? { buckets[bucket] }

    /// The table to paste into F214's closing log entry, with F212's baseline beside the observed
    /// rate — the ticket's decision rule is a comparison, not a number.
    public func markdown() -> String {
        var lines = [
            "| words | entries | attempted | timed out | rate | F212 bench baseline |",
            "|---|---|---|---|---|---|",
        ]
        for bucket in Bucket.allCases {
            let tally = buckets[bucket] ?? Tally()
            let rate = tally.timeoutRate.map { String(format: "%.0f%%", $0 * 100) } ?? "—"
            lines.append(
                "| \(bucket.label) | \(tally.total) | \(tally.attempted) | \(tally.timedOut) "
                + "| \(rate) | \(bucket.baseline ?? "—") |"
            )
        }
        lines.append("")
        lines.append(
            "A dash is *not measured*, never a zero. `skipped` and `rawBusy` are counted in "
            + "**entries** and excluded from **attempted**: the policy declined, or the engine was "
            + "still busy, and neither says anything about decode speed."
        )
        lines.append("")
        lines.append(
            "**How to read it** (F214's own rule): timeouts concentrated in 41–60 point at decode "
            + "speed, so consider the 4B refiner for 18 GB Macs. Timeouts spread evenly across the "
            + "buckets point at memory pressure instead, and a smaller model will not fix that."
        )

        let unrecognised = buckets.values.reduce(0) { $0 + $1.unrecognised }
        if unrecognised > 0 {
            lines.append("")
            lines.append(
                "\(unrecognised) entr\(unrecognised == 1 ? "y" : "ies") recorded a refinement "
                + "outcome this build does not know, most likely written by a newer one. Counted in "
                + "**entries**, excluded from the rate: an outcome we cannot classify is not an "
                + "attempt we can score."
            )
        }
        if let over = buckets[.over60], over.attempted > 0 {
            lines.append("")
            lines.append(
                "**\(over.attempted) dictation\(over.attempted == 1 ? "" : "s") above the 60-word "
                + "skip threshold was attempted.** `DictationRefinePolicy.decision(for:)` skips "
                + "above 60, so the log and the policy disagree — a build mismatch, or the threshold "
                + "moved since these were recorded. Settle that before reading any rate here."
            )
        }
        return lines.joined(separator: "\n")
    }
}
