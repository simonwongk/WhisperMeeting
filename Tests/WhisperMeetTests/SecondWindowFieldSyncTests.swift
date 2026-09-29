import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F564 — `EditableMeetingTitle` seeded its text from the library once, on appear, and on disappear
// committed it whenever it differed from the stored title. File ▸ New Window gives each window its
// own copy, so a rename made in window A was written back to the OLD title the moment window B's
// untouched field went away (another selection, or closing B). Notes did the same the other way: B
// never saw A's notes, so the first keystroke in B wrote B's stale text over them.
//
// Two `SharedFieldDraft`s over one real `MeetingStore` are the two windows' fields; the calls are
// the ones the views make (`MeetingFieldSync`, and `libraryChanged` from their `onChange`).

@MainActor
private func makeStore(title: String = "Weekly sync", notes: String? = nil) throws -> (MeetingStore, UUID, URL) {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent("F564-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let store = MeetingStore(rootDirectory: root)
    let id = UUID()
    store.upsert(MeetingRecord(id: id, title: title, recordingPath: "Recordings/\(id.uuidString)/meeting.wav", notes: notes))
    return (store, id, root)
}

@MainActor
@Test("A rename in one window survives the other window's untouched title field going away (F564)")
func aRenameSurvivesTheOtherWindowsStaleField() throws {
    let (store, id, root) = try makeStore()
    defer { store.flushPendingEdits(); try? FileManager.default.removeItem(at: root) }
    var windowA = SharedFieldDraft(stored: "Weekly sync")
    var windowB = SharedFieldDraft(stored: "Weekly sync")

    windowA.userTyped("Q3 budget review")
    MeetingFieldSync.commitTitle(&windowA, store: store, meetingID: id)
    #expect(store.meeting(id: id)?.title == "Q3 budget review")

    // B's view sees the library change; its field is not being edited.
    windowB.libraryChanged(to: store.meeting(id: id)?.title ?? "", isEditingHere: false)
    #expect(windowB.text == "Q3 budget review", "window B kept showing the old title")

    // B's detail view goes away: another meeting clicked, or the window closed.
    MeetingFieldSync.commitTitle(&windowB, store: store, meetingID: id)
    #expect(store.meeting(id: id)?.title == "Q3 budget review", "window B wrote the old title back")
}

@MainActor
@Test("A field focused in the other window is not rewritten under the cursor, and still writes nothing it was not given (F564)")
func aFocusedButUntouchedFieldWritesNothing() throws {
    let (store, id, root) = try makeStore()
    defer { store.flushPendingEdits(); try? FileManager.default.removeItem(at: root) }
    var windowA = SharedFieldDraft(stored: "Weekly sync")
    var windowB = SharedFieldDraft(stored: "Weekly sync")

    windowA.userTyped("Q3 budget review")
    MeetingFieldSync.commitTitle(&windowA, store: store, meetingID: id)
    windowB.libraryChanged(to: "Q3 budget review", isEditingHere: true)
    #expect(windowB.text == "Weekly sync", "not re-seeded under a cursor the user has put there")

    MeetingFieldSync.commitTitle(&windowB, store: store, meetingID: id)
    #expect(store.meeting(id: id)?.title == "Q3 budget review",
            "focus is not an edit: B typed nothing, so B has nothing to save")

    // When B's field lets go of focus, it catches up.
    windowB.libraryChanged(to: "Q3 budget review", isEditingHere: false)
    #expect(windowB.text == "Q3 budget review")
}

@MainActor
@Test("What the user typed in the other window is kept, and saved when that field commits (F564)")
func typingInTheOtherWindowIsKept() throws {
    let (store, id, root) = try makeStore()
    defer { store.flushPendingEdits(); try? FileManager.default.removeItem(at: root) }
    var windowA = SharedFieldDraft(stored: "Weekly sync")
    var windowB = SharedFieldDraft(stored: "Weekly sync")

    windowB.userTyped("Hiring panel")   // typing in B, not yet committed
    windowA.userTyped("Q3 budget review")
    MeetingFieldSync.commitTitle(&windowA, store: store, meetingID: id)
    windowB.libraryChanged(to: "Q3 budget review", isEditingHere: false)
    #expect(windowB.text == "Hiring panel", "a re-seed must never throw away what the user typed")

    MeetingFieldSync.commitTitle(&windowB, store: store, meetingID: id)
    #expect(store.meeting(id: id)?.title == "Hiring panel", "the later deliberate rename wins")
}

@MainActor
@Test("Clearing the title reverts it rather than saving an empty name (F564 keeps the old rule)")
func anEmptyTitleReverts() throws {
    let (store, id, root) = try makeStore()
    defer { store.flushPendingEdits(); try? FileManager.default.removeItem(at: root) }
    var field = SharedFieldDraft(stored: "Weekly sync")
    field.userTyped("   ")
    MeetingFieldSync.commitTitle(&field, store: store, meetingID: id)
    #expect(store.meeting(id: id)?.title == "Weekly sync")
    #expect(field.text == "Weekly sync")
}

