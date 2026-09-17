import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F191 slice E4, carrying F252 — a library with no retained generation and no backup.
//
// F252 was closed `wontfix` as a standalone feature for a reason worth restating, because this
// slice is the same capability arriving by the route that makes it safe. Built alone it would have
// been a bespoke path that rewrites the index of an already-damaged library, validated only against
// fixtures I wrote myself. Here it is a restore SOURCE: it produces the same reviewed plan that a
// backup generation does, goes through the same apply with the same pre-restore snapshot and the
// same tested rollback, and is refused in all the same states.
//
// What it can restore is deliberately narrow. The unambiguous facts on disk are the folder's UUID,
// its audio, and what the manifests say. The transcript is NOT parsed out of `notes.md` — that
// parse is the inverse of a formatter which interleaves summary, confidence and markers, and
// getting it wrong would put fabricated text in a user's transcript. Titles come from the one line
// the exporter always writes first.

private func makeOrphanedLibrary(_ label: String) throws -> (root: URL, library: URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("FolderRebuild-\(label)-\(UUID().uuidString)", isDirectory: true)
    let library = root.appendingPathComponent("Library", isDirectory: true)
    let recordings = library.appendingPathComponent("Recordings", isDirectory: true)
    try FileManager.default.createDirectory(at: recordings, withIntermediateDirectories: true)
    return (root, library)
}

@discardableResult
private func makeMeetingFolder(
    in library: URL,
    id: UUID = UUID(),
    audioName: String = "meeting.wav",
    seconds: Int = 2,
    notesTitle: String? = nil
) throws -> UUID {
    let folder = library
        .appendingPathComponent("Recordings/\(id.uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    try WAVWriter.wavData(from: [Float](repeating: 0.2, count: 48_000 * seconds), sampleRate: 48_000)
        .write(to: folder.appendingPathComponent(audioName))
    if let notesTitle {
        try Data("# \(notesTitle)\n\n_Sep 17, 2026 at 9:00 AM · 2:00_\n\n## Transcript\n\nSome text.\n".utf8)
            .write(to: folder.appendingPathComponent("notes.md"))
    }
    return id
}

@Test("A folder rebuild proposes one meeting per recording folder")
func rebuildProposesEveryFolder() throws {
    let (root, library) = try makeOrphanedLibrary("propose")
    defer { try? FileManager.default.removeItem(at: root) }
    let a = try makeMeetingFolder(in: library, notesTitle: "Pricing sync")
    let b = try makeMeetingFolder(in: library)

    let proposal = try FolderRebuild.propose(in: library)

    #expect(proposal.meetings.count == 2)
    // The title comes from notes.md when it is there — the one line the exporter always writes
    // first — and is synthesized otherwise rather than left blank.
    let named = try #require(proposal.meetings.first { $0.id == a })
    #expect(named.title == "Pricing sync")
    let unnamed = try #require(proposal.meetings.first { $0.id == b })
    #expect(unnamed.title.hasPrefix("Recovered Meeting"))
    // Duration comes from the audio, so the rebuilt row is playable and correctly long.
    #expect(abs(named.duration - 2.0) < 0.05)
}

@Test("A rebuild never claims a transcript it did not read")
func rebuildDoesNotInventTranscripts() throws {
    // The refusal that makes this safe. `notes.md` contains the transcript, and parsing it back is
    // the inverse of a formatter that interleaves summary, confidence and marker sections —
    // fabricated transcript text is worse than an absent one, and an absent one is recoverable
    // because the file is still there.
    let (root, library) = try makeOrphanedLibrary("notext")
    defer { try? FileManager.default.removeItem(at: root) }
    try makeMeetingFolder(in: library, notesTitle: "Has notes")

    let proposal = try FolderRebuild.propose(in: library)
    let meeting = try #require(proposal.meetings.first)
    #expect(meeting.transcriptText.isEmpty)
    #expect(meeting.segments.isEmpty)
    #expect(meeting.status == .recorded)
    // And it says so, where the user will read it.
    #expect(proposal.cannotRestore.contains { $0.lowercased().contains("transcript") })
}

@Test("A folder with no finalized audio is not proposed as a meeting")
func unfinishedFolderIsNotAMeeting() throws {
    // An interrupted capture is `InterruptedRecordingRecovery`'s job, not this one. Proposing it
    // as a meeting would index a folder whose audio does not exist yet, which is the F256 floor's
    // defect arriving from a new direction.
    let (root, library) = try makeOrphanedLibrary("unfinished")
    defer { try? FileManager.default.removeItem(at: root) }
    let folder = library.appendingPathComponent("Recordings/\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let samples = [Float](repeating: 0.2, count: 48_000)
    try samples.withUnsafeBytes {
        try Data($0).write(to: folder.appendingPathComponent("system-audio.f32"))
    }

    let proposal = try FolderRebuild.propose(in: library)
    #expect(proposal.meetings.isEmpty)
    #expect(proposal.deferredToRecovery == 1)
}

@Test("A rebuilt meeting carries the provenance the folder shows")
func rebuiltMeetingCarriesProvenance() throws {
    // F273's field, from the file that is actually there: a folder holding
    // `meeting-recovered.wav` was rebuilt from raw tracks, and the restored row must say so rather
    // than presenting as an ordinary capture.
    let (root, library) = try makeOrphanedLibrary("provenance")
    defer { try? FileManager.default.removeItem(at: root) }
    try makeMeetingFolder(in: library, audioName: "meeting-recovered.wav")

    let proposal = try FolderRebuild.propose(in: library)
    let meeting = try #require(proposal.meetings.first)
    #expect(meeting.recoverySource == RecoveredRecording.Source.rebuiltSourceTracks.rawValue)
    #expect(MeetingStore.recoveryCaveats(for: meeting).contains {
        $0.contains("aligned to the start of the file")
    })
}

@Test("A rebuild names everything it cannot bring back")
func rebuildNamesWhatIsLost() throws {
    // F193's constraint and the honesty rule together: the user commits to this knowing what it
    // does not restore, not discovering it afterwards.
    let (root, library) = try makeOrphanedLibrary("lost")
    defer { try? FileManager.default.removeItem(at: root) }
    try makeMeetingFolder(in: library, notesTitle: "A meeting")

    let proposal = try FolderRebuild.propose(in: library)
    let joined = proposal.cannotRestore.joined(separator: " ").lowercased()
    for absent in ["transcript", "summar", "tag", "note"] {
        #expect(joined.contains(absent), "the proposal does not mention \(absent)")
    }
}

@Test("A library with no recording folders proposes nothing and says so")
func emptyLibraryProposesNothing() throws {
    let (root, library) = try makeOrphanedLibrary("empty")
    defer { try? FileManager.default.removeItem(at: root) }

    let proposal = try FolderRebuild.propose(in: library)
    #expect(proposal.meetings.isEmpty)
    #expect(proposal.deferredToRecovery == 0)
    #expect(!proposal.isWorthApplying)
}
