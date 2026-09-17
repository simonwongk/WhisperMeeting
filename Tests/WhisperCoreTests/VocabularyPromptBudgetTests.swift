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

@Test("One oversized term does not discard the terms after it (F265)")
func oversizedTermSkipsRatherThanStops() {
    // Found by self-review. `build` used `break`, so the FIRST term that did not fit ended the loop
    // and every later term was lost even with most of the budget unspent. The store sorts
    // alphabetically, so an unlucky single term could land first and return an empty prompt —
    // reinstating the exact whole-vocabulary loss F265 exists to prevent.
    //
    // Reachable, not theoretical: the Add box splits only on "," and newline
    // (`ContentView.swift:2239`), so a Chinese line punctuated with 、 or ，becomes ONE term. At two
    // estimated tokens per non-ASCII scalar, 86 characters is ~173 tokens — over the 170 budget by
    // itself. `MeetingStore.promptSafeTerms:885` already uses `continue` for this reason.
    let oversized = String(repeating: "關", count: 100)   // ~201 estimated tokens on its own
    #expect(VocabularyPrompt.estimatedTokenCount(of: [oversized])
            > VocabularyPrompt.promptTokenBudget, "the fixture must actually be over budget")

    let prompt = VocabularyPrompt.build([oversized, "Acme", "Kubernetes", "Grafana"])
    let kept = prompt.components(separatedBy: ", ")

    #expect(!prompt.isEmpty, "an oversized first term must not empty the whole prompt")
    #expect(kept == ["Acme", "Kubernetes", "Grafana"])
    #expect(!prompt.contains("關"), "the oversized term itself is skipped, never truncated")
}

@Test("A term that cannot ever fit is skipped, and the rest still build (F265)")
func unfittableTermIsSkippedMidList() {
    let oversized = String(repeating: "績", count: 100)
    let prompt = VocabularyPrompt.build(["Acme", oversized, "Grafana"])
    #expect(prompt == "Acme, Grafana")
}

@Test("The echo guard judges only against terms that actually reached the prompt (F265)")
func echoGuardUsesPromptedTermsOnly() {
    // Found by self-review. `isPromptEcho` normalised `terms(raw)` — capped at 100 but NOT budgeted —
    // while `build` now puts far fewer into `--initial_prompt`. Whisper cannot regurgitate a term it
    // was never given, so matching against a trimmed-out term can only ever delete real speech: the
    // guard sets `cleaned = ""` on a noisy clip (`DictationController.swift:733-736`), so the user's
    // dictation vanishes silently. The gap existed before the budget but was nearly empty; the
    // budget widened it to roughly 44 terms.
    let terms = (1...100).map { "term\($0)" }
    let prompted = VocabularyPrompt.promptedTerms(terms)
    #expect(prompted.count < terms.count, "the fixture needs terms that were trimmed out")

    let trimmed = terms.filter { !prompted.contains($0) }
    #expect(trimmed.count >= 2)

    // Two adjacent terms the model was never prompted with, on a clip that scored as silence.
    let dictated = trimmed.suffix(2).joined(separator: " ")
    #expect(!VocabularyPrompt.shouldDropAsPromptEcho(dictated, terms: terms, noSpeechProb: 0.95),
            "real speech was discarded as an echo of terms that were never in the prompt")
}

@Test("A genuine echo of prompted terms is still dropped on a silent clip (F265 keeps F187's guard)")
func echoGuardStillCatchesRealEchoes() {
    let terms = (1...100).map { "term\($0)" }
    let prompted = VocabularyPrompt.promptedTerms(terms)
    let echoed = prompted.prefix(3).joined(separator: " ")
    #expect(VocabularyPrompt.shouldDropAsPromptEcho(echoed, terms: terms, noSpeechProb: 0.95))
    // …and never on a clip that scored as real speech.
    #expect(!VocabularyPrompt.shouldDropAsPromptEcho(echoed, terms: terms, noSpeechProb: 0.1))
}

// MARK: - F272: making the limit visible instead of silent

@Test("Coverage reports how many terms actually reach the prompt (F272)")
func coverageCountsFittingTerms() {
    // F265 made trimming real, which made the Vocabulary screen's copy false: it said "every term
    // shown below … is included in Whisper's local prompt". Some are not, and nothing said so — the
    // user cannot tell which of their terms are actually biasing anything.
    let terms = (1...100).map { "term\($0)" }
    let coverage = VocabularyPrompt.coverage(of: terms)
    #expect(coverage.total == 100)
    #expect(coverage.fitting < 100)
    #expect(coverage.fitting == VocabularyPrompt.promptedTerms(terms).count)
    #expect(coverage.isTruncated)
}

