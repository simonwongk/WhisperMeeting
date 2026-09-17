import Foundation
import Testing
@testable import WhisperCore

// F239 — F190 keeps past index generations under `<stem>.history/` so a library-wiping save can be
// undone, and those generations hold meeting titles, transcripts, notes and summaries. Deleting a
// meeting removes its recording folder immediately but leaves its TEXT in every retained
// generation, with no in-app way to remove it. `docs/RECOVERY.md` documents deleting the directory
// by hand, which is not a feature.
//
// So "Delete Meeting" reads as erasure and is not, for the text. The bound is the retention
// policy's oldest age anchor — about a week — with one unbounded exception: the high-water
// generation is pinned indefinitely, so if it predates the deletion the text stays until a larger
// generation replaces it. On a library that is not growing, that is forever.
//
// This is the first half: a command that forgets the retained history outright. The shred-on-delete
// half needs a decision about defaults and is recorded in the log entry rather than guessed at.

private func makeHistory() throws -> (history: StoreHistory, root: URL, primary: URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("F239-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let primary = root.appendingPathComponent("meetings.json")
    return (StoreHistory(primaryURL: primary), root, primary)
}

/// Archives `bytes` as generation `sequence`, the way a real save does: stage a file, then retain
/// it under its content-addressed name.
@discardableResult
private func archive(
    _ bytes: Data,
    sequence: UInt64,
    in history: StoreHistory,
    root: URL
) throws -> String {
    let staged = root.appendingPathComponent("staged-\(sequence).json")
    try bytes.write(to: staged)
    let name = try history.record(
        stagedAt: staged,
        generation: sequence,
        fingerprint: StoreFileIO.live.fingerprint(bytes)
    )
    try? FileManager.default.removeItem(at: staged)
    return try #require(name)
}

@Test("Forgetting history removes every retained generation (F239)")
func forgetRemovesEveryGeneration() throws {
    let (history, root, _) = try makeHistory()
    defer { try? FileManager.default.removeItem(at: root) }

    for sequence in 1...3 {
        try archive(
            Data(#"[{"title":"Board review \#(sequence)"}]"#.utf8),
            sequence: UInt64(sequence),
            in: history,
            root: root
        )
    }
    #expect(history.retained().count == 3)

    let forgotten = try history.forgetAll()

    #expect(forgotten.count == 3)
    #expect(history.retained().isEmpty)
}

@Test("Forgetting history leaves the live index and its backup untouched (F239)")
func forgetKeepsTheLivePair() throws {
    // The whole point of the retained generations is undo protection; forgetting them must not
    // touch the library itself. A command that erased the live index while claiming to clear
    // history would be the F187 wipe with a different trigger.
    let (history, root, primary) = try makeHistory()
    defer { try? FileManager.default.removeItem(at: root) }
    let backup = root.appendingPathComponent("meetings.backup.json")
    let live = Data(#"[{"title":"Still here"}]"#.utf8)
    try live.write(to: primary)
    try live.write(to: backup)
    try archive(Data(#"[{"title":"old"}]"#.utf8), sequence: 1, in: history, root: root)

    _ = try history.forgetAll()

    #expect(try Data(contentsOf: primary) == live)
    #expect(try Data(contentsOf: backup) == live)
}

@Test("A forgotten meeting's text is in no file under the library root (F239)")
func forgottenTextIsGoneFromDisk() throws {
    // The assertion the ticket asks for, and the only one that actually answers the user's
    // question. Not "the generation list is empty" — the bytes must not be anywhere.
    let (history, root, primary) = try makeHistory()
    defer { try? FileManager.default.removeItem(at: root) }
    let secret = "the acquisition price is confidential"
    try Data(#"[{"title":"Kept"}]"#.utf8).write(to: primary)
    try archive(
        Data(#"[{"transcriptText":"\#(secret)"}]"#.utf8), sequence: 1, in: history, root: root
    )
    #expect(try fileContaining(secret, under: root) != nil, "fixture did not write the text at all")

    _ = try history.forgetAll()

    #expect(try fileContaining(secret, under: root) == nil,
            "the deleted meeting's transcript is still on disk")
}

@Test("Conflict branches are forgotten too — they hold text as well (F239)")
func forgetRemovesConflictBranches() throws {
    // `prune` never touches `conflict-` files, deliberately: they are a losing writer's work and
    // exist nowhere else, so only the user may remove them. But this IS the user asking, and a
    // conflict branch is a full copy of the index — leaving them behind would answer "forget my
    // history" with "most of it".
    let (history, root, _) = try makeHistory()
    defer { try? FileManager.default.removeItem(at: root) }
    try archive(Data(#"[{"title":"a"}]"#.utf8), sequence: 1, in: history, root: root)
    let branch = history.directoryURL.appendingPathComponent("conflict-000000002-abc.json")
    try Data(#"[{"title":"lost writer"}]"#.utf8).write(to: branch)
    #expect(history.conflictBranchCount() == 1)

    let forgotten = try history.forgetAll()

    #expect(forgotten.count == 2, "the conflict branch was left behind")
    #expect(history.conflictBranchCount() == 0)
}

@Test("Forgetting an empty or absent history is not an error (F239)")
func forgetIsIdempotent() throws {
    let (history, root, _) = try makeHistory()
    defer { try? FileManager.default.removeItem(at: root) }

    #expect(try history.forgetAll().isEmpty)
    try archive(Data(#"[{"title":"a"}]"#.utf8), sequence: 1, in: history, root: root)
    #expect(try history.forgetAll().count == 1)
    #expect(try history.forgetAll().isEmpty)
}

/// The first file under `root` whose bytes contain `needle`, or nil.
private func fileContaining(_ needle: String, under root: URL) throws -> URL? {
    let bytes = Data(needle.utf8)
    guard let walker = FileManager.default.enumerator(
        at: root,
        includingPropertiesForKeys: [.isRegularFileKey]
    ) else { return nil }
    for case let url as URL in walker {
        guard (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true else {
            continue
        }
        if let data = try? Data(contentsOf: url), data.range(of: bytes) != nil { return url }
    }
    return nil
}
