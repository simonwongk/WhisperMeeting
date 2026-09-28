import Foundation
import Testing

// Source assertions for Settings ▸ Quick Dictation and the review sheets. The `WhisperMeet` target
// has no view-render harness (F174's standing reason), so what a view calls is checkable only as
// its source text, with comments stripped first (F285) and string literals blanked so a `{` in a
// literal is not a scope.

private func contentViewSource() throws -> String {
    SourceAssertion.stripComments(
        try String(contentsOf: SourceAssertion.url("Sources/WhisperMeet/ContentView.swift"), encoding: .utf8),
        blankStringLiterals: true
    )
}

/// The braces-balanced body that follows the first `marker`.
private func body(following marker: String, in source: String) -> String {
    guard let markerRange = source.range(of: marker),
          let openBrace = source.range(of: "{", range: markerRange.upperBound..<source.endIndex) else {
        Issue.record("could not find \(marker.debugDescription) in ContentView.swift; did it move?")
        return ""
    }
    var depth = 1
    var cursor = openBrace.upperBound
    while cursor < source.endIndex, depth > 0 {
        if source[cursor] == "{" { depth += 1 } else if source[cursor] == "}" { depth -= 1 }
        cursor = source.index(after: cursor)
    }
    return String(source[openBrace.upperBound..<cursor])
}

@Test("Choosing a trigger hears only its own window, lets other keys through and cancels on Escape (F521)")
func triggerCaptureIsScopedAndCancellable() throws {
    let capture = body(following: "private func toggleKeyCapture()", in: try contentViewSource())
    #expect(!capture.isEmpty)
    // The rules live in WhisperCore's tested `DictationTriggerCapture`; the view only feeds it.
    #expect(capture.contains("keyCapture.handle("), "the capture does not ask DictationTriggerCapture what a key means")
    // An app-wide monitor heard the toolbar search and every other window.
    #expect(capture.contains("event.window === "), "the capture is not scoped to the window its button is in")
    #expect(capture.contains("case .cancel"), "Escape does not end the capture")
    // Returning nil for every event is what swallowed ⌘W, Tab and Space.
    #expect(capture.contains("return event"), "the capture swallows every key")
}

@Test("The trigger row no longer promises F-keys type nothing, and warns about keys macOS uses (F547)")
func triggerRowDescribesWhatTheKeyReallyDoes() throws {
    // Literals kept: the claim being removed is copy.
    let source = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/ContentView.swift")
    #expect(
        !source.contains("they don’t type text while held") && !source.contains("they don't type text while held"),
        "Settings still says an F-key does not reach the app in front"
    )
    #expect(
        source.contains("DictationKeyName.systemShortcut(for: dictation.hotkey.keyCode)"),
        "the trigger row does not warn about an F-key macOS already uses"
    )
}

// F537 part 2 — the review sheets had no Return or Escape: no `.cancelAction` anywhere in the app, and
// no `.defaultAction` on these sheets' primary buttons, so without Full Keyboard Access a keyboard
// user could neither confirm nor leave them.

@Test("Suggested Vocabulary and Correct toward Vocabulary answer Return and Escape (F537)")
func reviewSheetsAnswerReturnAndEscape() throws {
    let source = try contentViewSource()
    for sheet in ["VocabularySuggestionSheet", "GlossarySuggestionSheet"] {
        let sheetBody = body(following: "private struct \(sheet): View", in: source)
        #expect(sheetBody.contains(".keyboardShortcut(.cancelAction)"), "\(sheet): Escape does not cancel")
        #expect(sheetBody.contains(".keyboardShortcut(.defaultAction)"), "\(sheet): Return does not confirm")
    }
}

@Test("Remove Lines answers Escape, and Return never removes lines (F537)")
func lineRemovalSheetCancelsButNeverDefaultsToRemoving() throws {
    let sheetBody = body(following: "private struct LanguageLineRemovalSheet: View", in: try contentViewSource())
    #expect(sheetBody.contains(".keyboardShortcut(.cancelAction)"), "Escape does not cancel")
    // Its primary action is destructive, and the HIG keeps a destructive action off Return.
    #expect(!sheetBody.contains(".defaultAction"), "Return removes lines")
}

@Test("Add from a Link: Escape stops or cancels, and Return in the link field is the field's own submit (F537)")
func linkImportSheetAnswersReturnAndEscape() throws {
    let sheetBody = body(following: "private struct LinkImportSheet: View", in: try contentViewSource())
    #expect(sheetBody.contains(".keyboardShortcut(.cancelAction)"), "Escape neither stops the download nor cancels")
    // A default button would also take the Return typed in the link field, so it is the default
    // only while that field does not have focus.
    #expect(sheetBody.contains("@FocusState"), "the sheet cannot tell when the link field has focus")
    #expect(sheetBody.contains("? nil : .defaultAction)"), "Return fires Download while typing in the field")
}

@Test("Settings' Grant… reaches the controller's retrying request, not the bare system prompt (F523)")
func grantButtonReachesTheRetryingRequest() throws {
    let source = try contentViewSource()
    // `requestAccessibility()` is what starts the checks that arm the trigger once trusted; calling
    // `HotkeyMonitor.requestAccessibility()` from the view would only open System Settings.
    #expect(source.contains("dictation.requestAccessibility()"), "Grant… no longer calls the controller")
    #expect(
        !source.contains("HotkeyMonitor.requestAccessibility()"),
        "a view asks for Accessibility without arming the trigger afterwards"
    )
}
