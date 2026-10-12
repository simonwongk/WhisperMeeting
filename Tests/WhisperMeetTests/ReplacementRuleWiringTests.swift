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
func ruleCorrectionsReachApplyPath() throws {
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

    let proposals = model.replacementRuleCorrections(for: id)
    #expect(proposals == [GlossaryCorrection(segmentIndex: 0, from: "Sequoia", to: "Sequoya", proposedLine: "We use Sequoia for infra.")])

    model.applyGlossaryCorrections(proposals, to: id)
    #expect(model.store.meeting(id: id)?.segments.first?.text == "We use Sequoya for infra.")
    #expect(model.store.meeting(id: id)?.transcriptText.contains("Sequoya") == true)
}

@MainActor
@Test("Improve proposes a lower-case rule for the sentence-initial capital, and Apply writes it (F858)")
func ruleCorrectionsMatchASentenceInitialCapital() throws {
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

    let proposals = model.replacementRuleCorrections(for: id)
    #expect(proposals == [GlossaryCorrection(segmentIndex: 0, from: "Jon", to: "Jonathan", proposedLine: "Jon said the build is green.")])

    model.applyGlossaryCorrections(proposals, to: id)
    #expect(model.store.meeting(id: id)?.segments.first?.text == "Jonathan said the build is green.")
}

@MainActor
@Test("Improve proposes a lower-case rule for the word, never for the same word capitalised mid-sentence (F858)")
func ruleCorrectionsLeaveAMidSentenceCapitalAlone() throws {
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

    let proposals = model.replacementRuleCorrections(for: id)
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

    let proposals = model.replacementRuleCorrections(for: id)
    #expect(proposals == [GlossaryCorrection(segmentIndex: 0, from: "Jon", to: "Jonathan", characterOffset: 13, proposedLine: "Zoë and Jon. Jon left.")])
    // The row's sentence is about the second "Jon", the one it changes.
    #expect(await model.proposalContexts(proposals, in: id)
        == [ProposalContext(before: "Zoë and Jon. ", match: "Jon", after: " left.")])

    model.applyGlossaryCorrections(proposals, to: id)
    #expect(model.store.meeting(id: id)?.segments.first?.text == "Zoë and Jon. Jonathan left.")
}

@MainActor
@Test("Improve reads a line that continues the line before it as mid-sentence, and a title's full stop as no sentence end (F938)")
func ruleCorrectionsReadSentencesAcrossLines() throws {
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

    let proposals = model.replacementRuleCorrections(for: id)
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
func applySkipsARowWhoseLineChanged() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ReplacementRuleWiringTests-changedline-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let model = try makeModel(root: root)
    model.store.addReplacementRule(heard: "jon", preferred: "jonathan")
    let id = meeting(model, lines: ["Sam and Jon. Jon left."])

    // The rules review: one row, for the sentence's "Jon", carrying its place (F950).
    let rows = model.replacementRuleCorrections(for: id)
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
func applySkipsEveryRowOnAChangedLineOnly() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ReplacementRuleWiringTests-changedlines-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let model = try makeModel(root: root)
    model.store.addReplacementRule(heard: "jon", preferred: "Jonathan")
    model.store.addReplacementRule(heard: "bill", preferred: "invoice")
    let id = meeting(model, lines: ["ask jon and bill", "jon met jon"])

    let rows = model.replacementRuleCorrections(for: id)
    #expect(rows.count == 3)
    // Line 0 changes after the review was proposed; neither of its rows has a stored place, and
    // each would still find its word there.
    model.applyGlossaryCorrections([GlossaryCorrection(segmentIndex: 0, from: "ask", to: "Ask")], to: id)

    let applied = model.applyGlossaryCorrections(rows, to: id)
    #expect(applied != nil)
    #expect(model.store.meeting(id: id)?.segments.map(\.text) == ["Ask jon and bill", "Jonathan met jon"])
    #expect(model.alertMessage == AppModel.correctionsOnChangedLinesMessage(2))
    #expect(AppModel.correctionsOnChangedLinesMessage(2).contains("2 corrections"))
}
