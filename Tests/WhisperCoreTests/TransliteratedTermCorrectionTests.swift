import Foundation
import Testing
@testable import WhisperCore

// F768 — the user's decision of 2026-10-16, relayed by whisper-dfd4 and recorded on the ticket: "Yes,
// when it's in my vocabulary". F628 measured Qwen writing the spoken 王老师 as "Wang老师" (and F589
// Whisper Turbo the same), refinement could not repair it (F631: the model translated the line), and
// Qwen takes no vocabulary prompt. So a half-transliterated name is put back in characters — only
// for a term in Business Vocabulary, and only where the pinyin is the characters' own sound.

@Test("A half-transliterated vocabulary name is written in characters (F768)")
func aHalfTransliteratedVocabularyNameIsWrittenInCharacters() {
    // F628's encs4 sentence, as Qwen wrote it.
    #expect(TransliteratedTermCorrection.corrected("我今晚 ping 一下 Wang老师 作业的事。", terms: ["王老师"])
            == "我今晚 ping 一下 王老师 作业的事。")
    #expect(TransliteratedTermCorrection.corrected("跟Wang老师说", terms: ["王老师"]) == "跟王老师说")
    // Any case, and a space a recognizer put between the scripts.
    #expect(TransliteratedTermCorrection.corrected("wang 老师好", terms: ["王老师"]) == "王老师好")
    // Two syllables in pinyin, joined or apart, and the pinyin at the end of the term.
    #expect(TransliteratedTermCorrection.corrected("问Zhang San丰", terms: ["张三丰"]) == "问张三丰")
    #expect(TransliteratedTermCorrection.corrected("问Zhangsan丰", terms: ["张三丰"]) == "问张三丰")
    #expect(TransliteratedTermCorrection.corrected("找小Wang吧", terms: ["小王"]) == "找小王吧")
    // F631's recorded raw encs4 rows (Qwen3-ASR, then Whisper Turbo), which the re-run of F631's
    // refine bench takes as corrected here.
    #expect(TransliteratedTermCorrection.corrected("I'll ping Wang老师 about the作业 tonight.", terms: ["王老师"])
            == "I'll ping 王老师 about the作业 tonight.")
    #expect(TransliteratedTermCorrection.corrected("I'll ping, Wang老师, about the,作业, tonight.", terms: ["王老师"])
            == "I'll ping, 王老师, about the,作业, tonight.")
}

@Test("Nothing else changes: other sounds, whole words, full pinyin, and terms not in the vocabulary (F768)")
func onlyAVocabularyTermsOwnSoundIsCorrected() {
    // Not in the vocabulary.
    #expect(TransliteratedTermCorrection.corrected("Wang老师", terms: []) == "Wang老师")
    #expect(TransliteratedTermCorrection.corrected("Wang老师", terms: ["李老师"]) == "Wang老师")
    // The pinyin is a different sound from the term's character: Huang is 黄, not 王.
    #expect(TransliteratedTermCorrection.corrected("Huang老师", terms: ["王老师"]) == "Huang老师")
    // A near sound is not enough here (MandarinSound's table is for characters heard as characters).
    #expect(TransliteratedTermCorrection.corrected("Zang老师", terms: ["张老师"]) == "Zang老师")
    // Part of a longer Latin word.
    #expect(TransliteratedTermCorrection.corrected("Swang老师", terms: ["王老师"]) == "Swang老师")
    #expect(TransliteratedTermCorrection.corrected("小Wangs", terms: ["小王"]) == "小Wangs")
    // Entirely in pinyin: not half-transliterated, and "Wang" alone is also an English surname.
    #expect(TransliteratedTermCorrection.corrected("Ask Wang Laoshi", terms: ["王老师"]) == "Ask Wang Laoshi")
    // Already right.
    #expect(TransliteratedTermCorrection.corrected("王老师好", terms: ["王老师"]) == "王老师好")
    // A Latin or mixed term is not this correction's business.
    #expect(TransliteratedTermCorrection.corrected("Kubernetes集群", terms: ["Kubernetes集群", "K8s"]) == "Kubernetes集群")
}
