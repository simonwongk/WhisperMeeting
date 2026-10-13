import Foundation
import UniformTypeIdentifiers
import WhisperCore

/// Shrink (F795): see each meeting's size, and replace a meeting's audio with one compressed
/// recording. The shape is Rebuild Audio's: request, confirmation, `perform(confirmed:)`, then the
/// heavy work detached and every store mutation on the main actor. docs/MEETING_STORAGE_DESIGN.md.
extension AppModel {
    struct ShrinkRequest: Equatable {
        struct Skipped: Equatable {
            let title: String
            let reason: MeetingStoragePlan.Unavailability
        }
        let meetingIDs: [UUID]
        let titles: [String]
        let currentBytes: Int64
        let predictedBytes: Int64
        let skipped: [Skipped]
        let includesUntranscribed: Bool
        let includesVideo: Bool
        /// A meeting with several audio tracks or more than two channels, which the copy mixes into one (F942).
        var includesMixedTracks = false
    }

    /// The meeting's measured size, or nil before it has been measured.
    func storageBytes(for id: UUID) -> Int64? {
        storageFacts[id].map { MeetingStoragePlan.totalBytes($0.entries) }
    }

    /// The library total: the meetings in the index that have been measured. A deleted meeting's
    /// cached size is not counted, so freeing space shows in this number (final review).
    var measuredLibraryBytes: Int64 {
        MeetingStoragePlan.totalBytes(store.meetings.compactMap { meeting in
            storageBytes(for: meeting.id).map { MeetingStoragePlan.FolderEntry(name: "", bytes: $0) }
        })
    }

    /// Measures these meetings off the main actor and caches what the disk says. Facts for meetings
    /// no longer in the index are dropped.
    func refreshStorage(ids: [UUID]) async {
        let indexed = Set(store.meetings.map(\.id))
        for stale in storageFacts.keys where !indexed.contains(stale) { storageFacts[stale] = nil }
        for id in ids {
            guard let meeting = store.meeting(id: id) else { storageFacts[id] = nil; continue }
            storageFacts[id] = await diskFacts(for: meeting)
        }
    }

    /// Why Shrink can't run for this meeting now, or nil when it can.
    func shrinkUnavailability(for meeting: MeetingRecord) -> MeetingStoragePlan.Unavailability? {
        guard let disk = storageFacts[meeting.id] else { return nil }
        return MeetingStoragePlan.unavailability(disk: disk, live: liveShrinkFacts(for: meeting.id), mixing: shrinkMixesRecordings)
    }

    func requestShrink(ids: [UUID]) {
        var eligible: [MeetingRecord] = [], skipped: [ShrinkRequest.Skipped] = []
        var current: Int64 = 0, predicted: Int64 = 0
        for id in ids {
            guard let meeting = store.meeting(id: id), let disk = storageFacts[id] else { continue }
            if let reason = MeetingStoragePlan.unavailability(disk: disk, live: liveShrinkFacts(for: id), mixing: shrinkMixesRecordings) {
                skipped.append(.init(title: meeting.title, reason: reason)); continue
            }
            eligible.append(meeting)
            let total = MeetingStoragePlan.totalBytes(disk.entries)
            let output = MeetingStoragePlan.outputName(forRecordingNamed: disk.recordingName) ?? disk.recordingName
            let resume = MeetingStoragePlan.isResume(disk)
            let reclaim = resume
                ? MeetingStoragePlan.totalBytes(MeetingStoragePlan.removableFiles(in: disk.entries, keeping: output))
                : MeetingStoragePlan.reclaimableBytes(in: disk.entries, recordingName: disk.recordingName, outputName: output)
            let encoded = resume ? 0 : MeetingStoragePlan.predictedOutputBytes(durationSeconds: disk.durationSeconds)
            current = MeetingStoragePlan.totalBytes([.init(name: "", bytes: current), .init(name: "", bytes: total)])
            predicted = MeetingStoragePlan.totalBytes([.init(name: "", bytes: predicted),
                                                       .init(name: "", bytes: Swift.max(0, total - reclaim)),
                                                       .init(name: "", bytes: encoded)])
        }
        guard !eligible.isEmpty else {
            alertMessage = skipped.first.map { "“\($0.title)” can't be shrunk now. \($0.reason.message)" }
                ?? "There is nothing to shrink."
            return
        }
        pendingShrink = ShrinkRequest(
            meetingIDs: eligible.map(\.id), titles: eligible.map(\.title),
            currentBytes: current, predictedBytes: predicted, skipped: skipped,
            includesUntranscribed: eligible.contains { $0.transcriptText.isEmpty },
            includesVideo: eligible.contains {
                UTType(filenameExtension: URL(fileURLWithPath: $0.recordingPath).pathExtension)?.conforms(to: .movie) == true
            },
            includesMixedTracks: eligible.contains { meeting in
                storageFacts[meeting.id].map { !MeetingStoragePlan.isResume($0) && MeetingStoragePlan.needsMix($0) } ?? false
            }
        )
    }

