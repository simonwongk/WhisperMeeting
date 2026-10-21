import Foundation
import Testing
@testable import WhisperMeet

// F835 (folded into F1038) — the watched folder's precompute and Second Opinion's Replace each wrote out
// the restore-in-progress refusal and then the read-only one by hand, so their order and wording could
// drift from `AppModel.libraryRefusal(_:)`, which exists so that they cannot. Both call it now.
@Test("The restoring-then-read-only refusal pair is written once, in libraryRefusal (F835)")
func theLibraryRefusalPairIsWrittenOnce() throws {
    let source = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/AppModel.swift")
    #expect(source.components(separatedBy: "ReadOnlyLibraryNotice.actionRefused(").count - 1 == 1,
            "the read-only refusal is written outside libraryRefusal again")
    // libraryRefusal's own, and libraryIsNotBeingRestored's, which shows it in the alert.
    #expect(source.components(separatedBy: "libraryRestoringMessage(").count - 1 == 3,
            "the restore refusal is written outside libraryRefusal again (its definition, libraryRefusal, libraryIsNotBeingRestored)")
    #expect(source.contains("libraryRefusal(\"Import\")"))
    #expect(source.contains("libraryRefusal(Self.secondOpinionReplaceAction)"))
}
