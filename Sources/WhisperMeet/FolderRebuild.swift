import Foundation
import WhisperCore

/// Rebuilding an index from the recording folders themselves (F191 slice E4, carrying F252).
///
/// **Why this exists here and not as its own feature.** F252 asked for exactly this and was closed
/// `wontfix`, because built alone it would have been a bespoke path that rewrites the index of an
/// already-damaged library — the most dangerous operation this app can perform — validated only
/// against fixtures written by the person who wrote the path. Here it is a restore *source*: it
/// produces a proposal the user reviews, and the apply, the pre-restore snapshot and the tested
/// rollback are the ones slice E2 already has.
///
/// **What it restores is deliberately narrow.** The unambiguous facts on disk are a folder's UUID,
/// its finalized audio, and which audio file is there. Everything else is either absent or is
/// derived text.
///
/// The transcript is **not** parsed out of `notes.md`, and that is the load-bearing refusal. That
/// parse is the inverse of `MeetingNotesExporter`, which interleaves Notes, Summary, Confidence and
/// marker sections around the transcript — so a parser would be guessing at boundaries, and a wrong
/// guess puts fabricated text in the user's transcript and presents it as theirs. An absent
/// transcript is recoverable, because `notes.md` is still sitting next to the audio where F198 put
/// it for exactly this situation. A fabricated one is not recoverable at all, because nobody knows
/// it is wrong.
///
/// The title IS taken from `notes.md`, because the exporter's first line is always `# <title>` —
/// one unambiguous line, not a parse of the document.
enum FolderRebuild {
    /// What a rebuild would produce, for review before anything is written.
    struct Proposal: Equatable, Sendable {
        /// One record per folder holding finalized audio.
        let meetings: [MeetingRecord]
        /// Folders holding raw `.f32` tracks and no finalized audio. Left for
        /// `InterruptedRecordingRecovery`, which is what they are for — proposing one as a meeting
        /// would index a folder whose audio does not exist yet, which is the F256 floor's defect
        /// arriving from a new direction.
        let deferredToRecovery: Int
        /// What a rebuild cannot bring back, in the user's words, so they commit knowing it rather
        /// than discovering it afterwards (F193's constraint).
        let cannotRestore: [String]

        /// Whether there is anything here worth doing. A proposal of nothing must not present as a
        /// recovery the user should accept.
        var isWorthApplying: Bool { !meetings.isEmpty }
    }

    /// Reads the library's recording folders. Writes nothing.
    static func propose(in library: URL) throws -> Proposal {
        let recordings = library.appendingPathComponent("Recordings", isDirectory: true)
        let fileManager = FileManager.default
        guard fileManager.fileExists(atPath: recordings.path) else {
            return Proposal(meetings: [], deferredToRecovery: 0, cannotRestore: [])
        }

        let folders = try fileManager.contentsOfDirectory(
            at: recordings,
            includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        )

        var meetings: [MeetingRecord] = []
        var deferred = 0
        for folder in folders {
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]))?.isDirectory == true,
                  let id = UUID(uuidString: folder.lastPathComponent) else { continue }

            // `finalizedRecording` is the codebase's single definition of "this recording
            // finished", and using it here rather than a second file-name check is the point: a
            // folder it declines is an interrupted capture, which belongs to recovery.
            guard let finalized = InterruptedRecordingRecovery.finalizedRecording(in: folder) else {
                if fileManager.fileExists(
                    atPath: folder.appendingPathComponent("system-audio.f32").path
                ) || fileManager.fileExists(
                    atPath: folder.appendingPathComponent("microphone-audio.f32").path
                ) {
                    deferred += 1
                }
                continue
            }

            let created = (try? folder.resourceValues(forKeys: [.creationDateKey]))?.creationDate
                ?? Date()
            let title = notesTitle(in: folder)
                ?? "Recovered Meeting \(created.formatted(date: .abbreviated, time: .shortened))"

            meetings.append(MeetingRecord(
                id: id,
                title: title,
                createdAt: created,
                duration: finalized.duration,
                recordingPath: "Recordings/\(folder.lastPathComponent)/\(finalized.recordingURL.lastPathComponent)",
                // Never `.completed`: there is no transcript in this record, and `.completed` is
                // what makes the app render a transcript section for it.
                status: .recorded,
                errorMessage: "This meeting was rebuilt from the recording folders after the meeting index was lost. Its transcript and notes, if it had any, are in notes.md beside the audio.",
                // F273's field, from the file that is actually there.
                recoverySource: finalized.source.rawValue
            ))
        }

        return Proposal(
            meetings: meetings.sorted { $0.createdAt < $1.createdAt },
            deferredToRecovery: deferred,
            cannotRestore: meetings.isEmpty ? [] : [
                "Transcripts are not restored. Each meeting's text is still in the notes.md file beside its audio, and a meeting can be transcribed again.",
                "Summaries, tags, notes and markers are not restored — they lived only in the index.",
                "Titles are restored where a notes.md records one; the rest are named by date.",
            ]
        )
    }

    /// The exporter's first line is always `# <title>`, so this reads one unambiguous line rather
    /// than parsing the document. A file that does not start that way yields nil instead of a guess.
    private static func notesTitle(in folder: URL) -> String? {
        guard let text = try? String(
            contentsOf: folder.appendingPathComponent("notes.md"), encoding: .utf8
        ) else { return nil }
        guard let first = text.split(separator: "\n", maxSplits: 1).first,
              first.hasPrefix("# ") else { return nil }
        let title = first.dropFirst(2).trimmingCharacters(in: .whitespaces)
        return title.isEmpty ? nil : title
    }
}
