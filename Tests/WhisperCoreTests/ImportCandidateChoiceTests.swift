import Foundation
import Testing
@testable import WhisperCore

// F453 part 2 — an interrupted link import can hold two `recording.*` files, and recovery took
// whichever the directory listed first.
//
// yt-dlp extracts the audio with ffmpeg straight into `recording.wav` when the downloaded file has
// another extension, and deletes the original only once ffmpeg has finished (yt-dlp 2026.08.19,
// `yt_dlp/postprocessor/ffmpeg.py`: `FFmpegExtractAudioPP.run` sets `temp_path = new_path` at line
// 509, runs ffmpeg into it at 523, and returns `[orig_path]` for deletion at 535). ffmpeg's WAV muxer
// writes RIFF and data sizes of 0xFFFFFFFF and patches them in at the end. So for the whole
// extraction — minutes on a long recording — the folder holds a complete `recording.webm` and a
// growing `recording.wav` whose header promises more than it holds, and that is what a power loss
// or a crash leaves behind. `importedRecordingCandidate` used `contents.first`, so the meeting could
// be indexed against the partial file while the complete source sat beside it unreferenced.
//
// The other half is a writer that outlived the app (ffmpeg is in its own process group, so a crash
// does not stop it). Recovery must not adopt that folder at all while it is being written — the
// source it would pick is about to be deleted — which is what the liveness half pins.

/// A temp folder holding the given files.
private func makeFolder(_ files: [String: Data]) throws -> URL {
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("F453-candidates-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    for (name, data) in files {
        try data.write(to: folder.appendingPathComponent(name))
    }
    return folder
}

/// A WAV whose extraction finished: a complete header over the samples it declares.
private func finishedWAV() -> Data {
    WAVWriter.wavData(from: [Float](repeating: 0.1, count: 8_000), sampleRate: 16_000)
}

/// What ffmpeg has written while it is still extracting: the same WAV with its RIFF and data sizes
/// left at the 0xFFFFFFFF placeholder that is replaced only when it finishes.
private func extractionInProgressWAV() throws -> Data {
    var data = finishedWAV()
    let placeholder = Data([0xFF, 0xFF, 0xFF, 0xFF])
    data.replaceSubrange(4..<8, with: placeholder)
    let dataTag = try #require(data.range(of: Data("data".utf8)))
    data.replaceSubrange(dataTag.upperBound..<(dataTag.upperBound + 4), with: placeholder)
    return data
}

private let downloadedSource = Data("a complete downloaded file".utf8)

/// Formats yt-dlp can hand the extractor. Several, because which of two names a directory lists
/// first is the file system's business; a fix that depends on the order would pass for some.
private let sourceExtensions = ["webm", "m4a", "opus", "mp4", "mkv", "ogg", "mp3", "aac", "flac", "mov", "mka", "3gp"]

@Test("A complete download is recovered rather than the extraction that never finished (F453)")
func aCompleteSourceBeatsAnUnfinishedExtraction() throws {
    var wrong: [String] = []
    for ext in sourceExtensions {
        let folder = try makeFolder([
            "recording.\(ext)": downloadedSource,
            "recording.wav": try extractionInProgressWAV(),
        ])
        defer { try? FileManager.default.removeItem(at: folder) }

        let candidate = InterruptedRecordingRecovery.importedRecordingCandidate(in: folder)
        let recovered = InterruptedRecordingRecovery.finalizedRecording(in: folder)
        if candidate?.lastPathComponent != "recording.\(ext)"
            || recovered?.recordingURL.lastPathComponent != "recording.\(ext)"
            || recovered?.source != .importedRecording {
            wrong.append("\(ext): candidate \(candidate?.lastPathComponent ?? "nil"), recovered \(recovered?.recordingURL.lastPathComponent ?? "nil")")
        }
    }
    #expect(wrong == [], "the partial extraction was chosen: \(wrong)")
}

@Test("A finished extraction is recovered rather than the source it was made from (F453)")
func aFinishedExtractionBeatsItsSource() throws {
    // ffmpeg finished and the app died before yt-dlp deleted the original: the WAV is the import.
    let folder = try makeFolder(["recording.webm": downloadedSource, "recording.wav": finishedWAV()])
    defer { try? FileManager.default.removeItem(at: folder) }
    #expect(InterruptedRecordingRecovery.importedRecordingCandidate(in: folder)?.lastPathComponent == "recording.wav")
    #expect(InterruptedRecordingRecovery.finalizedRecording(in: folder)?.recordingURL.lastPathComponent == "recording.wav")
}

