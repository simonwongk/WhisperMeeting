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

/// `DictationTriggerChooser`, which took Change's monitors out of `SettingsView` (F691).
private func triggerChooserSource() throws -> String {
    SourceAssertion.stripComments(
        try String(
            contentsOf: SourceAssertion.url("Sources/WhisperMeet/Dictation/DictationTriggerChooser.swift"),
            encoding: .utf8
        ),
        blankStringLiterals: true
    )
}

/// The braces-balanced body that follows the first `marker`.
private func body(following marker: String, in source: String) -> String {
    guard let markerRange = source.range(of: marker),
          let openBrace = source.range(of: "{", range: markerRange.upperBound..<source.endIndex) else {
        Issue.record("could not find \(marker.debugDescription) in the source; did it move?")
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

// Since F691 Change's monitors live in `DictationTriggerChooser`, and F521's and F653's checks below
// read that file. What the chooser does with each decision is driven for real in
// `DictationTriggerChooserTests`; what is left to read here is the event plumbing no test can feed.

@Test("Choosing a trigger hears only its own window, lets other keys through and cancels on Escape (F521)")
func triggerCaptureIsScopedAndCancellable() throws {
    let source = try triggerChooserSource()
    let begin = body(following: "private func begin(", in: source)
    #expect(!begin.isEmpty)
    // An app-wide monitor heard the toolbar search and every other window.
    #expect(begin.contains("event.window === "), "the capture is not scoped to the window its button is in")
    // Returning nil for every event is what swallowed ⌘W, Tab and Space.
    #expect(begin.contains("? event : nil"), "the capture swallows keys its rules let through")
    let receive = body(following: "func receive(", in: source)
    // The rules live in WhisperCore's tested `DictationTriggerCapture`; the chooser only feeds it.
    #expect(receive.contains("capture.handle("), "the capture does not ask DictationTriggerCapture what a key means")
    #expect(receive.contains("case .cancel"), "Escape does not end the capture")
}

@Test("Choosing a trigger hears clicks, in the app and outside it, as chord input (F653)")
func triggerCaptureHearsClicks() throws {
    let source = try triggerChooserSource()
    let begin = body(following: "private func begin(", in: source)
    #expect(begin.contains("receive(.click)"), "a click is not fed to the capture")
    #expect(begin.contains(".leftMouseDown"), "the capture's monitors do not include mouse-down")
    #expect(begin.contains("monitors.addGlobal("), "a modifier-click in another app is not heard")
    #expect(source.contains("NSEvent.addGlobalMonitorForEvents("), "the app's global monitor is not NSEvent's")
    let end = body(following: "func end()", in: source)
    #expect(end.contains("clickMonitor"), "the click monitor outlives the capture")
}

@Test("Settings' Change drives the trigger chooser, and leaving Settings ends it (F521, F691)")
func settingsChangeDrivesTheTriggerChooser() throws {
    let source = try contentViewSource()
    let settings = body(following: "struct SettingsView: View", in: source)
    #expect(settings.contains("triggerChooser.toggle("), "Change does not start choosing a trigger")
    #expect(settings.contains(".onDisappear { triggerChooser.end() }"), "leaving Settings leaves a choice running")
    // A monitor installed by the view itself would be one nothing ends.
    #expect(!source.contains("addLocalMonitorForEvents"), "ContentView installs an event monitor of its own")
    #expect(!source.contains("addGlobalMonitorForEvents"), "ContentView installs a global event monitor of its own")
}

@Test("The trigger row no longer promises F-keys type nothing, and warns about keys macOS uses (F547)")
func triggerRowDescribesWhatTheKeyReallyDoes() throws {
    // Literals kept: the claim being removed is copy. The caption itself is the controller's since
    // F684, so both files are read.
    let source = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/ContentView.swift")
    let caption = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/Dictation/DictationController.swift")
    for text in [source, caption] {
        #expect(
            !text.contains("they don’t type text while held") && !text.contains("they don't type text while held"),
            "Settings still says an F-key does not reach the app in front"
        )
    }
    #expect(
        source.contains("DictationKeyName.systemShortcut(for: dictation.hotkey.keyCode)"),
        "the trigger row does not warn about an F-key macOS already uses"
    )
}

@Test("Settings' trigger caption is the controller's, which knows the tap it armed (F684)")
func triggerCaptionComesFromTheArmedTap() throws {
    let settings = body(following: "struct SettingsView: View", in: try contentViewSource())
    #expect(settings.contains("Text(dictation.triggerKeyCaption)"), "the trigger row does not show the controller's caption")
    // A second copy of the claim in the view is one that cannot see whether the key is held back.
    let source = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/ContentView.swift")
    #expect(!source.contains("does not receive it"), "the view still writes its own caption for an F-key")
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
