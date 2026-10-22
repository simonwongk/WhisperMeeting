import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F177 — action item cards. Drives the AppModel wiring: editing an item's done/owner/due persists to
// the index, and summarizing resolves each item's supporting timestamp from the meeting's segments.

private final class StubSummarizer: MeetingSummarizer, @unchecked Sendable {
    let stub: MeetingSummary
    init(_ stub: MeetingSummary) { self.stub = stub }
    func summarize(transcript: String, language: String?, style: SummaryStyle, template: MeetingTemplate) async throws -> MeetingSummary {
        stub
    }
}

@MainActor
private func makeModel() throws -> AppModel {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("ActionItemWiringTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let defaults = UserDefaults(suiteName: testSuiteName())!
    return AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(), defaults: defaults)
}

@MainActor
@Test("Editing an action item's done/owner/due persists to the meeting index (F177)")
func editingActionItemPersists() throws {
    let model = try makeModel()
    let id = UUID()
    model.store.upsert(MeetingRecord(
        id: id, title: "M", status: .completed, transcriptText: "hello",
        summary: MeetingSummary(summary: "s", keyPoints: [], actionItems: ["Email vendor", "Call Bob"])
    ))

    model.updateActionItem(at: 0, for: id) { $0.done = true }
    model.updateActionItem(at: 1, for: id) { $0.owner = "Bob"; $0.due = "Fri" }

    let items = try #require(model.store.meeting(id: id)?.summary?.actionItems)
    #expect(items[0].done)
    #expect(items[1].owner == "Bob")
    #expect(items[1].due == "Fri")
    #expect(!items[1].done)
}

@MainActor
@Test("An out-of-range action-item edit is a no-op (F177)")
func outOfRangeEditIsNoOp() throws {
    let model = try makeModel()
    let id = UUID()
    model.store.upsert(MeetingRecord(
        id: id, title: "M", status: .completed,
        summary: MeetingSummary(summary: "s", keyPoints: [], actionItems: ["only one"])
    ))
    model.updateActionItem(at: 5, for: id) { $0.done = true } // must not crash or mutate
    #expect(model.store.meeting(id: id)?.summary?.actionItems == ["only one"])
}

@MainActor
@Test("Summarizing resolves each action item's supporting timestamp from the segments (F177)")
func summarizeResolvesTimestamps() async throws {
    let model = try makeModel()
    let summarizer = StubSummarizer(MeetingSummary(
        summary: "s", keyPoints: [], actionItems: ["Alice to send the budget spreadsheet"]
    ))
    model.makeSummarizer = { _, _ in summarizer }

    let segments = [
        TranscriptSegment(speaker: nil, start: 0, end: 5, text: "Kick off the project."),
        TranscriptSegment(speaker: nil, start: 12, end: 20, text: "Alice will send the budget spreadsheet to finance by Friday."),
    ]
    let id = UUID()
    model.store.upsert(MeetingRecord(
        id: id, title: "M", status: .completed,
        transcriptText: TranscriptFormatter.timestamped(segments), segments: segments
    ))

    await model.performSummarization(
        id: id, engine: .local, apiKey: "", transcript: "t", language: nil, style: .balanced
    )

    let items = try #require(model.store.meeting(id: id)?.summary?.actionItems)
    #expect(items[0].timestamp == 12)
    #expect(items[0].quote?.contains("budget spreadsheet") == true)
}

// MARK: - F307: re-summarizing must not discard what the user typed

@MainActor
@Test("Re-summarizing keeps the user's ticks, owners and dates (F307)")
func reSummarizingKeepsUserEdits() async throws {
    // The call site, not the merge rule. `ActionItemMergeTests` pins the rule; this pins that
    // `performSummarization` applies it — the defect was one line, `$0.summary = resolved`,
    // replacing the whole struct.
    let model = try makeModel()
    let summarizer = StubSummarizer(MeetingSummary(
        summary: "s", keyPoints: [],
        actionItems: ["Send the Kestrel report", "Book the Fairhaven room"]
    ))
    model.makeSummarizer = { _, _ in summarizer }

    let id = UUID()
    model.store.upsert(MeetingRecord(id: id, title: "M", status: .completed, transcriptText: "t"))
    await model.performSummarization(
        id: id, engine: .local, apiKey: "", transcript: "t", language: nil, style: .balanced
    )

    // The user works the list: ticks one off, assigns the other.
    model.updateActionItem(at: 0, for: id) { $0.done = true }
    model.updateActionItem(at: 1, for: id) { $0.owner = "Priya"; $0.due = "Fri" }

    // Then re-summarizes, which is what the style and template controls are for.
    await model.performSummarization(
        id: id, engine: .local, apiKey: "", transcript: "t", language: nil, style: .detailed
    )

    let items = try #require(model.store.meeting(id: id)?.summary?.actionItems)
    #expect(items.count == 2)
    #expect(items[0].done, "the tick was cleared by the re-summarization")
    #expect(items[1].owner == "Priya", "the owner was cleared by the re-summarization")
    #expect(items[1].due == "Fri")
}

