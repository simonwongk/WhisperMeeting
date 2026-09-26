import Foundation
import Testing
@testable import WhisperMeet

/// F492: the Vocabulary screen's header claimed "Up to 100 reviewed terms are kept" — that number
/// is `VocabularyPrompt`'s PROMPT budget, not storage's. `MeetingStore.maxStoredVocabularyTerms`
/// (5,000) is what actually governs what is kept, and the same screen's Add-result message already
/// quoted 5,000 as a hand-typed literal — two numbers, on one screen, both describing the same
/// ceiling, with no code path forcing them to agree.
///
/// `ContentView` cannot be rendered in this target (F174's standing reason), so this is a source
/// assertion in the F306/F374 style: it reads the file as text (comments stripped, per F285) rather
/// than mounting the view.
@Test("Vocabulary header and Add-result copy derive the storage limit from MeetingStore, not a literal (F492)")
func vocabularyCopyDerivesStorageLimitFromTheStoreConstant() throws {
    let source = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/ContentView.swift")

    #expect(
        !source.contains("Up to 100 reviewed terms are kept"),
        "the header must not hard-code the PROMPT budget (100) as if it were the storage limit"
    )
    #expect(
        !source.contains("5,000-term limit"),
        "the Add-result message must not hard-code 5,000 as a literal"
    )

    // Both copies must be built from the same symbol, or a future edit to one can silently
    // reintroduce a second, disagreeing number.
    let referenceCount = source.components(separatedBy: "MeetingStore.maxStoredVocabularyTerms").count - 1
    #expect(
        referenceCount >= 2,
        "expected the header and the Add-result message to both reference MeetingStore.maxStoredVocabularyTerms; found \(referenceCount) reference(s)"
    )
}

/// The constant the copy above must be able to see. Reachable from `ContentView` requires it not be
/// `private` — this is the failing half of the red state before the fix (a `private` constant
/// cannot be named from another file, so the copy above could not have compiled against it).
@MainActor
@Test("MeetingStore's stored-vocabulary ceiling is visible outside the file that declares it (F492)")
func storedVocabularyCeilingIsNotPrivate() {
    #expect(MeetingStore.maxStoredVocabularyTerms == 5_000)
}
