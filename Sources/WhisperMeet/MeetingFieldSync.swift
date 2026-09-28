import Foundation
import WhisperCore

/// What a meeting's title and notes fields do with their `SharedFieldDraft` (F564) — the views call
/// these, so a test drives two windows' fields through the same calls.
@MainActor
enum MeetingFieldSync {
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
