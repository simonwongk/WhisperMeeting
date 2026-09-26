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
    /// The schema this build writes. Bumped when a persisted shape changes incompatibly.
    ///
    /// 2, not 1, because 1 is the implicit shape of every index written before the marker existed —
    /// which is what `schemaVersion == nil` means, and why nothing needs to rewrite those records to
    /// give them a number they already have by omission.
    static let currentSchemaVersion = 2

    /// The schema version this record's **content** was written against, or nil when it was written
    /// before the marker existed (F188 item 1, "Mark it", the user's answer of 2026-09-19).
    ///
    /// **It is a marker, not a fence, and the distinction is the whole reason this option was
    /// chosen.** The fence F188 asked for cannot exist: no change to this file can make an
    /// *already-shipped* reader refuse, because a reader that does not know about versions cannot
    /// check one — `Codable` ignores an unknown key, which is exactly what makes adding this field
    /// free. So this buys diagnosis and cheap future migration, and buys **no** protection against a
    /// downgrade. That protection is F190's recoverable generations plus F188 item 3's exclusive
    /// instance guard, which does not exist yet. The alternative that would have fenced (an
    /// envelope) does so only by *being* the breakage it prevents, once, for every user who
    /// downgrades; `docs/superpowers/specs/2026-09-17-schema-fence-design.md` has the full
    /// reasoning and the user's answer.
    ///
    /// **Nothing reads this to make a decision, and that is enforced** by
    /// `markerIsNeverReadToMakeADecision`. A reader that branches on it turns this into the fence
    /// the analysis says it cannot be, and does so invisibly, because such code looks like an
    /// improvement.
    ///
    /// **One file holds records at mixed versions, and that is normal** — records written by
    /// different builds. So *"the index's version"* is not a well-formed question; only *"this
    /// record's version"* is. Anyone reaching for the former will find nothing to reach for, and the
    /// obvious repair is an envelope, which is the rejected option arriving by the back door.
    ///
    /// It describes the record's content, not the bytes around it: a record nobody edited keeps
    /// saying what it was written against even when the file is rewritten for an unrelated reason.
    /// `MeetingStore.upsert` and `update` stamp it, because those are where content changes.
    ///
    /// Stamping on every *save* instead is the obvious simplification and it is a trap. A record
    /// untouched since the old schema genuinely has old-schema content; marking it current would
    /// make a future migration **skip exactly the records that need migrating**. That is worse than
    /// having no marker — no marker means "check everything", a wrong marker means "check nothing"
    /// with a confident-looking reason. `rewriteHistory` does not stamp either, for the same rule
    /// aimed at evidence: it rewrites *retained generations*, and restamping one would make a
    /// snapshot claim a version it was never written under.
    var schemaVersion: Int? = MeetingRecord.currentSchemaVersion

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
    /// A plain-language note when a rebuild from raw tracks stopped early because a source track
    /// became unreadable partway through (F256). Optional so indexes written before this field still
    /// decode; `nil` means the audio is whole. Its presence must mean exactly one thing — this
    /// recording is short by an unknown amount — so nothing else may borrow it for another notice.
    ///
    /// Separate from `errorMessage`, which every recovered meeting already carries: that string
    /// explains the recovery, this one contradicts it.
    var recoveryWarning: String?
    /// How this meeting was recovered, when it was (F273). Nil for every meeting that was never
    /// recovered. Holds `RecoveredRecording.Source`'s raw value.
    ///
    /// **Structural rather than prose, and that is the fix.** The provenance used to live in
    /// `errorMessage`, which `performTranscription` clears twice — once on start and once on
    /// success — so transcribing a recovered meeting destroyed the only record that it had been
    /// interrupted. Observed in a real 63-minute meeting, not hypothesised. A fact nothing else
    /// owns cannot be erased by a path that owns a message, and the sentence is generated in one
    /// place instead of stored in three.
    ///
    /// A `String` rather than the enum so a value a newer build writes decodes and is ignored
    /// rather than making the index unreadable — F250's rule, one file over.
    var recoverySource: String?
    /// A plain-language note when the meeting's audio was rebuilt after its transcript was made
    /// (F267), so the text describes a file that no longer exists and its timestamps point into a
    /// different one. Optional so older indexes decode.
    ///
    /// The transcript is deliberately KEPT rather than cleared — F148 #1 forbids a rebuild blanking
    /// the user's text, and losing it would be the greater harm anyway. Saying so is the F281 rule:
    /// a transcript silently describing superseded audio reads as current because nothing
    /// contradicts it. Cleared the next time the meeting is transcribed.
    var staleTranscriptWarning: String?
    /// Why this meeting had to be recovered, as `RecoveryInterruption`'s raw value (F305).
    ///
    /// A field rather than prose for the reason F273 established and F274 then did not apply: the
    /// message that used to carry this is cleared by transcription, so the reason died while the
    /// fact of the recovery survived. Stored as a `String` so an unknown value decodes and is
    /// ignored (F250), and rendered as nothing when unrecognised.
    var recoveryInterruption: String?
    /// A plain-language note when the transcript's dominant script disagrees with the language the
    /// user explicitly selected — the "original language only" net (F32). Optional so old indexes
    /// decode; nil under automatic detection or when the language matches.
    var languageWarning: String?
    /// How many echoes of a stuck decode were removed from this transcript: whole repeated lines plus
    /// in-line copies of a looping unit (F422). Nil when nothing was removed, and on every index
    /// written before this field existed.
    ///
    /// A count rather than a sentence, for the F273 reason: the notice is generated from it in one
    /// place, so no path that owns a message can erase the fact that text was removed. Set by the
    /// transcription write (replacing any earlier value, because a new transcript's echoes are the
    /// only ones it can have), and added to by Remove Repeated Lines and by a per-segment re-run.
    var repeatsRemoved: Int?
    /// The engine that produced this meeting's transcript, as its raw persisted string (F250).
    ///
    /// **Stored as a string, not as the enum, and that is the whole fix.** It was
    /// `MeetingTranscriptionEngine?` — a raw-value enum with no lenient decode — so an index written
    /// by a build with an engine this one lacks failed with `DecodingError.dataCorrupted`. The
    /// persisted root is a single `[MeetingRecord]` array, so that one value failed the decode of
    /// *every* meeting: the whole library unreadable. It made adding any engine a one-way door, and
    /// F240 recorded it as a blocker while considering a whisper.cpp engine.
    ///
    /// Leniency at the enum could not fix it. `Decodable` cannot yield `nil` from a type's own
    /// initialiser, and `decodeIfPresent` returns nil only for an absent or null key, never for a
    /// value that throws — so enum-level leniency would have to invent a case, and decoding an
    /// unrecognised engine as `.whisperLarge` would claim a meeting was transcribed by a model that
    /// never touched it. This field is a provenance record; a wrong answer is worse than no answer.
    /// Holding the string moves the decision out of `Decodable` entirely: the string always
    /// round-trips, and `transcriptionEngine` below answers nil for what this build cannot name,
    /// which is the truth rather than a guess.
    ///
    /// Read and written through `transcriptionEngine`. The on-disk key is unchanged, which is why
    /// `CodingKeys` below is hand-written.
    private(set) var transcriptionEngineRawValue: String?

    /// The engine that produced this meeting's transcript, when this build recognises it.
    ///
    /// Recorded so a "second opinion" can run the genuine other engine regardless of current
    /// Settings (F142). Nil means either "no engine recorded" (an old index) or "an engine this
    /// build does not know" (a newer one) — deliberately not distinguished here, because every
    /// caller wants the same answer for both: fall back to the current selection rather than
    /// assert something about a model that may never have run. `transcriptionEngineRawValue` keeps
    /// the distinction for anything that needs it.
    var transcriptionEngine: MeetingTranscriptionEngine? {
        get { transcriptionEngineRawValue.flatMap(MeetingTranscriptionEngine.init(rawValue:)) }
        set { transcriptionEngineRawValue = newValue?.rawValue }
    }
    /// The language this meeting's transcription was asked to run in — `WhisperLanguage`'s raw value
    /// ("automatic", "english", "chinese") — or nil for a meeting transcribed before this was
    /// recorded (F471). Written by `AppModel.apply(result:)` from the Settings snapshot the run was
    /// queued with, and read by `reTranscribeSegment` through `WhisperLanguage(storedRequestedLanguage:)`.
    ///
    /// Kept apart from `languageCode`, which is what the engine *returned*. Under Automatic — the
    /// default — that is only the detected majority language (Whisper detects once from the first
    /// 30 seconds; Qwen's helper takes the majority script of the whole text), so it cannot say
    /// whether anyone pinned anything. Reading a pin off it forced the majority language onto every
    /// minority-language line of a code-switched meeting on re-run — the silent mistranslation
    /// F471 exists to stop, arriving from the other side. A per-segment re-run pins its language
    /// only when this says the meeting's own run was pinned.
    ///
    /// A plain string rather than the enum, as `transcriptionEngineRawValue` is (F250): a value this
    /// build has never heard of decodes and round-trips untouched, and the typed read answers
    /// `.automatic` for it — the deferring answer, since a language this build cannot pin is one it
    /// can still detect. Nil is not only "written before this field existed": a downgrade round-trip
    /// produces it too, because the older build drops the key on its next save. Both read the same
    /// way — detect, never pin — so nil is never an age marker.
    var requestedLanguage: String?
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
        recoveryWarning: String? = nil,
        recoverySource: String? = nil,
        staleTranscriptWarning: String? = nil,
        recoveryInterruption: String? = nil,
        languageWarning: String? = nil,
        repeatsRemoved: Int? = nil,
        transcriptionEngine: MeetingTranscriptionEngine? = nil,
        requestedLanguage: String? = nil,
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
        self.recoveryWarning = recoveryWarning
        self.recoverySource = recoverySource
        self.staleTranscriptWarning = staleTranscriptWarning
        self.recoveryInterruption = recoveryInterruption
        self.languageWarning = languageWarning
        self.repeatsRemoved = repeatsRemoved
        self.transcriptionEngineRawValue = transcriptionEngine?.rawValue
        self.requestedLanguage = requestedLanguage
        self.source = source
        self.referenceSegments = referenceSegments
    }

    /// Hand-written so `transcriptionEngineRawValue` persists under its original on-disk name
    /// (F250). Everything else keeps the name synthesis gave it — renaming any of these would make
    /// every existing index lose that field on the next save, with nothing failing to announce it.
    /// `theWireKeySetIsPinned` asserts the full set, because a case missing from this enum is
    /// exactly that silent loss.
    private enum CodingKeys: String, CodingKey {
        case schemaVersion
        case id, title, createdAt, duration, recordingPath, status, transcriptText
        case languageCode, confidence, segments, errorMessage, summary, transcriptNormalized
        case markers, pinned, notes, tags, healthReport, alignmentWarning, recoveryWarning
        case languageWarning, source, referenceSegments
        // F304: these two were missing, so they were encoded and decoded by nothing — in-memory
        // only. `recoverySource` IS F273's fix: that ticket exists because provenance lived in a
        // field another path cleared, and the fix moved it into a field nothing persisted, so it
        // survived transcription and not a reload. `staleTranscriptWarning` is F267's notice and
        // failed the same way. A hand-written `CodingKeys` encodes only what it lists, and nothing
        // warns about the rest — `MeetingRecordWireFormatTests` now enumerates the stored
        // properties with `Mirror` so the omission cannot recur.
        case recoverySource, staleTranscriptWarning, recoveryInterruption
        case repeatsRemoved
        // F471: the language the run was asked for, beside the engine that ran it. Listed for the
        // reason the F304 comment above gives — `everyStoredFieldIsEncoded` named this field the
        // moment the property existed without this line.
        case requestedLanguage
        case transcriptionEngineRawValue = "transcriptionEngine"
    }

    /// Markers sorted by offset (empty when none). Convenience for the UI and exports.
    var orderedMarkers: [RecordingMarker] {
        (markers ?? []).sorted { $0.offset < $1.offset }
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

    /// For a control that is disabled rather than refused (F194). The Improve menu's actions each
    /// run an on-device model for minutes and produce proposals that can only land through a
    /// `store.update` the read-only library will refuse, so offering them enabled invites the user
    /// to spend real time on work that cannot be kept. Says what is unavailable and why, because a
    /// greyed row with no explanation is what the menu's footnote convention exists to prevent.
    static let menuFootnote =
        "\(lead) Suggestions could not be applied to a transcript, so these are unavailable until recovery is resolved."

    /// The Settings → Library section's read-only sentence (F313): what is true of the library,
    /// beside the controls that resolve it, with nothing about menus or transcripts.
    static let librarySectionNotice =
        "\(lead) Your recordings are untouched. Recover Library restores an earlier copy of the index, or rebuilds one from the recording folders when no copy was kept."

    /// The standing notice above the detail column while degraded (F313). Names the way out,
    /// because the read-only state is only ever resolved by taking it.
    static let banner =
        "\(lead) Your recordings are untouched. To recover, open Settings → Library → Recover Library…"

    /// For the library check, which reads the index it is reporting on (F194). Reporting "no audio
    /// problems were found" for a library that failed to decode is a clean bill of health for an
    /// index nobody managed to read.
    static let integrityCheckDeclined =
        "\(lead) The library check cannot report on an index it could not read, so nothing was checked. Your recordings are untouched."

    /// The one sentence shape every pre-action refusal shares. Private so the surfaces above stay the
    /// only vocabulary callers see.
    private static func refused(_ action: String, resolution: String) -> String {
        "\(action) cannot start because \(lead) Your existing recordings are untouched — resolve recovery \(resolution)."
    }
}

