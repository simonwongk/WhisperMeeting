import Foundation

/// What Shrink (F795) may remove from a meeting's folder, what it writes, and when it is refused.
///
/// Pure: it sees names and sizes, never the disk, so each rule in `docs/MEETING_STORAGE_DESIGN.md`
/// is a unit test. The app collects the facts (`DiskFacts`, `LiveFacts`) and acts on the answers.
public enum MeetingStoragePlan {
    /// One regular file in a meeting's folder: its name relative to the folder, and its size on disk.
    public struct FolderEntry: Sendable, Equatable {
        public let name: String
        public let bytes: Int64
        public init(name: String, bytes: Int64) {
            self.name = name
            self.bytes = bytes
        }
    }

    /// AAC at `-b 32000` measured 32,928 bit/s on a bench clip (F795): about 4,116 bytes a second.
    public static let predictedBytesPerSecond: Double = 4_100

    /// The shrunk recording's name, or nil for a recording Shrink does not handle.
    ///
    /// The stem is kept and only the extension changes, because the stem is how
    /// `InterruptedRecordingRecovery.finalizedRecording` tells a capture, a rebuild (F273) and an
    /// import apart after a lost index. A name that is already `.m4a` keeps its exact spelling: on a
    /// case-insensitive volume `recording.M4A` and `recording.m4a` are one file, and writing one then
    /// deleting the other would delete the output.
    public static func outputName(forRecordingNamed name: String) -> String? {
        let url = URL(fileURLWithPath: name)
        let stem = url.deletingPathExtension().lastPathComponent
        let ext = url.pathExtension.lowercased()
        guard !ext.isEmpty else { return nil }
        switch stem {
        case "meeting", "meeting-recovered":
            guard ext == "wav" || ext == "m4a" else { return nil }
        case "recording":
            break
        default:
            return nil
        }
        return ext == "m4a" ? name : stem + ".m4a"
    }

    /// Whether `name` is a recording Shrink wrote for an in-app capture or rebuild. Such a meeting is
    /// never encoded again; Shrink only finishes removing what an interrupted run left behind.
    /// Whether Shrink only has to finish an earlier, interrupted run: the recording is already its
    /// AAC output and the originals it replaced are still there. A capture's `meeting*.m4a` is always
    /// Shrink's own output; an import's `recording.m4a` beside a leftover `recording.<ext>` can only
    /// come from Shrink's commit, since an import keeps exactly one file. Nothing is encoded again.
    public static func isResume(_ disk: DiskFacts) -> Bool {
        if isShrunkCapture(disk.recordingName) { return true }
        guard URL(fileURLWithPath: disk.recordingName).pathExtension.lowercased() == "m4a",
              let output = outputName(forRecordingNamed: disk.recordingName) else { return false }
        return !removableFiles(in: disk.entries, keeping: output).isEmpty
    }

    public static func isShrunkCapture(_ name: String) -> Bool {
        ["meeting.m4a", "meeting-recovered.m4a"].contains(name.lowercased())
    }

    /// Whether the recording's container can hold more than one audio track, so its tracks are
    /// counted before it is shrunk (F801). An import keeps the container it came in, and a movie or
    /// MPEG-4 file can carry a track per side of a call. A capture's recording is the app's own mono
    /// WAV, or Shrink's one-track `.m4a`.
    public static func mayHoldSeveralAudioTracks(_ recordingName: String) -> Bool {
        URL(fileURLWithPath: recordingName).deletingPathExtension().lastPathComponent == "recording"
    }

    /// The other `recording.<ext>` files in a meeting's folder: every top-level file with an import's
    /// stem except the recording itself. Shrink removes each of them (`removableFiles`), or, the one
    /// that already has the output's name, replaces it with the output. A link import whose
    /// extraction was interrupted keeps its complete download among them (F911).
    public static func otherRecordings(in entries: [FolderEntry], recordingName: String) -> [FolderEntry] {
        let recording = recordingName.lowercased()
        return entries.filter { entry in
            let lower = entry.name.lowercased()
            guard lower != recording, !lower.contains("/") else { return false }
            let url = URL(fileURLWithPath: lower)
            return url.deletingPathExtension().lastPathComponent == "recording" && !url.pathExtension.isEmpty
        }
    }

