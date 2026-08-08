import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F179 — replacement rules persist alongside vocabulary, and the AppModel surfaces rule-based
// corrections through the same review + apply path as F82 glossary corrections.

@MainActor
private func makeModel(root: URL) throws -> AppModel {
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let defaults = UserDefaults(suiteName: "F179.\(UUID().uuidString)")!
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
    #expect(proposals == [GlossaryCorrection(segmentIndex: 0, from: "Sequoia", to: "Sequoya")])

    model.applyGlossaryCorrections(proposals, to: id)
    #expect(model.store.meeting(id: id)?.segments.first?.text == "We use Sequoya for infra.")
    #expect(model.store.meeting(id: id)?.transcriptText.contains("Sequoya") == true)
}
