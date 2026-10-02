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
    public static func isShrunkCapture(_ name: String) -> Bool {
        name == "meeting.m4a" || name == "meeting-recovered.m4a"
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
            guard lower != keep else { return nil }
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
        public var rebuildOffered: Bool
        /// The recording's decoded length when it could be read, else the index's duration.
        public var durationSeconds: TimeInterval
        public var entries: [FolderEntry]

        public init(recordingName: String, recordingExists: Bool, inOwnFolder: Bool, hasIntegrityProblem: Bool,
                    rebuildOffered: Bool, durationSeconds: TimeInterval, entries: [FolderEntry]) {
            self.recordingName = recordingName
            self.recordingExists = recordingExists
            self.inOwnFolder = inOwnFolder
            self.hasIntegrityProblem = hasIntegrityProblem
            self.rebuildOffered = rebuildOffered
            self.durationSeconds = durationSeconds
            self.entries = entries
        }
    }

    /// The app's state at the moment of asking. These clear on their own.
    public struct LiveFacts: Sendable, Equatable {
        public var libraryReadOnly = false
        public var captureOrImportInProgress = false
        public var meetingBusy = false
        public var backupRunning = false
        public var anotherShrinkRunning = false
        public init() {}
    }

    public enum Unavailability: Sendable, Equatable {
        case unsupportedRecording
        case recordingMissing
        case damaged(rebuildOffered: Bool)
        case cannotMeasureLength
        case alreadyShrunk
        case nothingToGain
        case libraryReadOnly
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
            case .cannotMeasureLength:
                return "This recording's length can't be read, so a compressed copy couldn't be checked against it."
            case .alreadyShrunk:
                return "Already shrunk."
            case .nothingToGain:
                return "Already compact: shrinking would save less than a quarter of its space."
            case .libraryReadOnly:
                return "The library is read-only, so nothing can be changed."
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
        if isShrunkCapture(disk.recordingName) {
            // Resume mode: nothing is encoded, so damage and size rules about an encode don't apply.
            if removableFiles(in: disk.entries, keeping: output).isEmpty { return .alreadyShrunk }
        } else {
            if disk.hasIntegrityProblem || disk.rebuildOffered {
                return .damaged(rebuildOffered: disk.rebuildOffered)
            }
            guard disk.durationSeconds.isFinite, disk.durationSeconds > 0 else { return .cannotMeasureLength }
            let reclaim = reclaimableBytes(in: disk.entries, recordingName: disk.recordingName, outputName: output)
            let predicted = predictedOutputBytes(durationSeconds: disk.durationSeconds)
            if !isWorthShrinking(encodedBytes: predicted, reclaimableBytes: reclaim) { return .nothingToGain }
        }
        if live.libraryReadOnly { return .libraryReadOnly }
        if live.captureOrImportInProgress { return .captureOrImportInProgress }
        if live.meetingBusy { return .meetingBusy }
        if live.backupRunning { return .backupRunning }
        if live.anotherShrinkRunning { return .anotherShrinkRunning }
        return nil
    }
}