    /// The first other `recording.<ext>` that is not shown to hold no more audio than the recording, or
    /// nil (F911). Shown means measured (`DiskFacts.otherRecordingSeconds`) and running no more than
    /// `InterruptedLinkImportExtraction.lengthTolerance` past the recording; an empty file holds
    /// nothing. Fail-closed: a file with no measurement is at risk, so a caller that never measured
    /// refuses rather than deletes.
    public static func otherRecordingAtRisk(_ disk: DiskFacts) -> FolderEntry? {
        otherRecordings(in: disk.entries, recordingName: disk.recordingName).first { entry in
            guard entry.bytes > 0 else { return false }
            guard let seconds = disk.otherRecordingSeconds[entry.name], seconds.isFinite,
                  disk.durationSeconds.isFinite, disk.durationSeconds > 0 else { return true }
            return seconds > disk.durationSeconds + InterruptedLinkImportExtraction.lengthTolerance
        }
    }

    /// Below this RMS level (about -80 dBFS) a recording counts as silence for `levelsAgree`: there is
    /// no sound to lose, and a ratio against it means nothing.
    public static let silenceLevel = 0.000_1

    /// How far a compressed copy's level may be from its original's, as a ratio (F801). Measured
    /// through Shrink's own two-step encode on this Mac, the original's level taken over all its
    /// channels' samples: speech 0.997, a mono tone and stereo with identical channels 1.000, stereo
    /// with one side per channel (or right only) 0.707 — the mono mix halves each side — white
    /// noise 0.535 and right-only white noise 0.379 — the working WAV is 16 kHz, so whatever lies
    /// above 8 kHz is gone, which broadband noise has most of — and a silent encode, or a stereo pair
    /// that cancels in the mix, 0. A quarter clears the lowest of those with room to spare and still
    /// refuses a copy 12 dB quieter; four times is the same margin the other way, for a copy that
    /// came out as something other than the recording.
    public static let levelRatioBand: ClosedRange<Double> = 0.25...4

    /// Whether a compressed copy carries the recording's sound (F801). Its length alone did not show
    /// it: an encode that came out silent has the right length. Both levels are RMS over every
    /// channel's samples, decoded the same way, so the original's is the sound before any mixing:
    /// read after the mono mix instead, a stereo recording whose channels cancel in that mix read as
    /// silence on both sides and was shrunk to silence (F801 review). The copy is mono. A silent
    /// original agrees with anything; a level that is not a finite, non-negative number agrees with
    /// nothing.
    public static func levelsAgree(original: Double, compressed: Double) -> Bool {
        guard original.isFinite, compressed.isFinite, original >= 0, compressed >= 0 else { return false }
        guard original >= silenceLevel else { return true }
        return levelRatioBand.contains(compressed / original)
    }

    /// How long a stretch the copy's level is also compared over, besides the whole file (F801 review).
    public static let levelWindowSeconds: Double = 5

    /// The first `levelWindowSeconds` stretch in which a compressed copy lost the recording's sound,
    /// or nil when none did (F801 review). The whole-file band cannot see a copy of the right length
    /// that holds only part of the recording: one holding the first fifth reads sqrt(0.2) ≈ 0.45 of
    /// the level, inside the band. So every stretch in which the original is audible — at least a
    /// tenth of its whole-file level, and above `silenceLevel` — must keep at least the band's lower
    /// bound of its level in the copy. Lower bound only: the windows look for missing sound. Measured
    /// per window through Shrink's encode: lowest legitimate ratio 0.377 (right-only white noise),
    /// speech at least 0.996, also when it drops to a fifth of the level after a loud start.
    /// Windows past the shorter list's end are not compared; the length check covers a short copy.
    public static func firstWindowLosingSound(original: [Double], compressed: [Double], originalLevel: Double) -> Int? {
        let audible = Swift.max(silenceLevel, originalLevel / 10)
        for index in 0..<Swift.min(original.count, compressed.count) where original[index] >= audible {
            let copy = compressed[index]
            guard copy.isFinite, copy >= original[index] * levelRatioBand.lowerBound else { return index }
        }
        return nil
    }

