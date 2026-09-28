import AppKit
import ApplicationServices
import Foundation
import Testing
@testable import WhisperMeet

/// F601, part 1 — F516's probe counted any element with a text role, or any element answering
/// `kAXSelectedTextRangeAttribute`, as a text field. A focused read-only `AXTextArea` (a console or
/// log pane) is both, so ⌘V inserted nothing, the pill said "Pasted", and 1.5 s later the user's old
/// clipboard was put back over the transcript — the one case F516's rule exists to prevent.
///
/// Read-only takes positive evidence: `AXUIElementIsAttributeSettable` answering "no" for both the
/// value and the selected text. AXAttributeConstants.h allows an editable element's value to be
/// unsettable ("it does not need to be writable if some other form of direct manipulation is more
/// appropriate"), so one "no", or no answer, leaves the element a text field.

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

@Test("A read-only text area is not a text field (F601)")
func aReadOnlyTextAreaIsNotATextField() {
    #expect(!FocusedTextField.probe(reading: reading(valueSettable: false, selectedTextSettable: false)).isTextField)
    // Not a text role, only a selection — a web page's document, say — read-only as well.
    #expect(!FocusedTextField.probe(reading: reading(valueSettable: false, selectedTextSettable: false, role: "AXWebArea")).isTextField)
}

@Test("An editable text area, or one Accessibility gives no clear answer for, is still a text field (F601)")
func anEditableOrUnansweredTextAreaIsATextField() {
    #expect(FocusedTextField.probe(reading: reading(valueSettable: true, selectedTextSettable: true)).isTextField)
    #expect(FocusedTextField.probe(reading: reading(valueSettable: false, selectedTextSettable: true)).isTextField)
    #expect(FocusedTextField.probe(reading: reading(valueSettable: true, selectedTextSettable: false)).isTextField)
    // One "no" and no answer: the value may simply not be the way this element is edited.
    #expect(FocusedTextField.probe(reading: reading(valueSettable: false, selectedTextSettable: nil)).isTextField)
    #expect(FocusedTextField.probe(reading: reading(valueSettable: nil, selectedTextSettable: nil)).isTextField)
}

@MainActor
@Test("A dictation into a read-only pane is left on the clipboard, not restored over (F601)")
func aDictationIntoAReadOnlyPaneStaysOnTheClipboard() throws {
    let board = NSPasteboard.withUniqueName()
    defer { board.releaseGlobally() }
    board.clearContents()
    board.setString("copied on my phone", forType: .string)
    try #require(board.string(forType: .string) == "copied on my phone", "the private pasteboard does not round-trip a string on this host")
    var scheduled = 0
    var pasted = 0
    let injector = TextInjector(
        pasteboard: board,
        canSynthesizePaste: { true },
        focusedTextField: { FocusedTextField.probe(reading: reading(valueSettable: false, selectedTextSettable: false)) },
        synthesizePaste: {
            pasted += 1
            return true
        },
        schedule: { _, _ in scheduled += 1 }
    )

    #expect(injector.deliver("dictated words", autoPaste: true) == .pastedUnconfirmed)
    #expect(pasted == 1)
    #expect(scheduled == 0)
    #expect(board.string(forType: .string) == "dictated words")
}
