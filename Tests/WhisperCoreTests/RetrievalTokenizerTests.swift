import Foundation
import Testing
@testable import WhisperCore

// F180 — the retrieval tokenizer must preserve term frequency (BM25 needs per-doc counts) and be
// CJK-safe (Chinese has no word spaces), reusing the same splitting as the action-item matcher.

@Test("Tokenizer preserves term frequency as an ordered array, not a set (F180)")
func tokenizerPreservesFrequency() {
    #expect(RetrievalTokenizer.tokens("budget budget review") == ["budget", "budget", "review"])
}

@Test("Tokenizer lowercases Latin words and drops stopwords / single chars (F180)")
func tokenizerLatinNormalization() {
    #expect(RetrievalTokenizer.tokens("The Pricing Plan") == ["pricing", "plan"])
    #expect(RetrievalTokenizer.tokens("a X to of") == []) // all stopwords or <2 chars
}

@Test("Tokenizer emits CJK unigrams and overlapping bigrams (F180)")
func tokenizerCJKUnigramsAndBigrams() {
    // Unigrams (so a single-char query can match) followed by overlapping bigrams (for precision).
    #expect(RetrievalTokenizer.tokens("预算会议") == ["预", "算", "会", "议", "预算", "算会", "会议"])
}

@Test("Tokenizer handles mixed Latin/CJK/number script (F180)")
func tokenizerMixedScript() {
    #expect(RetrievalTokenizer.tokens("Q3 预算") == ["q3", "预", "算", "预算"])
}
