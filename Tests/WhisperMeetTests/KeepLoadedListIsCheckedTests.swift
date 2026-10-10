import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F865 — Keep This List (and Start a New List) saved a damaged list unchecked.
//
// A list whose file did not load cleanly is read-only until the person keeps what it shows (F464). The
// load handed back a generation token only for a clean file, so that keep was `save(expecting: nil)`:
// last-writer-wins. With two copies of the app open on one library, the other copy could keep its own
// view of the damaged list and add to it — and this window's keep then replaced that newer list with the
// damaged window's, without a conflict copy, and without a word. Found by Wave 4 lane Q ("Grafana" gone).
//
// Keep is now compared against the file as this window read it, so a newer save is a lost race like any
// other list change's (F663): this window re-reads the list and shows what the other copy saved. Every
// damage `makeDamagedLibrary` (F464) makes, on both lists.

@MainActor
private func contents(of file: DamagedFile, in store: MeetingStore) -> [String] {
    switch file {
    case .vocabulary: return store.vocabulary
    case .replacementRules: return store.replacementRules.map(\.preferred)
    }
}

@MainActor
private func add(_ term: String, to file: DamagedFile, in store: MeetingStore) {
    switch file {
    case .vocabulary: store.addVocabulary([term])
    case .replacementRules: store.addReplacementRule(heard: "\(term) heard", preferred: term)
    }
}

@MainActor
@Test(
    "Keeping a damaged list does not replace a newer list another copy saved meanwhile (F865)",
    arguments: DamagedFile.allCases, ListDamage.allCases
)
func keepingADamagedListLosesToANewerSave(file: DamagedFile, damage: ListDamage) throws {
    let root = try makeDamagedLibrary(file, damage)
    defer { try? FileManager.default.removeItem(at: root) }
    // Two copies open on the damaged list.
    let here = MeetingStore(rootDirectory: root)
    let other = MeetingStore(rootDirectory: root)
    try #require(here.isListReadOnly(file.list) && other.isListReadOnly(file.list), "fixture: the list is damaged")

    // The other copy keeps what it shows and adds to it.
    other.keepLoadedList(file.list)
    add("from-the-other-copy", to: file, in: other)
    try #require(contents(of: file, in: MeetingStore(rootDirectory: root)).contains("from-the-other-copy"),
                 "fixture: the other copy's newer list reached disk")

    here.keepLoadedList(file.list)

    let onDisk = contents(of: file, in: MeetingStore(rootDirectory: root))
    #expect(onDisk.contains("from-the-other-copy"), "Keep replaced the other copy's newer list: \(onDisk)")
    #expect(contents(of: file, in: here).contains("from-the-other-copy"), "this window does not show what is on disk")
    #expect(!here.isListReadOnly(file.list), "the list the other copy saved loads cleanly")
    let said = try #require(here.storageErrorMessage, "nothing said why Keep did not save")
    #expect(said.contains("The list now shows what the other copy saved."), "\(said)")
}
