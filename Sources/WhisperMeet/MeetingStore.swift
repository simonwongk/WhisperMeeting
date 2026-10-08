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
    /// with a confident-looking reason. `shredHistory` does not stamp either, for the same rule
    /// aimed at evidence: it rewrites *retained generations*, and restamping one would make a
    /// snapshot claim a version it was never written under — and since F552 it never re-encodes
    /// one, so a newer build's marker stays beside the fields it describes.
    ///
    /// **Except the one direction a save does change the content (F552).** A record a NEWER build
    /// wrote reaches this build's encoder without the fields this build does not know. Keeping the
    /// newer number there is the wrong marker this comment calls worse than none, so `SchemaMarker`
    /// writes the smaller of the two. Memory keeps what was read — the marker is data, not a gate —
    /// and a record at or below this build's version is written exactly as it was.
    ///
    /// The lowered marker is exact only for a newer schema that ADDS fields. One that changes what an
    /// existing field means passes through this build unchanged, so a lowered record can already
    /// hold values in the newer form: a future migration keyed on `schemaVersion < N` must therefore
    /// be idempotent over values already in form N (review of F552).
    var schemaVersion: Int? {
        get { schemaMarker?.version }
        set { schemaMarker = newValue.map(SchemaMarker.init) }
    }

    /// The stored form of `schemaVersion`, under the same on-disk key (F552). A type of its own
    /// only so its encoding can lower a newer build's marker without a hand-written encoder for the
    /// whole record — a second list of every field is exactly what F304 showed goes stale.
    private var schemaMarker: SchemaMarker? = SchemaMarker(MeetingRecord.currentSchemaVersion)

    struct SchemaMarker: Codable, Equatable, Sendable {
        let version: Int

        init(_ version: Int) {
            self.version = version
        }

        init(from decoder: Decoder) throws {
            version = try decoder.singleValueContainer().decode(Int.self)
        }

        /// The only place the marker's value decides anything, and what it decides is what this
        /// writer vouches for, never how a reader treats the record (`markerIsNeverReadToMakeADecision`).
        func encode(to encoder: Encoder) throws {
            var container = encoder.singleValueContainer()
            try container.encode(min(version, MeetingRecord.currentSchemaVersion))
        }
    }

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
    /// A plain-language note when a summary's language or Chinese script disagrees with its
    /// transcript's (F467 Part 2) — `LanguageConsistency.summaryMismatchWarning`. Optional so old
    /// indexes decode; nil when there is no summary yet or the two agree. Recomputed on every
    /// summarize (including a re-summarize), never left over from a previous summary — a stale
    /// warning about text the user can no longer see is worse than none.
    var summaryLanguageWarning: String?
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
    /// The publisher's own captions for a link-imported meeting, parsed to segments and stored for a
    /// future caption comparison — never the transcript itself, and never a source of speaker identity
    /// (`SubtitleParser` strips speaker labels). Nothing reads this yet: no view shows it, and Second
    /// Opinion compares engine against engine without it (F491). Optional so old indexes decode (F183).
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
        summaryLanguageWarning: String? = nil,
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
        self.summaryLanguageWarning = summaryLanguageWarning
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
        // F552: stored as `schemaMarker`, written under the key every build has always used.
        case schemaMarker = "schemaVersion"
        case id, title, createdAt, duration, recordingPath, status, transcriptText
        case languageCode, confidence, segments, errorMessage, summary, transcriptNormalized
        case markers, pinned, notes, tags, healthReport, alignmentWarning, recoveryWarning
        case languageWarning, source, referenceSegments
        // F467 Part 2: a summary-vs-transcript language/script mismatch note, added after the
        // `MeetingRecordWireFormatTests` guard existed — that test is what makes listing it here
        // non-optional rather than a step somebody could forget.
        case summaryLanguageWarning
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
    /// Why the library is read-only, in words that are true of EVERY state it can be read-only in
    /// (F540). It said "could not fully read", which is false when the index read cleanly as empty
    /// (`.suspectEmpty`) and when two readable versions were found (`.divergentGenerations`). This is
    /// the sentence the refusals share, so it cannot say what happened — `found(_:)` in
    /// `LibraryHealthNotice.swift` does that, per state, for the surfaces that can. "WhisperMeet"
    /// stays capitalized when this is embedded mid-sentence: it is a product name, not a word to be
    /// case-folded.
    static let lead = "WhisperMeet cannot be sure its meeting library is complete, so it is open in read-only mode."
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

    // The Settings section's sentence and the standing banner (F313) are not constants any more: they say
    // what was found, so they are `librarySectionNotice(for:)` and `banner(for:)` in
    // `LibraryHealthNotice.swift`, built from the store's health (F540).

    /// For the library check, which reads the index it is reporting on (F194). Reporting "no audio
    /// problems were found" for a library that failed to decode is a clean bill of health for an
    /// index nobody managed to read.
    static let integrityCheckDeclined =
        "\(lead) The library check cannot report on an index it could not read, so nothing was checked. Your recordings are untouched."

    /// Beside the disabled Forget History button (F457). The saved history is what Recover Library
    /// restores from, which is the one moment it must not be forgotten.
    static let forgetHistoryUnavailable =
        "Forget History is unavailable while the library is read-only: the saved history is what Recover Library restores from."

    /// Beside the disabled Remove buttons of the restore safety copies (F855), and as the refusal
    /// if one is pressed anyway. A safety copy is the library a restore replaced, which may be the
    /// way back for a library that cannot be read.
    static let restoreSnapshotRemovalUnavailable =
        "Safety copies kept by restores cannot be removed while the library is read-only: one of them may be how it is put back."

    /// The one sentence shape every pre-action refusal shares. Private so the surfaces above stay the
    /// only vocabulary callers see.
    private static func refused(_ action: String, resolution: String) -> String {
        "\(action) cannot start because \(lead) Your existing recordings are untouched — resolve recovery \(resolution)."
    }
}

/// Forget History's caption, dialog and result, generated from what is on disk (F457).
///
/// The caption used to promise that "a mistaken delete can still be undone" during the week a
/// deleted meeting stays in the history. Nothing in a healthy library offers that undo: Recover
/// Library, which restores from the history, appears only while the library cannot be read, and
/// refuses otherwise. Corrected to what the week is for — the user's answer of 2026-09-24 to F457
/// was to correct the caption rather than add a "Recently deleted" restore. The dialog said nothing
/// was lost while deleting the only copy of a conflict's losing save, and did not mention the
/// index's other copies; both are now counted from disk rather than asserted.
enum ForgetHistoryNotice {
    static let caption = "Deleting a meeting removes its recording at once. Its title, transcript and notes stay in the saved index history for a week and are then removed. That history is what Recover Library restores from if the library can no longer be read; there is no undo in WhisperMeet for deleting a meeting. Forget History removes the saved history now, without waiting. Your meetings and recordings are not touched."

    static func dialogMessage(_ inventory: MeetingStore.ForgetHistoryInventory) -> String {
        var text = "This deletes the earlier copies of your meeting index that Recover Library restores from, including any deleted meeting's title, transcript and notes still in them. Your meetings, recordings and current index are not touched, and the index's backup copy stays until your next save replaces it."
        var kept: [String] = []
        if inventory.conflictCopies > 0 {
            kept.append("\(copies(inventory.conflictCopies, "conflict copy", "conflict copies")) — changes another copy of WhisperMeet saved at the same moment, which exist nowhere else")
        }
        if !inventory.quarantineCopies.isEmpty {
            kept.append("\(copies(inventory.quarantineCopies.count, "copy set aside", "copies set aside")) when the index could not be read")
        }
        if !inventory.preRestoreSnapshots.isEmpty {
            kept.append("\(copies(inventory.preRestoreSnapshots.count, "copy kept by a restore", "copies kept by restores"))")
        }
        if !kept.isEmpty {
            text += " It keeps what you may still need to recover from: \(kept.joined(separator: "; ")). They also hold meeting text, and stay in the library folder until you remove them."
        }
        if inventory.conflictCopies > 0 {
            text += " Choose Forget History and Conflict Copies to remove the conflict copies too."
        }
        return text
    }

    static func result(_ outcome: MeetingStore.ForgetHistoryOutcome) -> String {
        var text: String
        if outcome.removedGenerations == 0 && outcome.removedConflictCopies == 0 {
            // "Nothing to forget" is a real and reassuring outcome, and conflating it with "removed
            // 7" would be the kind of small lie that makes a privacy command untrustworthy.
            text = "There was no saved history to remove."
        } else {
            text = "Removed \(copies(outcome.removedGenerations, "saved generation", "saved generations"))"
            if outcome.removedConflictCopies > 0 {
                text += " and \(copies(outcome.removedConflictCopies, "conflict copy", "conflict copies"))"
            }
            text += "."
        }
        var kept: [String] = []
        if outcome.keptConflictCopies > 0 {
            kept.append("\(copies(outcome.keptConflictCopies, "conflict copy", "conflict copies")) in meetings.history")
        }
        kept += outcome.keptQuarantineCopies
        kept += outcome.keptPreRestoreSnapshots
        if !kept.isEmpty {
            text += " Kept in the library folder: \(kept.joined(separator: ", "))."
        }
        return text
    }

    private static func copies(_ count: Int, _ one: String, _ many: String) -> String {
        count == 1 ? "1 \(one)" : "\(count) \(many)"
    }
}

/// What a damaged vocabulary or replacement-rule file means, in the user's words (F464).
///
/// Separate from `ReadOnlyLibraryNotice` on purpose. That one says the library is read-only, and a
/// damaged list no longer makes it so; saying it anyway would send the user to Recover Library,
/// which restores meeting indexes and cannot clear this — the dead end F464 was filed for. Each
/// sentence names the file, what the list on screen now is, what happened to the damaged bytes,
/// and the one control that clears it.
enum DamagedListNotice {
    /// The standing notice, or nil for a list that loaded cleanly. `libraryIsWritable: false`
    /// drops the tail naming the control and saying recording is unaffected, because while the
    /// meeting library is read-only neither is true.
    static func notice(
        for list: MeetingStore.EditableList,
        health: PersistedStoreHealth,
        libraryIsWritable: Bool
    ) -> String? {
        guard let what = description(of: list, health: health) else { return nil }
        guard libraryIsWritable else { return what }
        return "\(what) Editing the \(name(of: list)) is paused until you choose \(actionTitle(for: list, health: health)) in Business Vocabulary, which saves what is shown here as the current copy. Recording and your meetings are not affected."
    }

    /// The control beside the notice. "Keep" when the list on screen came from a file that read,
    /// and "Start" when nothing did and the list is empty — keeping an empty list is starting over,
    /// and the button should say so.
    static func actionTitle(for list: MeetingStore.EditableList, health: PersistedStoreHealth) -> String {
        let loadedSomething = health == .recoveredFromBackup || health == .divergentGenerations
        switch list {
        case .vocabulary: return loadedSomething ? "Keep This List" : "Start a New List"
        case .replacementRules: return loadedSomething ? "Keep These Rules" : "Start a New Rule List"
        }
    }

    /// Set as `storageErrorMessage` when an edit to a damaged list is refused.
    static func refused(_ list: MeetingStore.EditableList, health: PersistedStoreHealth) -> String {
        "Nothing was changed: the \(name(of: list)) is read-only because \(fileName(of: list)) could not be read cleanly. Choose \(actionTitle(for: list, health: health)) in Business Vocabulary to edit it again. Recording and your meetings are not affected."
    }

    private static func name(of list: MeetingStore.EditableList) -> String {
        switch list {
        case .vocabulary: return "vocabulary list"
        case .replacementRules: return "replacement rules"
        }
    }

    private static func fileName(of list: MeetingStore.EditableList) -> String {
        "\(stem(of: list)).json"
    }

    /// Where `BackupJSONStore` retains the list's generations: `<stem>.history`, beside the file.
    private static func historyFolder(of list: MeetingStore.EditableList) -> String {
        "\(stem(of: list)).history"
    }

    private static func stem(of list: MeetingStore.EditableList) -> String {
        switch list {
        case .vocabulary: return "vocabulary"
        case .replacementRules: return "replacement-rules"
        }
    }

