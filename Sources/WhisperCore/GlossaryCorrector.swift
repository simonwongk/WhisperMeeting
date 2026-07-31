import Foundation

/// A proposed, user-reviewable spelling correction toward a vocabulary term (F65).
public struct GlossaryCorrection: Sendable, Equatable {
    public let segmentIndex: Int
    public let from: String
    public let to: String

    public init(segmentIndex: Int, from: String, to: String) {
        self.segmentIndex = segmentIndex
        self.from = from
        self.to = to
    }
}

/// Pure near-miss matching of transcript spans against the user's vocabulary. For each term it finds
/// the best 1–3 word window in a segment whose normalized form is similar enough (longest-common-
/// subsequence ratio) to the term, skipping exact matches and too-distant/cross-script candidates.
/// The user reviews every proposal before it applies; nothing auto-applies (F65).
public enum GlossaryCorrector {
    static let similarityThreshold = 0.5
    static let maxWindow = 3

    public static func corrections(
        vocabulary: [String],
        segments: [TranscriptSegment]
    ) -> [GlossaryCorrection] {
        var results: [GlossaryCorrection] = []
        for (index, segment) in segments.enumerated() {
            let words = segment.text
                .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
                .map(String.init)
            guard !words.isEmpty else { continue }
            let normalizedWords = words.map(normalize)

            for term in vocabulary {
                let termNormalized = normalize(term)
                guard !termNormalized.isEmpty else { continue }
                // Already correct — an exact (normalized) token is present.
                if normalizedWords.contains(termNormalized) { continue }

                var best: (similarity: Double, phrase: String)?
                for size in 1...maxWindow where size <= words.count {
                    for start in 0...(words.count - size) {
                        let windowNormalized = normalizedWords[start..<(start + size)].joined()
                        guard !windowNormalized.isEmpty, windowNormalized != termNormalized else { continue }
                        let score = similarity(windowNormalized, termNormalized)
                        if score >= similarityThreshold, score > (best?.similarity ?? 0) {
                            best = (score, words[start..<(start + size)].joined(separator: " "))
                        }
                    }
                }
                if let best {
                    results.append(GlossaryCorrection(segmentIndex: index, from: best.phrase, to: term))
                }
            }
        }
        return results
    }

    /// Alphanumerics-lowercase, separator-free — CJK-safe (ideographs are alphanumeric).
    static func normalize(_ text: String) -> String {
        text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .joined()
    }

    static func similarity(_ a: String, _ b: String) -> Double {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        let lcs = longestCommonSubsequence(Array(a), Array(b))
        return Double(lcs) / Double(max(a.count, b.count))
    }

    static func longestCommonSubsequence(_ a: [Character], _ b: [Character]) -> Int {
        guard !a.isEmpty, !b.isEmpty else { return 0 }
        var dp = [Int](repeating: 0, count: b.count + 1)
        for i in 1...a.count {
            var diagonal = 0
            for j in 1...b.count {
                let current = dp[j]
                dp[j] = a[i - 1] == b[j - 1] ? diagonal + 1 : max(dp[j], dp[j - 1])
                diagonal = current
            }
        }
        return dp[b.count]
    }
}
