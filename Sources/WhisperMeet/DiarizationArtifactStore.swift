import CryptoKit
import Foundation
import WhisperCore

/// What a sidecar read produced. Distinguishing these is the whole point: "absent" offers analysis,
/// "stale" hides labels but keeps the file, and "unavailable" says the transcript is safe (F218).
enum DiarizationLoadOutcome: Sendable, Equatable {
    case absent
    case ready(DiarizationArtifactV1)
    case stale
    case unavailable(DiarizationUnavailableReason)
}

/// Why a sidecar that exists could not be turned into a result (F218).
///
/// One undifferentiated "could not be read" forces the UI into a single sentence for three
/// situations whose correct advice is opposite: damage left a NEW FILE in the user's recording
/// folder and the only way they will ever understand it is to be told its name; a newer build's
/// file is perfectly intact and the answer is to update WhisperMeet, not to repair anything; and a
/// file the OS will not hand over is a permissions problem in a third place entirely. The F187
/// precedent is `BackupJSONStoreError.noReadableCopy(primary:backup:quarantined:)`, which carries
/// the sibling names so `MeetingStore.startupRecoveryMessages` can report them.
enum DiarizationUnavailableReason: Sendable, Equatable {
    /// The bytes did not decode. A copy was kept under this name — nil when none could be made, in
    /// which case the load is reporting a second failure on top of the first.
    case corrupt(quarantinedAs: String?)
    /// Written by a newer build of WhisperMeet, which declared this schema version. Left exactly as
    /// found and never quarantined: it is not damaged, just not ours to read.
    case newerSchema(Int)
    /// The file exists but could not be read at all — permissions, or an I/O error.
    case unreadable
}

enum DiarizationArtifactStoreError: LocalizedError, Sendable, Equatable {
    case recordingFolderMissing(UUID)
    case newerSchemaPresent(Int)
    /// The artifact describes a different meeting than the one the caller asked to write. Refusing
    /// is the point: filing it under the artifact's own id instead would write into a folder the
    /// caller never named.
    case meetingMismatch(expected: UUID, found: UUID)

    var errorDescription: String? {
        switch self {
        case .recordingFolderMissing:
            return "That meeting's recording folder is missing, so its speaker analysis was not saved. Your transcript is unchanged."
        case .newerSchemaPresent:
            return "This meeting's speaker analysis was written by a newer version of WhisperMeet, so it was left untouched and nothing was saved over it."
        case .meetingMismatch:
            return "That speaker analysis describes a different meeting, so nothing was saved. Your recording and transcript are unchanged."
        }
    }
}

/// File I/O for `Recordings/<meeting-uuid>/diarization.json` (F218).
///
/// Unlike `notes.md`, this sidecar is NOT best-effort and NOT regenerable: it carries the aliases a
/// person typed for this meeting, which exist nowhere else. So every path here is written to lose
/// nothing — bytes that do not decode are copied aside before anything replaces them (the F187
/// quarantine rule), a file from a newer build is left exactly as found, and a save that cannot
/// complete leaves the previous file in place.
///
/// Deliberately a pure file helper with no `MeetingStore` reference: the degraded-library refusal
/// lives in `AppModel`, which owns the store, so this type stays testable against a bare directory.
enum DiarizationArtifactStore {
    static let fileName = "diarization.json"

    static func fileURL(meetingID: UUID, in root: URL) -> URL {
        root
            .appendingPathComponent("Recordings", isDirectory: true)
            .appendingPathComponent(meetingID.uuidString, isDirectory: true)
            .appendingPathComponent(fileName)
    }

    /// Reads the sidecar and classifies what it found. Never throws: every failure has a calm
    /// outcome the UI can state plainly, and none of them implicate the transcript.
    ///
    /// `currentRecordingSHA256` is the hash of the audio as it is *now*. Supplying it is what turns
    /// a result computed against different bytes into `.stale` instead of a confidently wrong
    /// overlay; omitting it reads the file without that check (for a rename, say, where the audio
    /// is not in hand).
    static func load(
        meetingID: UUID,
        in root: URL,
        currentRecordingSHA256: String? = nil,
        fileManager: FileManager = .default
    ) -> DiarizationLoadOutcome {
        let url = fileURL(meetingID: meetingID, in: root)
        guard fileManager.fileExists(atPath: url.path) else { return .absent }
        guard let data = try? Data(contentsOf: url) else { return .unavailable(.unreadable) }
        do {
            let artifact = try DiarizationArtifactCodec.decode(data)
            // A sidecar that describes a DIFFERENT meeting is not this meeting's result — a
            // duplicated or restored recording folder is how one gets here, and the file decodes
            // perfectly. The codec cannot see this: it has no expected id, so the store is the only
            // layer that can. Not quarantined, because the bytes are valid and merely misfiled.
            guard artifact.meetingID == meetingID else { return .stale }
            if let currentRecordingSHA256, currentRecordingSHA256 != artifact.recording.sha256 {
                return .stale
            }
            return .ready(artifact)
        } catch DiarizationArtifactError.newerSchema(let version) {
            // Not damaged — just not ours to read. Quarantining it would imply corruption and
            // leave a confusing sibling behind for a file a newer build will open perfectly. The
            // version it declared travels with the outcome: "a newer version" is advice, "format 99
            // and this build reads 1" is a fact the user can act on and report.
            return .unavailable(.newerSchema(version))
        } catch {
            // The sibling's name travels with the outcome too: that copy is the user's only route
            // back to the aliases they typed, and a file they cannot name is a file they will never
            // find in a folder they did not know they had.
            return .unavailable(.corrupt(quarantinedAs: quarantine(url, using: fileManager)))
        }
    }

