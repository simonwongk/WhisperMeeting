import Foundation
import WhisperCore

enum MeetingStatus: String, Codable, Sendable {
    case recorded
    case processing
    case completed
    case failed

    init(from decoder: Decoder) throws {
        let value = try decoder.singleValueContainer().decode(String.self)
        switch value {
        case "recorded": self = .recorded
        case "uploading", "queued", "processing": self = .processing
        case "completed": self = .completed
        case "failed": self = .failed
        default: self = .recorded
        }
    }

    var title: String {
        switch self {
        case .recorded: "Ready to transcribe"
        case .processing: "Transcribing"
        case .completed: "Completed"
        case .failed: "Needs attention"
        }
    }
}

struct MeetingRecord: Codable, Identifiable, Sendable, Equatable {
    let id: UUID
    var title: String
    let createdAt: Date
    var duration: TimeInterval
    var recordingPath: String
    var status: MeetingStatus
    var transcriptText: String
    var languageCode: String?
    var confidence: Double?
    var segments: [TranscriptSegment]
    var errorMessage: String?
    var summary: MeetingSummary?
    /// Whether the transcript text has been finalized (either freshly produced with inline
    /// timestamps, or migrated once from an older plain-text transcript). Optional so meeting
    /// indexes written before this field still decode. Once true, `transcriptText` is never
    /// rebuilt from `segments`, so user edits are safe.
    var transcriptNormalized: Bool?
    /// User-dropped markers (timestamps only). Optional so meeting indexes written before this
    /// feature still decode. The audio is never modified — see `docs/RECORDING_MARKERS.md`.
    var markers: [RecordingMarker]?
    /// Whether the user pinned this meeting to the top of the sidebar. Optional so meeting indexes
    /// written before this feature still decode (F64).
    var pinned: Bool?
    /// A free-text scratchpad (agenda / attendee notes) tied to this meeting, separate from the
    /// transcript and the Claude summary. Optional so old indexes decode; never sent to Claude (F72).
    var notes: String?
    /// User labels for organizing/filtering the sidebar (never speaker identity). Optional so old
    /// indexes decode; normalized via `MeetingTags` before storage (F67).
    var tags: [String]?
    /// Post-meeting capture-health rollup (why a recording was bad). Optional so old indexes decode;
    /// channel-level, never speaker identity (F58).
    var healthReport: RecordingHealthReport?
    /// A plain-language note when timestamp alignment was unavailable but the complete text was
    /// preserved (Qwen path). Optional so old indexes decode; nil on a normally aligned transcript.
    /// Carried from `TranscriptionResult.alignmentWarning` so the detail view can explain why a
    /// meeting has no seekable timestamps instead of dropping them silently (F30).
    var alignmentWarning: String?
    /// A plain-language note when the transcript's dominant script disagrees with the language the
    /// user explicitly selected — the "original language only" net (F32). Optional so old indexes
    /// decode; nil under automatic detection or when the language matches.
    var languageWarning: String?
    /// The engine that produced this meeting's transcript, recorded so a "second opinion" can run the
    /// genuine other engine regardless of current Settings (F142). Optional for backward compatibility.
    var transcriptionEngine: MeetingTranscriptionEngine?
    /// Where this meeting's audio came from when it was fetched from a link rather than recorded or
    /// imported from a local file (F183). Optional so meeting indexes written before this feature still
    /// decode — a non-optional field here would make every pre-existing meeting fail to decode, and the
    /// next persist would overwrite both the index and its backup.
    var source: MediaSource?
    /// The publisher's own captions for a link-imported meeting, parsed to segments and kept purely as a
    /// reviewable reference for the existing comparison sheet — never the transcript itself, and never a
    /// source of speaker identity (`SubtitleParser` strips speaker labels). Optional so old indexes
    /// decode (F183).
    var referenceSegments: [TranscriptSegment]?

    init(
        id: UUID = UUID(),
        title: String,
        createdAt: Date = Date(),
        duration: TimeInterval = 0,
        recordingPath: String = "",
        status: MeetingStatus = .recorded,
        transcriptText: String = "",
        languageCode: String? = nil,
        confidence: Double? = nil,
        segments: [TranscriptSegment] = [],
        errorMessage: String? = nil,
        summary: MeetingSummary? = nil,
        transcriptNormalized: Bool? = nil,
        markers: [RecordingMarker]? = nil,
        pinned: Bool? = nil,
        notes: String? = nil,
        tags: [String]? = nil,
        healthReport: RecordingHealthReport? = nil,
        alignmentWarning: String? = nil,
        languageWarning: String? = nil,
        transcriptionEngine: MeetingTranscriptionEngine? = nil,
        source: MediaSource? = nil,
        referenceSegments: [TranscriptSegment]? = nil
    ) {
        self.id = id
        self.title = title
        self.createdAt = createdAt
        self.duration = duration
        self.recordingPath = recordingPath
        self.status = status
        self.transcriptText = transcriptText
        self.languageCode = languageCode
        self.confidence = confidence
        self.segments = segments
        self.errorMessage = errorMessage
        self.summary = summary
        self.transcriptNormalized = transcriptNormalized
        self.markers = markers
        self.pinned = pinned
        self.notes = notes
        self.tags = tags
        self.healthReport = healthReport
        self.alignmentWarning = alignmentWarning
        self.languageWarning = languageWarning
        self.transcriptionEngine = transcriptionEngine
        self.source = source
        self.referenceSegments = referenceSegments
    }