/// A save that lost a race, in terms the UI can render (F190).
///
/// Carries whether the refused body was preserved, because that is the one thing the user must not
/// be misled about — the F187 honesty rule. `preservedAs` is nil exactly when preservation failed,
/// and `message` then says so rather than implying a copy exists.
struct WriteConflictReport: Equatable {
    /// The history file holding the refused body, or nil when it could not be written.
    let preservedAs: String?
    let message: String
    /// False when this was an ordinary save failure rather than a lost race — a full disk, a
    /// permissions change. The channel is shared so a caller has one place to look.
    let isRace: Bool

    init(_ error: any Error) {
        guard let storeError = error as? BackupJSONStoreError else {
            preservedAs = nil
            isRace = false
            message = error.localizedDescription
            return
        }
        switch storeError {
        case let .generationConflict(_, _, _, preserved):
            preservedAs = preserved
            isRace = true
        case .generationConflictNotPreserved:
            preservedAs = nil
            isRace = true
        case .noReadableCopy:
            preservedAs = nil
            isRace = false
        }
        message = storeError.errorDescription ?? "\(storeError)"
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

    /// A whole-library restore is replacing files underneath the store, so nothing may be written
    /// until it finishes (F506).
    case libraryIsBeingRestored

    var errorDescription: String? {
        switch self {
        case .libraryIsReadOnly:
            return ReadOnlyLibraryNotice.recordingRefused
        case .engineRunIsReadOnly:
            return ReadOnlyLibraryNotice.actionRefused("Transcription")
        case .libraryIsBeingRestored:
            return MeetingStore.changeRefusedDuringRestore
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
    /// The terms the user starred to be sent to the recognizer first (F300).
    @Published private(set) var prioritizedVocabulary: Set<String> = []

    /// The subset handed to an engine's `initial_prompt`, capped to the prompt budget at the point of
    /// use rather than in storage.
    var promptVocabulary: [String] { Self.promptSafeTerms(vocabulary, first: prioritizedVocabulary) }

    /// Exact `heard → preferred` replacement rules (F179), persisted like vocabulary. Reviewed before
    /// any apply — the matcher only proposes; nothing auto-applies and the audio is never touched.
    @Published private(set) var replacementRules: [ReplacementRule] = []
    @Published private(set) var storageErrorMessage: String?
    /// The WORST load result across every persisted store this guard covers — the meeting index, the
    /// vocabulary and the replacement rules (F187). Scoped that way because it gates all three: anything
    /// but `.complete` blocks EVERY mutation, not just persistence, because a mutator's save would
    /// overwrite an index nobody could read and some mutators touch the disk as well — the notes
    /// sidecar, a deleted meeting's audio. Only ever assigned through `degrade(to:)`, so a store that
    /// loaded cleanly can never raise a damaged one back to writable — see that method for what went
    /// wrong when it was written as a plain assignment.
    @Published private(set) var health: PersistedStoreHealth = .complete
    var isDegraded: Bool { !health.allowsMutation }

    /// True while a whole-library restore is replacing files underneath this object (F506).
    ///
    /// Every mutator refuses meanwhile. The restore copies every recording and takes minutes, and a
    /// change saved during it lands in files the restore is about to overwrite and misses the
    /// pre-restore snapshot, which was taken before the copy began — so it is in neither. And once
    /// a restore has set the live ledger aside (F463), a save of this object's pre-restore list is
    /// not even caught as a conflict: with no ledger to contradict it, it is adopted over the
    /// restored index. Separate from `health` because nothing here is damaged: it ends when the
    /// restore does, with `endLibraryRestore()`, whichever way the restore went.
    @Published private(set) var isRestoringLibrary = false

    /// `nonisolated`: an immutable string read from `MeetingStoreError.errorDescription`, which is
    /// not on the main actor — the release build treats the isolated reference as an error.
    nonisolated static let changeRefusedDuringRestore = "Your library is being restored, so this change was not saved. Try again when the restore finishes."

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
    /// Commits, as opposed to attempts. `persistCount` keeps its original meaning ("a save was
    /// attempted") because ~15 existing assertions depend on it and on its position before the save
    /// (F190).
    private(set) var persistCommitCount = 0

    /// A save that lost a race to another writer. A SEPARATE channel from `health` on purpose:
    /// `AppModel.startRecording` pre-flights `!isDegraded` and relies on that answer for the whole
    /// recording, so a mid-session degrade would make `stopRecording`'s `upsert` silently return and
    /// lose a finished meeting (F190). A conflict is a transient race, not a damaged library.
    @Published private(set) var writeConflict: WriteConflictReport?
    /// True while the in-memory value is ahead of what reached disk.
    @Published private(set) var unsavedChanges = false
    /// Who holds the single-writer lease. A NON-BLOCKING ADVISORY — it never sets `health`, because
    /// a lease that could make a library read-only would be a new way to lock a user out of their
    /// own meetings.
    @Published private(set) var writerLease: StoreWriterLease = .unmanaged

    /// The generation each store last read or wrote, threaded into the next `save(expecting:)`.
    /// Without these the compare-and-swap never fires.
    private var meetingsToken: GenerationToken?
    private var vocabularyToken: GenerationToken?
    private var replacementRulesToken: GenerationToken?
    private var leaseHandle: LibraryWriterLeaseHandle?

    init(rootDirectory: URL? = nil, transcriptWriteDebounce: TimeInterval = 0.5) {
        // F312: one decision for the whole library, and one variable that can move it.
        self.rootDirectory = rootDirectory ?? WhisperMeetLibrary.root()
        self.transcriptWriteDebounce = transcriptWriteDebounce
        meetingFiles = BackupJSONStore(
            primaryURL: self.rootDirectory.appendingPathComponent("meetings.json"),
            backupURL: self.rootDirectory.appendingPathComponent("meetings.backup.json"),
            recordCount: { $0.count },
            // One bad record costs one record, not the library (F187) — see `salvageMeetings(from:)`.
            salvage: MeetingStore.salvageMeetings(from:)
        )
        vocabularyFiles = BackupJSONStore(
            primaryURL: self.rootDirectory.appendingPathComponent("vocabulary.json"),
            backupURL: self.rootDirectory.appendingPathComponent("vocabulary.backup.json"),
            recordCount: { $0.count }
        )
        replacementRulesFiles = BackupJSONStore(
            primaryURL: self.rootDirectory.appendingPathComponent("replacement-rules.json"),
            backupURL: self.rootDirectory.appendingPathComponent("replacement-rules.backup.json"),
            recordCount: { $0.count }
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

        // After `createDirectory` so the lock's `open` cannot fail with ENOENT on a first launch,
        // and before the three loads. Taken ONCE, here — never on a save path. `shared(for:)` and
        // not `acquire`: `flock` attaches to the open file description, so two acquisitions in one
        // process contend, and this store and `DictationLogStore` would lock each other out of the
        // same library and each report the other as a rival application.
        let handle = LibraryWriterLock.shared(for: self.rootDirectory)
        leaseHandle = handle
        writerLease = handle.lease
        loadMeetings()
        loadVocabulary()
        loadVocabularyPriority()
        loadReplacementRules()
    }

    /// Creates (and returns) a meeting's recording folder. Refuses while the library is not
    /// known-complete: the matching `upsert` would be refused by `mutationIsAllowed()`, so the folder
    /// would hold audio the library could never index — and `orphanedRecordings()` hides it too, so the
    /// user would lose the whole meeting silently. Callers should refuse earlier and explain why; this
    /// throw is the invariant that stops a future caller from reintroducing the hole (F187).
    func recordingDirectory(for id: UUID) throws -> URL {
        guard !isDegraded else { throw MeetingStoreError.libraryIsReadOnly }
        guard !isRestoringLibrary else { throw MeetingStoreError.libraryIsBeingRestored }
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
        guard !isRestoringLibrary else { return } // F506: the ids stay pending for the next flush
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
        // Never outside the library, and never the library root itself — the containment `delete`
        // used before F452 narrowed it to the meeting's own folder. This one is a write of a fixed
        // filename, so the wider check cannot remove anything and could never clobber an index; the
        // root is excluded because no meeting's notes belong beside the indexes (F198).
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
            segments: meeting.segments,
            caveats: Self.caveats(for: meeting)
        )
    }

    /// The facts about a meeting's RECORDING that its notes document has to carry (F281).
    ///
    /// All three are optional plain-language strings the app already shows on screen, and they have
    /// the same argument for being here: each one tells the reader that something about the text
    /// below is not what they would assume. `notes.md` exists so the text survives an index loss
    /// (F198), which makes it the copy most likely to be read with no app around it to add context.
    ///
    /// Order is by how much of the transcript each one undermines. `recoveryWarning` is first
    /// because it is the only one of the three that says content is MISSING — the other two say the
    /// text is complete but a property of it is off. Doing only the first would have been the
    /// inconsistency this ticket was filed about.
    nonisolated static func caveats(for meeting: MeetingRecord) -> [String] {
        recoveryCaveats(for: meeting) + [
            meeting.alignmentWarning,
            meeting.languageWarning,
        ].compactMap { $0 }
    }

    /// The caveats about the RECORDING, as opposed to about the transcript.
    ///
    /// Split out so the detail view can render this family as a list rather than as one
    /// hand-written banner per field. Three separate banners is how the provenance sentence came
    /// to exist in `notes.md` and nowhere on screen — a new member of the family has to be added
    /// in two places to be visible, and F273 is a report of exactly that kind of omission.
    ///
    /// `alignmentWarning` and `languageWarning` stay out: they are about the transcript, they
    /// already render inside `transcriptSection`, and including them here would double them up.
    nonisolated static func recoveryCaveats(for meeting: MeetingRecord) -> [String] {
        [
            meeting.recoveryWarning,
            meeting.staleTranscriptWarning,
            provenanceCaveat(for: meeting),
            // F305: beside the provenance because they are about the same event — one says the
            // recording was recovered, the other says what interrupted it. It used to be prose in
            // `errorMessage`, which transcription clears.
            interruptionCaveat(for: meeting),
        ].compactMap { $0 }
    }

    /// The sentence F273 restored, generated from `recoverySource` rather than stored.
    ///
    /// The two cases say different things because they are true of different audio, and claiming
    /// the stronger one for a preserved recording would be as wrong as omitting it. A rebuild has
    /// no per-track start offsets — the manifest is written in `stop()`, which by definition did
    /// not run — so recovery zero-aligns the channels, and that caveat about the audio is the half
    /// F273 identified as mattering most. A recovery that found an already-finalized recording has
    /// intact channels and only lost its index entry.
    ///
    /// An unrecognised value yields nothing: a raw identifier shown to a user would be worse than
    /// silence, and F250's lenient rule is about surviving the unknown, not displaying it.
    private nonisolated static func provenanceCaveat(for meeting: MeetingRecord) -> String? {
        guard let raw = meeting.recoverySource,
              let source = RecoveredRecording.Source(rawValue: raw) else { return nil }
        switch source {
        case .rebuiltSourceTracks:
            return "This recording was rebuilt from its raw microphone and system tracks after an interruption, so the two channels are aligned to the start of the file rather than to each other."
        case .existingCapture:
            return "This meeting was recovered after an interruption. The original recording and its source tracks were preserved."
        // F305: an import has no source tracks, and the function that detects one says so —
        // "An imported recording keeps a single `recording.<ext>` file and no raw source tracks"
        // (`InterruptedRecordingRecovery.swift:146`). It was grouped with `.existingCapture` and so
        // told every recovered import it had kept tracks that never existed. F303 widened the reach
        // by giving the two `.failed` unverified imports this sentence too, where a claim that the
        // recording was "preserved" reads as reassurance about a file macOS declined to verify — so
        // this says what is actually true of an import and nothing more.
        case .importedRecording:
            return "This imported recording was recovered after an interruption. The file itself was preserved; it was never a WhisperMeet capture, so there are no separate source tracks."
        }
    }

    /// The interruption sentence, generated from `recoveryInterruption` (F305).
    ///
    /// Nil when absent or unrecognised: F250's leniency rule is about surviving a value a newer
    /// build wrote, not about displaying it.
    private nonisolated static func interruptionCaveat(for meeting: MeetingRecord) -> String? {
        guard let raw = meeting.recoveryInterruption,
              let interruption = RecoveryInterruption(rawValue: raw) else { return nil }
        return interruption.caveat
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

    /// Whether this instance may rebuild an interrupted recording folder (F255).
    ///
    /// Deliberately NOT folded into `orphanedRecordings()` below. That function is a
    /// read-and-report — a folder holding raw tracks and no finalized WAV genuinely is unindexed,
    /// whoever is running — and making it return `[]` on a lease it does not own would make it lie
    /// about the filesystem. The refusal belongs to whoever is about to *write*, so
    /// `AppModel.performStartupRecovery` consults this before its rebuild loop and reports why it
    /// skipped.
    ///
    /// Lives here rather than in `AppModel` because the lease is this type's state and the question
    /// is about the library, not about the app's lifecycle. `InterruptedRecordingRecovery` owns the
    /// policy; this is the one line that connects it to `writerLease`.
    var mayRebuildInterruptedRecordings: Bool {
        InterruptedRecordingRecovery.mayRebuildInterruptedRecordings(writerLease)
    }

    /// Re-asks who holds the lease, so a launch-time answer cannot outlive the rival it described
    /// (F188).
    ///
    /// Deliberately a method and not folded into `mayRebuildInterruptedRecordings`: that is a
    /// computed property read from views, and a property that mutates `@Published` state on read is
    /// how a SwiftUI update loop starts. The caller that needs a fresh answer asks for one.
    ///
    /// Not on any save path, and not at init — `init` has just acquired. This exists for the one
    /// caller that runs more than once per launch: `AppModel.performStartupRecovery`, which re-runs
    /// after a library recovery clears the read-only state and would otherwise decide the
    /// interrupted-recording rebuild on a lease sampled before the other copy quit.
    func refreshWriterLease() {
        let handle = LibraryWriterLock.refresh(for: rootDirectory)
        leaseHandle = handle
        writerLease = handle.lease
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
    /// in-memory or filesystem side effect, and before the save itself: a save from a library that did
    /// not fully load writes over the index it could not read, and `delete` removes audio once its
    /// save has landed.
    private func mutationIsAllowed() -> Bool {
        if isRestoringLibrary {
            storageErrorMessage = Self.changeRefusedDuringRestore
            return false
        }
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
        // Content written by this build carries this build's schema version (F188, "Mark it").
        if let index = meetings.firstIndex(where: { $0.id == meeting.id }) {
            meetings[index].schemaVersion = MeetingRecord.currentSchemaVersion
        }
        persistMeetings()
        scheduleNotesSidecarWrite(for: meeting.id)
    }

    func update(id: UUID, _ mutation: (inout MeetingRecord) -> Void) {
        guard mutationIsAllowed() else { return }
        guard let index = meetings.firstIndex(where: { $0.id == id }) else { return }
        mutation(&meetings[index])
        // As in `upsert`: the version tracks the content, and the content just changed (F188).
        meetings[index].schemaVersion = MeetingRecord.currentSchemaVersion
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
        // A flush with nothing to flush is not a mutation and must not be refused as one (F313).
        // `AppLifecycle` calls this on every `willResignActive` — every app switch — and the
        // refusal below sets `storageErrorMessage`, which the window shows as a modal alert. On a
        // read-only library that raised the read-only alert each time the user looked at another
        // app, including the Finder they were sent to for the manual recovery steps.
        guard pendingIndexFlush != nil || !pendingSidecarIDs.isEmpty else { return }
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
        // Re-arm when the write did not land. Clearing `pendingIndexFlush` before persisting left
        // nothing to re-attempt, so a failed flush silently dropped the user's edit (F190).
        if !persistMeetings() {
            scheduleDebouncedPersist()
        }
    }

    /// Replace a meeting's tags with the normalized (trimmed/deduped/capped) form of `raw`.
    func setTags(id: UUID, _ raw: [String]) {
        guard mutationIsAllowed() else { return }
        let normalized = MeetingTags.normalized(raw)
        update(id: id) { $0.tags = normalized.isEmpty ? nil : normalized }
    }

    /// Adds one tag across a selection with a single index write (F40's rule: don't write per record).
    /// Normalization goes through `MeetingTags.normalized`, exactly as `setTags(id:_:)` does, so the
    /// batch and single paths cannot diverge.
    func addTag(_ tag: String, to ids: [UUID]) {
        guard mutationIsAllowed() else { return }
        let target = Set(ids)
        var changed = false
        for index in meetings.indices where target.contains(meetings[index].id) {
            let merged = MeetingTags.normalized((meetings[index].tags ?? []) + [tag])
            guard merged != meetings[index].tags else { continue }
            meetings[index].tags = merged.isEmpty ? nil : merged
            changed = true
        }
        guard changed else { return }
        persistMeetings()
    }

    /// Removes one tag from every meeting in the selection, matched case-insensitively so it agrees
    /// with `MeetingTags.normalized`'s own de-duplication rule.
    func removeTag(_ tag: String, from ids: [UUID]) {
        guard mutationIsAllowed() else { return }
        let target = Set(ids)
        let needle = tag.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !needle.isEmpty else { return }
        var changed = false
        for index in meetings.indices where target.contains(meetings[index].id) {
            guard let existing = meetings[index].tags else { continue }
            let remaining = existing.filter { $0.lowercased() != needle }
            guard remaining.count != existing.count else { continue }
            meetings[index].tags = remaining.isEmpty ? nil : remaining
            changed = true
        }
        guard changed else { return }
        persistMeetings()
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

    // MARK: - Hand-edited transcripts (F541)

    /// The comparison behind `isTranscriptEdited(_:)`. Injectable only so a test can count how often
    /// it runs; defaults to the formatter's.
    var transcriptEditCheck: (String, [TranscriptSegment]) -> Bool = { text, segments in
        TranscriptFormatter.isEdited(transcriptText: text, segments: segments)
    }

    private struct TranscriptEditInput: Equatable {
        let text: String
        let segments: [TranscriptSegment]
    }

    /// Each meeting's last answer, with the text and lines it was computed from. Not `@Published`:
    /// it is filled from view bodies, and a published write there would schedule another render.
    private var transcriptEditMemos: [UUID: LastValueMemo<TranscriptEditInput, Bool>] = [:]

    /// Whether the user edited `meeting`'s transcript away from the rendering of its lines. When true,
    /// segment-derived overlays (quality flags, marker context) no longer describe the shown text, and
    /// the tools that rebuild the text from the lines refuse.
    ///
    /// Remembered per meeting and worked out again only when the text or the lines change (F541).
    /// The comparison renders the whole transcript, one formatted line per segment, and the
    /// transcript card used to ask from up to eleven places per render — so every Notes keystroke
    /// and every progress update the model published rendered a six-hour transcript that many times.
    /// Keyed on the two values, not on the paths that change them, so no mutation path can leave the
    /// answer stale.
    func isTranscriptEdited(_ meeting: MeetingRecord) -> Bool {
        let memo: LastValueMemo<TranscriptEditInput, Bool>
        if let existing = transcriptEditMemos[meeting.id] {
            memo = existing
        } else {
            memo = LastValueMemo()
            transcriptEditMemos[meeting.id] = memo
        }
        let check = transcriptEditCheck
        return memo.value(for: TranscriptEditInput(text: meeting.transcriptText, segments: meeting.segments)) {
            check($0.text, $0.segments)
        }
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

    /// The one folder a delete may remove: this meeting's own `Recordings/<id>` (F452).
    ///
    /// Inside the library was not enough. F148 #6 kept a delete from leaving the library and, inside
    /// it, excluded only the root — so a `recordingPath` one level deep resolved its "folder" to a
    /// directory everything shares: `Recordings/meeting.wav` to all of `Recordings`, `Models/x` to
    /// the downloaded models, `Recordings/../Runtime/x` to the installed runtime, and a path into
    /// another meeting's folder to that meeting's audio. Each of those was removed whole.
    ///
    /// Derived from `recordingPath`, because that is where the audio actually is, and accepted only
    /// when the folder sits directly in `Recordings` under a name that parses to this meeting's id.
    /// Compared as a `UUID`, not as a string: `FolderRebuild` keeps the folder's own spelling in
    /// `recordingPath`, and `UUID(uuidString:)` reads either case. Anything else returns nil, and the
    /// delete takes the index entry only and leaves the disk alone.
    private func ownRecordingFolder(of meeting: MeetingRecord) -> URL? {
        let folder = recordingURL(for: meeting).deletingLastPathComponent().standardizedFileURL
        let recordings = rootDirectory
            .appendingPathComponent("Recordings", isDirectory: true)
            .standardizedFileURL
        guard folder.deletingLastPathComponent().standardizedFileURL.path == recordings.path,
              UUID(uuidString: folder.lastPathComponent) == meeting.id else { return nil }
        return folder
    }

    /// Deletes one meeting. A wrapper, so there is exactly one delete (F451).
    ///
    /// F190 moved the index save ahead of the folder removal in this method, and the UI never
    /// called it: every delete a user can make goes through `AppModel.deleteMeetings(ids:)` and so
    /// `delete(ids:)`, which kept the old order. Two implementations of one operation is how a fix
    /// reached the copy nobody used, so this no longer has a body of its own to fix.
    func delete(id: UUID) {
        delete(ids: [id])
    }

    /// Delete means delete, after a grace window (F295).
    ///
    /// A deleted meeting's text used to stay in the retained index generations until they aged
    /// out — indefinitely in the high-water generation — which is a privacy expectation the app
    /// broke quietly. It is now scrubbed from every generation and from the backup copy, but not
    /// at once: a deletion is queued, and `processPendingShreds` rewrites the history once the
    /// deletion is older than `shredGracePeriod`. That window is the retention policy's own oldest
    /// anchor, a week, so the undo protection F190 exists for — the 2026-08-14 wipe, or a
    /// select-all-and-delete — is intact for exactly as long as the recovery list would have offered
    /// it, and after that the text is gone rather than pinned forever. *Forget History* remains the
    /// immediate option. Decided 2026-09-17 under the user's delegation; the immediate variant was
    /// tried first and `restoringAGenerationBringsTheLibraryBack` showed what it gave up.
    static let shredGracePeriod: TimeInterval = 604_800

    private var pendingShredURL: URL {
        rootDirectory.appendingPathComponent("meetings.pending-shred.json")
    }

    /// Deleted ids awaiting their shred, keyed by the epoch second of the deletion.
    ///
    /// Read leniently (F498). `UUID(uuidString:)` accepts either case, so a file naming one meeting
    /// in two spellings — hand-edited, or written by something other than this build — holds two
    /// keys for one id, and `Dictionary(uniqueKeysWithValues:)` trapped on it. This getter runs at
    /// every launch, so that file took the app down before any window could say why. The later
    /// deletion time wins: the shred then waits for the later of the two, and waiting loses nothing
    /// where shredding early cannot be taken back.
    private(set) var pendingShreds: [UUID: Int] {
        get {
            guard let data = try? Data(contentsOf: pendingShredURL),
                  let raw = try? JSONDecoder().decode([String: Int].self, from: data)
            else { return [:] }
            return Dictionary(
                raw.compactMap { key, value in UUID(uuidString: key).map { ($0, value) } },
                uniquingKeysWith: max
            )
        }
        set {
            let raw = Dictionary(uniqueKeysWithValues: newValue.map { ($0.key.uuidString, $0.value) })
            if raw.isEmpty {
                try? FileManager.default.removeItem(at: pendingShredURL)
            } else if let data = try? JSONEncoder().encode(raw) {
                try? data.write(to: pendingShredURL, options: .atomic)
            }
        }
    }

    /// Queues the ids for their shred. Never undoes the deletion, and never fails it: the queue file
    /// is best-effort, and a deletion whose queue write is lost is a deletion whose text ages out as
    /// it did before F295, which is the state we are improving on, not a regression from it.
    private func shredFromHistory(_ ids: [UUID], now: Int = Int(Date().timeIntervalSince1970)) {
        // The edited-check memo holds a copy of each transcript it answered for (F541). Every path
        // that deletes a meeting comes through here, so its copy goes at once rather than at quit.
        for id in ids { transcriptEditMemos[id] = nil }
        var pending = pendingShreds
        for id in ids { pending[id] = now }
        pendingShreds = pending
    }

    /// Shreds every queued deletion older than the grace window from the retained history and the
    /// backup copy. Idempotent; called at launch by `performStartupRecovery` and after each delete.
    /// Returns the ids shredded.
    ///
    /// Two things are settled before anything is due (F498), and both are written back even when
    /// nothing is:
    ///
    /// - **A queued id that is a live meeting again is cancelled, not shredded.** The grace window
    ///   exists so a mistaken delete can be undone, and every undo — restoring a generation from
    ///   the recovery list, restoring a backup (which does not carry this queue, so the live one
    ///   survives it), or a rebuild or recovery that finds the meeting's folder still on disk —
    ///   brings the meeting back under its old id without touching this file.
    ///   Shredding it anyway stripped a live meeting from every generation that held it, which is
    ///   the undo protection taken away from exactly the meeting the user had just rescued. Checked
    ///   here rather than in each restore path because this is the only place a shred happens, so
    ///   no future route back can miss it.
    /// - **A deletion dated in the future is re-dated to now.** A wrong clock or a foreign file
    ///   would otherwise defer the shred until that date — for `Int.max`, forever — and deferring
    ///   forever is its own failure: the text stays in the history the user was told it would
    ///   leave. Re-dating bounds the wait at one grace period from when it is first seen.
    ///
    /// Due is decided against a cutoff rather than as `now - deletedAt`, which trapped on a deletion
    /// time near `Int.min` — at every launch, like the getter's duplicate keys.
    @discardableResult
    func processPendingShreds(now: Int = Int(Date().timeIntervalSince1970)) -> [UUID] {
        guard !isDegraded else { return [] }   // F187: no rewrite of a library we could not read
        let stored = pendingShreds
        let live = Set(meetings.map(\.id))
        var pending: [UUID: Int] = [:]
        for (id, deletedAt) in stored where !live.contains(id) {
            pending[id] = min(deletedAt, now)
        }
        if pending != stored { pendingShreds = pending }
        let (cutoff, overflowed) = now.subtractingReportingOverflow(Int(Self.shredGracePeriod))
        // An overflowed cutoff means a `now` near `Int.min`; nothing is due then, which defers.
        let due = pending.filter { !overflowed && $0.value <= cutoff }.map(\.key)
        guard !due.isEmpty else { return [] }
        let gone = Set(due)
        do {
            let rewritten = try meetingFiles.rewriteHistory { records in
                let kept = records.filter { !gone.contains($0.id) }
                return kept.count == records.count ? nil : kept
            }
            if !rewritten.isEmpty {
                // `rewriteHistory` ended with an ordinary save of the live value to rotate the
                // backup; adopt its generation so the next save's compare-and-swap sees it.
                if let current = try? meetingFiles.load() { meetingsToken = current.token }
                persistCommitCount += 1
            }
            var remaining = pending
            for id in due { remaining.removeValue(forKey: id) }
            pendingShreds = remaining
            return due
        } catch {
            storageErrorMessage = "A deleted meeting's text could not be removed from the saved index history: \(error.localizedDescription) Settings → Meeting library → Forget History removes all of it."
            return []
        }
    }

    /// Deletes meetings: one read-only check, one index write for the whole selection (F199), and
    /// the index saved BEFORE any recording folder is removed (F190, F451). Returns the ids whose
    /// deletion stands.
    ///
    /// The order is the point. Removing the folders first meant a save that then failed — a full
    /// disk, a permissions change, a second running copy writing first — left an index that still
    /// listed every meeting while their audio was already gone, and the integrity sweep reported
    /// each one missing at the next launch. So the entries leave the index first; if that save fails
    /// nothing has been touched, and memory is put back to match the index still on disk.
    ///
    /// Per record: the read-only guard runs before anything else (F187), and the only folder ever
    /// removed is the meeting's own `Recordings/<id>` (`ownRecordingFolder(of:)`, F452) — for any
    /// other `recordingPath` only the index entry goes and the message says so. No notes-sidecar
    /// hook: the sidecar lives in the recording folder, which dies with the meeting.
    @discardableResult
    func delete(ids: [UUID]) -> [UUID] {
        guard mutationIsAllowed() else { return [] }
        var doomed: [MeetingRecord] = []
        var seen: Set<UUID> = []
        for id in ids where seen.insert(id).inserted {
            if let meeting = meeting(id: id) { doomed.append(meeting) }
        }
        guard !doomed.isEmpty else { return [] }

        // Classified before anything changes, so the save below is the first effect.
        var folders: [UUID: URL] = [:]
        var entryOnly = 0
        for meeting in doomed {
            if let folder = ownRecordingFolder(of: meeting) {
                folders[meeting.id] = folder
            } else {
                entryOnly += 1
            }
        }

        let before = meetings
        let removing = Set(doomed.map(\.id))
        meetings.removeAll { removing.contains($0.id) }
        guard persistMeetings() else {
            // Nothing was destroyed. `persistMeetings()` has already explained the failure.
            meetings = before
            return []
        }

        // The index no longer references these folders, so a failure below destroys nothing that
        // is still listed — and putting the entry back is a true rollback (F146: don't half-delete).
        var kept: [MeetingRecord] = []
        for meeting in doomed {
            guard let directory = folders[meeting.id] else { continue }
            do {
                try removeRecordingDirectory(directory)
            } catch {
                kept.append(meeting)
            }
        }
        let keptIDs = Set(kept.map(\.id))
        let removed = doomed.map(\.id).filter { !keptIDs.contains($0) }
        if !kept.isEmpty {
            let gone = Set(removed)
            meetings = before.filter { !gone.contains($0.id) }
            // If this restoring save also fails, the kept folders are merely unindexed, which
            // `orphanedRecordings()` finds and can re-adopt; the save's own message stands then,
            // because "changes could not be saved" is the more accurate thing to report.
            if persistMeetings() {
                storageErrorMessage = Self.batchDeleteFailureMessage(kept.map(\.title))
            }
        } else if entryOnly > 0 {
            storageErrorMessage = Self.entryOnlyDeleteMessage(count: entryOnly)
        }
        if !removed.isEmpty {
            shredFromHistory(removed)
            processPendingShreds()
        }
        return removed
    }

    private static func batchDeleteFailureMessage(_ titles: [String]) -> String {
        let names = titles.map { "“\($0)”" }.joined(separator: ", ")
        return "\(titles.count) meeting(s) could not have their recordings removed, so they were kept to avoid an inconsistent library: \(names)."
    }

    /// For a delete that removed index entries only, because the recording path did not name the
    /// meeting's own folder (F452) — outside the library, empty, or a directory other things share.
    private static func entryOnlyDeleteMessage(count: Int) -> String {
        count == 1
            ? "This meeting's recording path did not point to its own recording folder, so no files were deleted from disk; the meeting was removed from the list."
            : "\(count) meetings had a recording path that did not point to their own recording folder, so no files were deleted from disk for them; they were removed from the list."
    }

    /// Forgets the retained index history now — the immediate counterpart to the automatic shred
    /// (F239, F295).
    ///
    /// Deleting a meeting removes its recording folder at once; its title, transcript, notes and
    /// summary stay in the retained generations under `meetings.history/` and in the backup copy for
    /// `shredGracePeriod` (a week), so a mistaken delete can be undone, and `processPendingShreds`
    /// then removes them from every generation automatically. This command does not wait: it removes
    /// every generation and conflict branch at once, for every meeting. It does not rewrite
    /// `meetings.backup.json`, the previous generation, so a meeting deleted by the most recent save
    /// is still there until the next save rotates it out.
    ///
    /// **It discards F190's undo protection for the whole library**, not just for deleted meetings,
    /// which is why it is a separate command the caller must describe as such. (This comment used to
    /// say a deleted meeting's text could stay in the history for good unless this ran; F295 made
    /// the per-meeting removal automatic, and F450 corrected the comment.) Returns how many
    /// generations were removed, so the UI can report what happened
    /// rather than claim success; a failure sets `storageErrorMessage` and returns nil, because a
    /// privacy command that reports erasure it did not achieve is worse than one that fails loudly.
    @discardableResult
    func forgetIndexHistory() -> Int? {
        do {
            let forgotten = try meetingFiles.forgetHistory()
            storageErrorMessage = nil
            return forgotten.count
        } catch {
            storageErrorMessage = "The saved history could not be removed: \(error.localizedDescription)"
            return nil
        }
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
        if prioritizedVocabulary.contains(term) {
            prioritizedVocabulary.remove(term)
            persistVocabularyPriority()
        }
    }

    // MARK: - Which terms are sent first (F300)

    private var vocabularyPriorityURL: URL {
        rootDirectory.appendingPathComponent("vocabulary.priority.json")
    }

    /// Stars or unstars `term`. A starred term goes to the recognizer before the rest, so when the
    /// list exceeds the prompt budget it is something else that gets trimmed.
    ///
    /// Kept beside `vocabulary.json` rather than in it: that file is a bare `[String]` every shipped
    /// build reads, and a star is advisory — lose the side file and the prompt is simply in
    /// collation order again, which is what it was before this existed.
    func setVocabularyPriority(_ term: String, prioritized: Bool) {
        guard mutationIsAllowed() else { return }
        if prioritized {
            guard vocabulary.contains(term) else { return }
            prioritizedVocabulary.insert(term)
        } else {
            prioritizedVocabulary.remove(term)
        }
        persistVocabularyPriority()
    }

    private func persistVocabularyPriority() {
        if prioritizedVocabulary.isEmpty {
            try? FileManager.default.removeItem(at: vocabularyPriorityURL)
        } else if let data = try? JSONEncoder().encode(prioritizedVocabulary.sorted()) {
            try? data.write(to: vocabularyPriorityURL, options: .atomic)
        }
    }

    private func loadVocabularyPriority() {
        guard let data = try? Data(contentsOf: vocabularyPriorityURL),
              let stored = try? JSONDecoder().decode([String].self, from: data) else { return }
        // A star for a term that is no longer in the list is dropped rather than resurrected.
        prioritizedVocabulary = Set(stored).intersection(vocabulary)
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

    /// Dismisses a transient storage message. While the library is read-only this restores the
    /// standing explanation instead of clearing it (F194): the banner is the only persistent sign
    /// the library cannot be written, and an unguarded dismissal hid that until the next refused
    /// mutation set it again — leaving the user in a read-only library with nothing on screen
    /// saying so.
    /// Unconditional, and that is F313's fix. F194 made this restore the read-only explanation
    /// while degraded so that "dismissing the banner" would not hide it — but the only thing that
    /// renders `storageErrorMessage` is the window's modal `.alert`, presented whenever this is
    /// non-nil, so the alert reopened the instant it closed and every recovery control sat behind
    /// it. The standing explanation is `AppModel.libraryReadOnlyFootnote`, rendered by a banner
    /// that is not modal, the Settings library section and the Improve menu.
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
    private static func promptSafeTerms(_ values: [String], first: Set<String> = []) -> [String] {
        let sorted = Array(Set(values.map(normalizeTerm).filter { !$0.isEmpty }))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
        // F300: starred terms lead, each group still in collation order, so both budgets below
        // (and `VocabularyPrompt`'s token budget after them) trim the unstarred tail first.
        let candidates = sorted.filter(first.contains) + sorted.filter { !first.contains($0) }
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

    /// Returns whether the index actually reached disk, so a caller that is about to destroy
    /// something the index references can refuse to (F190). Callers that only mutate metadata can
    /// keep ignoring it.
    @discardableResult
    private func persistMeetings() -> Bool {
        // `persistCount` keeps its original position and meaning — "a save was attempted" — because
        // roughly fifteen existing assertions depend on both (F190).
        persistCount += 1
        do {
            let outcome = try meetingFiles.save(meetings, expecting: meetingsToken)
            meetingsToken = outcome.token
            persistCommitCount += 1
            unsavedChanges = false
            writeConflict = nil
            storageErrorMessage = nil
            return true
        } catch {
            unsavedChanges = true
            writeConflict = WriteConflictReport(error)
            storageErrorMessage = "Meeting changes could not be saved. The recording files and last readable index copy remain on this Mac. \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    private func persistVocabulary() -> Bool {
        do {
            let outcome = try vocabularyFiles.save(vocabulary, expecting: vocabularyToken)
            vocabularyToken = outcome.token
            storageErrorMessage = nil
            return true
        } catch {
            unsavedChanges = true
            writeConflict = WriteConflictReport(error)
            storageErrorMessage = "Vocabulary changes could not be saved. The last readable copy remains on this Mac. \(error.localizedDescription)"
            return false
        }
    }

    @discardableResult
    private func persistReplacementRules() -> Bool {
        do {
            let outcome = try replacementRulesFiles.save(
                replacementRules, expecting: replacementRulesToken
            )
            replacementRulesToken = outcome.token
            storageErrorMessage = nil
            return true
        } catch {
            unsavedChanges = true
            writeConflict = WriteConflictReport(error)
            storageErrorMessage = "Replacement-rule changes could not be saved. The last readable copy remains on this Mac. \(error.localizedDescription)"
            return false
        }
    }

    /// Every retained index generation, newest first, for a recovery list (F190).
    ///
    /// Readable while the library is degraded — it reads and reports, and changes nothing.
    func indexGenerations() throws -> [RetainedGeneration] {
        try meetingFiles.retainedGenerations()
    }

    /// Brings a retained generation back as the current index (F190).
    ///
    /// **The one mutator that works while the library is read-only,** and deliberately so. Every
    /// other mutator is refused when `health` is not `.complete`; a recovery action refused for the
    /// same reason would leave exactly the dead end F193 was filed for — a library that explains it
    /// is damaged and offers no way out. It is safe to allow because it does not trust the in-memory
    /// value at all: the bytes come off disk, are verified against the fingerprint in their own file
    /// name, and are decoded before anything is installed.
    ///
    /// Append-only, through the ordinary write algorithm, so the generation being replaced stays on
    /// disk and the restore is itself undoable.
    func restoreIndexGeneration(_ generation: RetainedGeneration) throws {
        guard !isRestoringLibrary else { throw MeetingStoreError.libraryIsBeingRestored }
        adoptRestoredIndex(try meetingFiles.restore(generation: generation))
    }

    /// Installs an index rebuilt from the recording folders as the current one (F289, F191 E4).
    ///
    /// **The second mutator that works while the library is read-only**, and the decision to have
    /// one is F289's. It is allowed for the same reason `restoreIndexGeneration` is: nothing in
    /// memory is trusted. The records come from `FolderRebuild.propose`, which reads the folders
    /// on disk and nothing else, and the user has reviewed them before this is called. What makes
    /// it safe is the write, not the source: it goes through the same append-only algorithm as a
    /// restore — `expecting:` the current generation, so it loses a race with a live sibling
    /// writer like any other write — so the damaged index it replaces stays on disk, and this is
    /// itself undoable through the restore list.
    ///
    /// F252 closed `wontfix` because this operation "rewrites the index of an already-damaged
    /// library" behind a bespoke path. This is not that path: the proposal, the review, the
    /// pre-existing generation and the tested reload are all slice E2's.
    func installRebuiltIndex(_ meetings: [MeetingRecord]) throws {
        guard !isRestoringLibrary else { throw MeetingStoreError.libraryIsBeingRestored }
        let current = try? meetingFiles.load()
        adoptRestoredIndex(try meetingFiles.save(meetings, expecting: current?.token))
    }

    /// What every degraded-mode index write does after the bytes are down, shared so the two
    /// cannot drift.
    private func adoptRestoredIndex(_ outcome: BackupJSONStore<[MeetingRecord]>.SaveOutcome) {
        meetingsToken = outcome.token
        persistCommitCount += 1
        // Re-read rather than decoding into memory a second time, so `meetings` and the ordering
        // come from exactly the bytes that are now on disk — and re-evaluate health, so a successful
        // restore actually returns the library to a writable state (F193). Before this, restore
        // brought the records back and left every mutator still refusing, because `health` only ever
        // worsened: the user completed a recovery and their next edit vanished silently.
        revalidateHealth()
        writeConflict = nil
        unsavedChanges = false
        // Only when the library really is writable again. Clearing this unconditionally asserted
        // "no storage problem" about a library the reload had just found still unreadable.
        if !isDegraded {
            storageErrorMessage = nil
        }
    }

    /// Recomputes `health` from all three persisted stores, exactly as `init` does (F193).
    ///
    /// This is the **only** place `health` is assigned outside `degrade(to:)`, and the reset is safe
    /// only because all three loads run immediately after it. `degrade`'s refusal to improve exists
    /// because one shared value gates three files, and its own comment gives the failure a plain
    /// assignment causes: "a perfectly readable `vocabulary.json` loading after a corrupt
    /// `meetings.json` puts `.complete` back and silently re-opens every mutator on a library that
    /// cannot be read". That hazard is a *partial* update. Here the invariant is preserved by
    /// restating it — after these three calls `health` is again the worst state any store currently
    /// loads to, not the worst it ever reached. A store that is still broken degrades it right back,
    /// so recovery cannot whitewash a library that is still unreadable.
    ///
    /// Only recovery may call this. Nothing on a save path should reconsider health.
    private func revalidateHealth() {
        health = .complete
        // Cleared with `health`, and for the same reason: these describe the state being replaced.
        // The three loads append to this as they go, so without the reset a recovery would leave the
        // launch-time "read-only" message sitting in front of whatever the reload actually found —
        // and `AppModel.performStartupRecovery`, which re-runs after a successful recovery, reads
        // exactly this array.
        startupRecoveryMessages = []
        loadMeetings()
        loadVocabulary()
        loadVocabularyPriority()
        loadReplacementRules()
    }

    /// Re-reads every index from disk after a whole-library restore (F191 slice E3).
    ///
    /// `restoreIndexGeneration` above restores ONE index through the write algorithm and then
    /// revalidates. A backup restore replaces all three indexes and the recordings underneath them
    /// by copying files directly, so there is no write algorithm involved and nothing has told this
    /// object that what it holds in memory is now stale.
    ///
    /// Goes through `revalidateHealth` for the reason F193 documents: without it a restore brings
    /// the records back and leaves every mutator refusing, because `health` only ever worsened, and
    /// the user's next edit vanishes silently. Re-evaluating also means a restore that landed a
    /// still-broken index degrades right back rather than reporting success.
    ///
    /// Same constraint as `revalidateHealth` itself: only recovery may call this. Nothing on a save
    /// path should reconsider health.
    func reloadAfterLibraryRestore() {
        revalidateHealth()
        writeConflict = nil
        unsavedChanges = false
    }

    /// Holds every change to the library until `endLibraryRestore()` (F506).
    ///
    /// Pending debounced edits are written first, so the pre-restore snapshot — taken next, by the
    /// restore itself — holds the user's last keystrokes instead of dropping them.
    func beginLibraryRestore() {
        flushPendingEdits()
        isRestoringLibrary = true
    }

    /// Lets go of the library after a restore, whether it succeeded or failed. The refusal notice a
    /// blocked change left behind goes with it, because it describes a state that has ended.
    func endLibraryRestore() {
        isRestoringLibrary = false
        if storageErrorMessage == Self.changeRefusedDuringRestore {
            storageErrorMessage = nil
        }
    }

    /// Re-reads the library after a lost race, so the next save can succeed.
    ///
    /// A conflict is a transient race, not a damaged library: nothing was made read-only, and the
    /// refused body is on disk as a `conflict-` branch. This discards the in-memory edit in favour
    /// of what is actually on disk — the caller is expected to have shown the user their choice
    /// first, which is what `writeConflict` is for.
    func reloadForConflictRecovery() {
        loadMeetings()
        writeConflict = nil
        unsavedChanges = false
        storageErrorMessage = nil
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

    /// A name the user can look for inside the quarantined copy. Never fails — a record too damaged
    /// to identify is simply another parked record, and losing its name must not cost the records
    /// around it (F187).
    ///
    /// **Title first, then the short id (F197).** This preferred the bare UUID, which tells the user
    /// nothing they can act on: they are being asked to find a meeting inside a quarantined JSON
    /// file, and what they remember is "Budget review", not `6F1A0000-…`. The first eight characters
    /// of the id stay alongside the title because that is the string they would actually grep for
    /// once the file is open — dropping it would trade one unusable name for another.
    nonisolated private static func parkedIdentifier(for element: Any, at index: Int) -> String {
        let position = "record at index \(index)"
        guard let object = element as? [String: Any] else { return position }
        let title = (object["title"] as? String).flatMap { $0.isEmpty ? nil : $0 }
        let shortID = (object["id"] as? String).flatMap { $0.isEmpty ? nil : String($0.prefix(8)) }
        switch (title, shortID) {
        case let (title?, shortID?): return "\(title) (\(shortID))"
        case let (title?, nil): return title
        // An id with no title: describe it rather than printing a raw UUID on its own, so the
        // sentence still reads as being about a meeting.
        case let (nil, shortID?): return "untitled meeting (\(shortID))"
        case (nil, nil): return position
        }
    }

    /// How many parked records to name before counting the remainder (F197).
    ///
    /// A wholly-corrupt index can park hundreds, and naming every one turns an actionable message
    /// into a wall of text. The names exist so a user can recognise what to look for, and past a
    /// handful they stop doing that.
    private static let parkedNamesToList = 5

    /// The startup message for a partially salvaged index (F197).
    ///
    /// It used to render only the count — "N meeting record(s) could not be read" — while the store
    /// held the identifiers all along. The user was told something was missing and given no way to
    /// tell what, and since salvage became reachable for the meeting index that sentence is the only
    /// thing they see.
    static func partialSalvageMessage(parked: [String]) -> String {
        let count = parked.count
        let noun = count == 1 ? "1 meeting record" : "\(count) meeting records"
        let listed = parked.prefix(parkedNamesToList)
        let remainder = count - listed.count
        var named = listed.joined(separator: ", ")
        if remainder > 0 { named += ", and \(remainder) more" }
        return """
        \(noun) could not be read and were left in the preserved copy: \(named). \
        The rest of the library loaded. Nothing was written.
        """
    }

    private func loadMeetings() {
        do {
            guard let result = try meetingFiles.load() else { return }
            meetings = MeetingOrdering.sorted(result.value)
            // A reload replaces every record, so no memo can describe one (F541): a meeting a
            // restore removed would otherwise keep its transcript copy in memory until quit.
            transcriptEditMemos.removeAll()
            meetingsToken = result.token
            degrade(to: result.health)
            if case .recoveredFromBackup = result.health {
                startupRecoveryMessages.append(
                    "The meeting index was damaged, so WhisperMeet loaded the previous readable backup, which may be one save behind. Nothing was written and no recording folders were deleted — confirm the library looks right before editing."
                )
            }
            if case let .partiallySalvaged(parked) = result.health {
                startupRecoveryMessages.append(Self.partialSalvageMessage(parked: parked))
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
            vocabularyToken = result.token
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
            replacementRulesToken = result.token
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
