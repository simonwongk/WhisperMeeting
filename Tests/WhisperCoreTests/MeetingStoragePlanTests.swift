import Foundation
import Testing
@testable import WhisperCore

// F795 — the rules Shrink acts on, with no disk involved (docs/MEETING_STORAGE_DESIGN.md).

private typealias Entry = MeetingStoragePlan.FolderEntry

private let capture: [Entry] = [
    Entry(name: "meeting.wav", bytes: 345_600_000),
    Entry(name: "system-audio.f32", bytes: 691_200_000),
    Entry(name: "microphone-audio.f32", bytes: 691_200_000),
    Entry(name: "source-tracks.json", bytes: 2_000),
    Entry(name: "notes.md", bytes: 40_000),
    Entry(name: "session.json", bytes: 1_000),
    Entry(name: "diarization.json", bytes: 9_000),
    Entry(name: "ask-embeddings.f32", bytes: 300_000),
    Entry(name: "ask-embeddings.json", bytes: 4_000),
    Entry(name: "meeting-recovered-superseded-1.wav", bytes: 100_000_000),
    Entry(name: ".shrink-ABC.m4a", bytes: 9_000),
    Entry(name: "something-unknown.bin", bytes: 7),
]

@Test("The shrunk name keeps the stem, so provenance survives a lost index (F795)")
func shrinkOutputNameKeepsTheStem() {
    #expect(MeetingStoragePlan.outputName(forRecordingNamed: "meeting.wav") == "meeting.m4a")
    #expect(MeetingStoragePlan.outputName(forRecordingNamed: "meeting-recovered.wav") == "meeting-recovered.m4a")
    #expect(MeetingStoragePlan.outputName(forRecordingNamed: "recording.mp4") == "recording.m4a")
    #expect(MeetingStoragePlan.outputName(forRecordingNamed: "recording.wav") == "recording.m4a")
    #expect(MeetingStoragePlan.outputName(forRecordingNamed: "meeting.m4a") == "meeting.m4a")
    #expect(MeetingStoragePlan.outputName(forRecordingNamed: "notes.md") == nil)
    #expect(MeetingStoragePlan.outputName(forRecordingNamed: "") == nil)
    #expect(MeetingStoragePlan.outputName(forRecordingNamed: "recording") == nil)
}

@Test("An upper-case .M4A import is replaced under its own spelling, never deleted as a leftover (F795)")
func shrinkOutputNameKeepsAnExistingM4ASpelling() {
    // On APFS `recording.M4A` and `recording.m4a` are one file: writing one and deleting the other
    // would delete the shrink's own output. Review Focus 1.
    #expect(MeetingStoragePlan.outputName(forRecordingNamed: "recording.M4A") == "recording.M4A")
    let removable = MeetingStoragePlan.removableFiles(
        in: [Entry(name: "recording.M4A", bytes: 10)], keeping: "recording.m4a"
    )
    #expect(removable.isEmpty)
}

@Test("Shrink removes only listed audio files, manifests first and the old recording last (F795)")
func shrinkRemovesListedFilesInSafeOrder() {
    let removable = MeetingStoragePlan.removableFiles(in: capture, keeping: "meeting.m4a").map(\.name)
    #expect(removable == [
        "source-tracks.json",
        "microphone-audio.f32", "system-audio.f32",
        ".shrink-ABC.m4a", "meeting-recovered-superseded-1.wav",
        "meeting.wav",
    ])
    for kept in ["notes.md", "session.json", "diarization.json", "ask-embeddings.f32",
                 "ask-embeddings.json", "something-unknown.bin"] {
        #expect(!removable.contains(kept), "\(kept) must be kept")
    }
}

@Test("An import's original file is removed, and its provenance and captions are kept (F795)")
func shrinkRemovesTheImportOriginalOnly() {
    let entries = [Entry(name: "recording.mp4", bytes: 900_000_000), Entry(name: "source.json", bytes: 800),
                   Entry(name: "captions.en.vtt", bytes: 5_000), Entry(name: "recording.m4a", bytes: 9_000)]
    #expect(MeetingStoragePlan.removableFiles(in: entries, keeping: "recording.m4a").map(\.name) == ["recording.mp4"])
}

@Test("Shrinking saves at least a quarter of what it frees, or it is refused (F795)")
func shrinkWorthItRule() {
    #expect(MeetingStoragePlan.isWorthShrinking(encodedBytes: 75, reclaimableBytes: 100))
    #expect(!MeetingStoragePlan.isWorthShrinking(encodedBytes: 76, reclaimableBytes: 100))
    #expect(!MeetingStoragePlan.isWorthShrinking(encodedBytes: 0, reclaimableBytes: 0))
    #expect(MeetingStoragePlan.isWorthShrinking(encodedBytes: 0, reclaimableBytes: .max))
    // An in-place replacement frees the recording it overwrites.
    let inPlace = MeetingStoragePlan.reclaimableBytes(
        in: [Entry(name: "recording.m4a", bytes: 1_000)], recordingName: "recording.m4a", outputName: "recording.m4a"
    )
    #expect(inPlace == 1_000)
}

