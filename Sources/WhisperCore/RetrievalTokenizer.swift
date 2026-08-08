import Foundation

/// Bag-of-tokens tokenizer for BM25 retrieval (F180). Uses the *same* splitting and normalization as
/// `ActionItemEvidence.contentWords` — lowercased Latin words (≥2 chars, non-stopword) plus
/// overlapping CJK character bigrams (a lone ideograph kept) — but returns an **ordered array that
/// preserves term frequency**, which BM25 needs for per-document counts (where `contentWords` returns a
/// `Set`). It reuses `ActionItemEvidence.isCJKIdeograph` and `.stopwords` verbatim so English and
/// Mandarin tokenize identically to the rest of the app and the F177 CJK fix is never re-broken.
public enum RetrievalTokenizer {
    public static func tokens(_ text: String) -> [String] {
        var out: [String] = []
        var latin = ""
        var cjk: [Character] = []

        func flushLatin() {
            if latin.count >= 2, !ActionItemEvidence.stopwords.contains(latin) { out.append(latin) }
            latin = ""
        }
        func flushCJK() {
            // Emit unigrams AND overlapping bigrams (the Lucene CJKBigramFilter `outputUnigrams` scheme):
            // bigrams give multi-character queries precision, while the unigrams let a legitimate
            // single-character query — a surname (王/李), or a one-character word (税/股/债) — match a
            // document where that character only appears inside a longer run. With bigrams alone, a
            // single-char query's unigram token could never intersect a run's bigram-only vocabulary.
            for character in cjk {
                out.append(String(character))
            }
            if cjk.count >= 2 {
                for i in 0..<(cjk.count - 1) {
                    out.append(String(cjk[i]) + String(cjk[i + 1]))
                }
            }
            cjk = []
        }

        for character in text.lowercased() {
            if let scalar = character.unicodeScalars.first,
               character.unicodeScalars.count == 1,
               ActionItemEvidence.isCJKIdeograph(scalar) {
                flushLatin()
                cjk.append(character)
            } else if character.isLetter || character.isNumber {
                flushCJK()
                latin.append(character)
            } else {
                flushLatin()
                flushCJK()
            }
        }
        flushLatin()
        flushCJK()
        return out
    }
}
