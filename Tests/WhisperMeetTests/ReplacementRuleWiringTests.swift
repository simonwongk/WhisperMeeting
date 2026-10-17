import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F179 — replacement rules persist alongside vocabulary, and the AppModel surfaces rule-based
// corrections through the same review + apply path as F82 glossary corrections.

@MainActor
private func makeModel(root: URL) throws -> AppModel {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let defaults = UserDefaults(suiteName: testSuiteName())!
    return AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(), defaults: defaults)
}

@MainActor
@Test("Replacement rules persist and reload from disk, ignoring empty/no-op/duplicate rules (F179)")
func replacementRulesPersist() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ReplacementRuleWiringTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }

    let store = MeetingStore(rootDirectory: root)
    store.addReplacementRule(heard: "Sequoia", preferred: "Sequoya")
    store.addReplacementRule(heard: "  Acme corp ", preferred: "ACME Corp") // trimmed
    store.addReplacementRule(heard: "same", preferred: "same")               // no-op, ignored
    store.addReplacementRule(heard: "", preferred: "x")                       // empty, ignored
    store.addReplacementRule(heard: "Sequoia", preferred: "Sequoya")         // duplicate, ignored

    #expect(store.replacementRules == [
        ReplacementRule(heard: "Sequoia", preferred: "Sequoya"),
        ReplacementRule(heard: "Acme corp", preferred: "ACME Corp"),
    ])

    // A fresh store over the same directory reloads the rules from disk.
    let reloaded = MeetingStore(rootDirectory: root)
    #expect(reloaded.replacementRules == store.replacementRules)

    store.removeReplacementRule(ReplacementRule(heard: "Sequoia", preferred: "Sequoya"))
    #expect(store.replacementRules == [ReplacementRule(heard: "Acme corp", preferred: "ACME Corp")])
}

@MainActor
@Test("AppModel surfaces rule-based corrections and applies them through the review path (F179)")
func ruleCorrectionsReachApplyPath() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ReplacementRuleWiringTests-apply-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let model = try makeModel(root: root)

    model.store.addReplacementRule(heard: "Sequoia", preferred: "Sequoya")
    let segments = [TranscriptSegment(speaker: nil, start: 0, end: 1, text: "We use Sequoia for infra.")]
    let id = UUID()
    model.store.upsert(MeetingRecord(
        id: id, title: "M", status: .completed,
        transcriptText: TranscriptFormatter.timestamped(segments), segments: segments
    ))

    let proposals = try #require(await model.replacementRuleCorrections(for: id))
    #expect(proposals == [GlossaryCorrection(segmentIndex: 0, from: "Sequoia", to: "Sequoya", proposedLine: "We use Sequoia for infra.")])

    model.applyGlossaryCorrections(proposals, to: id)
    #expect(model.store.meeting(id: id)?.segments.first?.text == "We use Sequoya for infra.")
    #expect(model.store.meeting(id: id)?.transcriptText.contains("Sequoya") == true)
}

@MainActor
@Test("Improve proposes a lower-case rule for the sentence-initial capital, and Apply writes it (F858)")
func ruleCorrectionsMatchASentenceInitialCapital() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ReplacementRuleWiringTests-capital-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let model = try makeModel(root: root)

    model.store.addReplacementRule(heard: "jon", preferred: "Jonathan")
    let segments = [TranscriptSegment(speaker: nil, start: 0, end: 1, text: "Jon said the build is green.")]
    let id = UUID()
    model.store.upsert(MeetingRecord(
        id: id, title: "M", status: .completed,
        transcriptText: TranscriptFormatter.timestamped(segments), segments: segments
    ))

    let proposals = try #require(await model.replacementRuleCorrections(for: id))
    #expect(proposals == [GlossaryCorrection(segmentIndex: 0, from: "Jon", to: "Jonathan", proposedLine: "Jon said the build is green.")])

    model.applyGlossaryCorrections(proposals, to: id)
    #expect(model.store.meeting(id: id)?.segments.first?.text == "Jonathan said the build is green.")
}