@Test("Predicted size reads correctly at the extremes, not merely without trapping (F795)")
func shrinkPredictionSaturates() {
    #expect(MeetingStoragePlan.predictedOutputBytes(durationSeconds: 3_600) == 14_760_000)
    #expect(MeetingStoragePlan.predictedOutputBytes(durationSeconds: 1e30) == .max)
    #expect(MeetingStoragePlan.predictedOutputBytes(durationSeconds: -5) == 0)
    #expect(MeetingStoragePlan.predictedOutputBytes(durationSeconds: .nan) == 0)
    #expect(MeetingStoragePlan.totalBytes([Entry(name: "a", bytes: .max), Entry(name: "b", bytes: 1)]) == .max)
}

private func disk(_ name: String = "meeting.wav", entries: [Entry] = capture, duration: TimeInterval = 3_600,
                  exists: Bool = true, ownFolder: Bool = true, problem: Bool = false,
                  rebuild: Bool = false) -> MeetingStoragePlan.DiskFacts {
    MeetingStoragePlan.DiskFacts(recordingName: name, recordingExists: exists, inOwnFolder: ownFolder,
                                 hasIntegrityProblem: problem, rebuildOffered: rebuild,
                                 durationSeconds: duration, entries: entries)
}

@Test("Each refusal is reported, in the order a person can act on (F795)")
func shrinkRefusalsAndTheirOrder() {
    let idle = MeetingStoragePlan.LiveFacts()
    #expect(MeetingStoragePlan.unavailability(disk: disk(), live: idle) == nil)
    #expect(MeetingStoragePlan.unavailability(disk: disk(ownFolder: false), live: idle) == .unsupportedRecording)
    #expect(MeetingStoragePlan.unavailability(disk: disk(exists: false), live: idle) == .recordingMissing)
    #expect(MeetingStoragePlan.unavailability(disk: disk(problem: true), live: idle) == .damaged(rebuildOffered: false))
    #expect(MeetingStoragePlan.unavailability(disk: disk(rebuild: true), live: idle) == .damaged(rebuildOffered: true))
    #expect(MeetingStoragePlan.unavailability(disk: disk(duration: 0), live: idle) == .cannotMeasureLength)
    let compact = disk("recording.m4a", entries: [Entry(name: "recording.m4a", bytes: 14_800_000)])
    #expect(MeetingStoragePlan.unavailability(disk: compact, live: idle) == .nothingToGain)
    let shrunk = disk("meeting.m4a", entries: [Entry(name: "meeting.m4a", bytes: 14_800_000),
                                               Entry(name: "notes.md", bytes: 9)])
    #expect(MeetingStoragePlan.unavailability(disk: shrunk, live: idle) == .alreadyShrunk)
    var live = idle; live.libraryReadOnly = true
    #expect(MeetingStoragePlan.unavailability(disk: disk(), live: live) == .libraryReadOnly)
    live = idle; live.captureOrImportInProgress = true
    #expect(MeetingStoragePlan.unavailability(disk: disk(), live: live) == .captureOrImportInProgress)
    live = idle; live.meetingBusy = true
    #expect(MeetingStoragePlan.unavailability(disk: disk(), live: live) == .meetingBusy)
    live = idle; live.backupRunning = true
    #expect(MeetingStoragePlan.unavailability(disk: disk(), live: live) == .backupRunning)
    live = idle; live.anotherShrinkRunning = true
    #expect(MeetingStoragePlan.unavailability(disk: disk(), live: live) == .anotherShrinkRunning)
    // Facts about the meeting are said before busy states that clear on their own.
    live = idle; live.meetingBusy = true
    #expect(MeetingStoragePlan.unavailability(disk: disk(problem: true), live: live) == .damaged(rebuildOffered: false))
}

@Test("A shrunk capture with leftovers is finished, not refused as damaged or compact (F795)")
func shrinkResumeModeIgnoresEncodeRefusals() {
    // The app stopped mid-delete: the index already names meeting.m4a and a raw track survived.
    let leftovers = disk("meeting.m4a", entries: [Entry(name: "meeting.m4a", bytes: 14_800_000),
                                                  Entry(name: "system-audio.f32", bytes: 691_200_000)],
                         duration: 0, problem: true, rebuild: true)
    #expect(MeetingStoragePlan.unavailability(disk: leftovers, live: .init()) == nil)
}