    /// The files Shrink removes, in the order it removes them. Only names on this list are ever removed.
    ///
    /// The order is what keeps a folder from looking damaged if the app stops partway (design, step 7):
    /// manifests before tracks, so Verify Library never sees a track shorter than its manifest; tracks
    /// before the old WAVs, so `SourceRebuild.offer` never sees tracks with no complete WAV.
    public static func removableFiles(in entries: [FolderEntry], keeping outputName: String) -> [FolderEntry] {
        let keep = outputName.lowercased()
        func rank(_ name: String) -> Int? {
            let lower = name.lowercased()
            // Only the meeting folder's own top-level files: a nested `sub/recording.txt` is the
            // user's, whatever it is called (final review).
            guard lower != keep, !lower.contains("/") else { return nil }
            switch lower {
            case "source-tracks.json", "source-tracks.recovered.json": return 0
            case "system-audio.f32", "microphone-audio.f32": return 1
            case ".meeting.wav.mixing": return 2
            case "meeting.wav", "meeting-recovered.wav": return 3
            default: break
            }
            if lower.hasPrefix(".shrink-") { return 2 }
            if lower.hasPrefix("meeting-recovered-superseded-"), lower.hasSuffix(".wav") { return 2 }
            let url = URL(fileURLWithPath: lower)
            if url.deletingPathExtension().lastPathComponent == "recording", !url.pathExtension.isEmpty { return 3 }
            return nil
        }
        return entries
            .compactMap { entry in rank(entry.name).map { (entry, $0) } }
            .sorted { $0.1 != $1.1 ? $0.1 < $1.1 : $0.0.name < $1.0.name }
            .map(\.0)
    }

    /// *R* in the design: what a shrink frees. Every removable file, plus the recording itself when
    /// the output replaces it in place.
    public static func reclaimableBytes(in entries: [FolderEntry], recordingName: String, outputName: String) -> Int64 {
        var total = totalBytes(removableFiles(in: entries, keeping: outputName))
        if recordingName.lowercased() == outputName.lowercased(),
           let recording = entries.first(where: { $0.name.lowercased() == recordingName.lowercased() }) {
            total = totalBytes([FolderEntry(name: "", bytes: total), recording])
        }
        return total
    }

    /// The predicted size of the encoded `.m4a`, before encoding.
    public static func predictedOutputBytes(durationSeconds: TimeInterval) -> Int64 {
        guard durationSeconds.isFinite || durationSeconds == .infinity else { return 0 }
        return Int64(saturating: Swift.max(0, durationSeconds) * predictedBytesPerSecond)
    }

    /// Worth it only when it saves at least a quarter of what it frees: *E* ≤ *R* − *R*/4.
    public static func isWorthShrinking(encodedBytes: Int64, reclaimableBytes: Int64) -> Bool {
        guard reclaimableBytes > 0 else { return false }
        return encodedBytes <= reclaimableBytes - reclaimableBytes / 4
    }

    /// The sum of `entries`, saturating rather than trapping.
    public static func totalBytes(_ entries: [FolderEntry]) -> Int64 {
        entries.reduce(Int64(0)) { sum, entry in
            let (value, overflow) = sum.addingReportingOverflow(Swift.max(0, entry.bytes))
            return overflow ? .max : value
        }
    }