@MainActor
@Test("Typing the library refused stays in the field, and a later library change does not replace it unseen (F564)")
func refusedTypingIsNotReseededAway() throws {
    let (store, id, root) = try makeStore()
    defer { store.endLibraryRestore(); store.flushPendingEdits(); try? FileManager.default.removeItem(at: root) }
    var title = SharedFieldDraft(stored: "Weekly sync")
    var notes = SharedFieldDraft(stored: "")
    store.beginLibraryRestore()   // every change is refused until it ends

    title.userTyped("Q3 budget review")
    MeetingFieldSync.commitTitle(&title, store: store, meetingID: id)
    MeetingFieldSync.typeNotes("Agenda: budget", into: &notes, store: store, meetingID: id)
    #expect(store.meeting(id: id)?.title == "Weekly sync", "sanity: the restore refused the rename")

    title.libraryChanged(to: "Weekly sync", isEditingHere: false)
    notes.libraryChanged(to: "", isEditingHere: false)
    #expect(title.text == "Q3 budget review", "the user's typing is still theirs to retry, not silently gone")
    #expect(notes.text == "Agenda: budget")
    #expect(title.hasUnsavedEdit && notes.hasUnsavedEdit)

    store.endLibraryRestore()
    MeetingFieldSync.commitTitle(&title, store: store, meetingID: id)
    #expect(store.meeting(id: id)?.title == "Q3 budget review", "retried once the library accepts changes")
}

@MainActor
@Test("Notes typed in one window survive typing in the other (F564)")
func notesFromOneWindowSurviveTypingInTheOther() throws {
    let (store, id, root) = try makeStore()
    defer { store.flushPendingEdits(); try? FileManager.default.removeItem(at: root) }
    var windowA = SharedFieldDraft(stored: "")
    var windowB = SharedFieldDraft(stored: "")

    MeetingFieldSync.typeNotes("Agenda: budget", into: &windowA, store: store, meetingID: id)
    #expect(store.meeting(id: id)?.notes == "Agenda: budget")
    windowB.libraryChanged(to: store.meeting(id: id)?.notes ?? "", isEditingHere: false)

    // The user clicks into window B's notes and adds a line to what they see there.
    MeetingFieldSync.typeNotes(windowB.text + "\nAction: send deck", into: &windowB, store: store, meetingID: id)
    #expect(store.meeting(id: id)?.notes == "Agenda: budget\nAction: send deck",
            "window B's stale text replaced window A's notes")

    windowA.libraryChanged(to: store.meeting(id: id)?.notes ?? "", isEditingHere: false)
    #expect(windowA.text == "Agenda: budget\nAction: send deck", "window A catches up once it is not being typed in")
}

// MARK: - F675: a title field with the cursor in it, in a window that is not in front

@MainActor
@Test("A title with the cursor in it in a background window is not re-seeded, so its field editor cannot write the old title back (F675)")
func aFocusedTitleInABackgroundWindowKeepsTheRename() throws {
    let (store, id, root) = try makeStore()
    defer { store.flushPendingEdits(); try? FileManager.default.removeItem(at: root) }
    var windowA = SharedFieldDraft(stored: "Weekly sync")
    var windowB = SharedFieldDraft(stored: "Weekly sync")

    windowA.userTyped("Q3 budget review")
    MeetingFieldSync.commitTitle(&windowA, store: store, meetingID: id)

    // Window B's title has the cursor, but B is not the key window — the case F564's rule let
    // through: it re-seeded the draft while AppKit's field editor may still show "Weekly sync".
    let editing = MeetingFieldSync.isEditing(.title, focused: true, windowIsActive: false)
    windowB.libraryChanged(to: store.meeting(id: id)?.title ?? "", isEditingHere: editing)
    // When B's editing ends, SwiftUI may hand the field editor's string back through the setter.
    windowB.userTyped("Weekly sync")
    MeetingFieldSync.commitTitle(&windowB, store: store, meetingID: id)

    #expect(store.meeting(id: id)?.title == "Q3 budget review", "the field editor wrote the old title back over the rename")
    // And once B's commit has run, the field catches up (the view's `commit()` does exactly this).
    windowB.libraryChanged(to: store.meeting(id: id)?.title ?? "", isEditingHere: false)
    #expect(windowB.text == "Q3 budget review")
}

@Test("Focus alone is editing for the title; the notes still follow the other window while theirs is not in front (F675)")
func focusAloneIsEditingForTheTitle() {
    #expect(MeetingFieldSync.isEditing(.title, focused: true, windowIsActive: false))
    #expect(MeetingFieldSync.isEditing(.title, focused: true, windowIsActive: true))
    #expect(!MeetingFieldSync.isEditing(.title, focused: false, windowIsActive: true))
    // Notes are written through on every keystroke, so a background window's notes hold nothing
    // unsaved and follow the other window; F564's notes rule is unchanged.
    #expect(!MeetingFieldSync.isEditing(.notes, focused: true, windowIsActive: false))
    #expect(MeetingFieldSync.isEditing(.notes, focused: true, windowIsActive: true))
}

@Test("The title and notes views run the shared draft, and re-seed from the library when it changes (F564)")
func theViewsUseTheSharedDraft() throws {
    let content = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/ContentView.swift")
    let titleStart = try #require(content.range(of: "private struct EditableMeetingTitle: View {"))
    let title = content[titleStart.lowerBound...].prefix(2_500)
    #expect(title.contains("MeetingFieldSync.commitTitle(&draft"))
    #expect(title.contains(".onChange(of: store.meeting(id: meetingID)?.title)"))
    #expect(title.contains("draft.libraryChanged("))
    #expect(title.contains("draft.userTyped("), "typing must reach the draft through the binding's setter")
    // F675: the re-seed asks the shared rule, not a local `focused && windowIsActive`.
    #expect(title.contains("MeetingFieldSync.isEditing(.title, focused: focused"))
    #expect(title.contains("isEditingHere: isBeingEdited"))
    #expect(!title.contains("isEditingHere: focused && windowIsActive"))

    #expect(content.contains("MeetingFieldSync.isEditing(.notes, focused: notesFocused"))
    #expect(content.contains("MeetingFieldSync.typeNotes("))
    #expect(content.contains(".onChange(of: store.meeting(id: meetingID)?.notes)"))
    #expect(content.contains("notesDraft.libraryChanged("))
}