@MainActor
@Test("Improve proposes a lower-case rule for the word, never for the same word capitalised mid-sentence (F858)")
func ruleCorrectionsLeaveAMidSentenceCapitalAlone() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ReplacementRuleWiringTests-midsentence-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let model = try makeModel(root: root)

    model.store.addReplacementRule(heard: "bill", preferred: "invoice")
    let segments = [TranscriptSegment(speaker: nil, start: 0, end: 1, text: "Ask Bill about the bill.")]
    let id = UUID()
    model.store.upsert(MeetingRecord(
        id: id, title: "M", status: .completed,
        transcriptText: TranscriptFormatter.timestamped(segments), segments: segments
    ))

    let proposals = try #require(await model.replacementRuleCorrections(for: id))
    #expect(proposals == [GlossaryCorrection(segmentIndex: 0, from: "bill", to: "invoice", proposedLine: "Ask Bill about the bill.")])

    model.applyGlossaryCorrections(proposals, to: id)
    #expect(model.store.meeting(id: id)?.segments.first?.text == "Ask Bill about the invoice.")
}

@MainActor
@Test("Improve proposes a sentence's first word after the same name mid-sentence, shows its own sentence, and applies it there (F950)")
func ruleCorrectionsReachASentenceStartAfterTheSameName() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ReplacementRuleWiringTests-samename-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let model = try makeModel(root: root)

    model.store.addReplacementRule(heard: "jon", preferred: "jonathan")
    let segments = [TranscriptSegment(speaker: nil, start: 0, end: 1, text: "Zoë and Jon. Jon left.")]
    let id = UUID()
    model.store.upsert(MeetingRecord(
        id: id, title: "M", status: .completed,
        transcriptText: TranscriptFormatter.timestamped(segments), segments: segments
    ))

    let proposals = try #require(await model.replacementRuleCorrections(for: id))
    #expect(proposals == [GlossaryCorrection(segmentIndex: 0, from: "Jon", to: "Jonathan", characterOffset: 13, proposedLine: "Zoë and Jon. Jon left.")])
    // The row's sentence is about the second "Jon", the one it changes.
    #expect(await model.proposalContexts(proposals, in: id)
        == [ProposalContext(before: "Zoë and Jon. ", match: "Jon", after: " left.")])

    model.applyGlossaryCorrections(proposals, to: id)
    #expect(model.store.meeting(id: id)?.segments.first?.text == "Zoë and Jon. Jonathan left.")
}

@MainActor
@Test("Improve reads a line that continues the line before it as mid-sentence, and a title's full stop as no sentence end (F938)")
func ruleCorrectionsReadSentencesAcrossLines() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ReplacementRuleWiringTests-acrosslines-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let model = try makeModel(root: root)

    model.store.addReplacementRule(heard: "jason", preferred: "JSON")
    let lines = ["I talked to", "Jason about the jason file.", "Ask Dr. Jason.", "Done.", "Jason said so."]
    let segments = lines.enumerated().map {
        TranscriptSegment(speaker: nil, start: Double($0.offset), end: Double($0.offset + 1), text: $0.element)
    }
    let id = UUID()
    model.store.upsert(MeetingRecord(
        id: id, title: "M", status: .completed,
        transcriptText: TranscriptFormatter.timestamped(segments), segments: segments
    ))

    let proposals = try #require(await model.replacementRuleCorrections(for: id))
    #expect(proposals == [
        GlossaryCorrection(segmentIndex: 1, from: "jason", to: "JSON", proposedLine: lines[1]),
        GlossaryCorrection(segmentIndex: 4, from: "Jason", to: "JSON", proposedLine: lines[4]),
    ])

    model.applyGlossaryCorrections(proposals, to: id)
    #expect(model.store.meeting(id: id)?.segments.map(\.text)
        == ["I talked to", "Jason about the JSON file.", "Ask Dr. Jason.", "Done.", "JSON said so."])
}

// F971 — Apply resolved a reviewed row against the meeting's lines at Apply time. If a line changed
// after the review was proposed (a second window on the meeting, or the lines replaced under an
// open sheet), a row could land on a word nobody reviewed: since F950 a row with a stored place, on
// another occurrence that now starts there; before it, any row, on the first occurrence of its text.

@MainActor
private func meeting(_ model: AppModel, lines: [String]) -> UUID {
    let segments = lines.enumerated().map {
        TranscriptSegment(speaker: nil, start: Double($0.offset), end: Double($0.offset + 1), text: $0.element)
    }
    let id = UUID()
    model.store.upsert(MeetingRecord(
        id: id, title: "M", status: .completed,
        transcriptText: TranscriptFormatter.timestamped(segments), segments: segments
    ))
    return id
}