@MainActor
@Test("An item the user ticked survives the model no longer mentioning it (F307)")
func aTickedItemOutlivesItsDisappearance() async throws {
    // The second half of the rule, at the call site: the user's edit is the stronger signal, so a
    // summary that drops a task they had already handled must not delete their record of it.
    let model = try makeModel()
    let first = StubSummarizer(MeetingSummary(
        summary: "s", keyPoints: [], actionItems: ["Send the Kestrel report"]
    ))
    model.makeSummarizer = { _, _ in first }

    let id = UUID()
    model.store.upsert(MeetingRecord(id: id, title: "M", status: .completed, transcriptText: "t"))
    await model.performSummarization(
        id: id, engine: .local, apiKey: "", transcript: "t", language: nil, style: .balanced
    )
    model.updateActionItem(at: 0, for: id) { $0.done = true }

    let second = StubSummarizer(MeetingSummary(
        summary: "s", keyPoints: [], actionItems: ["Book the Fairhaven room"]
    ))
    model.makeSummarizer = { _, _ in second }
    await model.performSummarization(
        id: id, engine: .local, apiKey: "", transcript: "t", language: nil, style: .brief
    )

    let items = try #require(model.store.meeting(id: id)?.summary?.actionItems)
    #expect(items.map(\.text).contains("Book the Fairhaven room"), "the new summary leads")
    let kept = try #require(items.first { $0.text == "Send the Kestrel report" })
    #expect(kept.done)
}

// F1056 — an action item has no identity of its own, so the card kept its typed owner and due by position and wrote
// them back by position: re-summarize while an owner was being typed, and the owner landed on whatever item then sat
// in that slot. The card's write now names the item it was typed for, by its text, and finds it where it now is.
@MainActor
@Test("An owner typed on a card lands on that card's item after a re-summarize moves it, and on nothing if it is gone (F1056)")
func anOwnerTypedBeforeAReSummarizeLandsOnItsOwnItem() throws {
    let model = try makeModel()
    let id = UUID()
    model.store.upsert(MeetingRecord(
        id: id, title: "M", status: .completed, transcriptText: "hello",
        summary: MeetingSummary(summary: "s", keyPoints: [], actionItems: ["Email vendor", "Call Bob"])
    ))
    // The card for item 0 ("Email vendor") holds a typed owner; a re-summarize then puts a new item first.
    model.store.update(id: id) { $0.summary = MeetingSummary(summary: "s2", keyPoints: [], actionItems: ["Book room", "Email vendor"]) }

    model.updateActionItem(at: 0, expecting: "Email vendor", for: id) { $0.owner = "Priya" }

    let items = try #require(model.store.meeting(id: id)?.summary?.actionItems)
    #expect(items[0].owner == nil, "the owner landed on the item now in the card's old slot")
    #expect(items[1].owner == "Priya", "the owner never reached the item it was typed for")

    // An item the re-summarize dropped takes nothing, and nothing else does either.
    model.updateActionItem(at: 0, expecting: "Call Bob", for: id) { $0.due = "Fri" }
    let after = try #require(model.store.meeting(id: id)?.summary?.actionItems)
    #expect(after.allSatisfy { $0.due == nil }, "\(after)")
}

@Test("The action item card names its item on every write, and keys the card by the item too (F1056)")
func theCardNamesItsItemOnEveryWrite() throws {
    let view = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/ContentView.swift")
    #expect(view.components(separatedBy: "model.updateActionItem(at: index, expecting: text, for: meetingID)").count - 1 == 3,
            "a card's done, owner or due write goes by position alone again")
    #expect(!view.contains("model.updateActionItem(at: index, for: meetingID)"))
    #expect(view.contains("ActionItemSlot(index:"), "the card is keyed by position alone again")
}
