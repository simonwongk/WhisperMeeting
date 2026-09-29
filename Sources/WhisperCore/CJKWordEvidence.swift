import Foundation

/// What the replacement matchers may consult to decide where a Chinese word begins and ends (F594).
///
/// Chinese is written without spaces, so a CJK phrase has no visible word edge: a rule
/// 会议 → 会议室 used to rewrite the 会议 inside 整理会议纪要 as readily as a standalone 会议, the
/// same shape F444 fixed for a Latin "Jon" inside "Jones". `WhisperCore` is Foundation-only (the
/// purity rule, F372), so it cannot segment Chinese itself; the app supplies a segmenter —
/// `NLTokenizer(unit: .word)` — through `segmenter`. The default is no evidence at all, which is
/// exactly the behaviour before F594.
public struct CJKWordEvidence: Sendable {
    /// The word ranges a segmenter finds in the string it is given — ranges into THAT string.
    public typealias Segmenter = @Sendable (String) -> [Range<String.Index>]

    public let segmenter: Segmenter?
    /// Terms the user has taught the app (the Business Vocabulary).
    public let knownTerms: [String]

    public init(segmenter: Segmenter? = nil, knownTerms: [String] = []) {
        self.segmenter = segmenter
        self.knownTerms = knownTerms
    }

    /// No segmenter and no known terms: CJK occurrences are judged as they were before F594.
    public static let none = CJKWordEvidence()
}
