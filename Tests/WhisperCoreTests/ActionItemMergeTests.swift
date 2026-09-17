import Foundation
import Testing
@testable import WhisperCore

// F307 — re-summarizing a meeting discarded everything the user had typed on its action items.
//
// `performSummarization` ends with `store.update(id: id) { $0.summary = resolved }`, replacing the
// whole struct. `ActionItem` carries three fields the model never produces and the user does:
// `done`, and `owner` / `due`, both documented "Optional, user-entered". `updateActionItem` exists
// precisely so they can be set. Nothing merged them forward.
//
// So: tick off four items, assign two owners and a due date, then re-summarize — which is the whole
// reason the style and template controls exist — and every tick is cleared and every owner blank.
// Nothing warns and nothing fails; the checkboxes are simply empty again.
//
// The matching rule is deliberately exact-after-normalisation rather than fuzzy. Carrying a tick
// onto a *different* task is worse than losing it: a wrong "done" is a task the user believes is
// handled and is not, while a lost one is visibly lost. So a reworded item starts clean.

private func item(
    _ text: String, done: Bool = false, owner: String? = nil, due: String? = nil
) -> ActionItem {
    ActionItem(text: text, done: done, owner: owner, due: due)
}

@Test("A tick, an owner and a due date survive a re-summarization (F307)")
func userEditsCarryForward() {
    let previous = [
        item("Send the Kestrel report", done: true, owner: "Priya", due: "Fri"),
        item("Book the Fairhaven room"),
    ]
    let fresh = [item("Send the Kestrel report"), item("Book the Fairhaven room")]

    let merged = ActionItemMerge.carryingUserEdits(from: previous, onto: fresh)

    #expect(merged.count == 2)
    #expect(merged[0].done)
    #expect(merged[0].owner == "Priya")
    #expect(merged[0].due == "Fri")
    #expect(!merged[1].done, "an untouched item stays untouched")
}

@Test("The model's own new wording and evidence win (F307)")
func theModelsFieldsAreNotOverwritten() {
    // Only the user-entered three carry over. The text, quote and timestamp belong to this
    // summarization — carrying an old quote forward would attach evidence to a sentence that no
    // longer says it.
    var previous = item("Send the report", done: true)
    previous.quote = "old quote"
    previous.timestamp = 12
    var fresh = item("Send the report")
    fresh.quote = "new quote"
    fresh.timestamp = 99

    let merged = ActionItemMerge.carryingUserEdits(from: [previous], onto: [fresh])
    #expect(merged[0].done, "the tick is the user's")
    #expect(merged[0].quote == "new quote", "the evidence is this run's")
    #expect(merged[0].timestamp == 99)
}

@Test("Matching ignores whitespace and case but nothing more (F307)")
func matchingIsNormalisedNotFuzzy() {
    let previous = [item("  Send the Kestrel report ", done: true)]
    #expect(
        ActionItemMerge.carryingUserEdits(
            from: previous, onto: [item("send the kestrel REPORT")]
        )[0].done,
        "trivial reformatting must not lose a tick"
    )
    // A reworded item is a different item. Carrying the tick would tell the user a task is done
    // when they ticked something else, which is worse than making them tick it again.
    #expect(
        !ActionItemMerge.carryingUserEdits(
            from: previous, onto: [item("Send the Kestrel report to Priya")]
        )[0].done
    )
}

@Test("An item the user had edited is kept when the new summary drops it (F307)")
func anEditedItemIsNotSilentlyDropped() {
    // The user's edit is the stronger signal: they looked at this task and did something about it.
    // A summarization that no longer mentions it is the model's opinion, and it must not delete
    // their record of having handled it.
    let previous = [
        item("Send the Kestrel report", done: true),
        item("Chase the invoice", owner: "Dan"),
        item("Something nobody touched"),
    ]
    let fresh = [item("Book the Fairhaven room")]

    let merged = ActionItemMerge.carryingUserEdits(from: previous, onto: fresh)

    #expect(merged.first?.text == "Book the Fairhaven room", "the new summary leads")
    let texts = merged.map(\.text)
    #expect(texts.contains("Send the Kestrel report"), "a ticked item is kept")
    #expect(texts.contains("Chase the invoice"), "an assigned item is kept")
    #expect(
        !texts.contains("Something nobody touched"),
        "an untouched item the model dropped is genuinely dropped — this is a merge, not an archive"
    )
    #expect(merged.count == 3)
}

@Test("A due date alone counts as an edit worth keeping (F307)")
func aDueDateAloneIsAnEdit() {
    let merged = ActionItemMerge.carryingUserEdits(
        from: [item("Chase the invoice", due: "Aug 15")], onto: []
    )
    #expect(merged.count == 1)
    #expect(merged[0].due == "Aug 15")
}

@Test("An empty owner or due string is not an edit (F307)")
func blankStringsAreNotEdits() {
    // A field the user opened and left blank must not pin an item the model dropped, or clearing a
    // typo would make an item permanent.
    let merged = ActionItemMerge.carryingUserEdits(
        from: [item("Chase the invoice", owner: "", due: "   ")], onto: []
    )
    #expect(merged.isEmpty)
}

@Test("A first summarization has nothing to carry and is unchanged (F307)")
func theFirstSummarizationIsUntouched() {
    let fresh = [item("Send the report"), item("Book the room")]
    #expect(ActionItemMerge.carryingUserEdits(from: [], onto: fresh) == fresh)
}

@Test("Two items with the same text do not both take one item's edits (F307)")
func duplicateTextsAreMatchedOnce() {
    // Degenerate but reachable — a model can repeat itself. Each previous edit is consumed once, so
    // a single tick does not multiply across every repetition.
    let previous = [item("Follow up", done: true)]
    let merged = ActionItemMerge.carryingUserEdits(
        from: previous, onto: [item("Follow up"), item("Follow up")]
    )
    #expect(merged.count == 2)
    #expect(merged.filter(\.done).count == 1, "one tick in, one tick out")
}