    /// Markers sorted by offset (empty when none). Convenience for the UI and exports.
    var orderedMarkers: [RecordingMarker] {
        (markers ?? []).sorted { $0.offset < $1.offset }
    }

    /// Whether the user has edited the transcript away from Whisper's segment rendering. When true,
    /// segment-derived overlays (quality flags, marker context) no longer match the shown text.
    var isTranscriptEdited: Bool {
        TranscriptFormatter.isEdited(transcriptText: transcriptText, segments: segments)
    }
}

struct OrphanedRecording: Sendable, Equatable {
    let id: UUID
    let directory: URL
    let createdAt: Date
}

/// The user-facing vocabulary for a read-only library (F187). One lead sentence, one tail per surface,
/// so the wording cannot drift between the store's refusal and AppModel's. `recordingRefused` in
/// particular is one event reached by two paths — AppModel's pre-check and the store's backstop throw —
/// and both must say the same thing.
enum ReadOnlyLibraryNotice {
    /// Why the library is read-only. "WhisperMeet" stays capitalized when this is embedded mid-sentence:
    /// it is a product name, not a word to be case-folded.
    static let lead = "WhisperMeet could not fully read its meeting library, so it is open in read-only mode."
    /// After the user attempted an edit, delete, or tag change.
    static let mutationRefused = "\(lead) Nothing has been changed. Resolve recovery before editing, deleting, or recording."
    /// Before a recording can start — from AppModel's pre-check and the store's backstop throw alike.
    /// Its exact wording is shipped through `MeetingStoreError`, so it keeps its own resolution clause
    /// rather than the generic one; only the shared middle is factored out.
    static let recordingRefused = refused("Recording", resolution: "before recording")
    /// Before a library-changing action that is not recording — import, transcription, summarization.
    /// The action reads as the subject of the sentence, so pass a noun phrase naming the action
    /// ("Import", "Transcription", "Summarization", "Re-transcribing a segment"), not an imperative
    /// verb.
    static func actionRefused(_ action: String) -> String {
        refused(action, resolution: "first")
    }

    /// The one sentence shape every pre-action refusal shares. Private so the surfaces above stay the
    /// only vocabulary callers see.
    private static func refused(_ action: String, resolution: String) -> String {
        "\(action) cannot start because \(lead) Your existing recordings are untouched — resolve recovery \(resolution)."
    }
}

/// Why the store refused an operation outright (F187).
/// `Equatable` is declared, not inferred: tests match on this error with `#expect(throws:)`, and the
/// synthesized conformance would silently disappear the moment a case gains an associated value.
enum MeetingStoreError: LocalizedError, Equatable {
    /// The meeting index is not known-complete, so the library is open read-only and nothing that
    /// would create files or records may run.
    case libraryIsReadOnly

    /// A transcription-engine pass was refused for the same reason, thrown by `AppModel.executeEngine`
    /// — the one admission point every heavy engine run passes through (F187). Separate from
    /// `libraryIsReadOnly` only so the message names transcription rather than recording: this is
    /// reachable from the full transcription, the per-segment re-run, and the second opinion alike.
    case engineRunIsReadOnly

    var errorDescription: String? {
        switch self {
        case .libraryIsReadOnly:
            return ReadOnlyLibraryNotice.recordingRefused
        case .engineRunIsReadOnly:
            return ReadOnlyLibraryNotice.actionRefused("Transcription")
        }
    }
}

@MainActor
final class MeetingStore: ObservableObject {
    @Published private(set) var meetings: [MeetingRecord] = []
    /// The full stored term list (F187). Never narrowed by the prompt budget — doing that at load and
    /// on every addition made the truncation permanent on the next write. `private(set)` so the only
    /// ways in are `addVocabulary`/`removeVocabulary`, which carry the read-only guard; a settable
    /// property would let a caller replace the list without ever passing `mutationIsAllowed()`.
    @Published private(set) var vocabulary: [String] = []

    /// The subset handed to an engine's `initial_prompt`, capped to the prompt budget at the point of
    /// use rather than in storage.
    var promptVocabulary: [String] { Self.promptSafeTerms(vocabulary) }

    /// Exact `heard → preferred` replacement rules (F179), persisted like vocabulary. Reviewed before
    /// any apply — the matcher only proposes; nothing auto-applies and the audio is never touched.
    @Published private(set) var replacementRules: [ReplacementRule] = []
    @Published private(set) var storageErrorMessage: String?
    /// The WORST load result across every persisted store this guard covers — the meeting index, the
    /// vocabulary and the replacement rules (F187). Scoped that way because it gates all three: anything
    /// but `.complete` blocks EVERY mutation, not just persistence, because `delete` removes audio
    /// before it saves the index. Only ever assigned through `degrade(to:)`, so a store that loaded
    /// cleanly can never raise a damaged one back to writable — see that method for what went wrong when
    /// it was written as a plain assignment.
    @Published private(set) var health: PersistedStoreHealth = .complete
    var isDegraded: Bool { !health.allowsMutation }

    private(set) var startupRecoveryMessages: [String] = []