@MainActor
@Test("A reviewed row whose line changed after it was proposed is not applied, and Apply says so (F971)")
func applySkipsARowWhoseLineChanged() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ReplacementRuleWiringTests-changedline-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let model = try makeModel(root: root)
    model.store.addReplacementRule(heard: "jon", preferred: "jonathan")
    let id = meeting(model, lines: ["Sam and Jon. Jon left."])

    // The rules review: one row, for the sentence's "Jon", carrying its place (F950).
    let rows = try #require(await model.replacementRuleCorrections(for: id))
    #expect(rows.map(\.characterOffset) == [13])
    // Meanwhile another Apply on the meeting changes the line: "Sam" → "Samantha" (+5 characters),
    // so the name "Jon" now starts where the reviewed "Jon" did.
    model.applyGlossaryCorrections([GlossaryCorrection(segmentIndex: 0, from: "Sam", to: "Samantha")], to: id)
    #expect(model.store.meeting(id: id)?.segments.first?.text == "Samantha and Jon. Jon left.")

    // The review's Apply: the row was reviewed on another line, so nothing is written, and the user is told.
    #expect(model.applyGlossaryCorrections(rows, to: id) == nil)
    #expect(model.store.meeting(id: id)?.segments.first?.text == "Samantha and Jon. Jon left.")
    #expect(model.alertMessage == AppModel.correctionsOnChangedLinesMessage(1))
    #expect(AppModel.correctionsOnChangedLinesMessage(1).contains("1 correction"))
}

@MainActor
@Test("Every row on a changed line is skipped, with or without a stored place, and rows on unchanged lines still apply (F971)")
func applySkipsEveryRowOnAChangedLineOnly() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ReplacementRuleWiringTests-changedlines-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let model = try makeModel(root: root)
    model.store.addReplacementRule(heard: "jon", preferred: "Jonathan")
    model.store.addReplacementRule(heard: "bill", preferred: "invoice")
    let id = meeting(model, lines: ["ask jon and bill", "jon met jon"])

    let rows = try #require(await model.replacementRuleCorrections(for: id))
    // Two rows on each line (every occurrence is a row since F967).
    #expect(rows.count == 4)
    // Line 0 changes after the review was proposed; neither of its rows has a stored place, and
    // each would still find its word there.
    model.applyGlossaryCorrections([GlossaryCorrection(segmentIndex: 0, from: "ask", to: "Ask")], to: id)

    let applied = model.applyGlossaryCorrections(rows, to: id)
    #expect(applied != nil)
    #expect(model.store.meeting(id: id)?.segments.map(\.text) == ["Ask jon and bill", "Jonathan met Jonathan"])
    #expect(model.alertMessage == AppModel.correctionsOnChangedLinesMessage(2))
    #expect(AppModel.correctionsOnChangedLinesMessage(2).contains("2 corrections"))
}

// F920 — Apply Replacement Rules built its proposals synchronously on the main actor from the Improve
// menu, and F858 doubled that work (a debug build measured 5.9 s for 500 rules over 1,500 lines). It
// runs off the main actor now, named in the status line while it runs, as F536 did for Correct
// Toward Vocabulary.

/// Polls `condition` on the main actor against the wall clock, with a cap far above any real wait.
@MainActor
private func waitUntil(_ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(30)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

private final class RulesGate: @unchecked Sendable {
    private let lock = NSLock()
    private var opened = false
    private var ranOnMainThread: Bool?
    var isOpen: Bool { lock.lock(); defer { lock.unlock() }; return opened }
    func open() { lock.lock(); opened = true; lock.unlock() }
    var sawMainThread: Bool? { lock.lock(); defer { lock.unlock() }; return ranOnMainThread }
    func record(isMain: Bool) { lock.lock(); ranOnMainThread = isMain; lock.unlock() }
    /// Blocks the pass until opened (capped, so a broken seam fails the test instead of hanging it).
    func wait() {
        let deadline = Date().addingTimeInterval(30)
        while !isOpen, Date() < deadline { usleep(1_000) }
    }
}

@MainActor
@Test("Apply Replacement Rules builds its proposals off the main actor, named in the status line while it runs; a second request is refused meanwhile (F920)")
func rulesPassRunsOffTheMainActor() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ReplacementRuleWiringTests-offmain-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let model = try makeModel(root: root)
    model.store.addReplacementRule(heard: "jon", preferred: "Jonathan")
    let id = meeting(model, lines: ["jon said hi"])
    let gate = RulesGate()
    let real = model.replacementRulePass
    model.replacementRulePass = { input in
        gate.record(isMain: Thread.isMainThread)
        gate.wait()
        return real(input)
    }

    let pass = Task { await model.replacementRuleCorrections(for: id) }
    let named = await waitUntil { model.replacementRuleRunID == id }
    try #require(named, "the status line never named the running pass")
    // The main actor is free while the pass runs — this test is running on it — and a second
    // request is refused rather than starting a second pass.
    #expect(await model.replacementRuleCorrections(for: id) == nil)

    gate.open()
    let rows = try #require(await pass.value)
    #expect(rows == [GlossaryCorrection(segmentIndex: 0, from: "jon", to: "Jonathan", proposedLine: "jon said hi")])
    #expect(model.replacementRuleRunID == nil)
    #expect(gate.sawMainThread == false)
}