    /// Writes the sidecar atomically. Throws rather than silently doing nothing, because a caller
    /// that just spent minutes analysing audio has to be able to say the result was not kept.
    ///
    /// `meetingID` is the meeting the caller believes it is writing, and it is the only id allowed
    /// to decide the folder. Resolving the path from `artifact.meetingID` instead let read and write
    /// address different folders: with a duplicated or restored recording folder, a rename loaded
    /// from B and wrote into A, so the rename appeared not to stick and A's aliases were silently
    /// rewritten. A mismatch is a refusal, never a redirect.
    ///
    /// Returns the name of the sibling a damaged previous file was copied aside to, or nil when
    /// nothing was quarantined. A save that quietly leaves a new `diarization.unreadable-….json` in
    /// someone's recording folder owes them its name, and this is the only layer that knows it.
    /// `@discardableResult` because a first save lands in a folder with no sidecar in it at all, so
    /// there is routinely nothing to report.
    @discardableResult
    static func save(
        _ artifact: DiarizationArtifactV1,
        for meetingID: UUID,
        in root: URL,
        fileManager: FileManager = .default
    ) throws -> String? {
        guard artifact.meetingID == meetingID else {
            throw DiarizationArtifactStoreError.meetingMismatch(
                expected: meetingID, found: artifact.meetingID
            )
        }
        let url = fileURL(meetingID: meetingID, in: root)
        let directory = url.deletingLastPathComponent()
        // Never create the folder. `InterruptedRecordingRecovery.removeIfEmpty` only reclaims a
        // *completely empty* folder, so a sidecar written beside a recording that never landed
        // would strand that folder forever, and a folder conjured for an unknown meeting would be
        // an orphan the library can never adopt.
        guard fileManager.fileExists(atPath: directory.path) else {
            throw DiarizationArtifactStoreError.recordingFolderMissing(meetingID)
        }
        var quarantined: String?
        if fileManager.fileExists(atPath: url.path) {
            if let existing = try? Data(contentsOf: url) {
                do {
                    _ = try DiarizationArtifactCodec.decode(existing)
                } catch DiarizationArtifactError.newerSchema(let version) {
                    // Downgrading a newer build's file would destroy whatever it carries that this
                    // build cannot even name. Refuse; the user keeps both the file and the message.
                    throw DiarizationArtifactStoreError.newerSchemaPresent(version)
                } catch {
                    // Undecodable is not worthless: these bytes may hold the only copy of the
                    // aliases someone typed. Copy them aside before replacing them, exactly as the
                    // load path does — a save can arrive without a preceding load. And if they
                    // cannot be preserved, refuse to write at all: `couldNotPreserve` promises the
                    // file "was left untouched and nothing was written", so swallowing it with
                    // `try?` would make that promise a lie (AGENTS.md:422, and the propagating
                    // `try` in BackupJSONStore.save).
                    quarantined = try StoreQuarantine.preserve(fileAt: url)
                }
            } else {
                // Bytes that exist but cannot even be READ are the ones most worth keeping — and
                // the ones a bare `try?` silently skips past. `Data.write(options: .atomic)` writes
                // a temp file and renames, so it needs only directory permission and would destroy
                // them without ever touching them. `preserve` throws `.couldNotPreserve` here, and
                // that refusal is what has to stop the write.
                quarantined = try StoreQuarantine.preserve(fileAt: url)
            }
        }
        try DiarizationArtifactCodec.encode(artifact).write(to: url, options: .atomic)
        return quarantined
    }

    /// Removes the sidecar and nothing else. The recording and the transcript are never touched:
    /// discarding speaker labels is not discarding the meeting.
    static func clear(meetingID: UUID, in root: URL, fileManager: FileManager = .default) throws {
        let url = fileURL(meetingID: meetingID, in: root)
        guard fileManager.fileExists(atPath: url.path) else { return }
        try fileManager.removeItem(at: url)
    }

    /// Best-effort preservation for the LOAD path only, where nothing is being overwritten and a
    /// failure to copy must not stop the caller from reporting the real problem. `save` must never
    /// use this: there, dropping the error would let the write destroy the very bytes the copy was
    /// meant to keep, so it calls `StoreQuarantine.preserve` with a propagating `try` instead.
    ///
    /// `StoreQuarantine.preserve` copies rather than moves and is idempotent per (file, byte
    /// content), so a relaunch loop cannot fill the folder with duplicates.
    /// Returns the sibling's name so the outcome can carry it; nil when nothing was copied, which
    /// on this path means either "no file" or "the copy failed" — indistinguishable, and deliberately
    /// so: on the load path nothing is being overwritten, so neither changes what the caller does.
    private static func quarantine(_ url: URL, using fileManager: FileManager) -> String? {
        try? StoreQuarantine.preserve(fileAt: url)
    }
}

/// SHA-256 of a recording, used to notice that a stored result no longer describes the audio (F218).
enum RecordingFingerprint {
    /// 1 MiB: big enough that the syscall overhead disappears, small enough that peak memory stays
    /// flat regardless of file size.
    static let chunkSize = 1 << 20

    /// Hashes the file incrementally. Deliberately NOT `Data(contentsOf:)` — the way
    /// `BackupCoordinator.sha256` does it — because a meeting recording is routinely hundreds of
    /// megabytes and can be multiple gigabytes, and loading one whole into memory to hash it would
    /// spike the app for no reason.
    static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