    func cancelShrink() { pendingShrink = nil }

    static func shrinkConfirmationTitle(_ request: ShrinkRequest) -> String {
        request.meetingIDs.count == 1
            ? "Shrink “\(request.titles[0])”?"
            : "Shrink \(request.meetingIDs.count) meetings?"
    }

    /// The confirmation's body. Static and here, not in the view, because it makes the promises the
    /// user relies on — what changes, that the deletion is permanent, and what is lost — and a
    /// promise nothing asserts drifts (the `rebuildConfirmationMessage` rule, F267).
    static func shrinkConfirmationMessage(_ request: ShrinkRequest) -> String {
        let size = { (bytes: Int64) in ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
        var text = "This replaces the recording with compressed audio: about \(size(request.currentBytes)) → about \(size(request.predictedBytes)). "
            + "The original recording and its raw tracks are deleted permanently. "
            + "Playback, transcription and summaries keep working. "
            + "Rebuild Audio and re-running a single segment will no longer be available."
        if request.includesUntranscribed {
            text += " A meeting that hasn't been transcribed yet will be transcribed from the compressed audio."
        }
        if request.includesVideo { text += " For a video, the picture is removed; only the audio is kept." }
        if request.includesMixedTracks {
            text += " A recording with several audio tracks or more than two channels is mixed into one; they can't be separated again afterwards."
        }
        if !request.skipped.isEmpty {
            text += " \(request.skipped.count) selected meeting(s) can't be shrunk and will be skipped."
        }
        return text
    }

    /// Runs the confirmed shrink, one meeting at a time. Nil unless `confirmed`; the returned task is
    /// the work, for a caller (a test) that waits for it.
    @discardableResult
    func performShrink(confirmed: Bool) -> Task<Void, Never>? {
        guard confirmed, let request = pendingShrink else { return nil }
        pendingShrink = nil
        return Task {
            var lines: [String] = []
            for id in request.meetingIDs {
                lines.append(await shrinkOne(id: id).sentence)
            }
            lines += request.skipped.map { "“\($0.title)” was skipped. \($0.reason.message)" }
            alertMessage = lines.joined(separator: "\n\n")
        }
    }

    enum ShrinkOutcome {
        case shrunk(title: String, before: Int64, after: Int64, unremoved: Int)
        case alreadyCompact(title: String)
        case refused(title: String, reason: MeetingStoragePlan.Unavailability)
        case failed(title: String, message: String)

        var sentence: String {
            let size = { (bytes: Int64) in ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file) }
            switch self {
            case let .shrunk(title, before, after, unremoved):
                var text = "Shrunk “\(title)” from \(size(before)) to \(size(after))."
                if unremoved > 0 {
                    text += " \(unremoved) file(s) could not be removed; Shrink again to finish."
                }
                return text
            case let .alreadyCompact(title):
                return "“\(title)” was not changed: \(MeetingStoragePlan.Unavailability.nothingToGain.message)"
            case let .refused(title, reason):
                return "“\(title)” was not changed. \(reason.message)"
            case let .failed(title, message):
                return "“\(title)” could not be shrunk, and nothing was removed. \(message)"
            }
        }
    }

