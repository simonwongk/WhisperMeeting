import Foundation
import WhisperCore

/// What a meeting's title and notes fields do with their `SharedFieldDraft` (F564) — the views call
/// these, so a test drives two windows' fields through the same calls.
@MainActor
enum MeetingFieldSync {
    enum Field { case title, notes }

    /// Whether a field counts as being edited, so a change from the other window must not be
    /// written into it (`SharedFieldDraft.libraryChanged(to:isEditingHere:)`).
    ///
    /// **The title: focus alone (F675).** A `TextField` with the cursor in it is backed by AppKit's
    /// field editor, which keeps first responder when its window goes to the background. Re-seeding
    /// the draft under it may leave the field editor showing the old title, and if that string comes
    /// back through the binding when editing ends it reads as typing — and the commit writes the old
    /// title over the rename. Not re-seeding while focused avoids the question; `EditableMeetingTitle`
    /// catches up in its `commit()` once focus leaves.
    ///
    /// **The notes: focused in the key window.** Notes are written through on every keystroke, so a
    /// background window's notes hold nothing unsaved; following the other window while this one is
    /// not in front is what keeps its copy current before the user types in it again (F564).
    nonisolated static func isEditing(_ field: Field, focused: Bool, windowIsActive: Bool) -> Bool {
        switch field {
        case .title: focused
        case .notes: focused && windowIsActive
        }
    }

    /// The title field's commit: on Return, on focus loss, and when the field goes away. Writes only
    /// what was typed in this field, so a window that never touched the title cannot write an old
    /// one back over a rename made in another window.
    static func commitTitle(_ draft: inout SharedFieldDraft, store: MeetingStore, meetingID: UUID) {
        let stored = store.meeting(id: meetingID)?.title ?? ""
        guard let typed = draft.takeEdit(stored: stored) else { return }
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        // An emptied title is put back rather than saved, as it always was.
        guard !trimmed.isEmpty else {
            draft.reset(to: stored)
            return
        }
        if trimmed != stored {
            store.update(id: meetingID) { $0.title = trimmed }
            if store.meeting(id: meetingID)?.title != trimmed { draft.writeWasRefused() }
        }
    }

    /// The notes field's keystroke: written straight through (debounced by the store, F133), so the
    /// draft holds no edit between keystrokes and the other window's field can follow it.
    static func typeNotes(_ text: String, into draft: inout SharedFieldDraft, store: MeetingStore, meetingID: UUID) {
        draft.userTyped(text)
        let stored = store.meeting(id: meetingID)?.notes ?? ""
        if let typed = draft.takeEdit(stored: stored) {
            store.editNotes(id: meetingID, text: typed)
            // `editNotes` stores an empty note as nil.
            if (store.meeting(id: meetingID)?.notes ?? "") != typed { draft.writeWasRefused() }
        }
    }
}
