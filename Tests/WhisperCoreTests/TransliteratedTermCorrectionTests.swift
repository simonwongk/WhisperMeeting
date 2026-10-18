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
    // Any case.
    #expect(TransliteratedTermCorrection.corrected("wang老师好", terms: ["王老师"]) == "王老师好")
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

private func c(_ text: String, _ terms: [String]) -> String {
    TransliteratedTermCorrection.corrected(text, terms: terms)
}

// The Wave 8 lane C review's findings 1, 3 and 5 (`.claude/wave8/reviews/lane-C-review.md`). Each
// narrows the user's rule rather than reopening it: where the Latin is not a name written half in
// pinyin, or the vocabulary cannot say which name it was, the text stays as heard.

@Test("An English word that is also a pinyin syllable is left as English (F768 review, finding 1)")
func anEnglishWordBesideHanIsNotPinyin() {
    // An English word spelled like a syllable, beside a Han character that continues a vocabulary term.
    #expect(c("我 ping 台湾同事一下", ["平台"]) == "我 ping 台湾同事一下")
    #expect(c("I need a 里程碑 by Friday", ["阿里"]) == "I need a 里程碑 by Friday")
    #expect(c("I want an 全新 design", ["安全"]) == "I want an 全新 design")
    #expect(c("you 先说吧", ["优先"]) == "you 先说吧")
    #expect(c("我们 long 时间没见了", ["龙时"]) == "我们 long 时间没见了")
    #expect(c("这个 bug 很 man 烦", ["满烦"]) == "这个 bug 很 man 烦")
    #expect(c("他是 a 姨的儿子", ["阿姨"]) == "他是 a 姨的儿子")
    // Joined to the characters, as Qwen writes English beside Han ("the作业", F631): only the derived
    // list of syllables that are common English words keeps these.
    #expect(c("you先说吧", ["优先"]) == "you先说吧")
    #expect(c("我ping台湾同事", ["平台"]) == "我ping台湾同事")
    // A surname the English list does not hold is still corrected.
    #expect(c("跟Zhang老师说", ["张老师"]) == "跟张老师说")
}

@Test("The derived list holds common English words and not the surnames the correction is for (F768)")
func theDerivedEnglishSyllablesAreCommonWords() {
    for word in ["a", "an", "you", "ping", "long", "man"] {
        #expect(PinyinEnglishWords.words.contains(word), "\(word)")
    }
    for surname in ["wang", "zhang", "li", "chen", "liu", "zhao", "huang", "zhou"] {
        #expect(!PinyinEnglishWords.words.contains(surname), "\(surname)")
    }
    // Every entry is a syllable the correction could compare against: lowercase ASCII letters.
    #expect(PinyinEnglishWords.words.allSatisfy { !$0.isEmpty && $0.allSatisfy { $0.isASCII && $0.isLowercase } })
}

@Test("Two vocabulary terms with the same pinyin leave the span as heard (F768 review, finding 3)")
func homophoneTermsLeaveTheSpanAsHeard() {
    #expect(c("跟Wang老师说", ["王老师", "汪老师"]) == "跟Wang老师说")
    #expect(c("跟Wang老师说", ["汪老师", "王老师"]) == "跟Wang老师说")
    // A longer term still wins over a shorter one it contains, which is not ambiguous.
    #expect(c("跟Wang老师说", ["王老", "王老师"]) == "跟王老师说")
}

@Test("Pinyin inside a longer word of any Latin script is left alone, and near misses stay as heard (F768 review, finding 5)")
func nearMissesStayAsHeard() {
    #expect(c("éwang老师", ["王老师"]) == "éwang老师")
    #expect(c("Wan老师", ["王老师"]) == "Wan老师")
    #expect(c("Wong老师", ["王老师"]) == "Wong老师")
    #expect(c("Wangg老师", ["王老师"]) == "Wangg老师")
    #expect(c("Wang-老师", ["王老师"]) == "Wang-老师")
    #expect(c("2wang老师", ["王老师"]) == "2wang老师")
    #expect(c("Wang 老师", ["王老师"]) == "Wang 老师")
    #expect(c("Wang老师", ["王 老师"]) == "Wang老师")
    #expect(c("Wang老师", ["王老师2"]) == "Wang老师")
}

// The Wave 8 round-2 review's findings C6 and C7 (`.claude/wave8/reviews/round2-CDG-review.md`).

@Test("An all-capitals acronym that spells a pinyin syllable is not a vocabulary name (F768 review, C6)")
func anAcronymIsNotPinyin() {
    // The review's probe rows: "AI" is the commonest Latin token in this user's code-switched speech.
    #expect(c("我们的AI芯片很快", ["爱芯"]) == "我们的AI芯片很快")
    #expect(c("我们做了一个小AI助手", ["小爱"]) == "我们做了一个小AI助手")
    #expect(c("这个AI模型", ["爱模"]) == "这个AI模型")
    #expect(c("看一下BI报表", ["比报"]) == "看一下BI报表")
    #expect(c("DA分析", ["大分"]) == "DA分析")
    // Recognizers write names "Wang", never "WANG"; a capitalised name is still corrected.
    #expect(c("WANG老师", ["王老师"]) == "WANG老师")
    #expect(c("Ai老师好", ["艾老师"]) == "艾老师好")
}

@Test("A capitalised surname that is also an English word is corrected right before Chinese; lowercase English is not (F768, the user's decision of 2026-10-17)")
func aCapitalisedSurnameBeforeChineseIsCorrected() {
    // The round-2 review's 13-surname probe: 12 of these stayed as heard before this decision.
    let rows: [(String, [String], String)] = [
        ("请Yang老师看一下", ["杨老师"], "请杨老师看一下"),
        ("Sun总说可以", ["孙总"], "孙总说可以"),
        ("He经理来了", ["何经理"], "何经理来了"),
        ("Song老师好", ["宋老师"], "宋老师好"),
        ("Tang总在吗", ["唐总"], "唐总在吗"),
        ("Fan老师好", ["范老师"], "范老师好"),
        ("Fang经理好", ["方经理"], "方经理好"),
        ("Long总好", ["龙总"], "龙总好"),
        ("Yuan老师好", ["袁老师"], "袁老师好"),
        ("Pan总好", ["潘总"], "潘总好"),
        ("Ding老师好", ["丁老师"], "丁老师好"),
        ("小Yang呢", ["小杨"], "小杨呢"),
        ("Wang老师好", ["王老师"], "王老师好"),
    ]
    for (text, terms, wanted) in rows {
        #expect(c(text, terms) == wanted, "\(text)")
    }
    // Lowercase English words stay untouched, as round 2's finding 1 fixed them.
    #expect(c("you先说吧", ["优先"]) == "you先说吧")
    #expect(c("我ping台湾同事", ["平台"]) == "我ping台湾同事")
    #expect(c("yang老师", ["杨老师"]) == "yang老师")
    #expect(c("YANG老师", ["杨老师"]) == "YANG老师")
    // Directly before Chinese characters: a space between them is still English beside Han.
    #expect(c("Yang 老师", ["杨老师"]) == "Yang 老师")
    #expect(c("小Yang.", ["小杨"]) == "小Yang.")
}