@MainActor
@Test("A transcript changed while the rules pass ran gets no proposals, and the user is told (F920, F536's guard)")
func changedTranscriptDiscardsTheRulesPass() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ReplacementRuleWiringTests-stale-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let model = try makeModel(root: root)
    model.store.addReplacementRule(heard: "jon", preferred: "Jonathan")
    // A line removed while the pass runs shifts every index after it (F536's hazard).
    let id = meeting(model, lines: ["um um", "jon said hi", "and jon left"])
    let gate = RulesGate()
    let real = model.replacementRulePass
    model.replacementRulePass = { input in
        let rows = real(input)
        gate.wait()
        return rows
    }

    let pass = Task { await model.replacementRuleCorrections(for: id) }
    let running = await waitUntil { model.replacementRuleRunID != nil }
    try #require(running, "the pass never started")
    let removal = model.removeTranscriptLines(at: IndexSet([0]), from: id)
    try #require(removal != nil, "the premise: a line can be removed while the pass runs")
    let afterRemoval = try #require(model.store.meeting(id: id)).segments
    gate.open()
    let result = await pass.value

    #expect(result == nil, "proposals computed over the old lines must not be offered")
    #expect(model.alertMessage == AppModel.transcriptChangedDuringRulesMessage)
    #expect(AppModel.transcriptChangedDuringRulesMessage.contains("changed"))
    #expect(model.store.meeting(id: id)?.segments == afterRemoval)
    #expect(model.replacementRuleRunID == nil)
}

@Test("The Improve menu awaits the rules pass, disables the item while it runs, and the status line names it (F920)")
func menuRunsTheRulesPassInTheBackground() throws {
    let source = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/ContentView.swift")
    // Through `reviewReplacementRules`, which awaits `replacementRuleCorrections` (F1000).
    let awaitsThePass = source.contains("await model.reviewReplacementRules(for: meetingID)")
    #expect(awaitsThePass)
    let callsItSynchronously = source.contains("= model.replacementRuleCorrections(for: meetingID)")
    #expect(!callsItSynchronously)
    let disabledWhileRunning = source.contains("model.replacementRuleRunID != nil")
    #expect(disabledWhileRunning)
    let statusLineNamesIt = source.contains("model.replacementRuleRunID == meetingID")
    #expect(statusLineNamesIt)
}

@MainActor
@Test("A rules pass that finishes after the user switched meetings keeps its proposals for that meeting and says so (F1000)")
func rulesPassFinishingAfterASwitchIsKeptAndSaid() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ReplacementRuleWiringTests-switch-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let model = try makeModel(root: root)
    model.store.addReplacementRule(heard: "jon", preferred: "Jonathan")
    let id = meeting(model, lines: ["jon said hi"])
    let other = meeting(model, lines: ["nothing here"])
    let gate = RulesGate()
    let real = model.replacementRulePass
    model.replacementRulePass = { input in
        gate.wait()
        return real(input)
    }

    // The meeting is on screen when Apply Replacement Rules is chosen…
    model.meetingDetailAppeared(id)
    let pass = Task { await model.reviewReplacementRules(for: id) }
    let running = await waitUntil { model.replacementRuleRunID == id }
    try #require(running, "the pass never started")
    // …and the user switches to another meeting before it finishes (the detail view is keyed by
    // meeting, so the old one goes away with the sheet it would have opened — F1000).
    model.meetingDetailDisappeared(id)
    model.meetingDetailAppeared(other)
    gate.open()
    await pass.value

    let message = try #require(model.alertMessage, "nothing said the pass finished")
    #expect(message.contains("Apply Replacement Rules") && message.contains("1 proposal"))
    #expect(model.takeHeldProposals(for: other) == nil)
    // Back on the meeting, the sheet opens with the pass's rows, once.
    let held = try #require(model.takeHeldProposals(for: id))
    #expect(held.source == .replacementRules)
    #expect(held.proposals == [GlossaryCorrection(segmentIndex: 0, from: "jon", to: "Jonathan", proposedLine: "jon said hi")])
    #expect(model.takeHeldProposals(for: id) == nil)
}

