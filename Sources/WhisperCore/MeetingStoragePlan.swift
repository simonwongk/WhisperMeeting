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
        /// Its logical length, when it was read (F949). It differs from `bytes` for a dataless file —
        /// one iCloud's Optimize Storage evicted, or a File Provider placeholder — which takes no space
        /// on disk and still holds its whole recording elsewhere.
        public let logicalBytes: Int64?
        /// Which file it was when it was listed — volume, inode, size and modification time — when that was read
        /// (F1005). A same-size rewrite in place moves the modification time; an atomic replace moves the inode.
        public let identity: InterruptedLinkImportExtraction.FileIdentity?
        public init(name: String, bytes: Int64, logicalBytes: Int64? = nil,
                    identity: InterruptedLinkImportExtraction.FileIdentity? = nil) {
            self.name = name
            self.bytes = bytes
            self.logicalBytes = logicalBytes
            self.identity = identity
        }

        /// Whether it holds nothing: no bytes on disk, and no logical length either (F949).
        public var isEmpty: Bool { bytes <= 0 && (logicalBytes ?? 0) <= 0 }
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

    /// Whether Shrink only has to finish an earlier, interrupted run: the recording is already its
    /// AAC output and the originals it replaced are still there. Nothing is encoded again.
    ///
    /// A capture's `meeting*.m4a` is always Shrink's own output. An import's `recording.m4a` beside
    /// another `recording.<ext>` usually is too, but not only: a link import recovered from its M4A
    /// download (F453) can hold the WAV ffmpeg never finished, or since F911 a shorter finished one,
    /// beside it — recovery removes that WAV since F894, but not in a folder recovered by an earlier
    /// build, nor while a process still had it open. What makes such a resume safe is not where the
    /// files came from: `unavailability` refuses first while any other `recording.<ext>` is not shown
    /// to hold no more audio than the recording (F911).
    public static func isResume(_ disk: DiskFacts) -> Bool {
        if isShrunkCapture(disk.recordingName) { return true }
        guard URL(fileURLWithPath: disk.recordingName).pathExtension.lowercased() == "m4a",
              let output = outputName(forRecordingNamed: disk.recordingName) else { return false }
        return !removableFiles(in: disk.entries, keeping: output).isEmpty
    }

    /// Whether `name` is a recording Shrink wrote for an in-app capture or rebuild. Such a meeting is
    /// never encoded again; Shrink only finishes removing what an interrupted run left behind.
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
    /// nothing — empty by its logical length too, since a dataless file has no bytes on disk and its
    /// whole recording elsewhere (F949). Fail-closed: a file with no measurement is at risk, so a
    /// caller that never measured refuses rather than deletes.
    public static func otherRecordingAtRisk(_ disk: DiskFacts) -> FolderEntry? {
        otherRecordings(in: disk.entries, recordingName: disk.recordingName).first { entry in
            guard !entry.isEmpty else { return false }
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
    /// What it catches, measured through the real encoder (second review, R6): a lost stretch of steady
    /// sound from 4.7 s when it falls inside one window, missed up to 9.3 s at the worst alignment, and
    /// always from 9.4 s; of speech, a lost 1–2 s never, 7 s in 10 of 15 placements, 10 s in 13 of 13.
    /// A backstop against an encoder losing a stretch, not a proof that every second survived.
    public static func firstWindowLosingSound(original: [Double], compressed: [Double], originalLevel: Double) -> Int? {
        let audible = Swift.max(silenceLevel, originalLevel / 10)
        for index in 0..<Swift.min(original.count, compressed.count) where original[index] >= audible {
            let copy = compressed[index]
            guard copy.isFinite, copy >= original[index] * levelRatioBand.lowerBound else { return index }
        }
        return nil
    }

    /// What afconvert's mono mix — the encode Shrink runs — does with a two-channel file's channels, judged by
    /// the position each is laid out at (F1001, rounds 2 and 3). It mixes by position, in a WAV's mask and in a
    /// CAF's, an AIFF's or any container's channel layout alike, and of some positions it leaves a channel out
    /// of the copy altogether (review 1 of round 2, and review 2's R2-A: a voice on a channel laid out as LFE
    /// was missing from the copy and the original deleted).
    public enum ChannelPositions: Sendable, Equatable {
        /// Both channels reach the copy.
        case keepsBoth
        /// A channel is laid out at a position the mix leaves out (`positionsLeftOut`).
        case leavesOneOut
        /// A layout this has not been shown to keep both channels of: kept, fail-closed.
        case notShown
    }

    /// Positions the mix keeps a channel at, beside any other of them: measured, every ordered pair of these
    /// keeps both channels (F1001 round 3, `gates/r3-04-pairs.txt`, 529 pairs of two-channel CAFs through
    /// `AudioCompressor.compressSpeech`, each channel at least 0.034 of an even mix's 0.05). Core Audio channel
    /// labels: left, right (1, 2), left and right surround (5, 6), left and right centre (7, 8), centre
    /// surround (9), left and right surround direct (10, 11), top centre surround (12), vertical height left,
    /// centre and right (13–15), rear surround left and right (33, 34), left and right wide (35, 36), X/Y (206,
    /// 207), binaural left and right (208, 209), headphones left and right (301, 302).
    public static let positionsMixedEvenly: Set<UInt32> = [1, 2, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 33, 34, 35, 36,
                                                            206, 207, 208, 209, 301, 302]

    /// Centre (3) and mono (42): kept beside each other and beside every position of `positionsMixedEvenly`
    /// but X and Y (206, 207), measured; beside X or Y the mix leaves one out.
    public static let centredPositions: Set<UInt32> = [3, 42]

    /// Positions the mix leaves a channel at out of the copy, or silences, beside every partner measured: unused
    /// (0), LFE (4), top back left, centre and right (16–18), LFE 2 (37), centre surround direct (44), haptic
    /// (45), positions given by coordinates (100–104), Ambisonic X, Y, Z (201–203), mid and side (204, 205),
    /// discrete 0 and 1 (65,536, 65,537). Measured with left and right as partners, and the positional ones
    /// with every positional label (`gates/r3-04-pairs.txt`).
    public static let positionsLeftOut: Set<UInt32> = [0, 4, 16, 17, 18, 37, 44, 45, 100, 101, 102, 103, 104,
                                                        201, 202, 203, 204, 205, 65_536, 65_537]

    /// What the mix does with two channels laid out at `labels` (Core Audio channel labels, one per channel),
    /// or with no layout (nil): no layout, both in `positionsMixedEvenly`, both centred, a centred one beside one
    /// of those but X and Y, and the matrix-encoded pair (left total, right total: 38, 39, in either order) keep
    /// both; a position in `positionsLeftOut` leaves one out; anything else — a layout not of two labels (one
    /// that could not be read is an empty list), an unknown position, or a pair whose positions interact (left
    /// beside left total, measured to leave one out) — is not shown. A plain WAV, and one with mask 0, read as
    /// no layout. Measured: 1,156 ordered pairs, none against this rule.
    public static func monoMix(ofChannelLabels labels: [UInt32]?) -> ChannelPositions {
        guard let labels else { return .keepsBoth }
        guard labels.count == 2 else { return .notShown }
        let (first, second) = (labels[0], labels[1])
        if positionsLeftOut.contains(first) || positionsLeftOut.contains(second) { return .leavesOneOut }
        if positionsMixedEvenly.contains(first) && positionsMixedEvenly.contains(second) { return .keepsBoth }
        if centredPositions.contains(first) && centredPositions.contains(second) { return .keepsBoth }
        let besideXY: Set<UInt32> = [206, 207]
        if centredPositions.contains(first), positionsMixedEvenly.contains(second), !besideXY.contains(second) { return .keepsBoth }
        if centredPositions.contains(second), positionsMixedEvenly.contains(first), !besideXY.contains(first) { return .keepsBoth }
        if (first, second) == (38, 39) || (first, second) == (39, 38) { return .keepsBoth }
        return .notShown
    }

    /// The other `recording.<ext>` files a resume must check the copy against before it removes them
    /// (F955): those with several audio tracks or more than two channels, which a mix holds and a copy
    /// made before F942 did not — that build kept the first track or channel. Their length alone, which
    /// F911 compares, cannot tell the two apart.
    public static func otherRecordingsToVerify(_ disk: DiskFacts) -> [FolderEntry] {
        otherRecordings(in: disk.entries, recordingName: disk.recordingName).filter { other in
            guard !other.isEmpty, let tracks = disk.otherRecordingTracks[other.name] else { return false }
            if case .mixEveryChannel = RecordingMixPlan.decision(for: tracks) { return true }
            return false
        }
    }

    /// The other `recording.<ext>` files with one track of two channels, which Shrink checks against the copy
    /// before it removes them, as it checks such a recording (F1001): a resume's leftover, and outside a
    /// resume a link import's download beside the mono WAV extracted from it (review 2, F2-1). The encode's
    /// mono mix sums the channels, so a voice in opposite polarity on the two is not in the copy. A mono one
    /// is removed as before.
    public static func twoChannelRecordingsToVerify(_ disk: DiskFacts) -> [FolderEntry] {
        otherRecordings(in: disk.entries, recordingName: disk.recordingName).filter { other in
            guard !other.isEmpty, let tracks = disk.otherRecordingTracks[other.name] else { return false }
            return tracks.count == 1 && tracks[0].channels == 2
        }
    }

    /// The other `recording.<ext>` files whose tracks could not be read — a link import's WebM/Opus download,
    /// which AVFoundation cannot open — so neither `twoChannelRecordingsToVerify` nor `otherRecordingsToVerify`
    /// sees their channels (F1004). Shrink decodes each with the installed ffmpeg and checks it against the copy
    /// as it checks a two-channel file, before it removes anything; one it cannot decode, or that holds more
    /// than two channels, is kept. Their length alone, which F911 compares, cannot show a voice in opposite
    /// polarity on the two channels, which the mono copy does not hold. An empty file holds nothing.
    public static func unreadRecordingsToVerify(_ disk: DiskFacts) -> [FolderEntry] {
        otherRecordings(in: disk.entries, recordingName: disk.recordingName).filter { other in
            !other.isEmpty && disk.otherRecordingTracks[other.name] == nil
        }
    }

    /// **The switch for Shrink of a recording that needs mixing — off (F980).** Wave 6 built it (F942):
    /// mix every track and channel into the copy, then show with `RecordingMixer.audit` and
    /// `RecordingMixPlan.firstFinding` that the copy holds each one before deleting the original. Its
    /// second review deleted originals whose sound was not in the copy anyway, with the real mixer: a quiet
    /// track whose stereo channels cancel, judged only above a tenth of the whole recording's level (D1),
    /// and a float WAV with one NaN channel, which silenced the mix while the audit read NaN as silence
    /// (D2); and it refused good ffmpeg-made copies about half the time. So Shrink refuses every recording
    /// that needs mixing (`mixingNotAvailableYet`), and a resume keeps a leftover that would need it — the
    /// integrator's decision of 2026-10-12, following the user's answer to F942, "keep refusing now, mix
    /// later". Transcription keeps mixing: it deletes nothing. F980 rewrote the audit (one-second windows,
    /// per-track alignment, fail closed on what it cannot measure) and no probe of either review deletes an
    /// original through it; but a good copy of tracks that share their sound — identical tracks, OBS's
    /// master beside its stems, a dual-mono track beside a mono one — is still refused in some runs, so the
    /// switch stays off until that is fixed too (the integrator's condition of 2026-10-15). The mixing
    /// Shrink stays in place behind this switch and its tests run it; a test pins that it is off.
    public static let shrinkMixesRecordings = false

    /// Whether Shrink mixes this recording into its copy rather than encoding it as it is (F942): it
    /// has several audio tracks, or more than two channels. One or two channels of one track are mixed
    /// by the encode itself (F796). While `shrinkMixesRecordings` is off, such a recording is refused.
    public static func needsMix(_ disk: DiskFacts) -> Bool {
        (disk.audioTrackCount ?? 1) > 1 || (disk.channelCount ?? 0) > 2
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

    /// What Shrink's delete step removes now (F949): `removableFiles` of a listing taken just before the
    /// removal (`current`), but only the files the checks ran on (`measured`, the listing `DiskFacts`
    /// was read from) and as they were then — the same name, size on disk and logical length, and, where the
    /// measured listing read it, the same file: volume, inode, size and modification time (F1005). A file
    /// that appeared or changed in between was never measured: F911's check that it holds no more
    /// audio than the recording never saw it, so it is kept, in `changed`, for the next Shrink to
    /// measure. Removing every name in the fresh listing, as before, let the deletion and the safety
    /// check read different facts; and a same-size rewrite in place kept the name and the sizes, so the
    /// identity is compared too. A measured identity the current listing could not read is a change.
    public static func removableNow(current: [FolderEntry], measured: [FolderEntry], keeping outputName: String)
        -> (remove: [FolderEntry], changed: [FolderEntry]) {
        var seen: [String: FolderEntry] = [:]
        for entry in measured { seen[entry.name.lowercased()] = entry }
        var remove: [FolderEntry] = [], changed: [FolderEntry] = []
        for entry in removableFiles(in: current, keeping: outputName) {
            if let before = seen[entry.name.lowercased()], before.bytes == entry.bytes,
               before.logicalBytes == entry.logicalBytes, before.identity == nil || before.identity == entry.identity {
                remove.append(entry)
            } else {
                changed.append(entry)
            }
        }
        return (remove, changed)
    }

    /// Whether the commit may put the copy at `outputName` (F1005): when a file already has that name — a link
    /// import's `recording.m4a` download, or an `.m4a` recording re-encoded under its own name — it is replaced,
    /// so it must be the file the checks measured (`measured`, by name, with the same identity as `current`, the
    /// file there now). Nothing there is fine; a file that appeared since, or changed, or whose identity was not
    /// read either time, is not.
    public static func mayReplaceOutput(named outputName: String, current: InterruptedLinkImportExtraction.FileIdentity?,
                                        exists: Bool, measured: [FolderEntry]) -> Bool {
        guard exists else { return true }
        guard let current,
              let before = measured.first(where: { $0.name.lowercased() == outputName.lowercased() }),
              let identity = before.identity else { return false }
        return identity == current
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
        /// What each of the recording's audio tracks holds, read with AVFoundation when it has several
        /// tracks or more than two channels, so the plan can tell whether they can be mixed into the copy
        /// (F942). Nil when not read or not readable.
        public var audioTracks: [RecordingMixPlan.Track]?
        /// What each other `recording.<ext>` in the folder holds, track by track, keyed like
        /// `otherRecordingSeconds`, where it could be read (F955). A name missing here was not read, and is
        /// judged by its length alone, as before.
        public var otherRecordingTracks: [String: [RecordingMixPlan.Track]]
        /// The first of the recording and the other `recording.<ext>` files that is a two-channel file whose
        /// channel layout the encode's mix is not shown to keep both channels of (`monoMix(ofChannelLabels:)`),
        /// with what the rule says of it; nil when none is (F1001).
        public var channelLayoutRefused: ChannelLayoutRefusal? = nil

        public init(recordingName: String, recordingExists: Bool, inOwnFolder: Bool, hasIntegrityProblem: Bool,
                    rebuildOffered: Bool, durationSeconds: TimeInterval, entries: [FolderEntry],
                    audioTrackCount: Int? = nil, otherRecordingSeconds: [String: TimeInterval] = [:],
                    channelCount: Int? = nil, audioTracks: [RecordingMixPlan.Track]? = nil,
                    otherRecordingTracks: [String: [RecordingMixPlan.Track]] = [:]) {
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
            self.audioTracks = audioTracks
            self.otherRecordingTracks = otherRecordingTracks
        }
    }

    /// A file Shrink would remove, or encode, whose channel layout it refuses (F1001).
    public struct ChannelLayoutRefusal: Sendable, Equatable {
        public var name: String
        public var positions: ChannelPositions
        public init(name: String, positions: ChannelPositions) {
            self.name = name
            self.positions = positions
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
        /// The container holds more than one audio track, and they could not be read to mix them into the
        /// copy, which would then keep only the first (F801, F942).
        case multipleAudioTracks(count: Int)
        /// The container's audio tracks are alternatives of one another — one alternate group, tagged with different
        /// languages: summing them would make none intelligible, and a copy keeps one track (F942, review R3).
        case alternateAudioTracks(count: Int)
        /// The recording holds more than two channels, and they could not be read to mix them into the
        /// copy, whose plain mono mix keeps only some of them — with no channel layout, channel 1 alone
        /// (F801 review, F942).
        case multipleChannels(count: Int)
        /// A mix of more channels than Shrink checks one by one in its copy (`RecordingMixPlan.mostCheckedChannels`,
        /// review of F942, R2): not shown to hold them all, so not shrunk.
        case tooManyChannelsToCheck(count: Int)
        /// The recording needs mixing — several audio tracks, or more than two channels — and Shrink of such
        /// a recording is held back until F980 (`shrinkMixesRecordings`). `tracks` and `channels` are what
        /// was read: the tracks, and their channels in all.
        case mixingNotAvailableYet(tracks: Int, channels: Int)
        /// Another `recording.<ext>` in the folder is not shown to hold no more audio than the
        /// recording, and Shrink would delete or replace it (F911) — a link import's complete download
        /// beside the shorter WAV an interrupted extraction finished. `seconds` is its length, nil when
        /// it could not be measured.
        case otherRecordingMayHoldMore(name: String, seconds: TimeInterval?)
        /// Another `recording.<ext>` in the folder has several audio tracks or more than two channels, and
        /// the copy is not shown to hold every one of them (F955): its tracks are alternatives that are
        /// never mixed, or could not be read, or — outside a resume, which checks the copy against it
        /// before removing it — nothing compares it with the copy at all.
        case otherRecordingHasMoreTracks(name: String, tracks: Int, channels: Int)
        /// A two-channel file — the recording, or another `recording.<ext>` Shrink would delete — lays a channel
        /// out at a position the encode's mix leaves out of the copy (`ChannelPositions.leavesOneOut`, F1001).
        case channelLayoutLeavesOneOut(name: String)
        /// Or lays its channels out in a way the mix is not shown to keep both of (`.notShown`, F1001).
        case channelLayoutNotShown(name: String)
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
                let others = count == 2 ? "the other track" : "the other \(count - 1) tracks"
                return "This recording has \(count) audio tracks, and they can't be read to mix them into one. A shrunk copy would keep only the first, and \(others) would be deleted with the original, so it isn't shrunk."
            case let .alternateAudioTracks(count):
                return "This recording has \(count) audio tracks in different languages, alternatives to each other. Mixed into one they would garble each other, and a shrunk copy keeps one track, so it isn't shrunk."
            case let .multipleChannels(count):
                return "This recording has \(count) channels, and they can't be read to mix them into one. A shrunk copy would keep only some of them, and the others would be deleted with the original, so it isn't shrunk."
            case let .tooManyChannelsToCheck(count):
                return "This recording has \(count) channels, more than Shrink checks one by one when it mixes them into one copy, so it isn't shrunk."
            case let .mixingNotAvailableYet(tracks, channels):
                let holds = tracks > 1 ? "\(tracks) audio tracks" : "\(channels) channels"
                return "This recording has \(holds); shrinking it isn't available yet, so its audio is kept as it is."
            case let .otherRecordingMayHoldMore(name, seconds?):
                return "This meeting's folder also holds “\(name)”, which runs \(TranscriptFormatter.clock(seconds)), longer than this recording. Shrinking would delete it, so it isn't shrunk."
            case let .otherRecordingMayHoldMore(name, nil):
                return "This meeting's folder also holds “\(name)”, and its length can't be read to show that this recording holds all of its audio. Shrinking would delete it, so it isn't shrunk."
            case let .otherRecordingHasMoreTracks(name, tracks, channels):
                let holds = tracks > 1 ? "\(tracks) audio tracks" : "\(channels) channels"
                return "This meeting's folder also holds “\(name)”, which has \(holds), and the shrunk copy isn't shown to hold them all. Shrinking would delete it, so it isn't shrunk."
            case let .channelLayoutLeavesOneOut(name):
                return "“\(name)” labels one of its two channels as a kind of channel (an LFE or a mid/side channel, say) which the compression leaves out of a mono copy, so it is kept as it is."
            case let .channelLayoutNotShown(name):
                return "“\(name)” labels its two channels in a way Shrink hasn't shown the compression keeps both of in a mono copy, so it is kept as it is."
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
    /// never clear on their own; busy states come last. `mixing` is `shrinkMixesRecordings` everywhere but
    /// the tests that run the held-back mixing Shrink (F980).
    public static func unavailability(disk: DiskFacts, live: LiveFacts,
                                      mixing: Bool = shrinkMixesRecordings) -> Unavailability? {
        guard disk.inOwnFolder, let output = outputName(forRecordingNamed: disk.recordingName) else {
            return .unsupportedRecording
        }
        guard disk.recordingExists else { return .recordingMissing }
        // F911: before the resume and encode rules alike, since both remove every other `recording.<ext>`.
        if let other = otherRecordingAtRisk(disk) {
            return .otherRecordingMayHoldMore(name: other.name, seconds: disk.otherRecordingSeconds[other.name])
        }
        // F1001: a two-channel file laid out so that the encode's mix, which follows the layout, may leave a
        // channel out.
        if let refused = disk.channelLayoutRefused {
            return refused.positions == .leavesOneOut ? .channelLayoutLeavesOneOut(name: refused.name)
                : .channelLayoutNotShown(name: refused.name)
        }
        // F955: and its tracks and channels, which its length cannot show. A leftover a mix must hold is
        // removed by a resume only after the copy is checked against it (`otherRecordingsToVerify`), and
        // only while mixing Shrink is on (F980); anything else of that kind is kept.
        let resume = isResume(disk)
        for other in otherRecordings(in: disk.entries, recordingName: disk.recordingName) where !other.isEmpty {
            guard let tracks = disk.otherRecordingTracks[other.name] else { continue }
            switch RecordingMixPlan.decision(for: tracks) {
            case .asItIs:
                continue
            case let .mixEveryChannel(channels) where mixing && resume && channels <= RecordingMixPlan.mostCheckedChannels:
                continue
            case .mixEveryChannel, .unsupported:
                return .otherRecordingHasMoreTracks(name: other.name, tracks: tracks.count,
                                                    channels: tracks.reduce(0) { $0 + Swift.max(0, $1.channels) })
            }
        }
        if isResume(disk) {
            // Resume mode: nothing is encoded, so damage and size rules about an encode don't apply. Nor
            // do the track and channel rules, which are about what an encode keeps of the recording: here
            // the recording is already Shrink's output and is kept. What a resume removes are originals
            // an earlier run had already replaced with its copy; F911's rule above refuses one that runs
            // longer than the recording, and F955's one whose tracks the copy is not shown to hold — the
            // resume itself checks the copy against each leftover a mix must hold before removing it.
            if removableFiles(in: disk.entries, keeping: output).isEmpty { return .alreadyShrunk }
        } else {
            if disk.hasIntegrityProblem || disk.rebuildOffered {
                return .damaged(rebuildOffered: disk.rebuildOffered)
            }
            // F801: a track or channel the shrunk copy cannot hold is never deleted with the original.
            // Since F942 such a recording is mixed into the copy, every channel of every track, whatever
            // its layout (F953), and only what cannot be mixed is refused: alternate tracks, and a
            // recording whose tracks were not read — fail-closed, because the plain encode would keep
            // track 1, or of a WAV with more than two channels and no layout, channel 1 (F801 review R5).
            // Refused, not warned about, because the loss would be permanent and the confirmation is
            // one click. And while mixing Shrink is held back (F980), a recording it would mix is refused
            // too; alternates and unread tracks keep their own reasons, which mixing would not change.
            if needsMix(disk) {
                switch disk.audioTracks.map(RecordingMixPlan.decision(for:)) {
                case let .mixEveryChannel(channels)? where !mixing:
                    return .mixingNotAvailableYet(tracks: disk.audioTracks?.count ?? 1, channels: channels)
                case let .mixEveryChannel(channels)? where channels > RecordingMixPlan.mostCheckedChannels:
                    // More than the check of a mixed copy fits one by one (review R2): not shown, so kept.
                    return .tooManyChannelsToCheck(count: channels)
                case .mixEveryChannel?:
                    break
                case let .unsupported(.alternateTracks(count))?:
                    return .alternateAudioTracks(count: count)
                default:
                    if let tracks = disk.audioTrackCount, tracks > 1 { return .multipleAudioTracks(count: tracks) }
                    return .multipleChannels(count: disk.channelCount ?? 0)
                }
            }
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