@Test("A list that fits reports no truncation (F272)")
func coverageOfAFittingList() {
    let coverage = VocabularyPrompt.coverage(of: ["Acme", "Kubernetes", "客户成功"])
    #expect(coverage.fitting == 3)
    #expect(coverage.total == 3)
    #expect(!coverage.isTruncated)
}

@Test("An empty list is not described as truncated (F272)")
func coverageOfNothing() {
    let coverage = VocabularyPrompt.coverage(of: [])
    #expect(coverage.total == 0)
    #expect(!coverage.isTruncated)
}

@Test("The notice appears only when terms are actually left out (F272)")
func coverageNoticeOnlyWhenTruncated() {
    #expect(VocabularyPrompt.coverageNotice(for: ["Acme", "Q3"]) == nil)
    #expect(VocabularyPrompt.coverageNotice(for: []) == nil)

    let notice = VocabularyPrompt.coverageNotice(for: (1...100).map { "term\($0)" })
    #expect(notice != nil)
    // It must say the real numbers, because "some terms were dropped" is not actionable — the user
    // needs to know how far over they are to decide what to remove.
    let fitting = VocabularyPrompt.coverage(of: (1...100).map { "term\($0)" }).fitting
    #expect(notice?.contains("\(fitting)") == true)
    #expect(notice?.contains("100") == true)
}

@Test("The Mandarin case is reported honestly, not as an English-sized limit (F272)")
func coverageNoticeForMandarin() {
    // 1.28 tokens/char means a CJK list runs out far sooner, which is exactly the user whose list
    // silently stopped working. The notice must reflect their actual number.
    let terms = (1...60).map { _ in "關鍵績效指標" }
    let coverage = VocabularyPrompt.coverage(of: terms)
    #expect(coverage.isTruncated)
    #expect(coverage.fitting < 30, "a 6-character CJK term costs ~13 estimated tokens")
    #expect(VocabularyPrompt.coverageNotice(for: terms)?.contains("\(coverage.fitting)") == true)
}

// MARK: - F196: the character cap could still cut a term in half

@Test("A prompt never ends in a partial term, whatever the caps do (F196)")
func buildNeverEmitsAPartialTerm() {
    // `build` ended with `.prefix(1000)` on the *joined* string, which can slice mid-word — and a
    // fragment is noise the decoder is being told to expect, which is worse than the term's absence.
    //
    // F265's token budget made this unreachable through the meeting path rather than fixed: 170
    // tokens is ~510 ASCII characters or ~85 CJK ones, both well under 1,000, so the character cap
    // no longer binds. Two caps in series where one is dead is how the character-versus-token
    // confusion survived in the first place (F272's Gap), and the dead one still carried the hazard
    // for the next caller.
    let terms = (0..<400).map { "Term\($0)WithAModeratelyLongName" }
    let prompt = VocabularyPrompt.build(terms)
    let emitted = prompt.components(separatedBy: ", ").filter { !$0.isEmpty }

    #expect(!emitted.isEmpty)
    for term in emitted {
        #expect(terms.contains(term), "emitted a fragment rather than a whole term: \(term)")
    }
    // And it is exactly the budgeted list, joined — no separate character truncation on top.
    #expect(prompt == VocabularyPrompt.promptedTerms(terms).joined(separator: ", "))
}

@Test("A single term longer than the old character cap is dropped, not halved (F196)")
func oneEnormousTermIsDroppedWhole() {
    // The realistic shape: the Add box splits only on "," and newline, so a pasted 、-punctuated
    // Chinese paragraph arrives as ONE term, and it can exceed every cap by itself.
    let enormous = String(repeating: "验", count: 900)
    let prompt = VocabularyPrompt.build([enormous, "Acme", "Kubernetes"])

    #expect(!prompt.contains(enormous.prefix(10)), "kept part of an over-budget term")
    // And it does not take the rest of the list with it — `promptedTerms` skips rather than stops.
    #expect(prompt.contains("Acme"))
    #expect(prompt.contains("Kubernetes"))
}