    /// What the disk says about one meeting, gathered off the main actor.
    public struct DiskFacts: Sendable, Equatable {
        public var recordingName: String
        public var recordingExists: Bool
        /// The recording sits directly in the meeting's own `Recordings/<id>/` folder.
        public var inOwnFolder: Bool
        /// Verify Library reports a problem (`IntegrityFinding.isProblem`) for this recording.
        public var hasIntegrityProblem: Bool
        /// Rebuild Audio would recover more audio than the recording holds (F256's truncation). Not
        /// merely "an offer exists": a recovered folder never has a complete `meeting.wav`, so it is
        /// always offered, and treating that as damage made every recovered meeting unshrinkable.
        public var rebuildOffered: Bool
        /// The recording's decoded length when it could be read, else the index's duration.
        public var durationSeconds: TimeInterval
        public var entries: [FolderEntry]
        /// How many audio tracks the recording's container holds, when they were counted — only for
        /// a recording that `mayHoldSeveralAudioTracks` (F801). Nil when not counted or not readable.
        public var audioTrackCount: Int?
        /// How long each other `recording.<ext>` in the folder (`otherRecordings`) is, keyed by its name
        /// in `entries`, where it could be measured (F911). A name missing here was not measured.
        public var otherRecordingSeconds: [String: TimeInterval]
        /// How many channels the recording holds, read from its header (F801 review). Nil when not read
        /// or not readable.
        public var channelCount: Int?

        public init(recordingName: String, recordingExists: Bool, inOwnFolder: Bool, hasIntegrityProblem: Bool,
                    rebuildOffered: Bool, durationSeconds: TimeInterval, entries: [FolderEntry],
                    audioTrackCount: Int? = nil, otherRecordingSeconds: [String: TimeInterval] = [:],
                    channelCount: Int? = nil) {
            self.recordingName = recordingName
            self.recordingExists = recordingExists
            self.inOwnFolder = inOwnFolder
            self.hasIntegrityProblem = hasIntegrityProblem
            self.rebuildOffered = rebuildOffered
            self.durationSeconds = durationSeconds
            self.entries = entries
            self.audioTrackCount = audioTrackCount
            self.otherRecordingSeconds = otherRecordingSeconds
            self.channelCount = channelCount
        }
    }

    /// The app's state at the moment of asking. These clear on their own.
    public struct LiveFacts: Sendable, Equatable {
        public var libraryReadOnly = false
        public var captureOrImportInProgress = false
        public var meetingBusy = false
        public var backupRunning = false
        public var anotherShrinkRunning = false
        public var libraryRestoring = false
        public init() {}
    }

    public enum Unavailability: Sendable, Equatable {
        case unsupportedRecording
        case recordingMissing
        case damaged(rebuildOffered: Bool)
        /// The container holds more than one audio track, and the encode keeps only the first (F801).
        case multipleAudioTracks(count: Int)
        /// The recording holds more than two channels, and the encode's mono mix keeps only some of them
        /// (F801 review): with no channel layout, channel 1 alone.
        case multipleChannels(count: Int)
        /// Another `recording.<ext>` in the folder is not shown to hold no more audio than the
        /// recording, and Shrink would delete or replace it (F911) — a link import's complete download
        /// beside the shorter WAV an interrupted extraction finished. `seconds` is its length, nil when
        /// it could not be measured.
        case otherRecordingMayHoldMore(name: String, seconds: TimeInterval?)
        case cannotMeasureLength
        case alreadyShrunk
        case nothingToGain
        case libraryReadOnly
        case libraryRestoring
        case captureOrImportInProgress
        case meetingBusy
        case backupRunning
        case anotherShrinkRunning

