import Foundation
import Testing
@testable import WhisperMeet

// F40 — the transcript editor persisted the whole meetings index on every keystroke (one full-array
// encode + two atomic file writes per character). Edits must coalesce: the in-memory value updates
// immediately so the editor stays live, but the expensive whole-index write is debounced to a single
// flush. This drives MeetingStore directly (headless), where the fix lives.

@MainActor
@Test("Transcript keystrokes coalesce into one index write, flushed on demand (F40)")
func transcriptEditsCoalesceIntoOneWrite() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("TranscriptEditCoalescingTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    // A large debounce means the pending flush never fires on its own during the test — only an
    // explicit flush writes, so the write count is fully determined by the coalescing behaviour.
    let store = MeetingStore(rootDirectory: root, transcriptWriteDebounce: 60)
    let id = UUID()
    store.upsert(MeetingRecord(id: id, title: "Meeting", status: .completed, transcriptText: "start"))
    let baseline = store.persistCount

    for i in 0..<20 { store.editTranscript(id: id, text: "edit \(i)") }

    // No disk write yet — 20 keystrokes coalesced into zero pending-window writes.
    #expect(store.persistCount - baseline == 0)
    // …but the in-memory value is live immediately so the editor reflects every keystroke.
    #expect(store.meeting(id: id)?.transcriptText == "edit 19")

    store.flushPendingEdits()

    // Exactly one write on flush.
    #expect(store.persistCount - baseline == 1)
    // …and it reached disk: a fresh store reloads the final text.
    let reloaded = MeetingStore(rootDirectory: root)
    #expect(reloaded.meeting(id: id)?.transcriptText == "edit 19")
}
