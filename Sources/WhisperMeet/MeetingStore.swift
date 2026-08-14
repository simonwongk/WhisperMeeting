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

@MainActor
final class MeetingStore: ObservableObject {
    @Published private(set) var meetings: [MeetingRecord] = []
    @Published var vocabulary: [String] = []
    /// Exact `heard → preferred` replacement rules (F179), persisted like vocabulary. Reviewed before
    /// any apply — the matcher only proposes; nothing auto-applies and the audio is never touched.
    @Published private(set) var replacementRules: [ReplacementRule] = []
    @Published private(set) var storageErrorMessage: String?

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
            backupURL: self.rootDirectory.appendingPathComponent("meetings.backup.json")
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

    func recordingDirectory(for id: UUID) throws -> URL {
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

    func relativeRecordingPath(for url: URL) -> String {
        url.standardizedFileURL.path.replacingOccurrences(
            of: rootDirectory.standardizedFileURL.path + "/",
            with: ""
        )
    }

    func orphanedRecordings() throws -> [OrphanedRecording] {
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

    func upsert(_ meeting: MeetingRecord) {
        if let index = meetings.firstIndex(where: { $0.id == meeting.id }) {
            meetings[index] = meeting
        } else {
            meetings.append(meeting)
        }
        meetings = MeetingOrdering.sorted(meetings)
        persistMeetings()
    }

    func update(id: UUID, _ mutation: (inout MeetingRecord) -> Void) {
        guard let index = meetings.firstIndex(where: { $0.id == id }) else { return }
        mutation(&meetings[index])
        persistMeetings()
    }

    /// Apply a transcript-body edit: update the in-memory record immediately (so the editor stays
    /// live) but coalesce the expensive whole-index write, which otherwise ran on every keystroke
    /// (F40). See `scheduleDebouncedPersist`.
    func editTranscript(id: UUID, text: String) {
        guard let index = meetings.firstIndex(where: { $0.id == id }) else { return }
        meetings[index].transcriptText = text
        scheduleDebouncedPersist()
    }

    /// Apply a notes edit with the same immediate-in-memory + debounced-write coalescing as the
    /// transcript editor — the notes field had the identical per-keystroke whole-index write (F133).
    /// Empty text clears the field (nil), matching the prior binding.
    func editNotes(id: UUID, text: String) {
        guard let index = meetings.firstIndex(where: { $0.id == id }) else { return }
        meetings[index].notes = text.isEmpty ? nil : text
        scheduleDebouncedPersist()
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
        guard let task = pendingIndexFlush else { return }
        pendingIndexFlush = nil
        task.cancel()
        persistMeetings()
    }

    /// Replace a meeting's tags with the normalized (trimmed/deduped/capped) form of `raw`.
    func setTags(id: UUID, _ raw: [String]) {
        let normalized = MeetingTags.normalized(raw)
        update(id: id) { $0.tags = normalized.isEmpty ? nil : normalized }
    }

    /// Pin or unpin a meeting so it floats to (or off) the top of the sidebar, then re-orders.
    func togglePin(id: UUID) {
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
    func isWithinLibrary(_ url: URL) -> Bool {
        let base = rootDirectory.standardizedFileURL.path
        let target = url.standardizedFileURL.path
        return target == base || target.hasPrefix(base + "/")
    }

    func delete(id: UUID) {
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

    func addVocabulary(_ terms: [String]) {
        vocabulary = Self.promptSafeTerms(vocabulary + terms)
        persistVocabulary()
    }

    func removeVocabulary(_ term: String) {
        vocabulary.removeAll { $0 == term }
        persistVocabulary()
    }

    /// Adds a `heard → preferred` replacement rule (F179), trimming both sides and ignoring an empty,
    /// no-op (`heard == preferred`), or already-present rule. Capped so the list can't grow unbounded.
    func addReplacementRule(heard: String, preferred: String) {
        let h = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        let p = preferred.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty, !p.isEmpty, h != p else { return }
        let rule = ReplacementRule(heard: h, preferred: p)
        guard !replacementRules.contains(rule), replacementRules.count < Self.maxReplacementRules else { return }
        replacementRules.append(rule)
        persistReplacementRules()
    }

    func removeReplacementRule(_ rule: ReplacementRule) {
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

    private func loadMeetings() {
        do {
            guard let result = try meetingFiles.load() else { return }
            meetings = MeetingOrdering.sorted(result.value)
            if result.health == .recoveredFromBackup {
                startupRecoveryMessages.append(
                    "The meeting index was damaged, so WhisperMeet restored the previous readable backup. No recording folders were deleted."
                )
                try meetingFiles.save(meetings)
            }
        } catch {
            startupRecoveryMessages.append(error.localizedDescription)
        }
    }

    private func loadVocabulary() {
        do {
            guard let result = try vocabularyFiles.load() else { return }
            vocabulary = Self.promptSafeTerms(result.value)
            if result.health == .recoveredFromBackup {
                startupRecoveryMessages.append(
                    "The vocabulary index was damaged, so WhisperMeet restored the previous readable backup."
                )
                try vocabularyFiles.save(vocabulary)
            }
        } catch {
            startupRecoveryMessages.append(error.localizedDescription)
        }
    }

    private func loadReplacementRules() {
        do {
            guard let result = try replacementRulesFiles.load() else { return }
            replacementRules = result.value
            if result.health == .recoveredFromBackup {
                startupRecoveryMessages.append(
                    "The replacement-rule index was damaged, so WhisperMeet restored the previous readable backup."
                )
                try replacementRulesFiles.save(replacementRules)
            }
        } catch {
            startupRecoveryMessages.append(error.localizedDescription)
        }
    }
}
