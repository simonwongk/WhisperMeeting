import AppKit
import ApplicationServices
import Foundation
import Testing
@testable import WhisperMeet

/// F601, part 1 — F516's probe counts any element with a text role, or any element answering
/// `kAXSelectedTextRangeAttribute`, as a text field. A focused read-only `AXTextArea` (a console or
/// log pane) is both, so ⌘V inserts nothing, the pill says "Pasted", and 1.5 s later the user's old
/// clipboard is put back over the transcript.
///
/// The probe reads `AXUIElementIsAttributeSettable` for the value and the selected text, and marks an
/// element answering "no" to both as "(read-only)" in the diagnostic log — but, after the lane J
/// review, does NOT act on it. Ghostty's terminal view implements only the getters for both
/// attributes and iTerm2's only a selection-range setter, and the review's in-process stand-in showed
/// AppKit reports a getters-only view as settable for neither: the same answer a read-only
/// `NSTextView` gives. Acting on it would most likely stop every dictation into those terminals from
/// giving the clipboard back — the worse of the two mistakes, since the user's own clipboard is
/// nowhere else. So the reading is logged until the F174 check records what Terminal, iTerm2 and
/// Ghostty really answer, and these tests pin that it changes nothing yet.

private func reading(valueSettable: Bool?, selectedTextSettable: Bool?, role: String = kAXTextAreaRole) -> FocusedTextField.Reading {
    FocusedTextField.Reading(
        bundleIdentifier: "com.example.console",
        processIdentifier: 300,
        focused: .init(
            role: role, subrole: nil, hasSelectedTextRange: true,
            valueSettable: valueSettable, selectedTextSettable: selectedTextSettable
        )
    )
}

@Test("A read-only reading is logged but does not yet change what counts as a text field (F601)")
func aReadOnlyReadingIsLoggedOnly() {
    let probe = FocusedTextField.probe(reading: reading(valueSettable: false, selectedTextSettable: false))
    #expect(probe.isTextField)
    #expect(probe.summary.contains("(read-only)"))
    let webArea = FocusedTextField.probe(reading: reading(valueSettable: false, selectedTextSettable: false, role: "AXWebArea"))
    #expect(webArea.isTextField)
    #expect(webArea.summary.contains("(read-only)"))
}

@Test("An editable text area, or one Accessibility gives no clear answer for, is a text field and not marked (F601)")
func anEditableOrUnansweredTextAreaIsATextField() {
    let cases: [(Bool?, Bool?)] = [(true, true), (false, true), (true, false), (false, nil), (nil, nil)]
    for (value, selectedText) in cases {
        let probe = FocusedTextField.probe(reading: reading(valueSettable: value, selectedTextSettable: selectedText))
        #expect(probe.isTextField)
        #expect(!probe.summary.contains("(read-only)"))
    }
}

/// Pins the interim decision end to end, so acting on the reading later is a deliberate change with
/// its own RED: a dictation into an element read as read-only still gives the clipboard back.
@MainActor
@Test("A dictation where the focused element reads as read-only still gives the clipboard back, for now (F601)")
func aReadOnlyReadingStillRestoresTheClipboard() throws {
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    board.clearContents()
    board.setString("copied on my phone", forType: .string)
    try #require(board.string(forType: .string) == "copied on my phone", "the private pasteboard does not round-trip a string on this host")
    var restores: [@MainActor () -> Void] = []
    var pasted = 0
    let injector = TextInjector(
        pasteboard: board,
        canSynthesizePaste: { true },
        focusedTextField: { FocusedTextField.probe(reading: reading(valueSettable: false, selectedTextSettable: false)) },
        synthesizePaste: {
            pasted += 1
            return true
        },
        schedule: { _, work in restores.append(work) }
    )

    #expect(injector.deliver("dictated words", autoPaste: true) == .pasted)
    #expect(pasted == 1)
    try #require(restores.count == 1)
    restores[0]()
    #expect(board.string(forType: .string) == "copied on my phone")
}
