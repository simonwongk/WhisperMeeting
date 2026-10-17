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

    /// A committed-on-exit field (the title; an action item's owner and due) seeing the library's
    /// value change underneath it. Returns true when the view should take the cursor out of the field.
    ///
    /// Not focused, or holding typing of its own: F564/F675's rule, unchanged — follow unless focused,
    /// keep the typing.
    ///
    /// **Focused with nothing typed, and now stale (F811).** F675 stopped re-seeding a focused title,
    /// because AppKit's field editor keeps first responder in a background window and may hand its
    /// old string back as typing. But nothing else re-seeds it either, and the field keeps the cursor
    /// when its window comes back to the front — so the user was shown the old value, typed onto it,
    /// and saved "old + edit" over the other window's change. So the field gives up the cursor
    /// instead. Its view's focus change commits (nothing: nothing was typed) and catches up
    /// (`libraryChanged(…, isEditingHere: false)`). The draft is untouched until then, so if the field
    /// editor hands its string back as it ends editing, that string equals the draft's and reads as no
    /// typing at all (`userTyped` ignores an unchanged value).
    static func committedFieldLibraryChanged(_ draft: inout SharedFieldDraft, to stored: String, focused: Bool) -> Bool {
        if focused, !draft.hasUnsavedEdit, draft.text != stored { return true }
        // Focus alone is editing for a committed-on-exit field (`isEditing(.title, …)`, F675).
        draft.libraryChanged(to: stored, isEditingHere: focused)
        return false
    }

    /// An action item's owner or due field's commit (F676): on Return, on focus loss, and when the
    /// card goes away — the title's rule (`commitTitle`) for a value that may be empty. It used to
    /// write whenever the field's text differed from the item, which is also true of an untouched
    /// field in a second window after the owner was set in the first, so that window's card going
    /// away wrote its empty owner back over it.
    ///
    /// Only typing writes. A typed value is trimmed, and an emptied field clears the value, as before.
    /// `readBack` reports what the item holds after the write, so a refused write (a read-only
    /// library) keeps the typing in the field.
    static func commitActionItemField(
        _ draft: inout SharedFieldDraft,
        stored: String?,
        write: (String?) -> Void,
        readBack: () -> String?
    ) {
        guard let typed = draft.takeEdit(stored: stored ?? "") else { return }
        let trimmed = typed.trimmingCharacters(in: .whitespacesAndNewlines)
        let value: String? = trimmed.isEmpty ? nil : trimmed
        guard value != stored else { return }
        write(value)
        if readBack() != value { draft.writeWasRefused() }
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
