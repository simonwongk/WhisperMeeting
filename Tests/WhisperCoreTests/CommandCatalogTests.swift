import Testing
@testable import WhisperCore

/// F69 — the keyboard command catalog.
@Test("No two commands share a shortcut; display strings and enablement are correct")
func commandCatalog() {
    // No two commands share the same (keyEquivalent, modifiers) — a real accessibility footgun.
    let shortcuts = CommandCatalog.all.compactMap { command -> String? in
        command.keyEquivalent.map { "\($0)|\(command.modifiers.rawValue)" }
    }
    #expect(Set(shortcuts).count == shortcuts.count)

    // displayShortcut exact strings.
    let addMarker = CommandCatalog.all.first { $0.id == "addMarker" }!
    #expect(CommandCatalog.displayShortcut(for: addMarker) == "⇧⌘M")
    let record = CommandCatalog.all.first { $0.id == "toggleRecording" }!
    #expect(CommandCatalog.displayShortcut(for: record) == "⌘R")
    let cancel = CommandCatalog.all.first { $0.id == "cancelRecording" }!
    #expect(CommandCatalog.displayShortcut(for: cancel) == nil) // no key equivalent

    // Add Marker is enabled only while recording.
    #expect(addMarker.enablement.isEnabled(AppCommandState(isRecording: true)))
    #expect(!addMarker.enablement.isEnabled(AppCommandState(isRecording: false)))
}