    // MARK: - The sequence (design, part 2)

    private func shrinkOne(id: UUID) async -> ShrinkOutcome {
        guard let meeting = store.meeting(id: id) else {
            return .failed(title: "A meeting", message: "It is no longer in the library.")
        }
        let disk = await diskFacts(for: meeting)
        storageFacts[id] = disk
        if let reason = MeetingStoragePlan.unavailability(disk: disk, live: liveShrinkFacts(for: id), mixing: shrinkMixesRecordings) {
            return .refused(title: meeting.title, reason: reason)
        }
        // Read-only and restoring are refused above, each with its own reason (final review: this
        // guard used to report a restore as "not stored in its own meeting folder").
        guard let folder = store.ownRecordingFolder(of: meeting),
              let output = MeetingStoragePlan.outputName(forRecordingNamed: disk.recordingName) else {
            return .refused(title: meeting.title, reason: .unsupportedRecording)
        }
        // F870: the encode, the commit and the removals all write in this folder, some off the main
        // actor, so the meeting is held for the whole sequence and a delete of it meanwhile is
        // refused rather than racing it. A delete runs synchronously on the main actor, so none can
        // be under way at this point and `begin` does not fail here; the guard is for its contract.
        guard store.folderWriters.begin(id) else {
            return .failed(title: meeting.title, message: "It is being deleted.")
        }
        defer { store.folderWriters.end(id) }
        shrinkRunningID = id
        defer { shrinkRunningID = nil }
        let before = MeetingStoragePlan.totalBytes(disk.entries)

        if !MeetingStoragePlan.isResume(disk) {
            let recordingURL = store.recordingURL(for: meeting)
            let token = UUID().uuidString
            let tempM4A = folder.appendingPathComponent(".shrink-\(token).m4a")
            let tempWAV = folder.appendingPathComponent(".shrink-\(token).wav")
            // F942: a recording with several audio tracks or more than two channels is mixed into this
            // 16 kHz mono WAV first, every channel of every track, and the mix is what is encoded. Reached
            // only with `shrinkMixesRecordings` on: while it is off (F980), `unavailability` refuses such a
            // recording above, and a resume keeps a leftover that would need it.
            let mixWAV = folder.appendingPathComponent(".shrink-\(token).mix.wav")
            let mixed = MeetingStoragePlan.needsMix(disk)
            let encode = encodeForShrink, decode = decodeForShrink, mix = mixForShrink, free = availableBytesForShrink
            let audit = auditForShrink
            let flush = flushForShrink
            let declaredLength = disk.durationSeconds
            let needed = MeetingStoragePlan.totalBytes([
                .init(name: "", bytes: Int64(saturating: declaredLength * 32_000)),
                .init(name: "", bytes: mixed ? Int64(saturating: declaredLength * 32_000) : 0),
                .init(name: "", bytes: MeetingStoragePlan.predictedOutputBytes(durationSeconds: declaredLength)),
                .init(name: "", bytes: 100_000_000),
            ])
            let encoded: Result<Int64, Error> = await Task.detached(priority: .userInitiated) {
                do {
                    if let available = free(folder), available < needed {
                        throw ShrinkFailure.insufficientSpace(needed: needed, available: available)
                    }
                    var expected = declaredLength
                    var mixedChannels: Int?
                    if mixed {
                        // The mix's own length is the recording's, every track's end included: the header
                        // read for `declaredLength` measures the first track alone. The mixer refuses a
                        // decode that stops short of where the audio tracks end (not a video track, R1).
                        let result = try await mix(recordingURL, mixWAV)
                        expected = result.duration
                        mixedChannels = result.channels
                        try encode(mixWAV, tempM4A, tempWAV)
                        try? FileManager.default.removeItem(at: mixWAV)
                    } else {
                        try encode(recordingURL, tempM4A, tempWAV)
                    }
                    let copy: DecodedAudio.Decoded
                    do { copy = try await decode(tempM4A) } catch { throw ShrinkFailure.unreadableCopy }
                    guard abs(copy.duration - expected) <= 0.5 else {
                        throw ShrinkFailure.lengthMismatch(expected: expected, decoded: copy.duration)
                    }
                    // The right length is not the right audio: a copy that came out silent has it too
                    // (F801). The original is decoded the same way, its level taken over all its channels
                    // (and, since F942, all its tracks) before any mixing, so a recording the mono mix
                    // silences cannot pass as silent (F801 review).
                    let original: DecodedAudio.Decoded
                    do { original = try await decode(recordingURL) } catch { throw ShrinkFailure.unreadableOriginal }
                    if let mixedChannels {
                        // A mix (F942). Levels — of the whole copy, of each stretch, of each channel —
                        // cannot show a track lost while another sounds over it, nor one whose channels
                        // cancel when combined: the review deleted an original both ways (R2, M8). So the
                        // copy's waveform is fitted onto every track and channel, stretch by stretch, and
                        // nothing is deleted unless each one that sounds is shown in it. Every channel the
                        // mixer read must have been measured in the recording too.
                        guard original.channelWindowLevels.count == mixedChannels else {
                            throw ShrinkFailure.unreadableOriginal
                        }
                        let measured: RecordingMixPlan.Audit
                        do { measured = try await audit(recordingURL, tempM4A) } catch { throw ShrinkFailure.unreadableOriginal }
                        if let finding = RecordingMixPlan.firstFinding(
                            measured, nativeChannelWindows: original.channelWindowLevels, nativeLevel: original.level
                        ) {
                            throw ShrinkFailure.mixNotShown(finding)
                        }
                    } else {
                        guard MeetingStoragePlan.levelsAgree(original: original.level, compressed: copy.level) else {
                            throw ShrinkFailure.levelMismatch(original: original.level, compressed: copy.level)
                        }
                        // And stretch by stretch: a copy of the right length can keep the whole file's level
                        // within the band and still have lost part of the recording (F801 review).
                        if let window = MeetingStoragePlan.firstWindowLosingSound(
                            original: original.windowLevels, compressed: copy.windowLevels, originalLevel: original.level
                        ) {
                            throw ShrinkFailure.soundLost(at: Double(window) * MeetingStoragePlan.levelWindowSeconds)
                        }
                    }
                    // On stable storage before anything is committed or removed (final review).
                    try flush(tempM4A)
                    let size = (try? tempM4A.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? nil
                    return .success(Int64(size ?? 0))
                } catch {
                    try? FileManager.default.removeItem(at: tempM4A)
                    try? FileManager.default.removeItem(at: tempWAV)
                    try? FileManager.default.removeItem(at: mixWAV)
                    return .failure(error)
                }
            }.value
            let encodedBytes: Int64
            switch encoded {
            case let .failure(error):
                return .failed(title: meeting.title, message: error.localizedDescription)
            case let .success(bytes):
                encodedBytes = bytes
            }
            let reclaim = MeetingStoragePlan.reclaimableBytes(in: disk.entries, recordingName: disk.recordingName, outputName: output)
            guard MeetingStoragePlan.isWorthShrinking(encodedBytes: encodedBytes, reclaimableBytes: reclaim) else {
                try? FileManager.default.removeItem(at: tempM4A)
                return .alreadyCompact(title: meeting.title)
            }
            // Every guard above ran before the encode's await. Ask again, on the main actor, before
            // committing: a restore, a read-only reload or another copy may have changed the record in
            // that window, and the temp file is still only ours to remove (final review).
            guard let current = store.meeting(id: id), current.recordingPath == meeting.recordingPath,
                  !store.isDegraded, !store.isRestoringLibrary else {
                try? FileManager.default.removeItem(at: tempM4A)
                return .failed(title: meeting.title,
                               message: "The meeting or the library changed while it was being compressed. Try again.")
            }
            // Commit (design, step 6).
            let final = folder.appendingPathComponent(output)
            do {
                if FileManager.default.fileExists(atPath: final.path) {
                    _ = try FileManager.default.replaceItemAt(final, withItemAt: tempM4A)
                } else {
                    try FileManager.default.moveItem(at: tempM4A, to: final)
                }
            } catch {
                try? FileManager.default.removeItem(at: tempM4A)
                return .failed(title: meeting.title, message: error.localizedDescription)
            }
            // The rename, flushed too, before the index names it or anything is removed.
            if (try? await Task.detached { try flush(folder) }.value) == nil {
                return .failed(title: meeting.title,
                               message: "The compressed copy could not be confirmed on disk. \(Self.leftCopyNote)")
            }
            if output.lowercased() != disk.recordingName.lowercased() {
                let relative = (meeting.recordingPath as NSString).deletingLastPathComponent + "/" + output
                guard store.replaceRecordingPath(id: id, with: relative) else {
                    // `final` is LEFT (final review, finding 1). After a lost race another copy's index
                    // may already name this file, and removing it would leave the meeting with no audio
                    // at all. Unreferenced, it is harmless, and the next shrink replaces it.
                    let reason = store.storageErrorMessage ?? "The library could not be saved."
                    return .failed(title: meeting.title, message: "\(reason) \(Self.leftCopyNote)")
                }
            }
        } else if !MeetingStoragePlan.otherRecordingsToVerify(disk).isEmpty {
            // F955: a resume encodes nothing, but before it removes a leftover with several tracks or more
            // than two channels it checks the copy against it as an encode checks a mix (F942, review R2):
            // a copy a build before F942 made kept only the first track or channel, and the leftover then
            // holds the last copy of the rest. Reached only with `shrinkMixesRecordings` on; while it is off
            // (F980), `unavailability` keeps every such leftover.
            let leftovers = MeetingStoragePlan.otherRecordingsToVerify(disk)
            let copyURL = store.recordingURL(for: meeting)
            let decode = decodeForShrink, audit = auditForShrink
            let checked: ShrinkFailure? = await Task.detached(priority: .userInitiated) {
                for leftover in leftovers {
                    let url = folder.appendingPathComponent(leftover.name)
                    let original: DecodedAudio.Decoded, measured: RecordingMixPlan.Audit
                    do {
                        original = try await decode(url)
                        measured = try await audit(url, copyURL)
                    } catch {
                        return .leftoverUnchecked(name: leftover.name)
                    }
                    guard original.channelWindowLevels.count == measured.trackChannels.reduce(0, +) else {
                        return .leftoverUnchecked(name: leftover.name)
                    }
                    if let finding = RecordingMixPlan.firstFinding(
                        measured, nativeChannelWindows: original.channelWindowLevels, nativeLevel: original.level
                    ) {
                        return .leftoverNotInCopy(name: leftover.name, finding: finding)
                    }
                }
                return nil
            }.value
            if let checked { return .failed(title: meeting.title, message: checked.localizedDescription) }
        }

        // Delete (design, step 7), in the planner's order, only names on its list — and of those, only
        // what the checks above ran on, unchanged since (F949). A file that appeared or changed during
        // the encode was never measured, so it stays for the next Shrink, which measures it.
        let now = MeetingStoragePlan.removableNow(current: storageEntries(folder), measured: disk.entries, keeping: output)
        var unremoved = now.changed.count
        for entry in now.remove {
            willRemoveForShrink(entry.name)
            let url = folder.appendingPathComponent(entry.name)
            do {
                try await Task.detached {
                    // F943: a copy an import made before F804 may still carry Finder's Locked flag,
                    // which blocks the unlink; it is the app's own file in the meeting's own folder.
                    MeetingStore.clearUserFlags(at: url)
                    try FileManager.default.removeItem(at: url)
                }.value
            } catch {
                unremoved += 1
            }
        }
        let after = await diskFacts(for: store.meeting(id: id) ?? meeting)
        storageFacts[id] = after
        return .shrunk(title: meeting.title, before: before,
                       after: MeetingStoragePlan.totalBytes(after.entries), unremoved: unremoved)
    }

    /// Said whenever a verified `.m4a` is left beside the originals it did not replace.
    static let leftCopyNote = "A compressed copy was left in the meeting's folder; it is not used until a shrink succeeds."

    enum ShrinkFailure: LocalizedError {
        case insufficientSpace(needed: Int64, available: Int64)
        case lengthMismatch(expected: TimeInterval, decoded: TimeInterval)
        /// The copy's level is not the original's (F801).
        case levelMismatch(original: Double, compressed: Double)
        /// Said in Shrink's own words, so a decoder's raw error ("The operation couldn't be completed.
        /// (com.apple.coreaudio.avfaudio error …)") is not the sentence the user reads (F801).
        case unreadableCopy
        case unreadableOriginal
        /// The copy is missing the recording's sound in the stretch that starts at this second (F801
        /// review). It is the first such stretch the check found, and the check stops there, so this
        /// says nothing about the stretches after it (second review, R7).
        case soundLost(at: TimeInterval)
        /// A mixed copy is not shown to hold every track and channel of the recording (F942, review R2).
        case mixNotShown(RecordingMixPlan.Finding)
        /// A resume's leftover with several tracks or more than two channels is not shown to be in the copy
        /// (F955, with F942's checks).
        case leftoverNotInCopy(name: String, finding: RecordingMixPlan.Finding)
        /// A resume's leftover, or the copy, could not be read to compare them (F955).
        case leftoverUnchecked(name: String)

        /// What a finding says, about `subject` — "the recording", or a leftover's name — and the copy.
        static func sentence(_ finding: RecordingMixPlan.Finding, subject: String) -> String {
            let at = { (window: Int) in TranscriptFormatter.clock(Double(window) * RecordingMixPlan.auditWindowSeconds) }
            switch finding {
            case let .channelNotRead(window, channel):
                return "channel \(channel + 1) of \(subject) could not be read to check the copy, at about \(at(window))"
            case let .notANumber(window, channel?):
                return "channel \(channel + 1) of \(subject) holds values that are not numbers at about \(at(window)), so the copy can't be checked against it"
            case let .notANumber(window, nil):
                return "the compressed copy holds values that are not numbers at about \(at(window)), so it can't be checked against \(subject)"
            case let .unreadableWindow(window):
                return "\(subject) could not be measured at about \(at(window)) to check the copy"
            case let .trackCancels(window, track):
                return "audio track \(track + 1) of \(subject) cancels itself when its channels are mixed into one, at about \(at(window))"
            case let .tracksCancel(window):
                return "the audio tracks of \(subject) cancel each other when mixed into one, at about \(at(window))"
            case let .copyMissingSound(window):
                return "the compressed copy is missing sound \(subject) has at about \(at(window))"
            case let .copyUnlikeMix(window):
                return "the compressed copy does not follow the sound of \(subject) at about \(at(window))"
            case let .trackMissing(window, track):
                return "the compressed copy is missing audio track \(track + 1) of \(subject) at about \(at(window))"
            case let .trackMasked(window, track):
                return "audio track \(track + 1) of \(subject) is too quiet beside the others at about \(at(window)) to show that the compressed copy holds it there"
            case let .channelMissing(window, channel):
                return "the compressed copy is missing channel \(channel + 1) of \(subject) at about \(at(window))"
            case let .channelMasked(window, channel):
                return "channel \(channel + 1) of \(subject) is too quiet beside the others at about \(at(window)) to show that the compressed copy holds it there"
            case let .tooManyChannels(count):
                return "\(subject) has \(count) channels, more than Shrink checks one by one in a mixed copy"
            }
        }
        var errorDescription: String? {
            let size = { (b: Int64) in ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
            switch self {
            case let .insufficientSpace(needed, available):
                return "Shrinking needs about \(size(needed)) free while it works, and \(size(available)) is available."
            case let .lengthMismatch(expected, decoded):
                return "The compressed copy was \(TranscriptFormatter.clock(decoded)) long instead of \(TranscriptFormatter.clock(expected)), so it was discarded."
            case let .levelMismatch(original, compressed):
                guard original.isFinite, compressed.isFinite else {
                    return "The compressed copy's sound could not be checked against the recording's, so it was discarded."
                }
                return compressed < original
                    ? "The compressed copy came out silent or much quieter than the recording, so it was discarded."
                    : "The compressed copy came out much louder than the recording, so it was discarded."
            case .unreadableCopy:
                return "The compressed copy could not be read back, so it was discarded."
            case .unreadableOriginal:
                return "The recording could not be read to check the compressed copy against it, so the copy was discarded."
            case let .soundLost(at):
                return "The compressed copy is missing sound the recording has at about \(TranscriptFormatter.clock(at)), so it was discarded."
            case let .mixNotShown(finding):
                let text = Self.sentence(finding, subject: "the recording")
                let first = String(text.prefix(1)).uppercased()
                let rest = String(text.dropFirst())
                return first + rest + ", so the copy was discarded."
            case let .leftoverNotInCopy(name, finding):
                return "“\(name)”, which the compressed copy replaced, was kept: "
                    + Self.sentence(finding, subject: "“\(name)”") + "."
            case let .leftoverUnchecked(name):
                return "“\(name)”, which the compressed copy replaced, could not be checked against the copy, so it was kept."
            }
        }
    }

    // MARK: - Facts

    private func liveShrinkFacts(for id: UUID) -> MeetingStoragePlan.LiveFacts {
        var live = MeetingStoragePlan.LiveFacts()
        live.libraryReadOnly = store.isDegraded
        live.captureOrImportInProgress = isRecordingActive || isImporting
        live.meetingBusy = transcription.contains(id) || diarizationRunningID == id
            || segmentReTranscriptionRunningID == id || sourceRebuildRunningID == id
        live.backupRunning = isBackingUp
        live.anotherShrinkRunning = shrinkRunningID != nil
        live.libraryRestoring = store.isRestoringLibrary
        return live
    }

    /// Reads the disk for one meeting, off the main actor.
    private func diskFacts(for meeting: MeetingRecord) async -> MeetingStoragePlan.DiskFacts {
        let recordingURL = store.recordingURL(for: meeting)
        let folder = store.ownRecordingFolder(of: meeting)
        let descriptor = integrityDescriptorForShrink(meeting)
        let entries = storageEntries, declared = declaredDurationForShrink
        let countTracks = audioTrackCountForShrink, readTracks = audioTracksForShrink
        let measureDownload = measureDownloadForShrink, unmeasurable = downloadsShrinkCouldNotMeasure
        let indexDuration = meeting.duration
        let (facts, couldNotMeasure) = await Task.detached(priority: .utility) { () -> (MeetingStoragePlan.DiskFacts, [String]) in
            let name = recordingURL.lastPathComponent
            let exists = FileManager.default.fileExists(atPath: recordingURL.path)
            // Only an import's container can hold more than one audio track (F801).
            let tracks = exists && MeetingStoragePlan.mayHoldSeveralAudioTracks(name)
                ? await countTracks(recordingURL) : nil
            // And how many channels it holds (F801 review), from its header, for every recording: a
            // capture's is the app's own mono WAV, so asking costs one header read and assumes nothing.
            let channels = exists ? DecodedAudio.channelCount(of: recordingURL) : nil
            // F942: when either says the copy must be a mix, what each track holds, so the planner can
            // tell a mix it can make from one it cannot (alternate tracks, or nothing readable).
            let audioTracks = exists && ((tracks ?? 1) > 1 || (channels ?? 0) > 2) ? await readTracks(recordingURL) : nil
            let problem = descriptor.map { MeetingIntegrityChecker.check($0).contains { $0.isProblem } } ?? false
            let directory = folder ?? recordingURL.deletingLastPathComponent()
            let length = declared(recordingURL) ?? (indexDuration > 0 ? indexDuration : 0)
            // Damage only when a rebuild would recover MORE audio than the recording holds, which is
            // F256's truncation. A recovered folder never has a complete meeting.wav, so an offer alone
            // always exists there; a second past the recording allows for track padding (final review).
            let rebuild = SourceRebuild.offer(in: directory, currentDuration: indexDuration)
                .map { $0.expectedDurationSeconds > length + 1 } ?? false
            let listed = folder.map(entries) ?? []
            // F911: every other `recording.<ext>` Shrink would remove is measured, so the plan can tell
            // whether removing it loses audio — a WAV from its header (or the audio it holds, when
            // ffmpeg never finished it), anything else with AVAudioFile, and a download AVAudioFile
            // cannot read (WebM) by the length recovery recorded when it converted all of it (F947).
            // Unreadable and unrecorded stays unmeasured.
            var otherSeconds: [String: TimeInterval] = [:]
            var otherTracks: [String: [RecordingMixPlan.Track]] = [:]
            var couldNotMeasure: [String] = []
            for other in MeetingStoragePlan.otherRecordings(in: listed, recordingName: name) {
                let url = directory.appendingPathComponent(other.name)
                var seconds = url.pathExtension.lowercased() == "wav"
                    ? InterruptedLinkImportExtraction.heldWAVSeconds(at: url)
                    : declared(url) ?? InterruptedLinkImportExtraction.convertedSeconds(of: url)
                // F962: a download AVAudioFile cannot read, in a folder with no record — one a build
                // before F947 recovered — is measured once with the installed ffprobe, and the answer
                // recorded as a conversion's is, so the next look reads the record. Not asked again
                // this session when it answered nothing; never for an empty file, which holds nothing.
                if seconds == nil, url.pathExtension.lowercased() != "wav", !other.isEmpty, !unmeasurable.contains(url.path) {
                    if let measured = await measureDownload(url), measured.isFinite, measured > 0 {
                        InterruptedLinkImportExtraction.recordConversion(of: url, seconds: measured)
                        seconds = InterruptedLinkImportExtraction.convertedSeconds(of: url) ?? measured
                    } else {
                        couldNotMeasure.append(url.path)
                    }
                }
                if let seconds { otherSeconds[other.name] = seconds }
                // F955: and its tracks and channels — a WAV's from its header, which ffmpeg writes before
                // it has finished (F911's half-written WAV), anything else with AVFoundation.
                if let header = WAVInspection.header(at: url) {
                    otherTracks[other.name] = [RecordingMixPlan.Track(channels: Int(header.channels))]
                } else if let tracks = await readTracks(url) {
                    otherTracks[other.name] = tracks
                }
            }
            let facts = MeetingStoragePlan.DiskFacts(
                recordingName: name, recordingExists: exists,
                inOwnFolder: folder != nil && recordingURL.deletingLastPathComponent().standardizedFileURL.path
                    == folder?.standardizedFileURL.path,
                hasIntegrityProblem: problem, rebuildOffered: rebuild,
                durationSeconds: length, entries: listed, audioTrackCount: tracks,
                otherRecordingSeconds: otherSeconds, channelCount: channels, audioTracks: audioTracks,
                otherRecordingTracks: otherTracks)
            return (facts, couldNotMeasure)
        }.value
        downloadsShrinkCouldNotMeasure.formUnion(couldNotMeasure)
        return facts
    }
}
