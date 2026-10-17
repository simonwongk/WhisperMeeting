import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F676 — an action item's owner and due fields had the stale write-back F564 fixed for the title:
// each card seeded its two drafts once, on appear, and on disappear wrote them whenever they differed
// from the item. So an owner set in window A was written back to window B's empty field the moment
// B's card went away. They now run F564's typed-here draft.
//
// F811 — after F675 a title with the cursor in it is never re-seeded, and a focused field keeps the
// cursor when its window comes back to the front. So window B showed the old title with the cursor
// in it, and typing there saved "old title + edit" over A's rename (the round-2 review of Wave 3
// lane L, probe P3: `bShows=Weekly sync storedAfterTypingInB=Weekly sync (draft)`). A focused field
// holding no typing of its own now gives up the cursor when the library changes under it; the
// view's focus change commits nothing (nothing was typed) and the field catches up.
//
// As in SecondWindowFieldSyncTests: two drafts over one real store are the two windows' fields, and
// the calls are the ones the views make.

@MainActor
private func makeModel() throws -> (AppModel, UUID, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("F676-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(),
                         defaults: UserDefaults(suiteName: testSuiteName())!)
    let id = UUID()
    model.store.upsert(MeetingRecord(
        id: id, title: "Weekly sync", recordingPath: "Recordings/\(id.uuidString)/meeting.wav", status: .completed,
        summary: MeetingSummary(summary: "Plans.", keyPoints: [], actionItems: [ActionItem(text: "Send the deck")])
    ))
    return (model, id, root)
}

@MainActor
private func owner(_ model: AppModel, _ id: UUID) -> String? {
    model.store.meeting(id: id)?.summary?.actionItems.first?.owner
}

/// The commit `ActionItemCard` makes for its owner field, through the model call the card's closure makes.
@MainActor
private func commitOwner(_ draft: inout SharedFieldDraft, _ model: AppModel, _ id: UUID) {
    MeetingFieldSync.commitActionItemField(
        &draft,
        stored: owner(model, id),
        write: { value in model.updateActionItem(at: 0, for: id) { $0.owner = value } },
        readBack: { owner(model, id) }
    )
}

@MainActor
@Test("An owner set in one window survives the other window's untouched card going away (F676)")
func anOwnerSurvivesTheOtherWindowsStaleCard() throws {
    let (model, id, root) = try makeModel()
    defer { model.store.flushPendingEdits(); try? FileManager.default.removeItem(at: root) }
    var windowA = SharedFieldDraft(stored: "")
    var windowB = SharedFieldDraft(stored: "")

    windowA.userTyped("Priya")
    commitOwner(&windowA, model, id)
    #expect(owner(model, id) == "Priya")

    // B's card goes away (another meeting selected, or the window closed) without B's field having
    // seen the change — before F676 it had no way to see it.
    commitOwner(&windowB, model, id)
    #expect(owner(model, id) == "Priya", "window B wrote its empty owner back over window A's")

    // And with the follow it now has, B shows A's owner.
    _ = MeetingFieldSync.committedFieldLibraryChanged(&windowB, to: owner(model, id) ?? "", focused: false)
    #expect(windowB.text == "Priya")
}

@MainActor
@Test("An owner typed in the other window is saved, trimmed, and clearing it saves no owner (F676)")
func typedOwnersAreStillSaved() throws {
    let (model, id, root) = try makeModel()
    defer { model.store.flushPendingEdits(); try? FileManager.default.removeItem(at: root) }
    var field = SharedFieldDraft(stored: "")

    field.userTyped("  Sam ")
    commitOwner(&field, model, id)
    #expect(owner(model, id) == "Sam")

    field.userTyped("")
    commitOwner(&field, model, id)
    #expect(owner(model, id) == nil, "an emptied owner field clears the owner, as it always did")
}