    /// Exhaustive with no `default`, like `PersistedStoreHealth.severity`: a new health must be
    /// described here or this stops compiling, rather than silently reading as undamaged.
    private static func description(of list: MeetingStore.EditableList, health: PersistedStoreHealth) -> String? {
        let file = fileName(of: list)
        switch health {
        case .complete:
            return nil
        case .recoveredFromBackup:
            return "\(file) was damaged, so this is its previous saved copy, which may be one change behind. The damaged file has not been changed, and is copied aside before anything replaces it."
        case .divergentGenerations:
            return "\(file) was changed outside WhisperMeet, so this is that edited copy. The version WhisperMeet last saved is still in \(historyFolder(of: list))."
        case let .unreadable(quarantined):
            return quarantined.isEmpty
                ? "\(file) and its backup could not be read, and could not be copied aside, so the list is empty. Nothing was changed on disk."
                : "\(file) and its backup could not be read, so the list is empty. The unreadable files were copied aside as \(quarantined.joined(separator: " and "))."
        case let .unavailable(reason):
            return "\(file) could not be read, so the list is empty. \(reason)"
        case .partiallySalvaged, .suspectEmpty:
            // Neither is produced for a list: no salvage is configured for either, and the empty
            // check is the meeting index's. Said generically rather than dropped, so a list that
            // someday reaches one is still read-only with a reason.
            return "\(file) could not be fully read."
        }
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

    /// A name `removeRestoreSnapshot(named:)` refused: not a `.pre-restore-…` folder directly inside
    /// the library, or a link rather than a folder (F855).
    case notARestoreSnapshot(String)

    var errorDescription: String? {
        switch self {
        case .libraryIsReadOnly:
            return ReadOnlyLibraryNotice.recordingRefused
        case .engineRunIsReadOnly:
            return ReadOnlyLibraryNotice.actionRefused("Transcription")
        case .libraryIsBeingRestored:
            return MeetingStore.changeRefusedDuringRestore
        case let .notARestoreSnapshot(name):
            return "\(name) is not a safety copy a restore made in this library, so it was not removed."
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

    /// The Vocabulary screen's "N of your M terms fit" notice, or nil when every term is sent (F525).
    ///
    /// N is counted over `promptVocabulary` — starred terms first, the list the recognizer is
    /// actually given — and M over every stored term. It used to be worked out from `vocabulary`
    /// itself, which `VocabularyPrompt` capped at its first 100 alphabetically, so past 100 terms
    /// both numbers were wrong: "of your 100" for a list of 5,000, and a fitting count taken over a
    /// different ordering from the one sent.
    var vocabularyCoverageNotice: String? {
        VocabularyPrompt.coverageNotice(
            sending: promptVocabulary, storedCount: vocabulary.count, starredCount: prioritizedVocabulary.count
        )
    }

    /// Exact `heard → preferred` replacement rules (F179), persisted like vocabulary. Reviewed before
    /// any apply — the matcher only proposes; nothing auto-applies and the audio is never touched.
    @Published private(set) var replacementRules: [ReplacementRule] = []
    @Published private(set) var storageErrorMessage: String?
    /// The meeting index's load result (F187). Anything but `.complete` makes the library read-only:
    /// it blocks EVERY mutation, not just persistence, because a mutator's save would overwrite an
    /// index nobody could read and some mutators touch the disk as well — the notes sidecar, a
    /// deleted meeting's audio — and it refuses recording, whose meeting could never be indexed.
    ///
    /// **The meeting index's alone (F464).** This used to be the worst of three loads, the two lists
    /// included, so a torn or hand-edited `vocabulary.json` refused recordings — and Recover Library,
    /// which restores meeting-index generations, could not clear it. Each list now has its own
    /// health, which makes only that list read-only; see `health(of:)`. The reverse still holds: a
    /// read-only library refuses list edits too, because nothing is changed until recovery.
    ///
    /// Only ever assigned through `degrade(to:)` outside `revalidateHealth`, so the meeting index's
    /// two verdicts in `loadMeetings` — its load's, then the suspect-empty check — and a reload that
    /// does not reset first (`reloadForConflictRecovery`) can only ever worsen it.
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

    /// The two lists that load beside the meeting index, each able to be damaged on its own (F464).
    enum EditableList: Sendable {
        case vocabulary
        case replacementRules
    }

    /// Each list's own load result (F464): anything but `.complete` makes that list read-only and
    /// nothing else. Assigned by that list's load, and by `keepLoadedList` once the list it shows has
    /// been saved as its current copy.
    @Published private(set) var vocabularyHealth: PersistedStoreHealth = .complete
    @Published private(set) var replacementRulesHealth: PersistedStoreHealth = .complete

    func health(of list: EditableList) -> PersistedStoreHealth {
        switch list {
        case .vocabulary: vocabularyHealth
        case .replacementRules: replacementRulesHealth
        }
    }

    private(set) var startupRecoveryMessages: [String] = []

    let rootDirectory: URL
    private let meetingFiles: BackupJSONStore<[MeetingRecord]>
    private let vocabularyFiles: BackupJSONStore<[String]>
    private let replacementRulesFiles: BackupJSONStore<[ReplacementRule]>
    /// How long a transcript keystroke waits before its edit is flushed to disk. Coalesces the
    /// per-keystroke full-index rewrite (F40) into one debounced write; tests pass a large value to
    /// prove coalescing and drive the flush explicitly.
    private let transcriptWriteDebounce: TimeInterval
    /// The production default above, named so another type can derive a bound from it instead of
    /// choosing its own timeout (F504): `BackupCoordinator` waits this long before retrying a copy
    /// whose source changed mid-run, because that is exactly how long a pending debounced save can
    /// take to land. `nonisolated`: a plain `Sendable` constant, and both this class's own init
    /// default and `BackupCoordinator` (which is not main-actor-isolated — it runs inside
    /// `Task.detached`) need to read it from a nonisolated context.
    nonisolated static let defaultTranscriptWriteDebounce: TimeInterval = 0.5
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

    /// `meetings` as of this session's own last successful load or persist (F433 follow-up).
    ///
    /// This is what makes `beginConflictRecovery()`'s delta *this session's own unsaved edit*
    /// rather than "everything that differs from the rival" — a record this session never touched
    /// is not this session's business, whatever the rival did to it. Set on every `loadMeetings()`
    /// (a fresh load IS what is persisted, as far as this session knows) and on every successful
    /// `persistMeetings()`. Deliberately never touched by `keepConflictedEdit()` itself except
    /// through the `persistMeetings()` it calls — reapplying an edit does not count as "saved" until
    /// the write actually lands.
    private var lastPersistedMeetings: [MeetingRecord] = []

    /// The generation each store last read or wrote, threaded into the next `save(expecting:)`.
    /// Without these the compare-and-swap never fires.
    private var meetingsToken: GenerationToken?
    private var vocabularyToken: GenerationToken?
    private var replacementRulesToken: GenerationToken?
    private var leaseHandle: LibraryWriterLeaseHandle?

    init(rootDirectory: URL? = nil, transcriptWriteDebounce: TimeInterval = MeetingStore.defaultTranscriptWriteDebounce) {
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
        // and before the three loads. Taken here at launch, re-asked only by `refreshWriterLease()`
        // (F188, F407) — never on a save path. `shared(for:)` and not `acquire`: `flock` attaches to
        // the open file description, so two acquisitions in one process contend, and this store and
        // `DictationLogStore` would lock each other out of the same library and each report the
        // other as a rival application.
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
        let indexed = rootDirectory.appendingPathComponent(meeting.recordingPath)
        // A record that still names a capture's WAV after Shrink replaced it (F795): an older index
        // generation restored by Recover Library, or another copy's stale record. Only those two
        // names, and only when the named file is absent, so the fallback never hides a real file.
        let name = indexed.lastPathComponent
        guard name == "meeting.wav" || name == "meeting-recovered.wav",
              !FileManager.default.fileExists(atPath: indexed.path) else { return indexed }
        let shrunk = indexed.deletingPathExtension().appendingPathExtension("m4a")
        return FileManager.default.fileExists(atPath: shrunk.path) ? shrunk : indexed
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
    /// On the actor it snapshots (`MeetingRecord` is `Sendable`), banks the write count, and
    /// afterwards reconciles any meeting that changed while the pass ran (below).
    ///
    /// The main actor is free while the pass runs, so an edit and its debounced flush can land
    /// first: the flush writes notes.md from the live record, then the pass compares that file with
    /// its own composition of the launch-time snapshot, finds them different, and writes the old
    /// text back (F496). Comparing before writing does not prevent that, because the two sides
    /// compare against different compositions. So once the pass returns, every meeting whose live
    /// record no longer equals its snapshot is queued again and flushed from the live record,
    /// which makes the last write the current one. Meetings deleted meanwhile are skipped. The flush
    /// keeps its own guards: degraded writes nothing, and mid-restore leaves the ids pending (F506).
    func backfillNotesSidecars() async {
        guard !isDegraded else { return }
        let snapshot = meetings
        let written = await notesBackfillPass(snapshot, rootDirectory)
        sidecarWriteCount += written
        let live = Dictionary(meetings.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let changed = snapshot.filter { record in
            guard let current = live[record.id] else { return false }
            return current != record
        }
        guard !changed.isEmpty else { return }
        pendingSidecarIDs.formUnion(changed.map(\.id))
        flushPendingNotesSidecars()
    }

    /// The detached per-meeting pass behind `backfillNotesSidecars`: writes the notes.md of each
    /// snapshot record whose file is stale and returns how many files were written. Injectable only
    /// so a test can land an edit and its flush while the pass is running (F496); defaults to
    /// `runNotesBackfillPass`.
    var notesBackfillPass: @Sendable ([MeetingRecord], URL) async -> Int = { snapshot, root in
        await MeetingStore.runNotesBackfillPass(snapshot, root: root)
    }

    nonisolated static func runNotesBackfillPass(_ snapshot: [MeetingRecord], root: URL) async -> Int {
        await Task.detached(priority: .utility) {
            snapshot.reduce(into: 0) { count, meeting in
                if Self.writeSidecarIfStale(for: meeting, root: root) { count += 1 }
            }
        }.value
    }

    /// The one composition of a meeting's human-readable notes document (F198). The manual Export…
    /// button and the automatic sidecar (debounced flush and detached backfill alike) all route
    /// through here, so none can drift. `nonisolated` so the backfill can compose off the actor.
    /// The date names its UTC offset (`MeetingNotesExporter.dateText`), so a time-zone change
    /// rewrites each sidecar once, visibly, and the Mac's language or 12/24-hour setting no longer
    /// changes the date at all (F568); `timeZone` is injectable only so a test can pin it.
    nonisolated static func composeNotes(for meeting: MeetingRecord, timeZone: TimeZone = .autoupdatingCurrent) -> String {
        MeetingNotesExporter.markdown(
            title: meeting.title,
            dateText: MeetingNotesExporter.dateText(for: meeting.createdAt, timeZone: timeZone),
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

    /// `mutationIsAllowed()`, plus refusing a NEW edit while a lost race's `conflictOffer` is still
    /// outstanding (F433 follow-up, F619).
    ///
    /// Why the person's edits wait for the answer: an edit made now would be made to the other
    /// copy's version of a meeting the banner may be about, and then Keep would put the older offered
    /// copy back over it, or Use the Other Copy would keep it — two questions shown as one. (This
    /// also once kept a second race from happening at all; since F662 a second race is folded into
    /// the outstanding offer instead, because the app's own results are saved meanwhile.)
    ///
    /// Silent by design — `storageErrorMessage` is NOT set here, unlike `mutationIsAllowed()`'s own
    /// refusals: the `WriteConflictBanner` is already visible and already explains why nothing is
    /// saving, and setting a message on every refused keystroke would pop the generic modal
    /// repeatedly while the banner is up, which is the very "second alert" this exists to avoid.
    ///
    /// `keepConflictedEdit()`/`discardConflictedEdit()` deliberately do NOT call this — they are how
    /// the outstanding offer gets resolved, not a new edit to refuse against it. Nor does a
    /// `WriteKind.result` write (F662).
    private func editMutationIsAllowed() -> Bool {
        guard mutationIsAllowed() else { return false }
        return conflictOffer == nil
    }

    /// Who a meeting write is for, which decides whether an outstanding conflict offer holds it back
    /// (F662).
    enum WriteKind: Sendable {
        /// Something the person changed: a title, a tag, a pin, a marker, a transcript edit. Refused,
        /// silently, while a conflict offer is outstanding (`editMutationIsAllowed()`, F619).
        case edit
        /// Work the app finished on its own: a stopped recording, an import, a transcription's status
        /// or its transcript, a summary, a rebuilt recording. Saved even while an offer is
        /// outstanding, because it is true whichever copy the person keeps — and applied to the
        /// offered copy of the same meeting as well, so that neither answer loses it. Refusing it was
        /// F662: Stop pressed while the banner was up left the meeting out of the list, and a
        /// transcript or summary that finished meanwhile was thrown away, all without a word.
        ///
        /// Its mutation may therefore run on two copies of a record, so it must be a function of the
        /// copy it is given. A result never renames a meeting, which is what lets the offer's message,
        /// written when it was made, keep naming the right meetings.
        case result
    }

    /// The gate every meeting write passes, by kind (F662). The library's own refusals — read-only,
    /// mid-restore — hold for both: they are about whether anything may be written at all.
    private func writeIsAllowed(_ kind: WriteKind) -> Bool {
        switch kind {
        case .edit: return editMutationIsAllowed()
        case .result: return mutationIsAllowed()
        }
    }

    /// A result written while an offer is outstanding goes into the offered copy of its meeting too,
    /// so Keep cannot put back a copy from before it (F662). Only a `.result` can reach this with an
    /// offer up; with none it does nothing.
    private func applyToOfferedCopies(of id: UUID, _ mutation: (inout MeetingRecord) -> Void) {
        guard let offer = conflictOffer else { return }
        conflictOffer = offer.applying(mutation, to: id)
    }

    /// `mutationIsAllowed()` for an edit to one list (F464): refused while the library is read-only,
    /// and while that list's own file did not load cleanly — its save would replace the copy the
    /// user has not yet chosen to keep. The same first-statement rule applies.
    private func listMutationIsAllowed(_ list: EditableList) -> Bool {
        guard mutationIsAllowed() else { return false }
        let state = health(of: list)
        guard !state.allowsMutation else { return true }
        storageErrorMessage = DamagedListNotice.refused(list, health: state)
        return false
    }

    /// Whether `list` is read-only because its own file did not load cleanly (F464). The Add
    /// controls read this so typed input is not cleared by an edit that would only be refused.
    func isListReadOnly(_ list: EditableList) -> Bool {
        !health(of: list).allowsMutation
    }

    /// The standing notice for a damaged list, shown beside the control that clears it, or nil
    /// when the list loaded cleanly (F464).
    ///
    /// Nil while the meeting library itself is read-only, too: that state refuses every edit
    /// anyway, has its own notice and its own way out, and a second notice saying recording is
    /// unaffected would contradict it. The list's notice appears once the library is writable.
    func damagedListNotice(for list: EditableList) -> String? {
        guard !isDegraded else { return nil }
        return DamagedListNotice.notice(for: list, health: health(of: list), libraryIsWritable: true)
    }

    /// The title of the control beside `damagedListNotice(for:)`.
    func keepLoadedListTitle(for list: EditableList) -> String {
        DamagedListNotice.actionTitle(for: list, health: health(of: list))
    }

    /// Makes a damaged list writable again by saving what it shows as its current copy (F464).
    ///
    /// The way out, and the reason it is safe to offer: nothing the damage left on disk is lost by
    /// it. A file that did not decode was either copied aside by the load (both copies unreadable)
    /// or is copied aside by this save before anything replaces it — the quarantine step every
    /// save runs (F187). A hand-edited copy is the one kept; its rival, the list this app last
    /// saved, stays in the list's history, because the divergence check only fires when that
    /// generation is still there to choose. Refused while the meeting library is read-only, like
    /// every mutator.
    ///
    /// Health becomes `.complete` only once the save has landed, because only then is the list in
    /// memory the one on disk. A save that fails leaves the list read-only and says why. A save that
    /// loses to another copy re-reads the list (F663): what that copy saved is the list now, and its
    /// own load says whether it still needs keeping. Not reached today: a damaged list's load holds no
    /// generation token (`BackupJSONStore.load` hands none back for anything but a clean primary), so
    /// this save is unchecked and cannot lose a race — it is last-writer-wins.
    func keepLoadedList(_ list: EditableList) {
        guard mutationIsAllowed(), isListReadOnly(list) else { return }
        switch saveList(list) {
        case .saved:
            switch list {
            case .vocabulary: vocabularyHealth = .complete
            case .replacementRules: replacementRulesHealth = .complete
            }
        case let .lostRace(report):
            reloadList(list)
            storageErrorMessage = "\(report.message) The list now shows what the other copy saved."
        case .failed:
            return
        }
    }

    /// - Parameter kind: `.result` for a meeting the app finished on its own — a stopped recording,
    ///   an import — which is saved even while a conflict offer is outstanding (F662).
    func upsert(_ meeting: MeetingRecord, as kind: WriteKind = .edit) {
        guard writeIsAllowed(kind) else { return }
        applyToOfferedCopies(of: meeting.id) { $0 = meeting }
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
        persistMeetingsOrRecover()
        scheduleNotesSidecarWrite(for: meeting.id)
    }

    /// - Parameter kind: `.result` for work the app finished on its own — a transcription's status or
    ///   transcript, a summary, a rebuilt recording — which is saved even while a conflict offer is
    ///   outstanding, and applied to the offered copy of this meeting as well (F662).
    func update(id: UUID, as kind: WriteKind = .edit, _ mutation: (inout MeetingRecord) -> Void) {
        guard writeIsAllowed(kind) else { return }
        applyToOfferedCopies(of: id, mutation)
        guard let index = meetings.firstIndex(where: { $0.id == id }) else { return }
        mutation(&meetings[index])
        // As in `upsert`: the version tracks the content, and the content just changed (F188).
        meetings[index].schemaVersion = MeetingRecord.currentSchemaVersion
        persistMeetingsOrRecover()
        scheduleNotesSidecarWrite(for: id)
    }

    /// Repoints a meeting at a new recording file and reports whether the index save landed (F795).
    ///
    /// Shrink deletes the old audio only after this returns true, so this is shaped like
    /// `delete(ids:)` (F451): the save is the first effect, and a failed save puts the record back. A
    /// lost race re-reads the library without offering the change back, because the shrink removes
    /// its new file when this fails, and "Keep my change" would then re-save a path to nothing.
    func replaceRecordingPath(id: UUID, with relativePath: String) -> Bool {
        guard editMutationIsAllowed() else { return false }
        guard let index = meetings.firstIndex(where: { $0.id == id }) else { return false }
        let before = meetings
        meetings[index].recordingPath = relativePath
        meetings[index].schemaVersion = MeetingRecord.currentSchemaVersion
        guard persistMeetings() else {
            meetings = before
            if writeConflict?.isRace == true { beginConflictRecovery() }
            return false
        }
        scheduleNotesSidecarWrite(for: id)
        return true
    }

    /// The save every synchronous mutator makes, with a lost race routed through the same recovery
    /// the debounced path takes (F642).
    ///
    /// F433 wired `beginConflictRecovery()` into `flushPendingEdits()` and Keep's re-save only.
    /// `upsert`, `update` (rename, `setTags`), `addTag`, `removeTag` and `togglePin` called
    /// `persistMeetings()` and ignored a race, so a single lost rename left `meetingsToken` stale
    /// and every later save in the session failed the same compare-and-swap, with only the generic
    /// alert to explain it. An ordinary failure (full disk, permissions) is not a race and is left
    /// exactly as before: the message stands and nothing is reloaded. `delete(ids:)` recovers on
    /// its own, because a lost delete must also put its rows back and say it did not happen.
    @discardableResult
    private func persistMeetingsOrRecover() -> Bool {
        guard !persistMeetings() else { return true }
        if writeConflict?.isRace == true { beginConflictRecovery() }
        return false
    }

    /// Apply a transcript-body edit: update the in-memory record immediately (so the editor stays
    /// live) but coalesce the expensive whole-index write, which otherwise ran on every keystroke
    /// (F40). See `scheduleDebouncedPersist`.
    func editTranscript(id: UUID, text: String) {
        guard editMutationIsAllowed() else { return }
        guard let index = meetings.firstIndex(where: { $0.id == id }) else { return }
        meetings[index].transcriptText = text
        scheduleDebouncedPersist()
        scheduleNotesSidecarWrite(for: id)
    }

    /// Apply a notes edit with the same immediate-in-memory + debounced-write coalescing as the
    /// transcript editor — the notes field had the identical per-keystroke whole-index write (F133).
    /// Empty text clears the field (nil), matching the prior binding.
    func editNotes(id: UUID, text: String) {
        guard editMutationIsAllowed() else { return }
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
        guard !persistMeetings() else { return }
        // A lost race (F433) is not the retryable kind: `meetingsToken` stays stale until something
        // re-reads the library, so re-arming with the SAME token would fail the SAME way every
        // 0.5 s forever — one keystroke became an endless write-and-alert loop. The bound is the
        // debounce cycle that already ran: exactly one attempt fails, then this defers to a person
        // instead of scheduling another. An ordinary failure (full disk, permissions) is not a race
        // and keeps the existing unconditional retry, unchanged.
        guard writeConflict?.isRace == true else {
            scheduleDebouncedPersist()
            return
        }
        beginConflictRecovery()
    }

    /// What this session's own unsaved edit was, kept so it can be offered back rather than dropped
    /// (F433).
    ///
    /// **Defined against `lastPersistedMeetings`, never against the rival's commit** (second
    /// follow-up fix to a review finding: diffing the losing snapshot against the reloaded WINNER —
    /// the first follow-up's approach — pulled in any record the rival's commit merely happened to
    /// disagree with, including one this session never touched, and reapplying that overwrote the
    /// rival's own newer data with this session's stale copy). Diffing against
    /// `lastPersistedMeetings` instead means `delta` is exactly what this session modified since ITS
    /// OWN last successful save — never a record only the rival changed.
    ///
    /// A meeting this session ADDED since then is not in `delta` (F667): the other copy has no
    /// version of it to prefer, so it is not a question. `beginConflictRecovery()` puts it back in the
    /// list and saves it at once (`keptNew`), or, when that cannot happen, holds it in `unsavedNew`,
    /// which both answers save.
    struct ConflictOffer: Equatable {
        /// Records this session modified since its own last successful persist that the rival's
        /// commit still has under the same id. Re-applied by `keepConflictedEdit()` into `meetings`
        /// in memory and saved once as a batch — a per-record merge, never a wholesale array
        /// replacement. `discardConflictedEdit()` drops them.
        let delta: [MeetingRecord]
        /// Meetings this session added — a recording just stopped, an import, a row a delete had to
        /// keep — that neither its last save nor the other copy has, and that could not be saved at
        /// once: the library refused changes, or the other copy saved again in between (F667). Both
        /// answers save them, so neither can drop the meeting that was just recorded — while the
        /// library can be written; while it cannot, both are refused and the message says so.
        let unsavedNew: [MeetingRecord]
        /// The titles of meetings this session added that were put back in the reloaded list at once
        /// (F667) — saved, or, after an ordinary save failure, listed and carried by the next save
        /// while that failure's own message says so. Named in the banner only, so the person knows
        /// neither answer removes them.
        let keptNew: [String]
        /// Records this session had saved and then modified, whose id the rival's commit no longer
        /// has at all — the rival deleted them. Never reapplied: doing so would resurrect a meeting
        /// whose recording folder the rival may already have removed. Kept only so the banner can
        /// name what was not re-applied and why.
        let deletedByOther: [MeetingRecord]
        /// What the caller needed said that the records cannot — a delete that did not happen
        /// (F642). Kept apart from `message` so a later race folded into this offer (F662) says it
        /// again rather than losing it.
        let notes: [String]
        /// The banner's text: the conflict, then which meetings each answer decides (F667).
        let message: String

        /// - Parameter libraryWritable: false when the reload left the library refusing changes, so
        ///   neither answer can save `unsavedNew` now and the banner must not say it will.
        init(
            delta: [MeetingRecord], unsavedNew: [MeetingRecord] = [], keptNew: [String] = [],
            deletedByOther: [MeetingRecord], notes: [String], report: String, libraryWritable: Bool = true
        ) {
            self.delta = delta
            self.unsavedNew = unsavedNew
            self.keptNew = keptNew
            self.deletedByOther = deletedByOther
            self.notes = notes
            message = Self.message(
                report: report, delta: delta, unsavedNew: unsavedNew, keptNew: keptNew,
                deletedByOther: deletedByOther, notes: notes, libraryWritable: libraryWritable
            )
        }

        private init(copying offer: ConflictOffer, delta: [MeetingRecord], unsavedNew: [MeetingRecord]) {
            self.delta = delta
            self.unsavedNew = unsavedNew
            keptNew = offer.keptNew
            deletedByOther = offer.deletedByOther
            notes = offer.notes
            message = offer.message
        }

        /// Whether there is anything for the person to answer: an edit to keep or drop, a meeting
        /// still to save, or a meeting the other copy deleted to be told about. Notes alone, or
        /// meetings already back in the list, are said without a banner.
        var asksAnything: Bool { !delta.isEmpty || !unsavedNew.isEmpty || !deletedByOther.isEmpty }

        /// This offer with `mutation` applied to every offered copy of `id` — a result the app
        /// finished while the offer was up (F662). `deletedByOther` is left alone: it is never
        /// written back, only named. The message is kept: a result never renames a meeting.
        func applying(_ mutation: (inout MeetingRecord) -> Void, to id: UUID) -> ConflictOffer {
            var delta = delta
            for index in delta.indices where delta[index].id == id {
                mutation(&delta[index])
            }
            var unsavedNew = unsavedNew
            for index in unsavedNew.indices where unsavedNew[index].id == id {
                mutation(&unsavedNew[index])
            }
            return ConflictOffer(copying: self, delta: delta, unsavedNew: unsavedNew)
        }

        /// The banner's text (F667). It used to be the conflict alone, so nothing said which
        /// meetings Keep My Edit and Use the Other Copy decide — and "Use the Other Copy" after a
        /// lost save at Stop dropped the recording just made with nothing on screen naming it.
        static func message(
            report: String, delta: [MeetingRecord], unsavedNew: [MeetingRecord], keptNew: [String],
            deletedByOther: [MeetingRecord], notes: [String], libraryWritable: Bool = true
        ) -> String {
            var sentences = [report]
            if !delta.isEmpty {
                sentences.append("Keep My Edit saves your changes to \(names(delta.map(\.title)).text) over the other copy's; Use the Other Copy keeps the other copy's version.")
            }
            if !unsavedNew.isEmpty {
                let new = names(unsavedNew.map(\.title))
                if libraryWritable {
                    sentences.append(new.plural
                        ? "\(new.text) are new in this window and not saved yet; either answer saves them."
                        : "\(new.text) is new in this window and not saved yet; either answer saves it.")
                } else {
                    // Both answers are refused while the library cannot be written. The recording
                    // folder stays on disk, and the startup sweep adopts it once the library can be
                    // written again — after Recover Library, or at the next launch.
                    sentences.append(new.plural
                        ? "\(new.text) are new in this window and cannot be saved while the library cannot be written; their recordings stay on this Mac and are added back once the library is recovered."
                        : "\(new.text) is new in this window and cannot be saved while the library cannot be written; its recording stays on this Mac and is added back once the library is recovered.")
                }
            }
            if !keptNew.isEmpty {
                let kept = names(keptNew)
                sentences.append(kept.plural
                    ? "\(kept.text), new in this window, stay in your list whichever you choose."
                    : "\(kept.text), new in this window, stays in your list whichever you choose.")
            }
            if !deletedByOther.isEmpty {
                let deleted = names(deletedByOther.map(\.title))
                sentences.append(deleted.plural
                    ? "\(deleted.text) were deleted by the other copy; your edits to them were not re-applied."
                    : "\(deleted.text) was deleted by the other copy; your edit to it was not re-applied.")
            }
            return (sentences + notes).joined(separator: " ")
        }

        /// “A”, “B” and “C”, each title once, and past three "and N more" — a batch tag over fifty
        /// meetings would otherwise fill the banner with names. `plural` counts titles, not records,
        /// so the verb agrees with what is printed.
        private static func names(_ raw: [String]) -> (text: String, plural: Bool) {
            var seen = Set<String>()
            let unique = raw.filter { seen.insert($0).inserted }.map { "“\($0)”" }
            switch unique.count {
            case 0, 1: return (unique.first ?? "", false)
            case 2, 3: return (unique.dropLast().joined(separator: ", ") + " and " + unique[unique.count - 1], true)
            default: return (unique.prefix(3).joined(separator: ", ") + " and \(unique.count - 3) more", true)
            }
        }
    }

    /// Set once a lost race's edit is retained for the user to resolve (F433). `nil` the rest of
    /// the time, including while an ordinary (non-race) save failure is being retried.
    @Published private(set) var conflictOffer: ConflictOffer?

    /// Re-reads the library after a lost race instead of leaving the token stale forever, and works
    /// out what THIS SESSION had not yet saved so `conflictOffer` can offer it back (F433). Wires
    /// `reloadForConflictRecovery()` into a real caller for the first time — until this, the only
    /// caller was a test, and every later save in this session failed the same compare-and-swap.
    ///
    /// `persistedByID` is captured BEFORE the reload runs, deliberately: `reloadForConflictRecovery()`
    /// calls `loadMeetings()`, which advances `lastPersistedMeetings` to the just-reloaded (rival's)
    /// state — the right thing for the NEXT race, but exactly the wrong thing to diff THIS one
    /// against, which would collapse back into "diff against the rival" (the bug the delta redesign
    /// fixes).
    ///
    /// A race while an offer is already outstanding is folded into it (F662). Since then the app's
    /// own results are saved while the banner is up, and such a save can lose to another copy that
    /// saved again in between. The offer used to be guarded single — the second race no-opped here,
    /// leaving `writeConflict`, the generic alert and a stale token behind it (F619's original
    /// problem). Folding keeps everything the outstanding offer held, re-judged against the newest
    /// reload, plus whatever the losing save added; and since a result was applied to the offered
    /// copies as well as to the list (`applyToOfferedCopies`), the offered copy of an id is the one
    /// that carries both the person's edit and the result, so it is kept over the list's copy.
    ///
    /// A meeting this session added that neither its last save nor the other copy has — a recording
    /// just stopped, an import, a row a delete had to keep — is not offered at all (F667). The other
    /// copy has no version of it to prefer, and as an offer it was unlisted until the person
    /// answered (so a transcription queued behind Stop found no meeting to run on) and dropped by
    /// "Use the Other Copy". It is put onto the reloaded library and saved now, once. If that save
    /// loses too, the recovery it starts is told not to try again (`savingNewMeetings: false`), and
    /// holds the meeting in `unsavedNew`, which both answers save. When the reload left the library
    /// refusing changes it is held there too, but neither answer can save it then, and the banner
    /// says so: its recording folder stays on disk for the startup sweep to adopt once the library
    /// can be written again.
    ///
    /// Since F642 every synchronous mutator's lost race comes here too. `note` is what the caller
    /// needs said that the snapshot cannot say — a delete that did not happen — and is appended to
    /// the offer's message, or, when there is nothing to offer, becomes the alert.
    private func beginConflictRecovery(note: String? = nil, savingNewMeetings: Bool = true) {
        guard let report = writeConflict else { return }
        let outstanding = conflictOffer
        let losing = meetings
        // Every saved copy of each id, not one. A hand-edited index can hold one id twice, and since
        // F642 any lost save reaches this line. `uniqueKeysWithValues` trapped on that; keeping the
        // first copy (the first F642 cut) made the second copy always "differ from what was saved",
        // so an untouched twin was offered as this session's edit and Keep wrote it over the other.
        let persistedByID = Dictionary(grouping: lastPersistedMeetings, by: \.id)
        // A debounced flush still scheduled would save the reloaded winner for nothing. Whatever it
        // was carrying is in `losing`, so it is offered back below rather than lost with the timer.
        pendingIndexFlush?.cancel()
        pendingIndexFlush = nil
        // Clears `writeConflict`/`unsavedChanges` and puts `storageErrorMessage` back to its resting
        // value (F553's unread notice, else nil — F669) as part of the reload, all
        // within this same synchronous call — SwiftUI observes only the state after this function
        // returns, so the generic "could not be saved" alert never flashes on its way to the banner
        // below, which is the one surface this conflict is meant to be resolved from.
        reloadForConflictRecovery()
        // This session's own edits since its last save — a record it never touched, whatever the
        // rival did to it, is excluded here regardless.
        let ownEdits = losing.filter { !(persistedByID[$0.id]?.contains($0) ?? false) }
        let held = (outstanding?.delta ?? []) + (outstanding?.unsavedNew ?? [])
        let heldIDs = Set(held.map(\.id))
        let candidates = held + ownEdits.filter { !heldIDs.contains($0.id) }
        let notes = (outstanding?.notes ?? []) + (note.map { [$0] } ?? [])
        let winnerIDs = Set(meetings.map(\.id))
        var delta: [MeetingRecord] = []
        var added: [MeetingRecord] = []
        var deletedByOther: [MeetingRecord] = outstanding?.deletedByOther ?? []
        for record in candidates {
            if winnerIDs.contains(record.id) {
                delta.append(record)
            } else if persistedByID[record.id] == nil {
                // Never saved by this session and not in the other copy's commit: added here, and
                // never the other copy's to delete (F642) or to prefer (F667).
                added.append(record)
            } else {
                // Saved by this session, and gone from the other copy's commit: it deleted them.
                deletedByOther.append(record)
            }
        }
        var keptNew = outstanding?.keptNew ?? []
        if !added.isEmpty, savingNewMeetings, !isDegraded, !isRestoringLibrary {
            // Published first, so if this save loses as well the recovery it starts folds in what is
            // still to decide rather than dropping it (F662's fold).
            conflictOffer = ConflictOffer(
                delta: delta, unsavedNew: added, keptNew: keptNew,
                deletedByOther: deletedByOther, notes: notes, report: report.message
            )
            writeBack(added)
            if persistMeetings() {
                keptNew += added.map(\.title)
                added = []
            } else if writeConflict?.isRace == true {
                beginConflictRecovery(savingNewMeetings: false)
                return
            } else {
                // An ordinary failure (a full disk): they stay listed and unsaved, as any change
                // whose save failed does, and the next save carries them. The failure's own message
                // stands; the banner below says they stay either way.
                keptNew += added.map(\.title)
                added = []
            }
        }
        let offer = ConflictOffer(
            delta: delta, unsavedNew: added, keptNew: keptNew,
            deletedByOther: deletedByOther, notes: notes, report: report.message,
            libraryWritable: !isDegraded && !isRestoringLibrary
        )
        guard offer.asksAnything else {
            // Nothing to offer back, so no banner: the one thing left to say goes in the alert,
            // once — the token is fresh now, so no later save repeats it.
            conflictOffer = nil
            if !notes.isEmpty { storageErrorMessage = ([report.message] + notes).joined(separator: " ") }
            return
        }
        conflictOffer = offer
    }

    /// Puts `records` into `meetings`, each into its own slot: the first copy of its id not already
    /// written this pass, or a new one — `firstIndex` alone put every edited copy of a duplicated id
    /// into one slot, so a batch tag over both twins lost one twin's body (lane C review round 2).
    /// Stamps only what it writes, as `upsert` does (F188, "Mark it"): an untouched twin keeps the
    /// marker it was written under. Saving is the caller's.
    private func writeBack(_ records: [MeetingRecord]) {
        var written: Set<Int> = []
        for var record in records {
            record.schemaVersion = MeetingRecord.currentSchemaVersion
            if let index = meetings.indices.first(where: { !written.contains($0) && meetings[$0].id == record.id }) {
                meetings[index] = record
                written.insert(index)
            } else {
                meetings.append(record)
                written.insert(meetings.count - 1)
            }
        }
        meetings = MeetingOrdering.sorted(meetings)
        for record in records {
            scheduleNotesSidecarWrite(for: record.id)
        }
    }

    /// Re-applies every record in the offer's `delta` — never `deletedByOther` — to `meetings` in
    /// memory, then persists ONCE for the whole batch (F433 follow-up). Never a wholesale array
    /// replacement, and never a record-at-a-time save: applying the batch and saving it as one
    /// write means a race on THIS save re-offers every record in the batch together, rather than
    /// silently dropping whichever one had not been attempted yet when an earlier one in the same
    /// loop failed (the bug the single-persist redesign fixes).
    ///
    /// If this save itself loses a NEW race, this never finishes silently: it re-runs
    /// `beginConflictRecovery()`, the same path a debounced flush's own race takes, so the failure
    /// is re-offered rather than swallowed. Because nothing has been marked persisted yet
    /// (`lastPersistedMeetings` only advances on a SUCCESSFUL save), that re-offer's own diff finds
    /// every one of these records still unsaved: the edits are re-offered together, and a new
    /// meeting among them is put back in the list as any lost save's is (F667).
    ///
    /// Also saves `unsavedNew` — meetings only this window has, which either answer keeps (F667).
    func keepConflictedEdit() {
        guard mutationIsAllowed() else { return }
        guard let offer = conflictOffer else { return }
        conflictOffer = nil
        saveBack(offer.delta + offer.unsavedNew)
    }

    /// Keeps the reloaded copy and discards the retained edit (F433). `meetings` already holds the
    /// winner — set by `reloadForConflictRecovery()` inside `beginConflictRecovery()` — so this only
    /// has to stop offering the alternative, and save `unsavedNew`: a meeting only this window has
    /// is not something the other copy has a version of, and dropping it here is what left a
    /// recording just stopped out of the list (F667). While the library refuses changes it cannot
    /// be saved; its folder stays on disk, unindexed, for the startup sweep to adopt once the
    /// library can be written again.
    func discardConflictedEdit() {
        guard let offer = conflictOffer else { return }
        conflictOffer = nil
        guard !offer.unsavedNew.isEmpty, mutationIsAllowed() else { return }
        saveBack(offer.unsavedNew)
    }

    /// Writes `records` back into the list and saves them as ONE write (F433); a race on that save
    /// re-offers them all together, through the recovery every lost save takes.
    private func saveBack(_ records: [MeetingRecord]) {
        guard !records.isEmpty else { return }
        writeBack(records)
        persistMeetings()
        guard writeConflict?.isRace == true else { return }
        beginConflictRecovery()
    }

    /// Replace a meeting's tags with the normalized (trimmed/deduped/capped) form of `raw`.
    func setTags(id: UUID, _ raw: [String]) {
        guard editMutationIsAllowed() else { return }
        let normalized = MeetingTags.normalized(raw)
        update(id: id) { $0.tags = normalized.isEmpty ? nil : normalized }
    }

    /// Adds one tag across a selection with a single index write (F40's rule: don't write per record).
    /// Normalization goes through `MeetingTags.normalized`, exactly as `setTags(id:_:)` does, so the
    /// batch and single paths cannot diverge.
    func addTag(_ tag: String, to ids: [UUID]) {
        guard editMutationIsAllowed() else { return }
        let target = Set(ids)
        var changed = false
        for index in meetings.indices where target.contains(meetings[index].id) {
            let merged = MeetingTags.normalized((meetings[index].tags ?? []) + [tag])
            guard merged != meetings[index].tags else { continue }
            meetings[index].tags = merged.isEmpty ? nil : merged
            changed = true
        }
        guard changed else { return }
        persistMeetingsOrRecover()
    }

    /// Removes one tag from every meeting in the selection, matched case-insensitively so it agrees
    /// with `MeetingTags.normalized`'s own de-duplication rule.
    func removeTag(_ tag: String, from ids: [UUID]) {
        guard editMutationIsAllowed() else { return }
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
        persistMeetingsOrRecover()
    }

    /// Pin or unpin a meeting so it floats to (or off) the top of the sidebar, then re-orders.
    func togglePin(id: UUID) {
        guard editMutationIsAllowed() else { return }
        guard let index = meetings.firstIndex(where: { $0.id == id }) else { return }
        meetings[index].pinned = !(meetings[index].pinned ?? false)
        meetings = MeetingOrdering.sorted(meetings)
        persistMeetingsOrRecover()
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
    /// `recordingPath`, and `UUID(uuidString:)` reads either case. Any other non-empty path returns
    /// nil, and the delete takes the index entry only and leaves the disk alone.
    ///
    /// An empty `recordingPath` has nothing to derive a folder from — it resolves to the library
    /// root — and it is what F311's "Interrupted import from <host>" entry has, whose folder holds
    /// the link's `source.json` and any partial download. Taking the entry only left that folder
    /// to `orphanedRecordings()`, which lists it as soon as the index no longer has its id, so the
    /// next launch indexed the same entry again (F576). So the folder is looked up by name, as that
    /// listing reads names: the first entry directly in `Recordings` whose name parses to this
    /// meeting's id. That keeps the name it has on disk, the only spelling a case-sensitive volume
    /// removes. When no entry has such a name, or `Recordings` cannot be listed, it is
    /// `recordingDirectoryURL(for:)`, and the default `removeRecordingDirectory` does nothing where
    /// nothing is there.
    ///
    /// The first such entry only, and not checked to be a directory, where `orphanedRecordings()`
    /// takes every matching directory: a delete removes one folder per meeting. So on a
    /// case-sensitive volume holding two spellings of one id, only one goes, and the next launch can
    /// list the other again; deleting again removes it. Not planned: every recording folder
    /// WhisperMeet makes is named `id.uuidString` (`recordingDirectoryURL(for:)`), and a restore puts
    /// back only names a backup already held, so a second spelling of one id exists only where
    /// something else made one, on a volume that is not the macOS default.
    func ownRecordingFolder(of meeting: MeetingRecord) -> URL? {
        let recordings = rootDirectory
            .appendingPathComponent("Recordings", isDirectory: true)
            .standardizedFileURL
        guard !meeting.recordingPath.isEmpty else {
            let listed = try? FileManager.default.contentsOfDirectory(
                at: recordings, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
            )
            let named = listed?.first { UUID(uuidString: $0.lastPathComponent) == meeting.id }
            return (named ?? recordingDirectoryURL(for: meeting.id)).standardizedFileURL
        }
        let folder = recordingURL(for: meeting).deletingLastPathComponent().standardizedFileURL
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
    ///
    /// What that protection is, stated because the Settings caption once overstated it (F457): the
    /// app offers the history (Recover Library) only while the library cannot be read, as after the
    /// wipe. A delete on a healthy library — one meeting, or all of them — has no in-app undo; the
    /// week keeps a hand restore (`docs/RECOVERY.md`) possible, and nothing more.
    nonisolated static let shredGracePeriod: TimeInterval = 604_800

    private var pendingShredURL: URL {
        rootDirectory.appendingPathComponent("meetings.pending-shred.json")
    }

    /// The queue file's three kinds of entry (F603, F668).
    ///
    /// `deletedAt` is the epoch second each deletion happened, as the clock read at the delete.
    /// `firstSeenFutureAt` is, for a deletion dated beyond `now + shredGracePeriod` — a date no
    /// deletion can have — the `now` at which this build first saw it that way. The deletion's
    /// own date is never rewritten from a later clock; see `processPendingShreds`.
    /// `sideCopiesPending` is a deletion whose history is shredded but which a copy of the index
    /// outside the history may still hold, or whose recording folder a restore snapshot still holds
    /// (`shredSideCopies`, F664), keyed to the deletion's date; it
    /// stays until every such copy is clean or gone, the meeting is live again, or the meeting is
    /// deleted again (which starts a new week), so a copy that could not be cleaned once is looked
    /// at again at the next launch rather than forgotten (F668). A copy that cannot be read at all
    /// keeps nothing here: it is reported instead.
    private struct PendingShredQueue: Equatable {
        var deletedAt: [UUID: Int] = [:]
        var firstSeenFutureAt: [UUID: Int] = [:]
        var sideCopiesPending: [UUID: Int] = [:]
    }

    /// The key prefix a `firstSeenFutureAt` entry is stored under, in the same `[String: Int]` file
    /// as the deletions (F603). One file, so the two cannot disagree after a crash; the shape every
    /// earlier build reads is unchanged, and an earlier build's reader drops a key that is not a UUID
    /// — so it ignores these, and its next write of the queue simply leaves them out.
    private static let firstSeenFuturePrefix = "first-seen-future:"

    /// The key prefix a `sideCopiesPending` entry is stored under, in the same file, for the same
    /// reasons (F668).
    private static let sideCopiesPrefix = "side-copies:"

    /// Read leniently (F498). `UUID(uuidString:)` accepts either case, so a file naming one meeting
    /// in two spellings — hand-edited, or written by something other than this build — holds two
    /// keys for one id, and `Dictionary(uniqueKeysWithValues:)` trapped on it. This getter runs at
    /// every launch, so that file took the app down before any window could say why. The later
    /// time wins, for both kinds of entry: the shred then waits for the later of the two, and
    /// waiting loses nothing where shredding early cannot be taken back.
    private var pendingShredQueue: PendingShredQueue {
        get {
            guard let data = try? Data(contentsOf: pendingShredURL),
                  let raw = try? JSONDecoder().decode([String: Int].self, from: data)
            else { return PendingShredQueue() }
            var deletions: [(UUID, Int)] = []
            var sightings: [(UUID, Int)] = []
            var sideCopies: [(UUID, Int)] = []
            for (key, value) in raw {
                if key.hasPrefix(Self.firstSeenFuturePrefix) {
                    if let id = UUID(uuidString: String(key.dropFirst(Self.firstSeenFuturePrefix.count))) {
                        sightings.append((id, value))
                    }
                } else if key.hasPrefix(Self.sideCopiesPrefix) {
                    if let id = UUID(uuidString: String(key.dropFirst(Self.sideCopiesPrefix.count))) {
                        sideCopies.append((id, value))
                    }
                } else if let id = UUID(uuidString: key) {
                    deletions.append((id, value))
                }
            }
            let deletedAt = Dictionary(deletions, uniquingKeysWith: max)
            // A sighting without its deletion describes nothing, and is dropped on the next write.
            let firstSeen = Dictionary(sightings, uniquingKeysWith: max).filter { deletedAt[$0.key] != nil }
            return PendingShredQueue(
                deletedAt: deletedAt,
                firstSeenFutureAt: firstSeen,
                sideCopiesPending: Dictionary(sideCopies, uniquingKeysWith: max)
            )
        }
        set {
            var raw: [String: Int] = [:]
            for (id, value) in newValue.deletedAt { raw[id.uuidString] = value }
            for (id, value) in newValue.firstSeenFutureAt where newValue.deletedAt[id] != nil {
                raw[Self.firstSeenFuturePrefix + id.uuidString] = value
            }
            for (id, value) in newValue.sideCopiesPending {
                raw[Self.sideCopiesPrefix + id.uuidString] = value
            }
            if raw.isEmpty {
                try? FileManager.default.removeItem(at: pendingShredURL)
            } else if let data = try? JSONEncoder().encode(raw) {
                try? data.write(to: pendingShredURL, options: .atomic)
            }
        }
    }

    /// Deleted ids awaiting their shred, keyed by the epoch second of the deletion.
    var pendingShreds: [UUID: Int] { pendingShredQueue.deletedAt }

    /// Queues the ids for their shred. Never undoes the deletion, and never fails it: the queue file
    /// is best-effort, and a deletion whose queue write is lost is a deletion whose text ages out as
    /// it did before F295, which is the state we are improving on, not a regression from it.
    private func shredFromHistory(_ ids: [UUID], now: Int = Int(Date().timeIntervalSince1970)) {
        // The edited-check memo holds a copy of each transcript it answered for (F541). Every path
        // that deletes a meeting comes through here, so its copy goes at once rather than at quit.
        for id in ids { transcriptEditMemos[id] = nil }
        var queue = pendingShredQueue
        for id in ids {
            queue.deletedAt[id] = now
            // A new deletion of the same id has its own date; an old sighting does not describe it.
            queue.firstSeenFutureAt[id] = nil
            // Nor does an old deletion's side-copy entry: left, the next pass would strip the side
            // copies at once, inside this deletion's week (F668, review round 2).
            queue.sideCopiesPending[id] = nil
        }
        pendingShredQueue = queue
    }

    /// Shreds every queued deletion older than the grace window from the retained history and the
    /// backup copy. Idempotent; called at launch by `performStartupRecovery` and after each delete.
    /// Returns the ids shredded.
    ///
    /// Two things are settled before anything is due (F498), and both are written back even when
    /// nothing is:
    ///
    /// - **A queued id that is a live meeting again is cancelled, not shredded.** The grace window
    ///   exists so a lost or damaged library can be brought back (F457: that is its purpose, not an
    ///   in-app undo for one delete), and every route back — restoring a generation from the
    ///   recovery list or by hand, restoring a backup (which does not carry this queue, so the live
    ///   one survives it), or a rebuild or recovery that finds the meeting's folder still on disk —
    ///   brings the meeting back under its old id without touching this file.
    ///   Shredding it anyway stripped a live meeting from every generation that held it, which is
    ///   the undo protection taken away from exactly the meeting the user had just rescued. Checked
    ///   here rather than in each restore path because this is the only place a shred happens, so
    ///   no future route back can miss it.
    /// - **A deletion dated beyond a week from now waits a week from when it is first seen that
    ///   way.** A wrong clock or a foreign file would otherwise defer the shred until that date —
    ///   for `Int.max`, forever — and deferring forever is its own failure: the text stays in the
    ///   history the user was told it would leave.
    ///
    /// **The deletion's own date is never rewritten from `now` (F603).** F498 first re-dated every
    /// future entry to `min(deletedAt, now)` and saved it, so a single launch with the clock behind
    /// moved a real, recent deletion into the past for good — and once the clock was right the
    /// shred fired early, inside the undo window, the one direction that cannot be taken back.
    /// Neither half of that survives here. An entry dated up to a week ahead is a clock that was a
    /// little ahead at the delete, and its own date still rules: at most a week's extra wait. An
    /// entry dated beyond that is kept as dated, and `firstSeenFutureAt` records the `now` it was
    /// first seen at; the wait runs from there while the date stays impossible, and the sighting is
    /// dropped the moment the date stops being impossible — which is what a clock that was behind
    /// looks like once it is corrected, so the real deletion date takes over again. A sighting
    /// dated beyond a week from now is itself not believed and is taken again, so a clock that was
    /// ahead at the sighting cannot defer the shred either. Nothing derived from `now` is written
    /// for an entry that is not beyond it.
    ///
    /// Due is decided against a cutoff rather than as `now - deletedAt`, which trapped on a deletion
    /// time near `Int.min` — at every launch, like the getter's duplicate keys.
    @discardableResult
    func processPendingShreds(now: Int = Int(Date().timeIntervalSince1970)) -> [UUID] {
        guard !isDegraded else { return [] }   // F187: no rewrite of a library we could not read
        let stored = pendingShredQueue
        let live = Set(meetings.map(\.id))
        let grace = Int(Self.shredGracePeriod)
        // Past this, a date is one no deletion can have. An overflowed horizon (a `now` near
        // `Int.max`) makes nothing impossible, so every entry keeps its own date — which defers.
        let (horizon, horizonOverflowed) = now.addingReportingOverflow(grace)
        var queue = PendingShredQueue()
        // A copy is never cleaned of a meeting that is live again, as the history is not (F668).
        queue.sideCopiesPending = stored.sideCopiesPending.filter { !live.contains($0.key) }
        for (id, deletedAt) in stored.deletedAt where !live.contains(id) {
            queue.deletedAt[id] = deletedAt
            guard !horizonOverflowed, deletedAt > horizon else { continue }
            if let seen = stored.firstSeenFutureAt[id], seen <= horizon {
                queue.firstSeenFutureAt[id] = seen
            } else {
                queue.firstSeenFutureAt[id] = now
            }
        }
        if queue != stored { pendingShredQueue = queue }
        let (cutoff, overflowed) = now.subtractingReportingOverflow(grace)
        // An overflowed cutoff means a `now` near `Int.min`; nothing is due then, which defers.
        let due = overflowed ? [] : queue.deletedAt.compactMap { id, deletedAt -> UUID? in
            (queue.firstSeenFutureAt[id] ?? deletedAt) <= cutoff ? id : nil
        }
        guard !due.isEmpty else {
            retrySideCopies(&queue)
            if queue != stored { pendingShredQueue = queue }
            return []
        }
        do {
            // At the JSON level, so what a newer build wrote into the history survives (F552).
            let shred = try meetingFiles.shredHistory(removingElementsWithIDs: Set(due.map(\.uuidString)))
            if let rotation = shred.rotation {
                persistCommitCount += 1
                // The rotation re-saved whatever the primary held. Adopt its generation only when
                // that was this session's own last commit: the content is then unchanged, and the
                // next save's compare-and-swap must see the new generation. If another copy had
                // committed in between, adopting would let the next save overwrite that commit
                // unseen, so the token is left stale and that save loses the race visibly instead.
                if let own = meetingsToken, let parent = rotation.parent, parent.hasSameBody(as: own) {
                    meetingsToken = rotation.token
                }
            }
            // F680: the rotation is skipped over an index that did not load cleanly, and then the
            // backup still holds the text. Those ids stay queued as deletions, so the next pass over
            // a clean load rotates the backup — and cleans the quarantine copy a non-clean load
            // makes of it — instead of the id leaving the queue with the text still on disk.
            var heldByBackup: Set<UUID> = []
            if shred.rotation == nil,
               let backup = try? Data(contentsOf: rootDirectory.appendingPathComponent("meetings.backup.json")),
               let held = JSONArrayShred.removingElements(withIDs: Set(due.map(\.uuidString)), from: backup)?.removed {
                heldByBackup = Set(due.filter { held.contains($0.uuidString.lowercased()) })
            }
            let shredded = due.filter { !heldByBackup.contains($0) }
            var remaining = queue
            for id in shredded {
                // The history is done; the copies outside it are next, and stay queued until clean.
                remaining.sideCopiesPending[id] = remaining.deletedAt[id]
                remaining.deletedAt.removeValue(forKey: id)
                remaining.firstSeenFutureAt.removeValue(forKey: id)
            }
            retrySideCopies(&remaining)
            pendingShredQueue = remaining
            return shredded
        } catch {
            storageErrorMessage = "A deleted meeting's text could not be removed from the saved index history: \(error.localizedDescription) Settings → Meeting library → Forget History removes the saved history at once."
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
    /// removed is the meeting's own `Recordings/<id>` (`ownRecordingFolder(of:)`, F452), found by the
    /// meeting's id when `recordingPath` is empty (F576) — for any other `recordingPath` only the
    /// index entry goes and the message says so. No notes-sidecar hook: the sidecar lives in the
    /// recording folder, which dies with the meeting.
    @discardableResult
    func delete(ids: [UUID]) -> [UUID] {
        guard editMutationIsAllowed() else { return [] }
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
            // A lost race also re-reads the library, so the next save is not refused the same way
            // (F642). The deletion itself is never offered back — "keep my delete" over another
            // copy's commit is a destructive choice to put one click away — so it is said instead;
            // an unsaved edit that rode along with this save is still offered, as F433 offers any.
            if writeConflict?.isRace == true {
                beginConflictRecovery(note: Self.lostDeleteNote(count: doomed.count))
            }
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
            } else if writeConflict?.isRace == true {
                // Lost to another copy between the two saves (F642): re-read, so the session is
                // not stuck. The kept rows are absent from this session's last save, so they are
                // offered back as rows it added, and keeping them lists them again.
                beginConflictRecovery(note: Self.keptFoldersNote(kept.map(\.title)))
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

    /// For a delete whose save lost a race to another copy (F642). Appended to the conflict
    /// message, which already says the change was not applied and where the refused save went.
    private static func lostDeleteNote(count: Int) -> String {
        count == 1
            ? "The meeting was not deleted. WhisperMeet re-read the library as the other copy saved it; delete it again if you still want it gone."
            : "The \(count) meetings were not deleted. WhisperMeet re-read the library as the other copy saved it; delete them again if you still want them gone."
    }

    /// For a delete whose folders could not all be removed, and whose save putting those rows back
    /// then lost a race to another copy (F642). True whichever side the user then keeps.
    private static func keptFoldersNote(_ titles: [String]) -> String {
        let names = titles.map { "“\($0)”" }.joined(separator: ", ")
        return "\(titles.count) meeting(s) could not have their recordings removed, so their recording folders are still in the library: \(names)."
    }

    /// For a delete that removed index entries only, because the recording path did not name the
    /// meeting's own folder (F452) — outside the library, or a directory other things share. An
    /// empty path is not one of them: its folder is found by the meeting's id (F576).
    private static func entryOnlyDeleteMessage(count: Int) -> String {
        count == 1
            ? "This meeting's recording path did not point to its own recording folder, so no files were deleted from disk; the meeting was removed from the list."
            : "\(count) meetings had a recording path that did not point to their own recording folder, so no files were deleted from disk for them; they were removed from the list."
    }

    /// What is on disk that Forget History concerns (F457): the conflict copies it keeps unless
    /// asked, and the index's other copies it never removes — quarantined copies and restore
    /// snapshots, which exist so someone can recover from them.
    struct ForgetHistoryInventory: Equatable {
        let conflictCopies: Int
        /// `meetings.unreadable-*` and `meetings.backup.unreadable-*`, by file name.
        let quarantineCopies: [String]
        /// `.pre-restore-*` folders, by name.
        let preRestoreSnapshots: [String]
    }

    /// What Forget History did, and what it left, so the UI reports exactly that (F239, F457).
    struct ForgetHistoryOutcome: Equatable {
        let removedGenerations: Int
        let removedConflictCopies: Int
        let keptConflictCopies: Int
        let keptQuarantineCopies: [String]
        let keptPreRestoreSnapshots: [String]
    }

    private var meetingHistory: StoreHistory {
        StoreHistory(primaryURL: rootDirectory.appendingPathComponent("meetings.json"))
    }

    /// The index's copies outside its history (F457), sorted by name. Reads a directory listing only.
    private func sideCopiesOfTheIndex() -> (quarantine: [String], snapshots: [String]) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: rootDirectory.path)) ?? []
        let quarantine = names.filter {
            $0.hasPrefix("meetings.unreadable-") || $0.hasPrefix("meetings.backup.unreadable-")
        }
        let snapshots = names.filter { name in
            var isDirectory: ObjCBool = false
            return name.hasPrefix(".pre-restore-")
                && FileManager.default.fileExists(
                    atPath: rootDirectory.appendingPathComponent(name).path, isDirectory: &isDirectory
                )
                && isDirectory.boolValue
        }
        return (quarantine.sorted(), snapshots.sorted())
    }

    /// One `.pre-restore-<epoch>` safety copy a backup restore kept (F855): the library it replaced,
    /// as `BackupRestore.apply` set it aside so the restore can be undone by hand.
    struct RestoreSnapshot: Equatable, Identifiable, Sendable {
        /// The folder's name inside the library, `.pre-restore-<epoch>`.
        let name: String
        /// When the restore made it — the epoch in its name, or the folder's own date when the name
        /// carries none a restore would write.
        let createdAt: Date?
        /// The regular files inside it, added up; a link inside is not followed.
        let byteCount: Int64
        var id: String { name }
    }

    /// The restore safety copies in the library, newest first, for Settings to list (F855). Only real
    /// folders: a link or a file under that name was not made by a restore, so it is neither listed
    /// nor offered for removal. Walks each folder's file sizes — metadata only, nothing is read.
    func restoreSnapshots() -> [RestoreSnapshot] {
        sideCopiesOfTheIndex().snapshots.compactMap { name -> RestoreSnapshot? in
            let url = rootDirectory.appendingPathComponent(name, isDirectory: true)
            guard Self.isRealFolder(url) else { return nil }
            let epoch = Int(name.dropFirst(Self.restoreSnapshotPrefix.count)).map(TimeInterval.init)
            let modified = (try? FileManager.default.attributesOfItem(atPath: url.path))?[.modificationDate] as? Date
            return RestoreSnapshot(
                name: name,
                createdAt: epoch.map(Date.init(timeIntervalSince1970:)) ?? modified,
                byteCount: Self.regularFileBytes(in: url)
            )
        }
        .sorted { ($0.createdAt ?? .distantPast, $0.name) > ($1.createdAt ?? .distantPast, $1.name) }
    }

    /// Removes one restore safety copy, whole, when the user asks (F855). The only way one is ever
    /// removed: nothing does it automatically — the user's decision of 2026-10-07. F664's per-meeting
    /// shred still removes a deleted meeting's recording from inside them after its week.
    ///
    /// Refused while the library is read-only, because a safety copy may be the way a library that
    /// cannot be read is put back, and while a restore runs, which writes a new one. Only a direct
    /// child of the library named `.pre-restore-…` that is a real folder: never a link (F664's rule,
    /// `isRealFolder`), and never a path. Throws the removal's own error when it fails, part-way or
    /// not at all; what is left stays where it was, and is listed again.
    func removeRestoreSnapshot(named name: String) throws {
        guard !isRestoringLibrary else { throw MeetingStoreError.libraryIsBeingRestored }
        guard !isDegraded else { throw MeetingStoreError.libraryIsReadOnly }
        let url = rootDirectory.appendingPathComponent(name, isDirectory: true)
        guard name.hasPrefix(Self.restoreSnapshotPrefix), !name.contains("/"),
              Self.isRealFolder(url)
        else { throw MeetingStoreError.notARestoreSnapshot(name) }
        try FileManager.default.removeItem(at: url)
    }

    /// The name `BackupRestore.apply` gives a safety copy, before its epoch.
    nonisolated static let restoreSnapshotPrefix = ".pre-restore-"

    /// Whether `url` is a folder itself rather than a link to one (F664, F855). `attributesOfItem`
    /// does not follow the last component, so a link reports as a link.
    nonisolated static func isRealFolder(_ url: URL) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: url.path))?[.type] as? FileAttributeType == .typeDirectory
    }

    /// The bytes of the regular files under `folder`, not descending into a link.
    nonisolated private static func regularFileBytes(in folder: URL) -> Int64 {
        let keys: [URLResourceKey] = [.isRegularFileKey, .isSymbolicLinkKey, .fileSizeKey]
        guard let walker = FileManager.default.enumerator(at: folder, includingPropertiesForKeys: keys) else {
            return 0
        }
        var total: Int64 = 0
        while let item = walker.nextObject() as? URL {
            let values = try? item.resourceValues(forKeys: Set(keys))
            if values?.isSymbolicLink == true {
                walker.skipDescendants()
                continue
            }
            guard values?.isRegularFile == true else { continue }
            total += Int64(values?.fileSize ?? 0)
        }
        return total
    }

    /// For the Forget History dialog, read when it opens. Reads directory listings only.
    func forgetHistoryInventory() -> ForgetHistoryInventory {
        let side = sideCopiesOfTheIndex()
        return ForgetHistoryInventory(
            conflictCopies: meetingHistory.conflictBranchCount(),
            quarantineCopies: side.quarantine,
            preRestoreSnapshots: side.snapshots
        )
    }

    /// Forgets the retained index history now — the immediate counterpart to the automatic shred
    /// (F239, F295).
    ///
    /// Deleting a meeting removes its recording folder at once; its title, transcript, notes and
    /// summary stay in the retained generations under `meetings.history/` and in the backup copy for
    /// `shredGracePeriod` (a week), and `processPendingShreds` then removes them from every
    /// generation automatically. That week is protection against losing the library, not an undo
    /// for one delete: Recover Library, which restores from these generations, is offered only while
    /// the library cannot be read (F457, the user's answer of 2026-09-24). This command does not
    /// wait: it removes every generation at once, for every meeting. It does not rewrite
    /// `meetings.backup.json`, the previous generation, so a meeting deleted by the most recent save
    /// is still there until the next save rotates it out.
    ///
    /// **Refused while the library is read-only (F457).** Those generations are exactly what Recover
    /// Library restores from then, and this used to delete them under a dialog that said nothing was
    /// lost. The refusal is `mutationIsAllowed()`'s, so it reads like every other.
    ///
    /// **Keeps what exists nowhere else unless asked (F457).** Conflict branches — a losing writer's
    /// work — are removed only with `includingConflictCopies`, which the dialog offers after naming
    /// how many there are. Quarantined copies and restore snapshots are never removed here; the
    /// outcome names them so the user knows where the text still is. The week-later shred removes a
    /// deleted meeting from them too (`shredSideCopies`).
    ///
    /// **It discards F190's undo protection for the whole library**, not just for deleted meetings,
    /// which is why it is a separate command the caller must describe as such. (This comment used to
    /// say a deleted meeting's text could stay in the history for good unless this ran; F295 made
    /// the per-meeting removal automatic, and F450 corrected the comment.) Returns what was removed
    /// and kept, so the UI can report what happened rather than claim success; a refusal or failure
    /// sets `storageErrorMessage` and returns nil, because a privacy command that reports erasure it
    /// did not achieve is worse than one that fails loudly.
    @discardableResult
    func forgetIndexHistory(includingConflictCopies: Bool = false) -> ForgetHistoryOutcome? {
        guard mutationIsAllowed() else { return nil }
        do {
            let forgotten = try meetingFiles.forgetHistory(includingConflictBranches: includingConflictCopies)
            storageErrorMessage = restingStorageMessage   // F553's notice stays until read (F669)
            let removedConflicts = forgotten.filter { $0.hasPrefix("conflict-") }.count
            let left = forgetHistoryInventory()
            return ForgetHistoryOutcome(
                removedGenerations: forgotten.count - removedConflicts,
                removedConflictCopies: removedConflicts,
                keptConflictCopies: left.conflictCopies,
                keptQuarantineCopies: left.quarantineCopies,
                keptPreRestoreSnapshots: left.preRestoreSnapshots
            )
        } catch {
            storageErrorMessage = "The saved history could not be removed: \(error.localizedDescription)"
            return nil
        }
    }

    /// A copy of the index outside its history that still holds (or may hold) deleted meetings after
    /// a pass (F668). `path` is relative to the library folder, so a snapshot's `meetings.json` is
    /// never mistaken for the live one.
    private struct StuckSideCopy: Equatable {
        enum Reason: Equatable {
            /// Its cleaned bytes could not be written back — worth retrying.
            case couldNotRewrite
            /// Not a readable index, and its bytes name a deleted meeting. Retrying cannot clean it;
            /// only the user can remove it.
            case notAnIndex
            /// Could not be read at all, so what it holds is unknown. Reported, but it holds no
            /// deletion in the queue: holding every pending id kept each later deletion queued for
            /// good and claimed text the copy may never have held (review round 2).
            case couldNotRead
            /// A restore snapshot's copy of a deleted meeting's recording folder that could not be
            /// removed (F664) — worth retrying, like `couldNotRewrite`.
            case couldNotRemoveRecording
        }
        let path: String
        let ids: Set<UUID>
        let reason: Reason
    }

    /// Removes deleted meetings from the index's copies outside its history — quarantined copies and
    /// the index files in a restore's snapshot — once their week is over (F457), the same way the
    /// history is shredded (`JSONArrayShred`, F552): only those meetings' entries go, and everything
    /// else in each copy stays readable, because these copies exist so someone can recover from
    /// them.
    ///
    /// And removes each one's copy of its recording folder from every restore snapshot (F664, the
    /// user's decision of 2026-10-07): `.pre-restore-*/Recordings/<id>/`, audio and `notes.md` —
    /// transcript and summary — together. A restore keeps every recording it overwrote, so a meeting
    /// deleted after a restore used to keep both there for good, out of sight in the app. Only the
    /// deleted meeting's folder goes; a folder whose meeting is live, or that a live meeting's
    /// recording path points into, is never touched, and neither is a snapshot or `Recordings`
    /// folder that is a link rather than a folder of its own.
    ///
    /// Returns every copy that still holds, or may hold, one of the ids (F668): one whose cleaned bytes
    /// could not be written back (with the ids it held), one that does not parse as an index but
    /// whose bytes name one of them (with those ids), one that could not be read at all (with no
    /// ids — what it holds is unknown), and a snapshot's recording folder that could not be removed
    /// (with its id). A copy that does not parse and names none of them is clean for this purpose.
    /// Nothing else is deleted.
    private func shredSideCopies(_ ids: Set<UUID>) -> [StuckSideCopy] {
        let side = sideCopiesOfTheIndex()
        var paths = side.quarantine
        for snapshot in side.snapshots {
            for name in ["meetings.json", "meetings.backup.json"] {
                let path = "\(snapshot)/\(name)"
                if FileManager.default.fileExists(atPath: rootDirectory.appendingPathComponent(path).path) {
                    paths.append(path)
                }
            }
        }
        let doomed = Set(ids.map(\.uuidString))
        let byLowercased = Dictionary(ids.map { ($0.uuidString.lowercased(), $0) }, uniquingKeysWith: { first, _ in first })
        func uuids(_ lowercased: Set<String>) -> Set<UUID> { Set(lowercased.compactMap { byLowercased[$0] }) }
        var stuck: [StuckSideCopy] = []
        for path in paths {
            let url = rootDirectory.appendingPathComponent(path)
            guard let data = try? Data(contentsOf: url) else {
                stuck.append(StuckSideCopy(path: path, ids: [], reason: .couldNotRead))
                continue
            }
            guard let shredded = JSONArrayShred.removingElements(withIDs: doomed, from: data) else {
                // Holds none of them — unless it does not parse, when only its bytes can say.
                if !JSONArrayShred.isArray(data) {
                    let named = uuids(JSONArrayShred.mentionedIDs(doomed, in: data))
                    if !named.isEmpty { stuck.append(StuckSideCopy(path: path, ids: named, reason: .notAnIndex)) }
                }
                continue
            }
            do {
                try shredded.data.write(to: url, options: .atomic)
            } catch {
                stuck.append(StuckSideCopy(path: path, ids: uuids(shredded.removed), reason: .couldNotRewrite))
            }
        }
        stuck += shredSnapshotRecordings(ids, in: side.snapshots)
        return stuck
    }

    /// The F664 half of `shredSideCopies`: each restore snapshot's copy of a deleted meeting's
    /// recording folder. Matched by the id the folder is named after, in either case, as
    /// `orphanedRecordings()` matches the library's own.
    private func shredSnapshotRecordings(_ ids: Set<UUID>, in snapshots: [String]) -> [StuckSideCopy] {
        // Never a meeting that is in the library: `retrySideCopies` passes only ids that are not, and
        // this asks again rather than rely on it. A live meeting whose recording path points into a
        // snapshot (a hand-edited index) keeps that folder too.
        let live = Set(meetings.map(\.id))
        let liveFolders = meetings.map { recordingURL(for: $0).standardizedFileURL.path }
        let fileManager = FileManager.default
        let isRealFolder = Self.isRealFolder
        var stuck: [StuckSideCopy] = []
        for snapshot in snapshots {
            let snapshotURL = rootDirectory.appendingPathComponent(snapshot, isDirectory: true)
            let recordings = snapshotURL.appendingPathComponent("Recordings", isDirectory: true)
            // Most snapshots hold no recordings: a restore that overwrote none. A link where a folder
            // should be leads somewhere this code did not make, so nothing is removed through it.
            guard isRealFolder(snapshotURL), isRealFolder(recordings) else { continue }
            guard let names = try? fileManager.contentsOfDirectory(atPath: recordings.path) else {
                stuck.append(StuckSideCopy(path: "\(snapshot)/Recordings", ids: [], reason: .couldNotRead))
                continue
            }
            for name in names {
                guard let id = UUID(uuidString: name), ids.contains(id), !live.contains(id) else { continue }
                let folder = recordings.appendingPathComponent(name, isDirectory: true)
                let folderPath = folder.standardizedFileURL.path
                guard !liveFolders.contains(where: { $0 == folderPath || $0.hasPrefix(folderPath + "/") })
                else { continue }
                do {
                    try fileManager.removeItem(at: folder)
                } catch {
                    stuck.append(StuckSideCopy(
                        path: "\(snapshot)/Recordings/\(name)", ids: [id], reason: .couldNotRemoveRecording
                    ))
                }
            }
        }
        return stuck
    }

    /// The copies this session has already reported, so one that stays stuck is said once per launch
    /// rather than at every delete's pass (F668). In memory on purpose: the next launch says it again,
    /// because the text may still be there.
    private var reportedStuckSideCopies: Set<String> = []

    /// The pending ids this session has already tried, so each is tried once per launch (F668, review
    /// round 2). Every try reads and parses every side copy on the main actor, and a copy that stays
    /// stuck would otherwise cost that at every delete for as long as it stays; the next launch tries
    /// again.
    private var sideCopiesTriedThisSession: Set<UUID> = []

    /// Runs the side-copy shred for the ids whose history is done and that this session has not tried
    /// yet, keeps queued the ids some copy still holds, and names the copies it has not named yet
    /// this session (F668).
    private func retrySideCopies(_ queue: inout PendingShredQueue) {
        let toTry = Set(queue.sideCopiesPending.keys).subtracting(sideCopiesTriedThisSession)
        guard !toTry.isEmpty else { return }
        sideCopiesTriedThisSession.formUnion(toTry)
        let stuck = shredSideCopies(toTry)
        let stillHeld = stuck.reduce(into: Set<UUID>()) { $0.formUnion($1.ids) }
        queue.sideCopiesPending = queue.sideCopiesPending.filter {
            !toTry.contains($0.key) || stillHeld.contains($0.key)
        }
        let unreported = stuck.filter { !reportedStuckSideCopies.contains($0.path) }
        reportedStuckSideCopies.formUnion(stuck.map(\.path))
        guard !unreported.isEmpty else { return }
        storageErrorMessage = Self.stuckSideCopiesMessage(unreported)
    }

    private static func stuckSideCopiesMessage(_ stuck: [StuckSideCopy]) -> String {
        var sentences: [String] = []
        let retryable = stuck.filter { $0.reason == .couldNotRewrite }.map(\.path).sorted()
        let notIndexes = stuck.filter { $0.reason == .notAnIndex }.map(\.path).sorted()
        let unopened = stuck.filter { $0.reason == .couldNotRead }.map(\.path).sorted()
        let recordings = stuck.filter { $0.reason == .couldNotRemoveRecording }.map(\.path).sorted()
        if !retryable.isEmpty {
            sentences.append("A deleted meeting's text could not be removed from \(retryable.joined(separator: ", ")) in the library folder. WhisperMeet will try again at the next launch.")
        }
        if !recordings.isEmpty {
            let folders = recordings.joined(separator: ", ")
            sentences.append(recordings.count == 1
                ? "A copy of a deleted meeting's recording and notes, kept by a restore, could not be removed from \(folders) in the library folder. WhisperMeet will try again at the next launch."
                : "Copies of deleted meetings' recordings and notes, kept by a restore, could not be removed from \(folders) in the library folder. WhisperMeet will try again at the next launch.")
        }
        if !notIndexes.isEmpty {
            let files = notIndexes.joined(separator: ", ")
            sentences.append(notIndexes.count == 1
                ? "\(files) in the library folder is a copy of the meeting index that cannot be read as one, and it may still contain a deleted meeting's text, so WhisperMeet cannot remove just that meeting from it. Delete the file yourself if you no longer need it."
                : "\(files) in the library folder are copies of the meeting index that cannot be read as one, and they may still contain a deleted meeting's text, so WhisperMeet cannot remove just that meeting from them. Delete the files yourself if you no longer need them.")
        }
        if !unopened.isEmpty {
            let files = unopened.joined(separator: ", ")
            sentences.append(unopened.count == 1
                ? "\(files) in the library folder could not be opened, so WhisperMeet could not check whether it still contains a deleted meeting's text."
                : "\(files) in the library folder could not be opened, so WhisperMeet could not check whether they still contain a deleted meeting's text.")
        }
        return sentences.joined(separator: " ")
    }

    /// Adds `terms` and says what happened to each (F525).
    ///
    /// At `maxStoredVocabularyTerms` the new terms are REFUSED, in the order offered, and counted —
    /// never the stored ones evicted. This used to keep the collation-first 5,000 of old + new, so a
    /// new term that sorted earlier pushed a reviewed one out (Mandarin first, because CJK sorts
    /// after Latin) while the screen said "Saved 3 terms." A term the user reviewed is worth more
    /// than one they have not seen yet, and a refusal can be undone by removing something; a silent
    /// eviction cannot, because nobody knows it happened.
    ///
    /// Reported as refused when the save does not land (F663) — nothing was added, the store has said
    /// why, and the Add box keeps the typing. It used to report "Saved N terms." regardless.
    @discardableResult
    func addVocabulary(_ terms: [String]) -> VocabularyAddition {
        guard listMutationIsAllowed(.vocabulary) else { return VocabularyAddition(wasRefused: true) }
        var result = VocabularyAddition()
        // Staged against the list as it is when it runs — again after a lost race, against what the
        // other copy saved — so the counts describe the list the terms actually went into.
        let saved = commitListChange(.vocabulary) {
            result = self.stageVocabularyAddition(terms)
            return result.added > 0
        }
        return saved ? result : VocabularyAddition(wasRefused: true)
    }

    /// Adds to `vocabulary`, in memory, whichever of `terms` are new and fit (F525), and says what
    /// happened to each. Saving is `commitListChange`'s.
    private func stageVocabularyAddition(_ terms: [String]) -> VocabularyAddition {
        let saved = Set(vocabulary)
        var result = VocabularyAddition()
        var accepted: [String] = []
        var seen = Set<String>()
        for term in terms.map(Self.normalizeTerm) where !term.isEmpty && seen.insert(term).inserted {
            if saved.contains(term) {
                result.alreadySaved += 1
            } else if vocabulary.count + accepted.count < Self.maxStoredVocabularyTerms {
                accepted.append(term)
            } else {
                result.refusedAtLimit += 1
                result.refusedTerms.append(term)
            }
        }
        result.added = accepted.count
        if !accepted.isEmpty {
            vocabulary = Self.storedTerms(vocabulary + accepted)
        }
        return result
    }

    func removeVocabulary(_ term: String) {
        guard listMutationIsAllowed(.vocabulary) else { return }
        let saved = commitListChange(.vocabulary) {
            guard self.vocabulary.contains(term) else { return false }
            self.vocabulary.removeAll { $0 == term }
            return true
        }
        // The star goes with the term, and only once the term is gone from disk.
        guard saved, prioritizedVocabulary.contains(term) else { return }
        prioritizedVocabulary.remove(term)
        persistVocabularyPriority()
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
        guard listMutationIsAllowed(.vocabulary) else { return }
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
    /// Returns what happened (F525): the rule editor keeps the typed rule unless it was `.added`,
    /// and says why for the rest — at the limit this used to return in silence while the editor
    /// cleared both fields as if the rule had been saved.
    ///
    /// `.refused` too when the save does not land (F663): the store has said why, and the editor keeps
    /// the fields. It used to return `.added` regardless, and the fields were cleared.
    @discardableResult
    func addReplacementRule(heard: String, preferred: String) -> ReplacementRuleAddition {
        guard listMutationIsAllowed(.replacementRules) else { return .refused }
        let h = heard.trimmingCharacters(in: .whitespacesAndNewlines)
        let p = preferred.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !h.isEmpty, !p.isEmpty, h != p else { return .noChange }
        let rule = ReplacementRule(heard: h, preferred: p)
        var outcome = ReplacementRuleAddition.added
        // Staged against the rules as they are when it runs — again after a lost race, against
        // what the other copy saved, which may already hold this rule or be at the limit.
        let saved = commitListChange(.replacementRules) {
            guard !self.replacementRules.contains(rule) else { outcome = .duplicate; return false }
            guard self.replacementRules.count < Self.maxReplacementRules else { outcome = .atLimit; return false }
            outcome = .added
            self.replacementRules.append(rule)
            return true
        }
        return saved ? outcome : .refused
    }

    func removeReplacementRule(_ rule: ReplacementRule) {
        guard listMutationIsAllowed(.replacementRules) else { return }
        commitListChange(.replacementRules) {
            guard self.replacementRules.contains(rule) else { return false }
            self.replacementRules.removeAll { $0 == rule }
            return true
        }
    }

    // MARK: - Saving one list (F663)

    /// How one list's save ended.
    private enum ListSave {
        case saved
        case lostRace(WriteConflictReport)
        case failed
    }

    /// Applies one change to `list` and saves it; returns whether the change is on disk (true when
    /// there was nothing to save).
    ///
    /// `stage` makes the change in memory and says whether it changed anything. A save that loses to
    /// another copy of the app re-reads this list alone and runs `stage` once more against what that
    /// copy saved, then saves again — the F433/F642 shape, without an offer, because a list change is
    /// one small known operation that can simply be made again. This used to set the meeting index's
    /// `writeConflict`/`unsavedChanges` and the generic alert, and never refreshed the list's token,
    /// so every later edit to that list failed the same compare-and-swap until a relaunch.
    ///
    /// Any other way the change does not land puts the list back as it was, so the screen shows what
    /// is on disk, and says why in `storageErrorMessage`. A second lost race re-reads too, so the next
    /// edit is compared against what is on disk, and is said rather than tried a third time.
    @discardableResult
    private func commitListChange(_ list: EditableList, _ stage: () -> Bool) -> Bool {
        var before = (vocabulary, replacementRules)
        guard stage() else { return true }
        switch saveList(list) {
        case .saved:
            return true
        case .failed:
            restoreList(list, from: before)
            return false
        case .lostRace:
            reloadList(list)
        }
        let state = health(of: list)
        guard state.allowsMutation else {
            storageErrorMessage = DamagedListNotice.refused(list, health: state)
            return false
        }
        before = (vocabulary, replacementRules)
        guard stage() else { return true }
        switch saveList(list) {
        case .saved:
            return true
        case .failed:
            restoreList(list, from: before)
            return false
        case let .lostRace(report):
            reloadList(list)
            storageErrorMessage = "\(report.message) It changed the list again while this change was being saved, so this change was not saved. The list now shows what the other copy saved; make the change again."
            return false
        }
    }

    /// Saves `list` against the generation this store last read or wrote for it. An ordinary failure
    /// is said here; a lost race is the caller's to recover. Neither touches `writeConflict` or
    /// `unsavedChanges` (F663): those describe the meeting index, and are what the meeting conflict
    /// recovery and its banner read.
    private func saveList(_ list: EditableList) -> ListSave {
        beforeIndexSaveForTesting?()
        do {
            switch list {
            case .vocabulary:
                vocabularyToken = try vocabularyFiles.save(vocabulary, expecting: vocabularyToken).token
            case .replacementRules:
                replacementRulesToken = try replacementRulesFiles.save(
                    replacementRules, expecting: replacementRulesToken
                ).token
            }
            storageErrorMessage = restingStorageMessage   // nil unless F553's notice is up
            return .saved
        } catch {
            let report = WriteConflictReport(error)
            if report.isRace { return .lostRace(report) }
            switch list {
            case .vocabulary:
                storageErrorMessage = "Vocabulary changes could not be saved. The last readable copy remains on this Mac. \(error.localizedDescription)"
            case .replacementRules:
                storageErrorMessage = "Replacement-rule changes could not be saved. The last readable copy remains on this Mac. \(error.localizedDescription)"
            }
            return .failed
        }
    }

    private func restoreList(_ list: EditableList, from snapshot: ([String], [ReplacementRule])) {
        switch list {
        case .vocabulary: vocabulary = snapshot.0
        case .replacementRules: replacementRules = snapshot.1
        }
    }

    /// Re-reads one list from disk, and nothing else — not the meeting index, not the other list.
    private func reloadList(_ list: EditableList) {
        switch list {
        case .vocabulary: readVocabulary()
        case .replacementRules: readReplacementRules()
        }
    }

    /// Not `private` (F525): `ReplacementRuleAddition.atLimit`'s sentence quotes it.
    nonisolated static let maxReplacementRules = 500

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
    ///
    /// The alert's OK is the acknowledgement F553's history notice waits for — but only when the
    /// notice is what the alert showed (F669). An OK on another storage message used to release the
    /// notice unread for the rest of the session; now the notice comes back to be read.
    ///
    /// One call is one dismissal, and the window's alert makes exactly one (its `isPresented`
    /// setter; the OK button itself does nothing — pinned by `alertClearsStorageOncePerDismissal`).
    /// It once made two per OK, and the second found the notice the first had just put back and
    /// released it. So the notice is not put back inside the dismissal: the message goes to nil
    /// and the notice returns on the next turn (`reshowPendingNotice`). A second call in the same
    /// turn therefore finds nil, not the notice, and cannot count it as read; and the alert is
    /// presented afresh rather than asked to re-present while it is still being dismissed.
    func clearStorageError() {
        if let notice = historyNoticeAwaitingDismissal, storageErrorMessage == notice {
            historyNoticeAwaitingDismissal = nil
        }
        storageErrorMessage = nil
        guard historyNoticeAwaitingDismissal != nil else { return }
        Task { [weak self] in self?.reshowPendingNotice() }
    }

    /// Shows F553's unread notice again once a dismissal of something else has finished (F669) —
    /// unless something else is being said by then, whose own dismissal brings it back in turn.
    private func reshowPendingNotice() {
        guard storageErrorMessage == nil, let notice = historyNoticeAwaitingDismissal else { return }
        storageErrorMessage = notice
    }

    /// What `storageErrorMessage` shows when nothing else is being said: F553's notice while it waits
    /// to be read, otherwise nil (F669). Every path that clears the message sets it to this rather
    /// than nil — the notice is its own fact, held in `historyNoticeAwaitingDismissal`, and the
    /// message only where it is shown, so a path that owns the message cannot erase the fact.
    private var restingStorageMessage: String? { historyNoticeAwaitingDismissal }

    private static func normalizeTerm(_ value: String) -> String {
        value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Storage-side normalization only (F187): trim, drop empties, dedupe, sort. The 1,000-character
    /// prompt budget belongs to `promptVocabulary`, not to what the user's file is allowed to contain.
    ///
    /// No ceiling here (F525): `addVocabulary` enforces `maxStoredVocabularyTerms` by refusing what
    /// does not fit. This used to cut the sorted list at the ceiling, which is what made an add evict
    /// stored terms — and at load it trimmed a longer file (another build's, or a hand edit) in memory,
    /// so the next save or Keep This List made the trim permanent.
    private static func storedTerms(_ values: [String]) -> [String] {
        Array(Set(values.map(normalizeTerm).filter { !$0.isEmpty }))
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
    }

    /// Not `private` (F492): the Vocabulary screen's header and the Add-result message
    /// (`VocabularyAddition.limitSentence`, F525) both quote this number, and a hand-copied literal in
    /// either one is exactly how they drifted apart — the header claimed 100 (the prompt's cap,
    /// `VocabularyPrompt.maxTerms`) while this constant, what storage actually enforces, was 5,000
    /// the whole time. The ceiling exists so a runaway paste cannot grow the file without bound; it is
    /// deliberately far above any budget a prompt could impose.
    nonisolated static let maxStoredVocabularyTerms = 5_000

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

    /// Whether this session has already told the user that the meeting index's past versions are
    /// not being kept (F553). Once per session: the condition is usually lasting — a file squatting
    /// `meetings.history`, a permissions change — and nearly every edit saves the index.
    private var didNoticeHistoryUnavailable = false
    /// That notice, while it waits for the alert's OK on it (`clearStorageError()`).
    ///
    /// Held apart from `storageErrorMessage` because every successful save used to clear that, and
    /// the next save — as little as the transcript debounce later — would take the notice off
    /// screen before anyone read it. Successful saves put THIS back instead of nil, so the notice
    /// stays up and, being the same value, is not posted again to the windowless channel, whose
    /// observer drops adjacent repeats. Since F669 so does every other path that clears the message
    /// (`restingStorageMessage`), and an OK on a different message does not release it.
    private var historyNoticeAwaitingDismissal: String?

    /// The user-facing words for `.historyUnavailable` (F553). Names no control: the recovery
    /// list's button only appears while the library is read-only, which this library is not.
    static func historyUnavailableNotice(reason: String) -> String {
        "Your meetings are being saved, but WhisperMeet cannot keep earlier versions of the meeting index right now (\(reason)). Until that is fixed, a bad change to your meeting list cannot be undone from the saved history. Your recordings and the current index are not affected."
    }

    /// What `storageErrorMessage` should read after a successful save: nil, unless this save — or
    /// an earlier one this session — found that no past version could be kept and the user has
    /// not yet dismissed the notice.
    private func historyNotice(after repairs: [BackupJSONStore<[MeetingRecord]>.StoreRepair]) -> String? {
        if !didNoticeHistoryUnavailable {
            for case let .historyUnavailable(reason) in repairs {
                didNoticeHistoryUnavailable = true
                historyNoticeAwaitingDismissal = Self.historyUnavailableNotice(reason: reason)
                break
            }
        }
        return historyNoticeAwaitingDismissal
    }

    /// Runs just before each save of the meeting index or of a list, so a test can put another copy's
    /// commit between two saves this store makes inside one call — the save `beginConflictRecovery()`
    /// makes for a new meeting right after its reload (F667), or a list's second try after a lost
    /// race (F663). Nil outside tests.
    var beforeIndexSaveForTesting: (() -> Void)?

    /// Returns whether the index actually reached disk, so a caller that is about to destroy
    /// something the index references can refuse to (F190). Callers that only mutate metadata can
    /// keep ignoring it.
    @discardableResult
    private func persistMeetings() -> Bool {
        // `persistCount` keeps its original position and meaning — "a save was attempted" — because
        // roughly fifteen existing assertions depend on both (F190).
        persistCount += 1
        beforeIndexSaveForTesting?()
        do {
            let outcome = try meetingFiles.save(meetings, expecting: meetingsToken)
            meetingsToken = outcome.token
            persistCommitCount += 1
            unsavedChanges = false
            writeConflict = nil
            storageErrorMessage = historyNotice(after: outcome.repairs)   // nil unless F553's notice is up
            // What actually reached disk (F433 follow-up) — a lost race's delta is diffed against
            // this, not against whatever any other writer happens to hold.
            lastPersistedMeetings = meetings
            return true
        } catch {
            unsavedChanges = true
            writeConflict = WriteConflictReport(error)
            storageErrorMessage = "Meeting changes could not be saved. The recording files and last readable index copy remain on this Mac. \(error.localizedDescription)"
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

    /// Keeps the index on disk when the load found two versions of the library (F833): moves
    /// `meetings.ledger.json` aside, kept beside the library, and reloads. Returns the name the
    /// ledger was kept under — nil when there was no ledger left to move, and the reload ran anyway.
    /// Does nothing unless the library is in that state.
    ///
    /// Allowed while the library is read-only, like `restoreIndexGeneration` and
    /// `installRebuiltIndex`, and safe for a stronger reason than either: it writes no index at all.
    /// Both versions stay where they are — the index in place, and the last save the ledger recorded
    /// as a generation in the history — so this only stops the ledger contradicting the index in
    /// place, which is what `docs/RECOVERY.md`'s manual step did with `rm`. Decided 2026-10-07 by the
    /// user: a button that moves the ledger aside, never deletes it. Only for `.divergentGenerations`;
    /// every other read-only state is about the index itself, which the ledger did not cause.
    func keepIndexOnDisk() throws -> String? {
        guard !isRestoringLibrary else { throw MeetingStoreError.libraryIsBeingRestored }
        guard health == .divergentGenerations else { return nil }
        let keptAs = try meetingFiles.setLedgerAside()
        // Health only ever worsens outside a recovery; this is one (`revalidateHealth`'s rule).
        reloadAfterLibraryRestore()
        if !isDegraded {
            storageErrorMessage = restingStorageMessage   // F553's notice stays until read (F669)
        }
        return keptAs
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
        // A snapshot from before this restore/rebuild describes a library that no longer exists
        // (F433 follow-up): keeping it would let `keepConflictedEdit()` reapply a stale edit over
        // whatever this restore just installed.
        conflictOffer = nil
        // Only when the library really is writable again. Clearing this unconditionally asserted
        // "no storage problem" about a library the reload had just found still unreadable.
        if !isDegraded {
            storageErrorMessage = restingStorageMessage   // F553's notice stays until read (F669)
        }
    }

    /// Recomputes every store's health from disk, exactly as `init` does (F193).
    ///
    /// This is the **only** place `health` is assigned outside `degrade(to:)`, and the reset is safe
    /// only because the loads run immediately after it: afterwards each health is again what its
    /// file *currently* loads to, not the worst it ever reached. A store that is still broken
    /// degrades right back, so recovery cannot whitewash one that is still unreadable — and since
    /// F464 each list answers only for itself, so restoring the meeting index returns the library
    /// to writable even while a damaged vocabulary stays read-only on its own.
    ///
    /// Only recovery may call this. Nothing on a save path should reconsider health.
    private func revalidateHealth() {
        health = .complete
        vocabularyHealth = .complete
        replacementRulesHealth = .complete
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
        // As in `adoptRestoredIndex` (F433 follow-up): a snapshot from before a whole-library
        // restore describes a library the restore just replaced.
        conflictOffer = nil
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
            storageErrorMessage = restingStorageMessage   // F553's notice stays until read (F669)
        }
    }

    /// Re-reads the library after a lost race, so the next save can succeed.
    ///
    /// A conflict is a transient race, not a damaged library: nothing was made read-only, and the
    /// refused body is on disk as a `conflict-` branch. This replaces the in-memory `meetings` with
    /// what is actually on disk — the losing edit is not destroyed by that, only no longer what
    /// `meetings` holds. `beginConflictRecovery()` (F433) is the only caller: it retains the
    /// pre-reload snapshot in `conflictOffer` before calling this, so the choice this comment used
    /// to require in advance is instead offered afterward, from that snapshot. Private since F642,
    /// when the last test that called it bare moved to the offer: a caller with no snapshot would
    /// discard the in-memory edit outright.
    private func reloadForConflictRecovery() {
        loadMeetings()
        writeConflict = nil
        unsavedChanges = false
        // Not nil (F669): this cleared F553's unread notice off screen until some later save put it
        // back. The conflict's own message is the offer's, not this.
        storageErrorMessage = restingStorageMessage
    }

    /// Worsen `health` toward `state`, and never improve it (F187).
    ///
    /// Written when three stores shared this one value: as a plain `health = result.health` it was
    /// last-writer-wins across three files, and a readable `vocabulary.json` loading after a corrupt
    /// `meetings.json` put `.complete` back and re-opened every mutator on a library that could not
    /// be read. Since F464 only the meeting index feeds it, and it stays monotonic for the reason
    /// given on `health`: `loadMeetings` can reach two verdicts, and `reloadForConflictRecovery`
    /// reloads without resetting. `.complete` is rank 0 in `PersistedStoreHealth.severity`, so it can
    /// only ever be the starting value, never an upgrade.
    private func degrade(to state: PersistedStoreHealth) {
        guard state.isWorse(than: health) else { return }
        health = state
    }

    /// What a failed load implies. Fails CLOSED: a load that threw is never a healthy store, so the
    /// `else` covers every error this does not recognize. Shared by every load path so the rule
    /// cannot drift between them — `BackupJSONStoreError` lives in WhisperCore, and a new case there
    /// raises no warning here (F187).
    private static func health(after error: Error) -> PersistedStoreHealth {
        if let storeError = error as? BackupJSONStoreError,
           case let .noReadableCopy(_, _, quarantined) = storeError {
            return .unreadable(quarantined: quarantined)
        }
        return .unavailable(error.localizedDescription)
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

    /// A loaded record, with a language name an earlier build stored read as its code (F535).
    ///
    /// Before F535 a Whisper meeting transcribed under a pinned language stored "Chinese" or
    /// "English" — the name openai-whisper echoes back — where every other path stores "zh"/"en".
    /// `lang:` search and `TranscriptLanguageFilter` compare the field as a code, and the detail
    /// chip and exports print it. `TranscriptionResult` now normalises, so nothing new can store a
    /// name; this is for libraries that already hold one. It changes memory only: the file follows
    /// at the next save, and "zh"/"en" are what earlier builds already read from every Qwen meeting.
    private static func withLanguageCodeNormalized(_ record: MeetingRecord) -> MeetingRecord {
        var record = record
        record.languageCode = WhisperLanguage.code(forReported: record.languageCode)
        return record
    }

    private func loadMeetings() {
        do {
            guard let result = try meetingFiles.load() else { return }
            meetings = MeetingOrdering.sorted(result.value.map(Self.withLanguageCodeNormalized))
            // What this session now believes is persisted (F433 follow-up) — a load establishes a
            // fresh baseline, whether at launch or after a conflict's reload.
            lastPersistedMeetings = meetings
            // A reload replaces every record, so no memo can describe one (F541): a meeting a
            // restore removed would otherwise keep its transcript copy in memory until quit.
            transcriptEditMemos.removeAll()
            meetingsToken = result.token
            degrade(to: result.health)
            // `.recoveredFromBackup` says nothing here any more (F540): this paragraph ended "confirm the
            // library looks right before editing", for a library that is read-only and refuses every edit,
            // and `performStartupRecovery` then added a sentence saying the damaged index "was copied
            // aside", which this path never does. `ReadOnlyLibraryNotice.startup(for:)` is the one account.
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
            degrade(to: Self.health(after: error))
            startupRecoveryMessages.append(error.localizedDescription)
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
        readVocabulary()
        recordDamage(to: .vocabulary)
    }

    /// `loadVocabulary` without the launch alert's notice, for a re-read after a lost race (F663) —
    /// a mid-session reload has no launch alert to add to.
    private func readVocabulary() {
        do {
            if let result = try vocabularyFiles.load() {
                vocabulary = Self.storedTerms(result.value)
                vocabularyToken = result.token
                // The list's own health, never the library's (F464). No re-persist on a backup
                // recovery either: that writes nothing, so the damaged primary is left exactly as it
                // is (F187, and what `docs/RECOVERY.md` promises). The old `save()` ran during
                // `init`, bypassing every mutation guard.
                vocabularyHealth = result.health
            }
        } catch {
            // The same state `init` starts from, so the notice's "the list is empty" is true on a
            // recovery's reload as well — and no token, so nothing arms a checked write against a
            // generation this load could not read.
            vocabulary = []
            vocabularyToken = nil
            vocabularyHealth = Self.health(after: error)
        }
    }

    private func loadReplacementRules() {
        readReplacementRules()
        recordDamage(to: .replacementRules)
    }

    /// As `readVocabulary`, for the rules (F663).
    private func readReplacementRules() {
        do {
            if let result = try replacementRulesFiles.load() {
                replacementRules = result.value
                replacementRulesToken = result.token
                // As `loadVocabulary`: its own health, and no silent re-persist (F187, F464).
                replacementRulesHealth = result.health
            }
        } catch {
            replacementRules = []
            replacementRulesToken = nil
            replacementRulesHealth = Self.health(after: error)
        }
    }

    /// Puts a damaged list's notice in the launch alert as well as beside the list (F464). The same
    /// sentence as the view's, generated in one place. Without the "recording is unaffected" tail
    /// while the meeting library is read-only, which it would contradict — `loadMeetings` runs
    /// first, so `isDegraded` is already this load's answer.
    private func recordDamage(to list: EditableList) {
        guard let notice = DamagedListNotice.notice(
            for: list, health: health(of: list), libraryIsWritable: !isDegraded
        ) else { return }
        startupRecoveryMessages.append(notice)
    }
}
