import Foundation
import Testing
@testable import WhisperMeet

// F518 Part 1 — the name finder must keep only NLTagger's person/place/organisation tags, not its
// `.otherWord` catch-all, so ordinary words (English or Chinese) stop being saved as vocabulary.

@Test("Ordinary words are not saved as vocabulary terms, even when NLTagger tags them (F518)")
func ordinaryWordsAreNotCandidates() {
    let terms = Set(VocabularyExtractor.candidates(
        in: "The agenda for tomorrow covers budget and hiring plans.",
        includeLineHeuristic: false
    ))
    // None of these are a person, a place, or an organisation.
    #expect(!terms.contains("The"))
    #expect(!terms.contains("agenda"))
    #expect(!terms.contains("budget"))
    #expect(!terms.contains("hiring"))
}

@Test("Ordinary Chinese words are not saved as vocabulary terms (F518)")
func ordinaryChineseWordsAreNotCandidates() {
    let terms = Set(VocabularyExtractor.candidates(
        in: "我们明天开会讨论预算", includeLineHeuristic: false
    ))
    #expect(!terms.contains("我们"))
    #expect(!terms.contains("明天"))
}

@Test("A real person's name is still saved as a vocabulary term (F518)")
func personalNameStillMatches() {
    let terms = Set(VocabularyExtractor.candidates(
        in: "Please loop in Priya Raman on the Kestrel release.", includeLineHeuristic: false
    ))
    #expect(terms.contains("Priya Raman"))
}

// MARK: - F518 Part 3: the document line heuristic

@Test("A short Chinese sentence ending in 。 or ！ is rejected, not saved as one term (F518)")
func chineseSentencesAreRejected() {
    let terms = Set(VocabularyExtractor.candidates(in: "本次会议讨论了预算问题。\n请大家准时参加！\n"))
    #expect(!terms.contains("本次会议讨论了预算问题。"))
    #expect(!terms.contains("请大家准时参加！"))
    // Nothing usable was salvaged from a rejected sentence either.
    #expect(!terms.contains("本次会议讨论了预算问题"))
}

@Test("An enumeration-comma-joined line splits into separate terms instead of one joined term (F518)")
func enumerationJoinedNamesSplit() {
    let terms = Set(VocabularyExtractor.candidates(in: "张经理、李总监\n"))
    #expect(terms.contains("张经理"))
    #expect(terms.contains("李总监"))
    #expect(!terms.contains("张经理、李总监"))
}

@Test("A full-width-comma-joined line also splits into separate terms (F518)")
func fullWidthCommaJoinedNamesSplit() {
    let terms = Set(VocabularyExtractor.candidates(in: "张经理，李总监\n"))
    #expect(terms.contains("张经理"))
    #expect(terms.contains("李总监"))
    #expect(!terms.contains("张经理，李总监"))
}

@Test("An ASCII-comma line is still rejected outright, unchanged from before this fix (F518)")
func asciiCommaLineStillRejected() {
    let terms = Set(VocabularyExtractor.candidates(in: "Kubernetes, Prometheus\n", includeLineHeuristic: true))
    // Neither the whole line nor a naive split survives — this ticket did not touch ASCII-comma
    // handling, only the Chinese punctuation gaps.
    #expect(!terms.contains("Kubernetes, Prometheus"))
}

@Test("A plain short line with no sentence or enumeration punctuation is still saved whole (F518)")
func plainLineStillSavedWhole() {
    let terms = Set(VocabularyExtractor.candidates(in: "Kubernetes\n"))
    #expect(terms.contains("Kubernetes"))
}

// MARK: - F518 Part 3 follow-up (review round 2): the widened rejection set dropped a term that is
// itself punctuated — "Yahoo!" — where the pre-F518 code kept it. Narrowed so a Latin
// sentence-ending mark only rejects when the line goes on to show sentence structure; a Chinese
// mark still rejects unconditionally, since no legitimate term itself ends in one.

@Test("A punctuated term on its own line survives the sentence filter (F518 follow-up)")
func punctuatedTermOnOwnLineSurvives() {
    let terms = Set(VocabularyExtractor.candidates(in: "Yahoo!\n"))
    #expect(terms.contains("Yahoo!"))
}

@Test("A Chinese sentence still rejects even when its only mark trails the line, no space, under the length cap (F518 follow-up)")
func moreChineseSentencesAreRejected() {
    let terms = Set(VocabularyExtractor.candidates(in: "这是一句话。\n请提醒我下午三点跟客户开会！\n"))
    #expect(!terms.contains("这是一句话。"))
    #expect(!terms.contains("请提醒我下午三点跟客户开会！"))
    #expect(!terms.contains("这是一句话"))
    #expect(!terms.contains("请提醒我下午三点跟客户开会"))
}

@Test("A multi-word Latin line ending in punctuation still reads as a sentence and rejects (F518 follow-up)")
func multiWordPunctuatedLineStillRejected() {
    let terms = Set(VocabularyExtractor.candidates(in: "Thank you!\n"))
    #expect(!terms.contains("Thank you!"))
}

@Test("A 、-joined list still splits after the follow-up narrowing (F518 follow-up)")
func enumerationListStillSplitsAfterFollowUp() {
    let terms = Set(VocabularyExtractor.candidates(in: "张经理、李总监\n"))
    #expect(terms.contains("张经理"))
    #expect(terms.contains("李总监"))
    #expect(!terms.contains("张经理、李总监"))
}

