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
    }

    /// The meeting's measured size, or nil before it has been measured.
    func storageBytes(for id: UUID) -> Int64? {
        storageFacts[id].map { MeetingStoragePlan.totalBytes($0.entries) }
    }

    /// The library total over meetings measured so far.
    var measuredLibraryBytes: Int64 {
        MeetingStoragePlan.totalBytes(storageFacts.values.map { .init(name: "", bytes: MeetingStoragePlan.totalBytes($0.entries)) })
    }

    /// Measures these meetings off the main actor and caches what the disk says.
    func refreshStorage(ids: [UUID]) async {
        for id in ids {
            guard let meeting = store.meeting(id: id) else { storageFacts[id] = nil; continue }
            storageFacts[id] = await diskFacts(for: meeting)
        }
    }

    /// Why Shrink can't run for this meeting now, or nil when it can.
    func shrinkUnavailability(for meeting: MeetingRecord) -> MeetingStoragePlan.Unavailability? {
        guard let disk = storageFacts[meeting.id] else { return nil }
        return MeetingStoragePlan.unavailability(disk: disk, live: liveShrinkFacts(for: meeting.id))
    }

    func requestShrink(ids: [UUID]) {
        var eligible: [MeetingRecord] = [], skipped: [ShrinkRequest.Skipped] = []
        var current: Int64 = 0, predicted: Int64 = 0
        for id in ids {
            guard let meeting = store.meeting(id: id), let disk = storageFacts[id] else { continue }
            if let reason = MeetingStoragePlan.unavailability(disk: disk, live: liveShrinkFacts(for: id)) {
                skipped.append(.init(title: meeting.title, reason: reason)); continue
            }
            eligible.append(meeting)
            let total = MeetingStoragePlan.totalBytes(disk.entries)
            let output = MeetingStoragePlan.outputName(forRecordingNamed: disk.recordingName) ?? disk.recordingName
            let reclaim = MeetingStoragePlan.isShrunkCapture(disk.recordingName)
                ? MeetingStoragePlan.totalBytes(MeetingStoragePlan.removableFiles(in: disk.entries, keeping: output))
                : MeetingStoragePlan.reclaimableBytes(in: disk.entries, recordingName: disk.recordingName, outputName: output)
            let encoded = MeetingStoragePlan.isShrunkCapture(disk.recordingName)
                ? 0 : MeetingStoragePlan.predictedOutputBytes(durationSeconds: disk.durationSeconds)
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
            }
        )
    }

    func cancelShrink() { pendingShrink = nil }

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
        if let reason = MeetingStoragePlan.unavailability(disk: disk, live: liveShrinkFacts(for: id)) {
            return .refused(title: meeting.title, reason: reason)
        }
        guard libraryAcceptsChanges("Shrinking a meeting"),
              let folder = store.ownRecordingFolder(of: meeting),
              let output = MeetingStoragePlan.outputName(forRecordingNamed: disk.recordingName) else {
            return .refused(title: meeting.title, reason: .unsupportedRecording)
        }
        shrinkRunningID = id
        defer { shrinkRunningID = nil }
        let before = MeetingStoragePlan.totalBytes(disk.entries)

        if !MeetingStoragePlan.isShrunkCapture(disk.recordingName) {
            let recordingURL = store.recordingURL(for: meeting)
            let token = UUID().uuidString
            let tempM4A = folder.appendingPathComponent(".shrink-\(token).m4a")
            let tempWAV = folder.appendingPathComponent(".shrink-\(token).wav")
            let encode = encodeForShrink, decode = decodedDurationForShrink, free = availableBytesForShrink
            let expected = disk.durationSeconds
            let needed = MeetingStoragePlan.totalBytes([
                .init(name: "", bytes: Int64(saturating: expected * 32_000)),
                .init(name: "", bytes: MeetingStoragePlan.predictedOutputBytes(durationSeconds: expected)),
                .init(name: "", bytes: 100_000_000),
            ])
            let encoded: Result<Int64, Error> = await Task.detached(priority: .userInitiated) {
                do {
                    if let available = free(folder), available < needed {
                        throw ShrinkFailure.insufficientSpace(needed: needed, available: available)
                    }
                    try encode(recordingURL, tempM4A, tempWAV)
                    let decoded = try decode(tempM4A)
                    guard abs(decoded - expected) <= 0.5 else {
                        throw ShrinkFailure.lengthMismatch(expected: expected, decoded: decoded)
                    }
                    let size = (try? tempM4A.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? nil
                    return .success(Int64(size ?? 0))
                } catch {
                    try? FileManager.default.removeItem(at: tempM4A)
                    try? FileManager.default.removeItem(at: tempWAV)
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
            if output.lowercased() != disk.recordingName.lowercased() {
                let relative = (meeting.recordingPath as NSString).deletingLastPathComponent + "/" + output
                guard store.replaceRecordingPath(id: id, with: relative) else {
                    try? FileManager.default.removeItem(at: final)
                    return .failed(title: meeting.title,
                                   message: store.storageErrorMessage ?? "The library could not be saved.")
                }
            }
        }

        // Delete (design, step 7), in the planner's order, only names on its list.
        let removable = MeetingStoragePlan.removableFiles(in: storageEntries(folder), keeping: output)
        var unremoved = 0
        for entry in removable {
            willRemoveForShrink(entry.name)
            let url = folder.appendingPathComponent(entry.name)
            do {
                try await Task.detached { try FileManager.default.removeItem(at: url) }.value
            } catch {
                unremoved += 1
            }
        }
        let after = await diskFacts(for: store.meeting(id: id) ?? meeting)
        storageFacts[id] = after
        return .shrunk(title: meeting.title, before: before,
                       after: MeetingStoragePlan.totalBytes(after.entries), unremoved: unremoved)
    }

    enum ShrinkFailure: LocalizedError {
        case insufficientSpace(needed: Int64, available: Int64)
        case lengthMismatch(expected: TimeInterval, decoded: TimeInterval)
        var errorDescription: String? {
            let size = { (b: Int64) in ByteCountFormatter.string(fromByteCount: b, countStyle: .file) }
            switch self {
            case let .insufficientSpace(needed, available):
                return "Shrinking needs about \(size(needed)) free while it works, and \(size(available)) is available."
            case let .lengthMismatch(expected, decoded):
                return "The compressed copy was \(TranscriptFormatter.clock(decoded)) long instead of \(TranscriptFormatter.clock(expected)), so it was discarded."
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
        return live
    }

    /// Reads the disk for one meeting, off the main actor.
    private func diskFacts(for meeting: MeetingRecord) async -> MeetingStoragePlan.DiskFacts {
        let recordingURL = store.recordingURL(for: meeting)
        let folder = store.ownRecordingFolder(of: meeting)
        let descriptor = integrityDescriptorForShrink(meeting)
        let entries = storageEntries, declared = declaredDurationForShrink
        let indexDuration = meeting.duration
        return await Task.detached(priority: .utility) {
            let name = recordingURL.lastPathComponent
            let exists = FileManager.default.fileExists(atPath: recordingURL.path)
            let problem = descriptor.map { MeetingIntegrityChecker.check($0).contains { $0.isProblem } } ?? false
            let directory = folder ?? recordingURL.deletingLastPathComponent()
            let rebuild = SourceRebuild.offer(in: directory, currentDuration: indexDuration) != nil
            let length = declared(recordingURL) ?? (indexDuration > 0 ? indexDuration : 0)
            return MeetingStoragePlan.DiskFacts(
                recordingName: name, recordingExists: exists,
                inOwnFolder: folder != nil && recordingURL.deletingLastPathComponent().standardizedFileURL.path
                    == folder?.standardizedFileURL.path,
                hasIntegrityProblem: problem, rebuildOffered: rebuild,
                durationSeconds: length, entries: folder.map(entries) ?? [])
        }.value
    }
}
