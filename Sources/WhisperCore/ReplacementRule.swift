import Foundation

/// A user-defined exact replacement: whenever `heard` appears in a transcript, propose replacing it
/// with `preferred` (F179). Unlike the near-miss `GlossaryCorrector`, this is an *exact* rule the user
/// knows recurs — persisted alongside the business vocabulary. It only ever proposes; the user reviews
/// every proposal before it applies, and the recording is never touched.
public struct ReplacementRule: Codable, Sendable, Equatable, Hashable {
    public let heard: String
    public let preferred: String

    public init(heard: String, preferred: String) {
        self.heard = heard
        self.preferred = preferred
    }
}

/// Turns exact replacement rules into reviewable `GlossaryCorrection`s over a transcript's segments
/// (F179), reusing the same mapping as F165's LLM corrections so rule-based fixes flow through the
/// identical F82 review sheet + `GlossaryCorrector.apply` path (which never opens the audio). Exact
/// substring match; one correction per segment that contains `heard`; no-op and empty rules are
/// dropped.
public enum ReplacementRuleMatcher {
    public static func corrections(
        rules: [ReplacementRule],
        segments: [TranscriptSegment]
    ) -> [GlossaryCorrection] {
        let asCorrections = rules.map { TranscriptCorrection(from: $0.heard, to: $0.preferred) }
        return TranscriptCorrection.glossaryCorrections(from: asCorrections, segments: segments)
    }
}