@MainActor
@Test("A rules pass that finishes while its meeting is on screen is handed over with no message (F1000)")
func rulesPassFinishingOnScreenIsHandedOverQuietly() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ReplacementRuleWiringTests-onscreen-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let model = try makeModel(root: root)
    model.store.addReplacementRule(heard: "jon", preferred: "Jonathan")
    let id = meeting(model, lines: ["jon said hi"])
    model.meetingDetailAppeared(id)
    await model.reviewReplacementRules(for: id)
    #expect(model.alertMessage == nil)
    #expect(model.takeHeldProposals(for: id)?.proposals.count == 1)
    // A pass that matches nothing says so, as the menu item always did, and holds nothing.
    let none = meeting(model, lines: ["nothing here"])
    model.meetingDetailAppeared(none)
    await model.reviewReplacementRules(for: none)
    #expect(model.alertMessage == "None of your replacement rules matched this transcript.")
    #expect(model.takeHeldProposals(for: none) == nil)
}

@Test("The meeting view hands every finished pass to the model and opens what the model holds for it (F1000)")
func meetingViewOpensHeldProposals() throws {
    let source = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/ContentView.swift")
    #expect(source.contains("await model.reviewReplacementRules(for: meetingID)"))
    #expect(source.contains("await model.reviewGlossaryCorrections(for: meetingID)"))
    #expect(source.contains("model.meetingDetailAppeared(meetingID)"))
    #expect(source.contains("model.meetingDetailDisappeared(meetingID)"))
    #expect(source.contains("model.takeHeldProposals(for: meetingID)"))
    // No pass presents into the view's own queue directly any more: a view that went away took
    // the sheet with it.
    #expect(!source.contains("proposalReviews.present(ProposalReview(proposals: proposals"))
}

@MainActor
@Test("Proposals held for a meeting are dropped when the meeting is deleted, and dropped with a message when its lines change (F1000, round 2)")
func heldProposalsGoWithTheirMeetingAndItsLines() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ReplacementRuleWiringTests-heldgone-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let model = try makeModel(root: root)
    model.store.addReplacementRule(heard: "jon", preferred: "Jonathan")
    // No meeting is on screen, so each finished pass is held and said.
    let edited = meeting(model, lines: ["um um", "jon said hi"])
    await model.reviewReplacementRules(for: edited)
    #expect(model.heldProposals[edited] != nil)
    model.alertMessage = nil
    // The lines change before the user comes back (an edit in another window, Remove Lines…): the
    // held rows describe text that is gone, so they are dropped and the user is told.
    _ = model.removeTranscriptLines(at: IndexSet([0]), from: edited)
    #expect(model.takeHeldProposals(for: edited) == nil)
    let message = try #require(model.alertMessage)
    #expect(message.contains("changed") && message.contains("Apply Replacement Rules"))
    #expect(model.heldProposals[edited] == nil)

    // A deleted meeting takes its held proposals with it.
    let deleted = meeting(model, lines: ["jon said hi"])
    await model.reviewReplacementRules(for: deleted)
    #expect(model.heldProposals[deleted] != nil)
    model.deleteMeetings(ids: [deleted])
    #expect(model.heldProposals[deleted] == nil)
}

@MainActor
@Test("A Correct Toward Vocabulary pass that finishes after the user switched meetings is held and said, as the rules pass is (F1000, round 2)")
func vocabularyPassFinishingAfterASwitchIsKeptAndSaid() async throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ReplacementRuleWiringTests-vocabswitch-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let model = try makeModel(root: root)
    model.store.addVocabulary(["Kestrel"])
    let id = meeting(model, lines: ["the Kestrol build"])
    let other = meeting(model, lines: ["nothing here"])
    model.meetingDetailAppeared(other)
    await model.reviewGlossaryCorrections(for: id)
    let message = try #require(model.alertMessage)
    #expect(message.contains("Correct Toward Vocabulary") && message.contains("1 proposal"))
    let held = try #require(model.takeHeldProposals(for: id))
    #expect(held.source == .vocabulary)
    #expect(held.proposals.map(\.from) == ["Kestrol"])
}