// MARK: - F593: single-word technical jargon on the transcript path

// F518 scoped the name finder to person/place/organisation tags on BOTH paths. That correctly
// stopped a document import from saving every common word, but on the transcript path
// (`includeLineHeuristic: false`) there is no line heuristic to fall back on, so a single-word
// technical term NLTagger classifies as `.otherWord` — "Kubernetes", "Kestrel", "gRPC" — stopped
// being suggested at all. These tests pin the minimal repro the ticket names, the shape-rule signals
// that rescue it, and that F518's own property (no ordinary word suggested) still holds.

@Test("A single-word technical term mid-sentence is suggested from a transcript (F593)")
func kubernetesInProseIsSuggested() {
    // RED before F593 (NLTagger tags "Kubernetes" here `.otherWord`, which F518 alone drops
    // entirely on the transcript path); GREEN after, via the mid-sentence-capitalization signal.
    let terms = Set(VocabularyExtractor.candidates(
        in: "We use Kubernetes for orchestration.", includeLineHeuristic: false
    ))
    #expect(terms.contains("Kubernetes"))
}

@Test("Every single-word jargon term in a jargon-heavy transcript is recovered (F593 recall)")
func jargonHeavyTranscriptRecoversEveryTerm() {
    // Real command output measuring this fixture is in docs/TICKET_LOG.md's F593 entry.
    let transcript = """
    We use Kubernetes for orchestration and Grafana for dashboards.
    Our Kestrel service talks to Redis and Postgres over gRPC.
    The team adopted Terraform and Ansible for infrastructure as code.
    We also rely on Prometheus, Kafka, and Elasticsearch daily.
    Kubernetes upgrades happen every quarter without downtime.
    """
    let terms = Set(VocabularyExtractor.candidates(in: transcript, includeLineHeuristic: false))
    let expectedJargon: Set<String> = [
        "Kubernetes", "Grafana", "Kestrel", "Redis", "Postgres", "gRPC",
        "Terraform", "Ansible", "Prometheus", "Kafka", "Elasticsearch",
    ]
    #expect(expectedJargon.isSubset(of: terms), "missed: \(expectedJargon.subtracting(terms))")
}

@Test("No common word is suggested from a plain-prose transcript, mid-sentence or not (F593 keeps F518's property)")
func plainProseTranscriptSuggestsNoCommonWord() {
    // Real command output measuring this fixture is in docs/TICKET_LOG.md's F593 entry.
    let transcript = """
    The agenda for tomorrow covers budget and hiring plans.
    We should focus on next week's meeting since approval is pending.
    Everyone agreed the schedule works and the office will be closed on Friday.
    The committee will review the proposal next week during the session.
    """
    let terms = Set(VocabularyExtractor.candidates(in: transcript, includeLineHeuristic: false))
    let commonWords = [
        "The", "the", "and", "we", "We", "will", "of", "on", "agenda", "budget", "hiring",
        "plans", "meeting", "approval", "pending", "schedule", "office", "committee",
        "proposal", "session", "Everyone",
    ]
    for word in commonWords {
        #expect(!terms.contains(word), "'\(word)' should not have been suggested")
    }
    // "Friday" is capitalized mid-sentence but is a calendar name, not a technical term.
    #expect(!terms.contains("Friday"))
}

@Test("A sentence-initial common word that recurs across lines is still excluded (F593 does not reopen F518)")
func recurringSentenceInitialCommonWordStaysExcluded() {
    // "The" opens all three lines here, so it repeats across lines exactly like a genuine recurring
    // term would (signal 4) — it must still be excluded, via the lexicalClass (Determiner, not Noun)
    // gate on that signal, not merely by being sentence-initial.
    let transcript = """
    The budget review starts on Monday.
    The team will finalize numbers by then.
    The report goes out after that.
    """
    let terms = Set(VocabularyExtractor.candidates(in: transcript, includeLineHeuristic: false))
    #expect(!terms.contains("The"))
}

@Test("A term that always opens a sentence is still suggested once it repeats across lines (F593 signal 4)")
func sentenceInitialRepeatedNounIsSuggested() {
    let transcript = """
    Kestrel handles authentication for every service.
    Kestrel also manages the session cache.
    """
    let terms = Set(VocabularyExtractor.candidates(in: transcript, includeLineHeuristic: false))
    #expect(terms.contains("Kestrel"))
}

@Test("F593's shape rule only applies to the transcript path, never to documents")
func documentPathUnaffectedByTranscriptShapeRule() {
    // One long sentence: `lineReadsAsSentence` already rejects it whole on the document path (over
    // 48 characters, ends in a sentence-ending mark), so the only question this test asks is
    // whether F593's new shape rule leaks into the document path and picks "Kestrel" out on its own
    // the way it now does on the transcript path.
    let text = "During the migration we adopted Kestrel for the internal API gateway before the rollout finished."
    let documentTerms = Set(VocabularyExtractor.candidates(in: text, includeLineHeuristic: true))
    let transcriptTerms = Set(VocabularyExtractor.candidates(in: text, includeLineHeuristic: false))
    #expect(!documentTerms.contains("Kestrel"))
    #expect(transcriptTerms.contains("Kestrel"))
}
