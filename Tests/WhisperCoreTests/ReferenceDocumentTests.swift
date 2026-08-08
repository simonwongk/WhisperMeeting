import Foundation
import Testing
@testable import WhisperCore

// F170 — prepare a user-chosen reference document for the on-device transcript-correction pass.
// The reference is capped so a large document can never overflow the local model's context window,
// and a cap must never hand the model a half-truncated line.

@Test("Reference under the cap is returned trimmed, unchanged (F170)")
func referenceUnderCapIsTrimmed() {
    let text = "  Preferred spelling: Sequoya\nProduct name: Kubernetes  "
    #expect(ReferenceDocument.prepared(text) == "Preferred spelling: Sequoya\nProduct name: Kubernetes")
}

@Test("Empty or whitespace-only reference prepares to nil so the caller skips it (F170)")
func emptyReferencePreparesToNil() {
    #expect(ReferenceDocument.prepared("") == nil)
    #expect(ReferenceDocument.prepared("   \n\t  ") == nil)
}

@Test("Oversized reference is cut back to a line boundary within the cap, never mid-line (F170)")
func oversizedReferenceCutsAtLineBoundary() {
    // Four 30-char lines (~124 chars with newlines); cap at 100 must keep whole lines only.
    let line = String(repeating: "x", count: 29)
    let text = (1...4).map { "\($0)\(line)" }.joined(separator: "\n")
    let prepared = ReferenceDocument.prepared(text, maxCharacters: 100)
    let unwrapped = try! #require(prepared)
    #expect(unwrapped.count <= 100)
    // No partial final line: every retained line is a full 30-char line.
    for retained in unwrapped.split(separator: "\n") {
        #expect(retained.count == 30)
    }
    // Some content survived, and it is a prefix of the original whole lines.
    #expect(text.hasPrefix(unwrapped))
}

@Test("Oversized single line with no newline still caps to the character limit (F170)")
func oversizedSingleLineCaps() {
    let text = String(repeating: "y", count: 500)
    let prepared = ReferenceDocument.prepared(text, maxCharacters: 100)
    let unwrapped = try! #require(prepared)
    #expect(unwrapped.count == 100)
}