    let rootDirectory: URL
    private let meetingFiles: BackupJSONStore<[MeetingRecord]>
    private let vocabularyFiles: BackupJSONStore<[String]>
    private let replacementRulesFiles: BackupJSONStore<[ReplacementRule]>
    /// How long a transcript keystroke waits before its edit is flushed to disk. Coalesces the
    /// per-keystroke full-index rewrite (F40) into one debounced write; tests pass a large value to
    /// prove coalescing and drive the flush explicitly.
    private let transcriptWriteDebounce: TimeInterval
    /// Count of completed index writes — lets F40's coalescing test assert how many disk writes ran.
    private(set) var persistCount = 0
    private var pendingIndexFlush: Task<Void, Never>?
    /// Meetings whose notes sidecar is stale. Flushed together, debounced like the index (F40).
    private var pendingSidecarIDs: Set<UUID> = []
    private var pendingSidecarFlush: Task<Void, Never>?
    /// Count of sidecar files actually written — lets tests assert the compare-first rule.
    private(set) var sidecarWriteCount = 0

    init(rootDirectory: URL? = nil, transcriptWriteDebounce: TimeInterval = 0.5) {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask
        ).first!
        self.rootDirectory = rootDirectory
            ?? appSupport.appendingPathComponent("WhisperMeet", isDirectory: true)
        self.transcriptWriteDebounce = transcriptWriteDebounce
        meetingFiles = BackupJSONStore(
            primaryURL: self.rootDirectory.appendingPathComponent("meetings.json"),
            backupURL: self.rootDirectory.appendingPathComponent("meetings.backup.json"),
            // One bad record costs one record, not the library (F187) — see `salvageMeetings(from:)`.
            salvage: MeetingStore.salvageMeetings(from:)
        )
        vocabularyFiles = BackupJSONStore(
            primaryURL: self.rootDirectory.appendingPathComponent("vocabulary.json"),
            backupURL: self.rootDirectory.appendingPathComponent("vocabulary.backup.json")
        )
        replacementRulesFiles = BackupJSONStore(
            primaryURL: self.rootDirectory.appendingPathComponent("replacement-rules.json"),
            backupURL: self.rootDirectory.appendingPathComponent("replacement-rules.backup.json")
        )

