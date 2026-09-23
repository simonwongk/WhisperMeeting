import Foundation
import Testing

// F422, F423, F424 — the three controls live in `ContentView`, which this target cannot render
// (F174's standing reason). `TranscriptLineRemovalTests` proves the AppModel layer; these prove a
// control still reaches it, which a passing model suite cannot see (F306: a deleted button left
// three tickets' worth of mechanism unreachable with every test green). Comments are stripped
// first, so an explanation of the wiring cannot stand in for the wiring (F285).

private func contentView() throws -> String {
    try SourceAssertion.uncommentedSource("Sources/WhisperMeet/ContentView.swift")
}

@Test("Delete Line in the Read view reaches the model's removal, with undo (F423)")
func deleteLineIsWired() throws {
    let source = try contentView()
    #expect(source.contains(#"Button("Delete Line", role: .destructive) { deleteLine(at: index) }"#))
    #expect(source.contains("model.removeTranscriptLines(at: [index], from: meetingID)"))
    #expect(source.contains(#"registerLineRemovalUndo(removal, model: model, undoManager: undoManager, actionName: "Delete Line")"#))
    #expect(source.contains("model.undoTranscriptLineRemoval(removal)"))
    // The rows are cached by index, so a deletion must rebuild them or the deleted line stays visible.
    #expect(source.contains(".onChange(of: segments) { _, _ in"))
}

@Test("Remove Repeated Lines sits beside its notice and reaches the model, gated (F422)")
func removeRepeatedLinesIsWired() throws {
    let source = try contentView()
    #expect(source.contains(#"Button("Remove Repeated Lines") { removeRepeatedLines() }"#))
    #expect(source.contains("model.removeRepeatedLines(from: meetingID)"))
    #expect(source.contains("TranscriptRepetitionCleanup.removableNotice(count: removableRepeats)"))
    #expect(source.contains("TranscriptRepetitionCleanup.removedNote(count: removed)"))
    #expect(source.contains("removableRepeats = edited ? 0 : model.removableRepeatCount(for: meetingID)"))
    #expect(source.contains(".disabled(model.lineRemovalBlockedReason(for: meetingID) != nil)"))
}

@Test("Remove Lines in Another Language opens a confirmation that reaches the model (F424)")
func languageLineRemovalIsWired() throws {
    let source = try contentView()
    #expect(source.contains(#"Label("Remove Lines in Another Language…", systemImage: "character.bubble")"#))
    #expect(source.contains("model.linesOutsideMeetingLanguage(for: meetingID)"))
    #expect(source.contains(".sheet(item: $languageRemovalOffer)"))
    #expect(source.contains("model.removeTranscriptLines(at: IndexSet(indices), from: meetingID)"))
}
