import CoreMedia
import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F888 — the sample handler reports why each failed append failed, so the at-risk warning gives the
// disk advice only when the disk may be what failed. The classifier is checked against what the
// real code throws, not against a hand-made error of the expected type: `FloatTrackWriter.append`
// for a buffer it cannot read, and `FloatTrackFile.append` for a write the file system refuses,
// which the writer passes on unchanged. The handler itself cannot be called off `captureQueue`
// (F402); F386's wiring guard (`aFailedAppendIsReported`) pins its call, cause included.

private struct DiskFull: Error {}

@Test("A buffer whose captured audio cannot be read is a format failure, not a storage one (F888)")
func anUnreadableBufferIsAFormatFailure() throws {
    // F856's fixture: a video description, which no audio format can be made of.
    var video: CMVideoFormatDescription?
    try #require(CMVideoFormatDescriptionCreate(
        allocator: kCFAllocatorDefault, codecType: kCVPixelFormatType_32BGRA, width: 2, height: 2,
        extensions: nil, formatDescriptionOut: &video
    ) == noErr)
    let format: CMVideoFormatDescription = try #require(video)
    var sampleBuffer: CMSampleBuffer?
    try #require(CMSampleBufferCreate(
        allocator: kCFAllocatorDefault, dataBuffer: nil, dataReady: true, makeDataReadyCallback: nil,
        refcon: nil, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 0,
        sampleTimingArray: nil, sampleSizeEntryCount: 0, sampleSizeArray: nil, sampleBufferOut: &sampleBuffer
    ) == noErr)
    let buffer = try #require(sampleBuffer)
    let url = try CapturedSampleBuffer.temporaryTrackURL("F888")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    let writer = try FloatTrackWriter(outputURL: url, targetSampleRate: CapturedSampleBuffer.rate)

    do {
        _ = try writer.append(buffer)
        Issue.record("a buffer with no audio format was appended")
    } catch {
        #expect(AudioCaptureEngine.writeFailureCause(of: error) == .format, "\(error)")
    }
}

@Test("A write the file system refuses is a storage failure (F888)")
func aRefusedWriteIsAStorageFailure() throws {
    let url = try CapturedSampleBuffer.temporaryTrackURL("F888-storage")
    defer { try? FileManager.default.removeItem(at: url.deletingLastPathComponent()) }
    // F501's writer seam: the write throws as a full disk would, and `FloatTrackFile.append` passes
    // the error on, as it does on the capture path, where `FloatTrackWriter` does not wrap it.
    for refused in [CocoaError(.fileWriteOutOfSpace) as Error, POSIXError(.ENOSPC), DiskFull()] {
        let track = try FloatTrackFile(url: url, writer: { _, _ in throw refused })
        do {
            try track.append([0, 0, 0])
            Issue.record("the refused write did not throw")
        } catch {
            #expect(AudioCaptureEngine.writeFailureCause(of: error) == .storage, "\(error)")
        }
        track.cancel()
    }
}

@Test("The in-window health panel words failing writes from the snapshot's cause and its one unsaved track (F888, F932)")
func thePanelWordsFailingWritesFromTheCause() throws {
    // The panel cannot be rendered here (F174), so its wiring is pinned as source, comments stripped:
    // the sentence is `RecordingHUD.failingWritesDetail`'s, which the WhisperCore tests check, fed the
    // cause and the unsaved track of the snapshot the panel is showing.
    let content = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/ContentView.swift")
    #expect(content.contains(
        "warningMessage(warning, writeFailureCause: health.writeFailureCause, unsavedTrack: health.unsavedTrack)"
    ))
    let branch = try #require(content.range(of: "case .captureWritesFailing:"))
    let next = try #require(content.range(of: "case .approachingLengthLimit:", range: branch.upperBound..<content.endIndex))
    let body = content[branch.upperBound..<next.lowerBound]
    #expect(body.contains(
        "RecordingHUD.failingWritesDetail(writeFailureCause: writeFailureCause, unsavedTrack: unsavedTrack)"
    ), "\(body)")
    #expect(!body.contains("free space"), "the panel restates the sentence instead of asking for it: \(body)")
}
