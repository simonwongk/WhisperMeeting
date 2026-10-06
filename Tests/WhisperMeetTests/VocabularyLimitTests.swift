import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F525 — the vocabulary and rule caps used to drop input silently: at 5,000 terms a new term evicted
// a reviewed one while the screen said "Saved N terms"; the "fits the prompt" notice counted the
// alphabetical first 100 terms instead of the starred-first list actually sent; and a 501st rule was
// discarded while the editor cleared the fields as if it had been saved.

@MainActor
private func makeRoot(_ tag: String) throws -> URL {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("F525-\(tag)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    return root
}

/// 4,990 Latin terms and 10 Mandarin ones: the shape the finding probed, because CJK sorts after
/// Latin and so was what an alphabetical cap evicted first.
private let latinFiller = (0..<4_990).map { String(format: "term-%04d", $0) }
private let mandarin = ["路线图", "金流", "预算", "客户成功", "会议纪要", "培训", "报价", "翻译", "作业", "周五"]

@MainActor
@Test("At the 5,000-term limit new terms are refused and counted, and no saved term is evicted (F525)")
func vocabularyAtTheLimitRefusesInsteadOfEvicting() throws {
    let root = try makeRoot("limit")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MeetingStore(rootDirectory: root)
    store.addVocabulary(latinFiller + mandarin)
    try #require(store.vocabulary.count == MeetingStore.maxStoredVocabularyTerms)
    store.setVocabularyPriority("预算", prioritized: true)
    let saved = store.vocabulary

    let result = store.addVocabulary(["Acme", "Dana Liu", "OKR", "预算"])

    // Compared as a Bool and a short list, so a failure does not print 5,000 terms.
    let evicted = Set(saved).subtracting(store.vocabulary)
    #expect(evicted.isEmpty, "evicted to make room: \(evicted.sorted())")
    let unchanged = store.vocabulary == saved
    #expect(unchanged)
    #expect(store.prioritizedVocabulary.contains("预算"))
    #expect(result.added == 0)
    #expect(result.alreadySaved == 1)
    #expect(result.refusedAtLimit == 3)
    #expect(result.message().contains("3 new terms were not added"))
    #expect(result.message().contains(MeetingStore.maxStoredVocabularyTerms.formatted()))
    #expect(!result.message().contains("Saved"))

    // And the list on disk is the one shown.
    let reloaded = MeetingStore(rootDirectory: root).vocabulary == saved
    #expect(reloaded)
}

@MainActor
@Test("Near the limit, what fits is added in the order offered and the rest is counted (F525)")
func vocabularyNearTheLimitAddsWhatFits() throws {
    let root = try makeRoot("near")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MeetingStore(rootDirectory: root)
    store.addVocabulary(Array((latinFiller + mandarin).prefix(MeetingStore.maxStoredVocabularyTerms - 2)))
    let saved = Set(store.vocabulary)

    let result = store.addVocabulary(["Zeta", "  Alpha  ", "Zeta", mandarin[0], "Beta", "Gamma"])

    #expect(result == VocabularyAddition(added: 2, alreadySaved: 1, refusedAtLimit: 2, refusedTerms: ["Beta", "Gamma"]))
    #expect(store.vocabulary.count == MeetingStore.maxStoredVocabularyTerms)
    let evicted = saved.subtracting(store.vocabulary)
    #expect(evicted.isEmpty, "evicted to make room: \(evicted.sorted())")
    let entered: Set<String> = Set(store.vocabulary).subtracting(saved)
    #expect(entered == ["Zeta", "Alpha"])
    #expect(result.message() == "Saved 2 terms. \(result.limitSentence ?? "")")
}

@MainActor
@Test("A list already past the limit loads whole, so the next save cannot trim it (F525)")
func vocabularyPastTheLimitLoadsWhole() throws {
    let root = try makeRoot("past")
    defer { try? FileManager.default.removeItem(at: root) }
    // Written by another build or by hand. Loading used to keep only the first 5,000 in memory, and
    // the next save — any edit, or Keep This List — made that the file.
    let terms = (0..<(MeetingStore.maxStoredVocabularyTerms + 3)).map { String(format: "entry-%05d", $0) }
    try JSONEncoder().encode(terms).write(to: root.appendingPathComponent("vocabulary.json"))

    let store = MeetingStore(rootDirectory: root)

    #expect(store.vocabulary.count == terms.count)
    #expect(store.addVocabulary(["one more"]).refusedAtLimit == 1)
}

@MainActor
@Test("The prompt notice counts the starred-first list actually sent, out of every stored term (F525)")
func coverageNoticeCountsWhatIsSent() throws {
    let root = try makeRoot("coverage")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MeetingStore(rootDirectory: root)
    store.addVocabulary(latinFiller + mandarin)
    for term in mandarin { store.setVocabularyPriority(term, prioritized: true) }

    // Derived from what the meeting path sends (`LocalWhisperClient` builds its prompt from
    // `promptVocabulary`), not restated.
    let sent = VocabularyPrompt.promptedTerms(store.promptVocabulary)
    try #require(Set(mandarin).isSubset(of: Set(sent)), "the premise: starred terms are sent first")
    let notice = try #require(store.vocabularyCoverageNotice)

    #expect(notice.hasPrefix("\(sent.count.formatted()) of your \(store.vocabulary.count.formatted()) terms fit"))
}

@MainActor
@Test("Adding a replacement rule says whether it was added, a duplicate, or over the limit (F525)")
func replacementRuleOutcomes() throws {
    let root = try makeRoot("rules")
    defer { try? FileManager.default.removeItem(at: root) }
    let store = MeetingStore(rootDirectory: root)

    #expect(store.addReplacementRule(heard: "Jon Snow", preferred: "Jonathan Stow") == .added)
    #expect(store.addReplacementRule(heard: " Jon Snow ", preferred: "Jonathan Stow") == .duplicate)
    #expect(store.addReplacementRule(heard: "same", preferred: "same") == .noChange)
    for index in 1..<MeetingStore.maxReplacementRules {
        store.addReplacementRule(heard: "heard \(index)", preferred: "preferred \(index)")
    }
    try #require(store.replacementRules.count == MeetingStore.maxReplacementRules)

    let outcome = store.addReplacementRule(heard: "Kubernets", preferred: "Kubernetes")

    #expect(outcome == .atLimit)
    #expect(store.replacementRules.count == MeetingStore.maxReplacementRules)
    #expect(outcome.message?.contains(MeetingStore.maxReplacementRules.formatted()) == true)
    #expect(ReplacementRuleAddition.added.message == nil)
}

// MARK: - The screen (ContentView cannot be rendered in this target — F174; comment-stripped source)

@Test("The rule editor keeps the typed rule unless it was added, and shows why (F525)")
func ruleEditorKeepsTheDraftsUnlessAdded() throws {
    let source = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/ContentView.swift")
    let start = try #require(source.range(of: "private func addRule()"))
    let body = String(source[start.upperBound...].prefix(700))

    // Booleans rather than `source`/`body` in the expectation, so a failure names the check and
    // does not print the whole file.
    let guardAdded = body.range(of: "guard outcome == .added else")
    let clear = body.range(of: "heardDraft = \"\"")
    let keepsDraftsUnlessAdded = guardAdded.map { g in clear.map { g.lowerBound < $0.lowerBound } ?? false } ?? false
    #expect(keepsDraftsUnlessAdded, "the drafts must be cleared only after the rule was added")
    let recordsTheReason = body.contains("ruleMessage = outcome.message")
    #expect(recordsTheReason)
    let showsTheReason = source.contains("Text(ruleMessage)")
    #expect(showsTheReason)
}

@Test("The Add box keeps the terms the store refused, and clears only what was taken (F525)")
func addBoxKeepsRefusedTerms() throws {
    let source = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/ContentView.swift")
    let start = try #require(source.range(of: "private func addManualTerms()"))
    let body = String(source[start.upperBound...].prefix(1_200))
    let end = body.range(of: "private func ").map { String(body[..<$0.lowerBound]) } ?? body
    // The review (rev-G F-d) set the field to "" unconditionally and every test still passed.
    let keepsRefused = end.contains("manualTerms = result.refusedTerms.joined(separator: \"\\n\")")
    #expect(keepsRefused)
    let clearsUnconditionally = end.contains("manualTerms = \"\"")
    #expect(!clearsUnconditionally)
    let keepsEverythingWhenRefused = end.contains("if !result.wasRefused")
    #expect(keepsEverythingWhenRefused)
}

@Test("The Vocabulary screen reports what the store refused and the notice it computes (F525)")
func vocabularyScreenUsesTheStoresAccounting() throws {
    let source = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/ContentView.swift")
    let usesStoreNotice = source.contains("store.vocabularyCoverageNotice")
    #expect(usesStoreNotice)
    let usesOldNotice = source.contains("VocabularyPrompt.coverageNotice(for: store.vocabulary")
    #expect(!usesOldNotice)
    // The Add box and Import Documents… say what the store reports, not a before/after diff,
    // which cannot see a term that was turned away.
    let diffsTheList = source.contains("Set(store.vocabulary).subtracting(before)")
    #expect(!diffsTheList)
    let messageUses = source.components(separatedBy: ".message(").count - 1
    #expect(messageUses >= 2)
    // Suggest Vocabulary had no message at all; a refusal at the limit must reach the user.
    let suggestReportsTheLimit = source.contains(".limitSentence")
    #expect(suggestReportsTheLimit)
}