@Test("Recovery's conversion temp is never the recording, however finished its header reads (F453)")
func theConversionTempIsNeverACandidate() throws {
    // `InterruptedLinkImportExtraction` writes `recording.extracting.wav` and renames it into place
    // only after a clean exit. A quit leaves it with ffmpeg running on to the end, and a SIGTERM makes
    // ffmpeg finish its header, so the temp a later launch finds can read as a complete WAV — of part
    // of the audio, or of all of it with nothing to say so (review of F453 round 2, finding 3).
    let tempName = InterruptedLinkImportExtraction.temporaryFilename
    let shapes: [[String: Data]] = [
        ["recording.webm": downloadedSource, "recording.wav": try extractionInProgressWAV(), tempName: finishedWAV()],
        ["recording.webm": downloadedSource, tempName: finishedWAV()],
    ]
    for files in shapes {
        let folder = try makeFolder(files)
        defer { try? FileManager.default.removeItem(at: folder) }
        let shape = files.keys.sorted()
        #expect(InterruptedRecordingRecovery.importedRecordingCandidate(in: folder)?.lastPathComponent == "recording.webm", "\(shape)")
        #expect(InterruptedRecordingRecovery.finalizedRecording(in: folder)?.recordingURL.lastPathComponent == "recording.webm", "\(shape)")
    }
}

@Test("A lone imported file is still found, whatever it holds (F453)")
func aLoneImportIsStillFound() throws {
    // The choice only orders candidates; it never discards the last one. An unverifiable lone file
    // is what the "Unverified Import" entry exists for, so it must still be returned.
    for (name, data) in [("recording.wav", try extractionInProgressWAV()), ("recording.m4a", downloadedSource)] {
        let folder = try makeFolder([name: data])
        defer { try? FileManager.default.removeItem(at: folder) }
        #expect(InterruptedRecordingRecovery.importedRecordingCandidate(in: folder)?.lastPathComponent == name)
    }
}

private func append(_ bytes: Int, to url: URL) throws {
    let handle = try FileHandle(forWritingTo: url)
    defer { try? handle.close() }
    try handle.seekToEnd()
    try handle.write(contentsOf: Data(repeating: 0, count: bytes))
}

@Test("An import file still being written reads as live (F453)")
func anImportBeingWrittenIsLive() throws {
    let folder = try makeFolder([
        "source.json": Data("{}".utf8),
        "recording.webm": downloadedSource,
        "recording.wav": try extractionInProgressWAV(),
    ])
    defer { try? FileManager.default.removeItem(at: folder) }

    let before = RecordingFolderLiveness.sample(in: folder)
    try append(4_096, to: folder.appendingPathComponent("recording.wav"))
    let after = RecordingFolderLiveness.sample(in: folder)
    #expect(RecordingFolderLiveness.isGrowing(from: before, to: after))
}

@Test("A download still arriving, or just renamed from its .part, reads as live (F453)")
func aDownloadStillArrivingIsLive() throws {
    let folder = try makeFolder(["source.json": Data("{}".utf8), "recording.webm.part": downloadedSource])
    defer { try? FileManager.default.removeItem(at: folder) }

    let before = RecordingFolderLiveness.sample(in: folder)
    try append(4_096, to: folder.appendingPathComponent("recording.webm.part"))
    #expect(RecordingFolderLiveness.isGrowing(from: before, to: RecordingFolderLiveness.sample(in: folder)))

    // yt-dlp renames the finished download before it extracts: a name that appears is growth.
    let renamedFrom = RecordingFolderLiveness.sample(in: folder)
    try FileManager.default.moveItem(at: folder.appendingPathComponent("recording.webm.part"),
                                     to: folder.appendingPathComponent("recording.webm"))
    #expect(RecordingFolderLiveness.isGrowing(from: renamedFrom, to: RecordingFolderLiveness.sample(in: folder)))
}

@Test("An import nobody is writing reads as dead, so it is recovered (F453)")
func anImportNobodyIsWritingIsDead() throws {
    let folder = try makeFolder([
        "source.json": Data("{}".utf8),
        "recording.webm": downloadedSource,
        "recording.wav": try extractionInProgressWAV(),
    ])
    defer { try? FileManager.default.removeItem(at: folder) }
    let before = RecordingFolderLiveness.sample(in: folder)
    #expect(!RecordingFolderLiveness.isGrowing(from: before, to: RecordingFolderLiveness.sample(in: folder)))
}
