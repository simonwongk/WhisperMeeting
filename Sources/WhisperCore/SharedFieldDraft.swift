import Foundation

/// One window's copy of a field that another window can change underneath it (F564).
///
/// File ▸ New Window gives every window its own copy of a meeting's title and notes fields. They
/// were seeded from the library once, when they appeared, and a title field committed on
/// disappearing whenever its text differed from the library — so a rename made in window A was
/// written back to the OLD title the moment window B's untouched field went away. The difference
/// was never evidence of an edit: the library had moved, not the field.
///
/// So the draft keeps the one fact that is evidence — the user typed here — and decides from it:
/// only a field holding typing of its own writes anything, and a field holding none follows the
/// library whenever it is not being edited.
public struct SharedFieldDraft: Sendable, Equatable {
    public private(set) var text: String
    /// Whether the field holds typing that differs from what it last matched — what it wrote or was given.
    public private(set) var hasUnsavedEdit = false
    /// What the field last matched: the value it was given, or the library's value it last followed (F1055).
    private var matched: String

    public init(stored: String) {
        text = stored
        matched = stored
    }

    /// The user typed in this window. Only the field's binding calls this, so a value the app puts
    /// in the field is never mistaken for typing.
    ///
    /// Typing back to what the field last matched is no edit (F1055): a letter typed and deleted in a
    /// focused title used to leave the field marked as typed in, so a rename from the other window was
    /// not followed, and the field's commit wrote the old title back over it.
    public mutating func userTyped(_ newText: String) {
        guard newText != text else { return }
        text = newText
        hasUnsavedEdit = newText != matched
    }

    /// The library's value changed — in another window, or by this field's own commit. Followed
    /// unless this window holds typing of its own, or the user is in the field right now: rewriting
    /// text under a cursor the user has put there moves it and can eat a keystroke. The caller calls
    /// this again when editing ends, so a focused field catches up then.
    public mutating func libraryChanged(to stored: String, isEditingHere: Bool) {
        guard !hasUnsavedEdit, !isEditingHere else { return }
        text = stored
        matched = stored
    }

    /// What this field has to write, or nil when it has nothing of its own: never typed in, or
    /// typed back to what the library already holds. Taking the edit clears it.
    public mutating func takeEdit(stored: String) -> String? {
        guard hasUnsavedEdit else { return nil }
        hasUnsavedEdit = false
        // What the field holds is what it now hands out to be written, so typing back to it is no edit.
        matched = text
        return text == stored ? nil : text
    }

    /// The write `takeEdit` handed out was refused (a read-only library, a restore in progress).
    /// The typing is the user's again, so the next library change cannot replace it unseen.
    public mutating func writeWasRefused() {
        hasUnsavedEdit = true
    }

    /// Puts the library's value back, discarding what is in the field.
    public mutating func reset(to stored: String) {
        text = stored
        matched = stored
        hasUnsavedEdit = false
    }
}