        do {
            try FileManager.default.createDirectory(
                at: self.rootDirectory,
                withIntermediateDirectories: true
            )
        } catch {
            startupRecoveryMessages.append(
                "WhisperMeet could not open its storage folder: \(error.localizedDescription)"
            )
            return
        }
        loadMeetings()
        loadVocabulary()
        loadReplacementRules()
    }

    /// Creates (and returns) a meeting's recording folder. Refuses while the library is not
    /// known-complete: the matching `upsert` would be refused by `mutationIsAllowed()`, so the folder
    /// would hold audio the library could never index — and `orphanedRecordings()` hides it too, so the
    /// user would lose the whole meeting silently. Callers should refuse earlier and explain why; this
    /// throw is the invariant that stops a future caller from reintroducing the hole (F187).
    func recordingDirectory(for id: UUID) throws -> URL {
        guard !isDegraded else { throw MeetingStoreError.libraryIsReadOnly }
        let directory = recordingDirectoryURL(for: id)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    func recordingDirectoryURL(for id: UUID) -> URL {
        rootDirectory
            .appendingPathComponent("Recordings", isDirectory: true)
            .appendingPathComponent(id.uuidString, isDirectory: true)
    }

    func recordingURL(for meeting: MeetingRecord) -> URL {
        rootDirectory.appendingPathComponent(meeting.recordingPath)
    }

    /// Marks a meeting's notes.md stale and schedules the debounced rewrite — the same clamp-and-cancel
    /// shape as `scheduleDebouncedPersist`, and the `Task {}` inherits this method's main-actor
    /// isolation, so no explicit hop back is needed (F198).
    private func scheduleNotesSidecarWrite(for id: UUID) {
        pendingSidecarIDs.insert(id)
        pendingSidecarFlush?.cancel()
        let delay = transcriptWriteDebounce
        pendingSidecarFlush = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.flushPendingNotesSidecars()
        }
    }

    /// Writes every pending notes.md now. Write-only insurance for the text a wiped index would
    /// otherwise take with it (F198): never read back into the app's state — the only read is the
    /// compare-before-write in `writeSidecarIfStale` — regenerable from the index at any time, so a
    /// failed write loses nothing, which is why failures are silent BY DESIGN, unlike the F187 fixes,
    /// where the failing store was the source of truth. Never writes while degraded, and never
    /// creates a folder.
    func flushPendingNotesSidecars() {
        pendingSidecarFlush?.cancel()
        pendingSidecarFlush = nil
        guard !isDegraded else { return }        // F187's read-only promise stays absolute
        let ids = pendingSidecarIDs
        pendingSidecarIDs = []
        for id in ids {
            guard let meeting = meeting(id: id) else { continue }
            if Self.writeSidecarIfStale(for: meeting, root: rootDirectory) {
                sidecarWriteCount += 1
            }
        }
    }

    /// Writes (or skips) one meeting's notes.md: containment, folder-exists, compose, compare, write.
    /// Returns whether a file was actually written. `nonisolated` — pure path/string/file work over a
    /// `Sendable` record — so the startup backfill can run it detached while the cheap per-edit
    /// debounce path calls it synchronously on the actor (F198).
    private nonisolated static func writeSidecarIfStale(for meeting: MeetingRecord, root: URL) -> Bool {
        guard !meeting.recordingPath.isEmpty else { return false }
        let directory = root
            .appendingPathComponent(meeting.recordingPath)
            .deletingLastPathComponent()
        // Same shape as `delete()`: never outside the library, and never the library root itself.
        // The sidecar filename is fixed, so a root-level write could never clobber the indexes —
        // excluding the root is for consistency with the delete path (F198).
        guard isWithinLibrary(directory, root: root),
              directory.standardizedFileURL != root.standardizedFileURL,
              FileManager.default.fileExists(atPath: directory.path) else { return false }
        let composed = composeNotes(for: meeting)
        let sidecarURL = directory.appendingPathComponent("notes.md")
        if let existing = try? String(contentsOf: sidecarURL, encoding: .utf8), existing == composed {
            return false
        }
        do {
            try composed.write(to: sidecarURL, atomically: true, encoding: .utf8)
            return true
        } catch {
            return false // Silent by design — see `flushPendingNotesSidecars`.
        }
    }

    /// One idempotent sweep: make sure every meeting that has a recording folder also has an
    /// up-to-date notes.md (F198). Covers everything transcribed before this feature existed.
    /// Compare-first, so a library whose sidecars are current writes nothing. Refused while
    /// degraded — the F187 read-only promise covers derived files too.
    ///
    /// Runs the sweep detached: it is on the launch path and does transcript-sized string work plus
    /// a file read per meeting, unbounded with library size, so it must not stall the main actor.
    /// The actor only snapshots (`MeetingRecord` is `Sendable`) and banks the write count; a
    /// debounced flush racing the sweep at worst rewrites identical bytes, because both sides
    /// compare before writing.
    func backfillNotesSidecars() async {
        guard !isDegraded else { return }
        let snapshot = meetings
        let root = rootDirectory
        let written = await Task.detached(priority: .utility) {
            snapshot.reduce(into: 0) { count, meeting in
                if Self.writeSidecarIfStale(for: meeting, root: root) { count += 1 }
            }
        }.value
        sidecarWriteCount += written
    }

    /// The one composition of a meeting's human-readable notes document (F198). The manual Export…
    /// button and the automatic sidecar (debounced flush and detached backfill alike) all route
    /// through here, so none can drift. `nonisolated` so the backfill can compose off the actor.
    nonisolated static func composeNotes(for meeting: MeetingRecord) -> String {
        MeetingNotesExporter.markdown(
            title: meeting.title,
            dateText: meeting.createdAt.formatted(date: .abbreviated, time: .shortened),
            durationSeconds: meeting.duration,
            languageCode: meeting.languageCode,
            summary: meeting.summary,
            transcriptText: meeting.transcriptText,
            notes: meeting.notes,
            markers: meeting.orderedMarkers,
            segments: meeting.segments
        )
    }

    func notesMarkdown(for meeting: MeetingRecord) -> String {
        Self.composeNotes(for: meeting)
    }

    func relativeRecordingPath(for url: URL) -> String {
        url.standardizedFileURL.path.replacingOccurrences(
            of: rootDirectory.standardizedFileURL.path + "/",
            with: ""
        )
    }

    func orphanedRecordings() throws -> [OrphanedRecording] {
        // An index that did not fully load is indistinguishable from "no meetings", which is exactly
        // how every recording folder came to look orphaned on 2026-08-14 (F187).
        guard !isDegraded else { return [] }
        let recordingsDirectory = rootDirectory
            .appendingPathComponent("Recordings", isDirectory: true)
        guard FileManager.default.fileExists(atPath: recordingsDirectory.path) else {
            return []
        }
        let indexedDirectories = Set(meetings.map {
            recordingURL(for: $0).deletingLastPathComponent().standardizedFileURL.path
        })
        // A folder whose UUID already belongs to a meeting is NOT an orphan even if that meeting's
        // recordingPath is wrong — otherwise "recovery" would upsert a blank stub under the same id and
        // overwrite the saved title/transcript/notes/tags/summary (F148 #1).
        let indexedIDs = Set(meetings.map(\.id))
        let urls = try FileManager.default.contentsOfDirectory(
            at: recordingsDirectory,
            includingPropertiesForKeys: [.isDirectoryKey, .creationDateKey],
            options: [.skipsHiddenFiles]
        )
        return urls.compactMap { url in
            guard !indexedDirectories.contains(url.standardizedFileURL.path),
                  let values = try? url.resourceValues(forKeys: [.isDirectoryKey, .creationDateKey]),
                  values.isDirectory == true,
                  let id = UUID(uuidString: url.lastPathComponent),
                  !indexedIDs.contains(id) else {
                return nil
            }
            return OrphanedRecording(
                id: id,
                directory: url,
                createdAt: values.creationDate ?? .now
            )
        }
        .sorted { $0.createdAt < $1.createdAt }
    }

    /// Whether a mutation may proceed. Returns false and explains why in `storageErrorMessage` while the
    /// library is not known-complete (F187). MUST be the first statement of every mutator — before any
    /// in-memory or filesystem side effect, because `delete` removes audio before it persists.
    private func mutationIsAllowed() -> Bool {
        guard isDegraded else { return true }
        storageErrorMessage = ReadOnlyLibraryNotice.mutationRefused
        return false
    }

    func upsert(_ meeting: MeetingRecord) {
        guard mutationIsAllowed() else { return }
        if let index = meetings.firstIndex(where: { $0.id == meeting.id }) {
            meetings[index] = meeting
        } else {
            meetings.append(meeting)
        }
        meetings = MeetingOrdering.sorted(meetings)
        persistMeetings()
        scheduleNotesSidecarWrite(for: meeting.id)
    }

    func update(id: UUID, _ mutation: (inout MeetingRecord) -> Void) {
        guard mutationIsAllowed() else { return }
        guard let index = meetings.firstIndex(where: { $0.id == id }) else { return }
        mutation(&meetings[index])
        persistMeetings()
        scheduleNotesSidecarWrite(for: id)
    }

    /// Apply a transcript-body edit: update the in-memory record immediately (so the editor stays
    /// live) but coalesce the expensive whole-index write, which otherwise ran on every keystroke
    /// (F40). See `scheduleDebouncedPersist`.
    func editTranscript(id: UUID, text: String) {
        guard mutationIsAllowed() else { return }
        guard let index = meetings.firstIndex(where: { $0.id == id }) else { return }
        meetings[index].transcriptText = text
        scheduleDebouncedPersist()
        scheduleNotesSidecarWrite(for: id)
    }

    /// Apply a notes edit with the same immediate-in-memory + debounced-write coalescing as the
    /// transcript editor — the notes field had the identical per-keystroke whole-index write (F133).
    /// Empty text clears the field (nil), matching the prior binding.
    func editNotes(id: UUID, text: String) {
        guard mutationIsAllowed() else { return }
        guard let index = meetings.firstIndex(where: { $0.id == id }) else { return }
        meetings[index].notes = text.isEmpty ? nil : text
        scheduleDebouncedPersist()
        scheduleNotesSidecarWrite(for: id)
    }

    /// Cancel any pending flush and schedule a single trailing one `transcriptWriteDebounce` later, so
    /// a burst of keystrokes collapses into one whole-index write (F40/F133).
    private func scheduleDebouncedPersist() {
        pendingIndexFlush?.cancel()
        let delay = transcriptWriteDebounce
        pendingIndexFlush = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.flushPendingEdits()
        }
    }

    /// Flush a pending debounced edit now — call on focus loss, meeting change, or view disappearance
    /// so no edit is lost (F40/F133). No-op when nothing is pending.
    func flushPendingEdits() {
        // Reaches `persistMeetings()` directly, so it carries the same refusal as every other mutator
        // even though only the already-guarded edit paths can schedule a flush today (F187).
        guard mutationIsAllowed() else { return }
        // The two pending queues empty independently: `upsert`/`update` persist the index
        // synchronously, so the sidecar queue is routinely non-empty while no index flush is pending.
        // Flush sidecars before the early return below or a quit-time flush would skip them (F198).
        flushPendingNotesSidecars()
        guard let task = pendingIndexFlush else { return }
        pendingIndexFlush = nil
        task.cancel()
        persistMeetings()
    }

    /// Replace a meeting's tags with the normalized (trimmed/deduped/capped) form of `raw`.
    func setTags(id: UUID, _ raw: [String]) {
        guard mutationIsAllowed() else { return }
        let normalized = MeetingTags.normalized(raw)
        update(id: id) { $0.tags = normalized.isEmpty ? nil : normalized }
    }

    /// Pin or unpin a meeting so it floats to (or off) the top of the sidebar, then re-orders.
    func togglePin(id: UUID) {
        guard mutationIsAllowed() else { return }
        guard let index = meetings.firstIndex(where: { $0.id == id }) else { return }
        meetings[index].pinned = !(meetings[index].pinned ?? false)
        meetings = MeetingOrdering.sorted(meetings)
        persistMeetings()
    }

    func meeting(id: UUID) -> MeetingRecord? {
        meetings.first { $0.id == id }
    }

    /// Removes a recording directory. Injectable so the failure path is testable (F146).
    var removeRecordingDirectory: (URL) throws -> Void = { url in
        if FileManager.default.fileExists(atPath: url.path) {
            try FileManager.default.removeItem(at: url)
        }
    }

    /// True when `url` is the library root or a path inside it — the containment check that stops a
    /// corrupt/tampered `recordingPath` (e.g. one with `../`) from reaching outside the library (F148 #6).
    /// The pure path math is `nonisolated static` so the detached sidecar backfill runs the same
    /// check off the actor (F198).
    nonisolated static func isWithinLibrary(_ url: URL, root: URL) -> Bool {
        let base = root.standardizedFileURL.path
        let target = url.standardizedFileURL.path
        return target == base || target.hasPrefix(base + "/")
    }

    func isWithinLibrary(_ url: URL) -> Bool {
        Self.isWithinLibrary(url, root: rootDirectory)
    }

    func delete(id: UUID) {
        // Must precede the lookup below: this is the single most important guard in the store, because
        // the removeRecordingDirectory call further down runs BEFORE the index is persisted. A guard
        // placed after any side effect would still destroy audio while merely refusing to save (F187).
        guard mutationIsAllowed() else { return }
        guard let meeting = meeting(id: id) else { return }
        let directory = recordingURL(for: meeting).deletingLastPathComponent()
        // Never delete outside the library, and never delete the library root itself — a corrupt index
        // with a `../` or empty `recordingPath` could otherwise resolve to an external or top-level dir
        // (F148 #6). In that case remove only the index entry and say the on-disk files were left alone.
        guard isWithinLibrary(directory),
              directory.standardizedFileURL != rootDirectory.standardizedFileURL else {
            meetings.removeAll { $0.id == id }
            persistMeetings()
            storageErrorMessage = "This meeting's recording path pointed outside the library, so no files were deleted from disk; the meeting was removed from the list."
            return
        }
        do {
            try removeRecordingDirectory(directory)
        } catch {
            // Don't half-delete: keep the meeting so the library stays consistent, and surface why.
            storageErrorMessage = "This meeting's recording could not be removed, so it was kept to avoid an inconsistent library. \(error.localizedDescription)"
            return
        }
        meetings.removeAll { $0.id == id }
        persistMeetings()
        storageErrorMessage = nil
    }

    /// Deletes several meetings in one pass: one read-only check, one index write. Looping
    /// `delete(id:)` would run a full index write per meeting, the same cost F40 removed from
    /// per-keystroke transcript edits (F199).
    ///
    /// Per record this keeps both existing invariants: the containment check that stops a corrupt or
    /// empty `recordingPath` resolving outside the library (F148 #6), and the read-only guard ahead of
    /// any filesystem side effect, because `removeRecordingDirectory` runs before the index is
    /// persisted (F187). No notes-sidecar hook, matching `delete(id:)` — the sidecar lives in the
    /// recording folder, which dies with the meeting. Returns the ids actually removed.
    @discardableResult
    func delete(ids: [UUID]) -> [UUID] {
        guard mutationIsAllowed() else { return [] }
        var removed: [UUID] = []
        var keptTitles: [String] = []
        var escapedLibrary = false
        for id in ids {
            guard let meeting = meeting(id: id) else { continue }
            let directory = recordingURL(for: meeting).deletingLastPathComponent()
            guard isWithinLibrary(directory),
                  directory.standardizedFileURL != rootDirectory.standardizedFileURL else {
                // Index entry only — nothing on disk is touched, exactly as `delete(id:)` does.
                removed.append(id)
                escapedLibrary = true
                continue
            }
            do {
                try removeRecordingDirectory(directory)
                removed.append(id)
            } catch {
                // Don't half-delete: keep the meeting so the library stays consistent.
                keptTitles.append(meeting.title)
            }
        }
        guard !removed.isEmpty else {
            if !keptTitles.isEmpty {
                storageErrorMessage = Self.batchDeleteFailureMessage(keptTitles)
            }
            return []
        }
        let removing = Set(removed)
        meetings.removeAll { removing.contains($0.id) }
        persistMeetings()
        // After `persistMeetings()`, which clears `storageErrorMessage` on a successful write.
        if !keptTitles.isEmpty {
            storageErrorMessage = Self.batchDeleteFailureMessage(keptTitles)
        } else if escapedLibrary {
            storageErrorMessage = "One or more meetings had a recording path outside the library, so no files were deleted from disk for them; they were removed from the list."
        }
        return removed
    }

    private static func batchDeleteFailureMessage(_ titles: [String]) -> String {
        let names = titles.map { "“\($0)”" }.joined(separator: ", ")
        return "\(titles.count) meeting(s) could not have their recordings removed, so they were kept to avoid an inconsistent library: \(names)."
    }

    func addVocabulary(_ terms: [String]) {
        guard mutationIsAllowed() else { return }
        vocabulary = Self.storedTerms(vocabulary + terms)
        persistVocabulary()
    }

    func removeVocabulary(_ term: String) {
        guard mutationIsAllowed() else { return }
        vocabulary.removeAll { $0 == term }
        persistVocabulary()
    }

    /// Adds a `heard → preferred` replacement rule (F179), trimming both sides and ignoring an empty,
    /// no-op (`heard == preferred`), or already-present rule. Capped so the list can't grow unbounded.
    func addReplacementRule(heard: String, preferred: String) {
        guard mutationIsAllowed() else { return }
        let h = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        let p = preferred.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty, !p.isEmpty, h != p else { return }
        let rule = ReplacementRule(heard: h, preferred: p)
        guard !replacementRules.contains(rule), replacementRules.count < Self.maxReplacementRules else { return }
        replacementRules.append(rule)
        persistReplacementRules()
    }

    func removeReplacementRule(_ rule: ReplacementRule) {
        guard mutationIsAllowed() else { return }
        replacementRules.removeAll { $0 == rule }
        persistReplacementRules()
    }

    private static let maxReplacementRules = 500

    func clearStorageError() {
        storageErrorMessage = nil
    }

    private static func normalizeTerm(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Storage-side normalization only (F187): trim, drop empties, dedupe, sort. The 1,000-character
    /// prompt budget belongs to `promptVocabulary`, not to what the user's file is allowed to contain.
    /// The ceiling here exists so a runaway paste cannot grow the file without bound; it is deliberately
    /// far above any budget a prompt could impose, so reaching it is a bug report, not a routine trim.
    private static func storedTerms(_ values: [String]) -> [String] {
        Array(Set(values.map(normalizeTerm).filter { !$0.isEmpty }))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .prefix(maxStoredVocabularyTerms)
            .map { $0 }
    }

    private static let maxStoredVocabularyTerms = 5_000

    /// The prompt budget: at most 100 terms AND at most 1,000 characters once joined. Applied only when
    /// a prompt is built (`promptVocabulary`) — never to what is stored (F187).
    private static func promptSafeTerms(_ values: [String]) -> [String] {
        let candidates = Array(Set(values.map(normalizeTerm).filter { !$0.isEmpty }))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        var result: [String] = []
        var characterCount = 0
        for term in candidates where result.count < 100 {
            let separatorCount = result.isEmpty ? 0 : 2
            guard characterCount + separatorCount + term.count <= 1_000 else { continue }
            result.append(term)
            characterCount += separatorCount + term.count
        }
        return result
    }

    private func persistMeetings() {
        persistCount += 1
        do {
            try meetingFiles.save(meetings)
            storageErrorMessage = nil
        } catch {
            storageErrorMessage = "Meeting changes could not be saved. The recording files and last readable index copy remain on this Mac. \(error.localizedDescription)"
        }
    }

    private func persistVocabulary() {
        do {
            try vocabularyFiles.save(vocabulary)
            storageErrorMessage = nil
        } catch {
            storageErrorMessage = "Vocabulary changes could not be saved. The last readable copy remains on this Mac. \(error.localizedDescription)"
        }
    }

    private func persistReplacementRules() {
        do {
            try replacementRulesFiles.save(replacementRules)
            storageErrorMessage = nil
        } catch {
            storageErrorMessage = "Replacement-rule changes could not be saved. The last readable copy remains on this Mac. \(error.localizedDescription)"
        }
    }

    /// Worsen `health` toward `state`, and never improve it (F187).
    ///
    /// All three persisted stores load in sequence inside `init` and share this ONE value, which gates
    /// mutation for all of them. Written as a plain `health = result.health` it becomes last-writer-wins
    /// across three independent files: a perfectly readable `vocabulary.json` loading after a corrupt
    /// `meetings.json` puts `.complete` back and silently re-opens every mutator on a library that
    /// cannot be read — the exact failure this ticket exists to prevent. `.complete` is rank 0 in
    /// `PersistedStoreHealth.severity`, so it can only ever be the starting value, never an upgrade.
    private func degrade(to state: PersistedStoreHealth) {
        guard state.isWorse(than: health) else { return }
        health = state
    }

    /// Degrade to whatever a failed load implies, and record why. Fails CLOSED: a load that threw is
    /// never a healthy store, so the `else` covers every error this does not recognize. Shared by all
    /// three load paths so the rule cannot drift between them — `BackupJSONStoreError` lives in
    /// WhisperCore, and a new case there raises no warning here (F187).
    private func degrade(after error: Error) {
        if let storeError = error as? BackupJSONStoreError,
           case let .noReadableCopy(_, _, quarantined) = storeError {
            degrade(to: .unreadable(quarantined: quarantined))
        } else {
            degrade(to: .unavailable(error.localizedDescription))
        }
        startupRecoveryMessages.append(error.localizedDescription)
    }

    /// Rebuild a meeting list from index bytes that no longer decode as a whole, keeping every record
    /// that still does (F187).
    ///
    /// `BackupJSONStore` has carried this seam since quarantine landed, but the meeting index — the one
    /// index actually wiped on 2026-08-14 — was constructed without it, so a single unreadable record
    /// still cost the entire library. `BackupJSONStore` calls this only AFTER both copies have been
    /// preserved, so this reads bytes that already survive on disk and writes nothing.
    ///
    /// The decoder MUST match `BackupJSONStore`'s own (`.iso8601`). Under the default date strategy
    /// every record's `createdAt` fails, and the salvage silently rescues nothing while looking wired.
    ///
    /// Returns nil when there is nothing element-wise to rescue, in two cases that matter equally:
    /// a top level that is not an array, and an array where NOTHING decoded. Reporting the second as
    /// `.partiallySalvaged` with an empty library would read to the user as "your meetings are gone"
    /// while claiming a partial rescue; the honest answer is `noReadableCopy`, which names the
    /// quarantine files. Returning nil lets that real error stand.
    ///
    /// `nonisolated` and `@Sendable` because `BackupJSONStore` stores this as a `@Sendable` closure and
    /// runs it on whatever context called `load()`: a `@MainActor`-isolated static could not be handed
    /// over at all, and an unmarked one converts only with a data-race warning. It is a pure function of
    /// its bytes and touches no store state, so both are statements of fact rather than escape hatches.
    @Sendable
    nonisolated private static func salvageMeetings(from data: Data) -> SalvagedValue<[MeetingRecord]>? {
        guard let elements = try? JSONSerialization.jsonObject(with: data) as? [Any] else { return nil }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601

        var kept: [MeetingRecord] = []
        var parked: [String] = []
        for (index, element) in elements.enumerated() {
            // Re-serialized wrapped back into a one-element ARRAY rather than as a bare fragment:
            // every value `JSONSerialization` hands back is legal inside an array, so a malformed
            // element (a number, a string, null) is parked rather than trapping the whole salvage.
            if JSONSerialization.isValidJSONObject([element]),
               let elementData = try? JSONSerialization.data(withJSONObject: [element]),
               let record = try? decoder.decode([MeetingRecord].self, from: elementData).first {
                kept.append(record)
            } else {
                parked.append(parkedIdentifier(for: element, at: index))
            }
        }
        guard !kept.isEmpty else { return nil }
        return SalvagedValue(value: kept, parkedIdentifiers: parked)
    }

    /// A name the user can look for inside the quarantined copy: the record's own id, else its title,
    /// else its position in the file. Never fails — a record too damaged to identify is simply another
    /// parked record, and losing its name must not cost the records around it (F187).
    nonisolated private static func parkedIdentifier(for element: Any, at index: Int) -> String {
        guard let object = element as? [String: Any] else { return "record at index \(index)" }
        if let id = object["id"] as? String, !id.isEmpty { return id }
        if let title = object["title"] as? String, !title.isEmpty { return title }
        return "record at index \(index)"
    }

    private func loadMeetings() {
        do {
            guard let result = try meetingFiles.load() else { return }
            meetings = MeetingOrdering.sorted(result.value)
            degrade(to: result.health)
            if case .recoveredFromBackup = result.health {
                startupRecoveryMessages.append(
                    "The meeting index was damaged, so WhisperMeet loaded the previous readable backup, which may be one save behind. Nothing was written and no recording folders were deleted — confirm the library looks right before editing."
                )
            }
            if case let .partiallySalvaged(parked) = result.health {
                startupRecoveryMessages.append(
                    "\(parked.count) meeting record(s) could not be read and were left in the preserved copy. The rest of the library loaded. Nothing was written."
                )
            }
            // A valid but empty index sitting next to FINALIZED recordings is suspicious, not normal:
            // that is the wipe shape — meetings that demonstrably happened, an index claiming none.
            // Keyed off `result.health` rather than `health` so it still asks "did THIS load come back
            // clean?" no matter what any other store has already reported.
            //
            // "Finalized" is the whole rule, and it is narrower than "a folder exists" for a reason
            // (F187). `AppModel.startRecording` creates the folder BEFORE any record exists, so a
            // force-quit mid-recording leaves raw capture tracks and no mixed WAV. Counting that folder
            // turned "deleted my last meeting, then crashed while recording" — no corruption anywhere —
            // into a read-only library with no in-app way out, in which the interrupted audio was never
            // even rebuilt, because `orphanedRecordings()` reports nothing while degraded. An unfinished
            // folder is exactly what `InterruptedRecordingRecovery` exists to rebuild, so it is evidence
            // of a crash, never of a lost meeting.
            //
            // Residual, accepted knowingly: an import copies `recording.<ext>` into place before it is
            // indexed, so a force-quit during that copy leaves a partial file that counts as finalized.
            // It is counted anyway, because a COMPLETED import leaves the identical file and nothing
            // else — excluding it would make a wiped library of imports look like a fresh install,
            // which is the failure this check exists to catch.
            if meetings.isEmpty, result.health == .complete {
                let count = finalizedRecordingFolderCount()
                if count > 0 { degrade(to: .suspectEmpty(recordingFolderCount: count)) }
            }
        } catch {
            degrade(after: error)
        }
    }

    /// How many recording folders hold a FINALIZED recording — the only folders that count as a
    /// meeting the index should have known about (F187). Reads only; creates and rewrites nothing,
    /// because this runs during `init` on a library that may be mid-recovery.
    ///
    /// `InterruptedRecordingRecovery.finalizedRecording(in:)` is the single definition of "finalized"
    /// and belongs there, not here: the recovery path and this check must agree, or one of them would
    /// treat a folder as a lost meeting while the other treats it as something to rebuild.
    private func finalizedRecordingFolderCount() -> Int {
        let recordings = rootDirectory.appendingPathComponent("Recordings", isDirectory: true)
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: recordings,
            includingPropertiesForKeys: [.isDirectoryKey],
            options: [.skipsHiddenFiles]
        )) ?? []
        return urls.filter {
            UUID(uuidString: $0.lastPathComponent) != nil
                && InterruptedRecordingRecovery.finalizedRecording(in: $0) != nil
        }.count
    }

    private func loadVocabulary() {
        do {
            guard let result = try vocabularyFiles.load() else { return }
            vocabulary = Self.storedTerms(result.value)
            // Through `degrade`, never a plain assignment: this runs AFTER `loadMeetings()`, so a
            // readable vocabulary index must not undo a degraded meeting index (F187).
            degrade(to: result.health)
            if result.health == .recoveredFromBackup {
                // No re-persist here, matching the meeting index: recovering from a stale backup writes
                // nothing, so the damaged primary is left exactly as it is for recovery to work from
                // (F187, and what `docs/RECOVERY.md` already promises). The old `save()` also ran during
                // `init` — bypassing `mutationIsAllowed()` entirely, on a library that had just declared
                // itself read-only.
                startupRecoveryMessages.append(
                    "The vocabulary index was damaged, so WhisperMeet loaded the previous readable backup, which may be one save behind. Nothing was written and the damaged copy was left exactly as it is."
                )
            }
        } catch {
            degrade(after: error)
        }
    }

    private func loadReplacementRules() {
        do {
            guard let result = try replacementRulesFiles.load() else { return }
            replacementRules = result.value
            degrade(to: result.health)
            if result.health == .recoveredFromBackup {
                // Same as `loadVocabulary`: no silent re-persist from inside `init` (F187).
                startupRecoveryMessages.append(
                    "The replacement-rule index was damaged, so WhisperMeet loaded the previous readable backup, which may be one save behind. Nothing was written and the damaged copy was left exactly as it is."
                )
            }
        } catch {
            degrade(after: error)
        }
    }
}
