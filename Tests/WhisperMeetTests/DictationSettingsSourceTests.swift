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
