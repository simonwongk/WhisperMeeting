import Foundation
import Testing
@testable import WhisperMeet

// F578 (the user's decision of 2026-10-16: "Document the steps"; nothing changes on screen). A
// vocabulary or rules list changed outside WhisperMeet opens read-only on the edited copy, and the
// version WhisperMeet last saved is kept only in `<stem>.history/`. The recovery guide now gives the
// steps to bring that version back, and this pins that they are there and name the real files.

@MainActor
@Test("RECOVERY.md gives the steps to bring back WhisperMeet's own last save of a hand-edited list (F578)")
func theRecoveryGuideHasTheHandEditedListSteps() throws {
    let doc = try String(contentsOf: SourceAssertion.url("docs/RECOVERY.md"), encoding: .utf8)
    let heading = "### If you want WhisperMeet's last saved list back after editing it by hand"
    let start = try #require(doc.range(of: heading), "the section is missing")
    let section = String(doc[start.upperBound...].prefix(2_500))
    for name in ["vocabulary.history", "replacement-rules.history", "vocabulary.json", "replacement-rules.json", "Keep This List"] {
        #expect(section.contains(name), "the steps do not mention \(name)")
    }
    // The steps keep the hand-edited file rather than overwrite it.
    #expect(section.contains("cp -n") || section.contains("mv "), "the steps do not set the edited copy aside")
    // And the button the list's notice names is the one that finishes it, so the sentence and the
    // steps agree.
    #expect(DamagedListNotice.actionTitle(for: .vocabulary, health: .divergentGenerations) == "Keep This List")
}
