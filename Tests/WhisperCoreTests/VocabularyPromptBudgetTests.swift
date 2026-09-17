import Foundation
import Testing
@testable import WhisperCore

// F265 — the vocabulary prompt was capped in CHARACTERS while Whisper budgets it in TOKENS, and
// exceeding that budget silently threw the whole vocabulary away.
//
// `transcribe.py:238` sets `remaining_prompt_length = n_text_ctx // 2 - 1` (223 on both installed
// 448-context checkpoints), `:242` subtracts the prompt's own token count, and `:290` slices
// `all_tokens[nignored:][-remaining_prompt_length:]`. Two branches break:
//   * negative -> `[-(-n):]` is `[n:]`, dropping a fixed prefix and keeping a run that grows with
//     the transcript;
//   * exactly zero -> `-0 == 0`, so `[-0:]` is the ENTIRE history.
// Either way `transcribe.py:291` puts the vocabulary FIRST (`initial_prompt_tokens + remaining`) and
// `decoding.py:609` truncates to the TAIL, so the vocabulary is evicted outright. Measured against a
// 5,000-token history: 150 tokens of vocabulary survive intact, 223 and 300 survive as 0 of 0.
//
// So the guard has to keep the prompt STRICTLY under the limit, which is what these tests pin.
//
// Token counts here are not guesses. They were measured with the installed runtime's own tokenizer
// (`whisper.tokenizer.get_tokenizer(multilingual=True)`): English runs 0.24-0.32 tokens/char, CJK
// 1.28 and up to 2.27 for CJK punctuation, and 100 ASCII terms is 299 real tokens — already over the
// budget, which is why the old "caps at 100 terms / 1000 characters" behaviour was partly fiction.

@Test("The budget stays strictly under Whisper's carried-prompt limit (F265)")
func promptBudgetIsStrictlyUnderTheLimit() {
    // Strictly under, not equal: at equality `remaining_prompt_length` is 0 and `[-0:]` returns the
    // whole token history, which is the eviction branch that looks harmless.
    #expect(VocabularyPrompt.promptTokenBudget < VocabularyPrompt.whisperCarriedPromptTokenLimit)
    #expect(VocabularyPrompt.whisperCarriedPromptTokenLimit == 223)
}

@Test("An empty term list estimates zero tokens (F265)")
func estimateOfNothingIsZero() {
    #expect(VocabularyPrompt.estimatedTokenCount(of: []) == 0)
}

@Test("A CJK character is estimated well above one token (F265)")
func estimateChargesCJKMoreThanASCII() {
    // Real ratios: CJK 1.28-2.27 tokens/char versus English 0.24-0.32. An estimator that charged
    // them alike is how 1,000 characters of Chinese terms blew a 223-token budget by ~6x.
    let cjk = VocabularyPrompt.estimatedTokenCount(of: ["季度營收"])
    let ascii = VocabularyPrompt.estimatedTokenCount(of: ["roadmap"])
    #expect(cjk > ascii)
    #expect(cjk >= 8)
}

@Test("A 100-term English list is trimmed to fit the budget (F265)")
func longEnglishListIsTrimmedToBudget() {
    let terms = (1...100).map { "term\($0)" }
    let prompt = VocabularyPrompt.build(terms)
    let kept = prompt.components(separatedBy: ", ")

    // 100 of these is 299 real tokens, so it MUST come back shorter than the input.
    #expect(kept.count < 100, "an over-budget list must be trimmed, not passed through")
    #expect(!kept.isEmpty)
    #expect(VocabularyPrompt.estimatedTokenCount(of: kept) <= VocabularyPrompt.promptTokenBudget)
    #expect(kept.first == "term1", "trimming drops from the end, keeping the user's first choices")
}

@Test("A Mandarin list is trimmed to fit the same budget (F265)")
func mandarinListIsTrimmedToBudget() {
    let terms = (1...100).map { _ in "關鍵績效指標" }
    let prompt = VocabularyPrompt.build(terms)
    let kept = prompt.components(separatedBy: ", ")

    #expect(kept.count < 100)
    #expect(VocabularyPrompt.estimatedTokenCount(of: kept) <= VocabularyPrompt.promptTokenBudget)
}

@Test("Trimming never cuts a term in half (F265)")
func trimmingKeepsWholeTerms() {
    // The old cap was `joined().prefix(1000)`, which could leave a fragment of a term in the prompt.
    // A half-term is noise the decoder is being told to expect, which is worse than omitting it.
    let terms = (1...100).map { "supercalifragilistic\($0)" }
    let prompt = VocabularyPrompt.build(terms)
    for piece in prompt.components(separatedBy: ", ") {
        #expect(terms.contains(piece), "\(piece) is not a whole term from the input")
    }
}

@Test("A short list is passed through unchanged (F265 must not shrink what already worked)")
func shortListIsUnchanged() {
    #expect(VocabularyPrompt.build(["Acme", "客户成功", "Q3"]) == "Acme, 客户成功, Q3")
    #expect(VocabularyPrompt.build([]) == "")
}

@Test("The built prompt always fits, for every list length up to the term cap (F265)")
func builtPromptAlwaysFits() {
    // The invariant, swept rather than spot-checked: whatever the caller passes, what comes back is
    // within budget — so `remaining_prompt_length` stays positive and nothing is evicted.
    for count in [1, 5, 20, 50, 100, 500] {
        let english = VocabularyPrompt.build((1...count).map { "Term\($0)" })
        let mandarin = VocabularyPrompt.build((1...count).map { _ in "使用者體驗" })
        for prompt in [english, mandarin] where !prompt.isEmpty {
            let kept = prompt.components(separatedBy: ", ")
            #expect(VocabularyPrompt.estimatedTokenCount(of: kept)
                    <= VocabularyPrompt.promptTokenBudget,
                    "count=\(count) produced an over-budget prompt")
        }
    }
}