@MainActor
@Test("A refused owner write keeps the typing, so the next library change cannot replace it unseen (F676)")
func aRefusedOwnerWriteKeepsTheTyping() throws {
    var field = SharedFieldDraft(stored: "")
    field.userTyped("Priya")
    MeetingFieldSync.commitActionItemField(&field, stored: nil, write: { _ in }, readBack: { nil })
    #expect(field.hasUnsavedEdit)
    _ = MeetingFieldSync.committedFieldLibraryChanged(&field, to: "", focused: false)
    #expect(field.text == "Priya")
}

@MainActor
@Test("A focused, untyped title gives up the cursor when a rename arrives, so typing there cannot save the old title (F811)")
func aFocusedUntypedTitleCatchesUpWhenARenameArrives() throws {
    let (model, id, root) = try makeModel()
    let store = model.store
    defer { store.flushPendingEdits(); try? FileManager.default.removeItem(at: root) }
    var windowA = SharedFieldDraft(stored: "Weekly sync")
    var windowB = SharedFieldDraft(stored: "Weekly sync")

    windowA.userTyped("Q3 budget review")
    MeetingFieldSync.commitTitle(&windowA, store: store, meetingID: id)

    // Window B's title has the cursor and nothing typed; B is behind A.
    let releaseFocus = MeetingFieldSync.committedFieldLibraryChanged(
        &windowB, to: store.meeting(id: id)?.title ?? "", focused: true
    )
    // What the view does with the answer: give up focus, whose change commits and catches up (the
    // field editor ends editing while the draft still holds what it shows, so it writes back nothing).
    if releaseFocus {
        windowB.userTyped(windowB.text)
        MeetingFieldSync.commitTitle(&windowB, store: store, meetingID: id)
        windowB.libraryChanged(to: store.meeting(id: id)?.title ?? "", isEditingHere: false)
    }

    // B comes to the front and the user types an edit onto what B shows.
    windowB.userTyped(windowB.text + " (draft)")
    MeetingFieldSync.commitTitle(&windowB, store: store, meetingID: id)

    #expect(store.meeting(id: id)?.title == "Q3 budget review (draft)",
            "B showed \"\(windowB.text)\" and saved the old title plus the edit over the rename")
}

@MainActor
@Test("Typing of its own keeps the cursor and the text when a rename arrives (F811 control, F564)")
func aFocusedTypedFieldKeepsItsTyping() throws {
    var field = SharedFieldDraft(stored: "Weekly sync")
    field.userTyped("Hiring panel")
    let releaseFocus = MeetingFieldSync.committedFieldLibraryChanged(&field, to: "Q3 budget review", focused: true)
    #expect(!releaseFocus)
    #expect(field.text == "Hiring panel")

    // Already showing the library's value: nothing to catch up on, so the cursor stays.
    var current = SharedFieldDraft(stored: "Q3 budget review")
    #expect(!MeetingFieldSync.committedFieldLibraryChanged(&current, to: "Q3 budget review", focused: true))
}

@Test("The title and the action-item fields run the shared rule (F676, F811)")
func theCommittedFieldViewsUseTheSharedRule() throws {
    let content = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/ContentView.swift")
    let titleStart = try #require(content.range(of: "private struct EditableMeetingTitle: View {"))
    let title = content[titleStart.lowerBound...].prefix(3_000)
    #expect(title.contains("MeetingFieldSync.committedFieldLibraryChanged(&draft"), "\(title)")
    #expect(title.contains("focused = false"))

    let cardStart = try #require(content.range(of: "private struct ActionItemCard: View {"))
    let card = content[cardStart.lowerBound...].prefix(6_000)
    #expect(card.contains("SharedFieldDraft"), "the card still keeps plain String drafts")
    #expect(card.contains("MeetingFieldSync.commitActionItemField(&ownerDraft"))
    #expect(card.contains("MeetingFieldSync.commitActionItemField(&dueDraft"))
    #expect(card.contains(".onChange(of: item.owner)") && card.contains(".onChange(of: item.due)"))
    #expect(card.contains("ownerDraft.userTyped(") && card.contains("dueDraft.userTyped("),
            "typing must reach the drafts through the bindings' setters")
}
