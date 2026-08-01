import Foundation
import Testing
@testable import WhisperMeet

// F133 — the Notes editor had the same per-keystroke whole-index write as the transcript editor
// (F40): notesSection's `.onChange(of: notesDraft)` called `store.update` on every character. Notes
// edits must coalesce the same way — immediate in-memory value, one debounced write.

@MainActor
@Test("Notes keystrokes coalesce into one index write, flushed on demand (F133)")
func notesEditsCoalesceIntoOneWrite() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("NotesEditCoalescingTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    let store = MeetingStore(rootDirectory: root, transcriptWriteDebounce: 60)
    let id = UUID()
    store.upsert(MeetingRecord(id: id, title: "Meeting", status: .completed))
    let baseline = store.persistCount

    for i in 0..<20 { store.editNotes(id: id, text: "note \(i)") }

    #expect(store.persistCount - baseline == 0)
    #expect(store.meeting(id: id)?.notes == "note 19")

    store.flushPendingEdits()

    #expect(store.persistCount - baseline == 1)
    let reloaded = MeetingStore(rootDirectory: root)
    #expect(reloaded.meeting(id: id)?.notes == "note 19")
}