        public var message: String {
            switch self {
            case .unsupportedRecording:
                return "This recording isn't stored in its own meeting folder, so Shrink can't tidy it safely."
            case .recordingMissing:
                return "The recording file is missing, so there is nothing to shrink."
            case .damaged(rebuildOffered: true):
                return "This recording is incomplete. Use Rebuild Audio first: shrinking now would keep the damage and delete the raw tracks that can repair it."
            case .damaged(rebuildOffered: false):
                return "Verify Library reports a problem with this recording, so it isn't shrunk: the damage would be kept and the original deleted."
            case let .multipleAudioTracks(count):
                let others = count == 2 ? "The other track" : "The other \(count - 1) tracks"
                return "This recording has \(count) audio tracks, and a shrunk copy keeps only the first. \(others) would be deleted with the original, so it isn't shrunk."
            case let .multipleChannels(count):
                return "This recording has \(count) channels, and a shrunk copy keeps only some of them. The others would be deleted with the original, so it isn't shrunk."
            case let .otherRecordingMayHoldMore(name, seconds?):
                return "This meeting's folder also holds “\(name)”, which runs \(TranscriptFormatter.clock(seconds)), longer than this recording. Shrinking would delete it, so it isn't shrunk."
            case let .otherRecordingMayHoldMore(name, nil):
                return "This meeting's folder also holds “\(name)”, and its length can't be read to show that this recording holds all of its audio. Shrinking would delete it, so it isn't shrunk."
            case .cannotMeasureLength:
                return "This recording's length can't be read, so a compressed copy couldn't be checked against it."
            case .alreadyShrunk:
                return "Already shrunk."
            case .nothingToGain:
                return "Already compact: shrinking would save less than a quarter of its space."
            case .libraryReadOnly:
                return "The library is read-only, so nothing can be changed."
            case .libraryRestoring:
                return "Wait for the library restore to finish."
            case .captureOrImportInProgress:
                return "Finish recording or importing first."
            case .meetingBusy:
                return "Wait for this meeting's transcription, speaker analysis or rebuild to finish."
            case .backupRunning:
                return "Wait for the backup to finish."
            case .anotherShrinkRunning:
                return "Another meeting is being shrunk."
            }
        }
    }

    /// Why Shrink can't run now, or nil when it can. Facts about the meeting come first, because they
    /// never clear on their own; busy states come last.
    public static func unavailability(disk: DiskFacts, live: LiveFacts) -> Unavailability? {
        guard disk.inOwnFolder, let output = outputName(forRecordingNamed: disk.recordingName) else {
            return .unsupportedRecording
        }
        guard disk.recordingExists else { return .recordingMissing }
        // F911: before the resume and encode rules alike, since both remove every other `recording.<ext>`.
        if let other = otherRecordingAtRisk(disk) {
            return .otherRecordingMayHoldMore(name: other.name, seconds: disk.otherRecordingSeconds[other.name])
        }
        if isResume(disk) {
            // Resume mode: nothing is encoded, so damage and size rules about an encode don't apply. Nor
            // do the track and channel rules, which are about what an encode keeps of the recording: here
            // the recording is already Shrink's output and is kept. What a resume removes are originals
            // an earlier run had already replaced with its copy; F911's rule above refuses one that runs
            // longer than the recording, and their tracks and channels are not read.
            if removableFiles(in: disk.entries, keeping: output).isEmpty { return .alreadyShrunk }
        } else {
            if disk.hasIntegrityProblem || disk.rebuildOffered {
                return .damaged(rebuildOffered: disk.rebuildOffered)
            }
            // F801: a track the shrunk copy cannot hold is never deleted with the original. Refused,
            // not warned about, because the loss is permanent and the confirmation is one click.
            if let tracks = disk.audioTrackCount, tracks > 1 { return .multipleAudioTracks(count: tracks) }
            // F801 review: the same for channels. The encode's mono mix (`-c 1 --mix`) mixes stereo
            // (F796) and a layout that gives each channel a position, but of a WAV with more than two
            // channels and no layout it keeps channel 1 alone — and with the channels at equal levels,
            // neither level check sees the loss. Refused whatever the layout, which is not read here, so
            // a positioned 5.1 or quad recording is refused too (F953).
            if let channels = disk.channelCount, channels > 2 { return .multipleChannels(count: channels) }
            guard disk.durationSeconds.isFinite, disk.durationSeconds > 0 else { return .cannotMeasureLength }
            let reclaim = reclaimableBytes(in: disk.entries, recordingName: disk.recordingName, outputName: output)
            let predicted = predictedOutputBytes(durationSeconds: disk.durationSeconds)
            if !isWorthShrinking(encodedBytes: predicted, reclaimableBytes: reclaim) { return .nothingToGain }
        }
        if live.libraryReadOnly { return .libraryReadOnly }
        if live.libraryRestoring { return .libraryRestoring }
        if live.captureOrImportInProgress { return .captureOrImportInProgress }
        if live.meetingBusy { return .meetingBusy }
        if live.backupRunning { return .backupRunning }
        if live.anotherShrinkRunning { return .anotherShrinkRunning }
        return nil
    }
}
