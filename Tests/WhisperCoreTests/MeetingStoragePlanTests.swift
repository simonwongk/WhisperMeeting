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

// MARK: - Final-review findings (F795)

@Test("A file in a subfolder is never on the delete list, whatever its name (F795 review)")
func shrinkNeverRemovesNestedFiles() {
    // The meter lists nested files as "sub/name"; a user's folder inside a meeting folder holding a
    // file called recording.txt or meeting.wav is not the meeting's audio.
    let nested = [Entry(name: "Notes/recording.md", bytes: 5), Entry(name: "sub/meeting.wav", bytes: 5),
                  Entry(name: "sub/system-audio.f32", bytes: 5)]
    #expect(MeetingStoragePlan.removableFiles(in: nested, keeping: "meeting.m4a").isEmpty)
}

@Test("An import whose shrink was interrupted is finished, not encoded a second time (F795 review)")
func shrinkResumesAnInterruptedImport() {
    // The index already names recording.m4a and the original recording.mp4 survived, so the AAC is not
    // encoded again. Since F911 the leftover must be measured as no longer than the recording before
    // it is removed — a Shrink original always is, since its encode was checked against it.
    var interrupted = disk("recording.m4a", entries: [Entry(name: "recording.m4a", bytes: 14_800_000),
                                                      Entry(name: "recording.mp4", bytes: 900_000_000)])
    interrupted.otherRecordingSeconds = ["recording.mp4": 3_600]
    #expect(MeetingStoragePlan.isResume(interrupted))
    #expect(MeetingStoragePlan.unavailability(disk: interrupted, live: .init()) == nil)
    // A plain AAC import with nothing left over is an ordinary candidate, judged by the size rule.
    let plain = disk("recording.m4a", entries: [Entry(name: "recording.m4a", bytes: 900_000_000)])
    #expect(!MeetingStoragePlan.isResume(plain))
    #expect(MeetingStoragePlan.isResume(disk("meeting.m4a", entries: [Entry(name: "meeting.m4a", bytes: 1),
                                                                     Entry(name: "meeting.wav", bytes: 9)])))
}

@Test("A restore in progress is its own refusal, not a wrong one (F795 review)")
func shrinkRefusesDuringARestore() {
    var live = MeetingStoragePlan.LiveFacts()
    live.libraryRestoring = true
    #expect(MeetingStoragePlan.unavailability(disk: disk(), live: live) == .libraryRestoring)
    #expect(MeetingStoragePlan.Unavailability.libraryRestoring.message.contains("restore"))
}

// MARK: - F801: a container with several audio tracks, and a copy whose level is wrong

// Since F942 a recording with several tracks is mixed into the copy when what each track holds was
// read (`shrinkMixesWhatItCanRead`). These are the facts as F801 left them, with no tracks read, which
// is still refused: the plain encode would keep track 1.
@Test("An import with several audio tracks nobody read is refused, saying how many would be lost (F801, F942)")
func shrinkRefusesSeveralAudioTracks() {
    let idle = MeetingStoragePlan.LiveFacts()
    var two = disk("recording.mov", entries: [Entry(name: "recording.mov", bytes: 900_000_000)])
    two.audioTrackCount = 2
    #expect(MeetingStoragePlan.unavailability(disk: two, live: idle) == .multipleAudioTracks(count: 2))
    var three = two
    three.audioTrackCount = 3
    #expect(MeetingStoragePlan.unavailability(disk: three, live: idle) == .multipleAudioTracks(count: 3))
    // One track, or a count nobody could read, is judged by the other rules as before.
    var one = two
    one.audioTrackCount = 1
    #expect(MeetingStoragePlan.unavailability(disk: one, live: idle) == nil)
    var unread = two
    unread.audioTrackCount = nil
    #expect(MeetingStoragePlan.unavailability(disk: unread, live: idle) == nil)
    // Damage is still said first: Rebuild Audio is the step that comes before anything else.
    var damaged = two
    damaged.hasIntegrityProblem = true
    #expect(MeetingStoragePlan.unavailability(disk: damaged, live: idle) == .damaged(rebuildOffered: false))
    // Finishing an interrupted shrink encodes nothing, so the tracks are not its question.
    var resume = disk("recording.m4a", entries: [Entry(name: "recording.m4a", bytes: 14_800_000),
                                                 Entry(name: "recording.mov", bytes: 900_000_000)])
    resume.audioTrackCount = 2
    // Measured as no longer than the recording, which F911 requires before a leftover is removed.
    resume.otherRecordingSeconds = ["recording.mov": 3_600]
    #expect(MeetingStoragePlan.unavailability(disk: resume, live: idle) == nil)
    #expect(MeetingStoragePlan.Unavailability.multipleAudioTracks(count: 2).message
        .contains("2 audio tracks, and they can't be read to mix them into one. A shrunk copy would keep only the first, and the other track would be deleted"))
    #expect(MeetingStoragePlan.Unavailability.multipleAudioTracks(count: 3).message.contains("the other 2 tracks"))
}

@Test("Only an import's container is asked how many audio tracks it holds (F801)")
func shrinkCountsTracksOnlyForAnImport() {
    #expect(MeetingStoragePlan.mayHoldSeveralAudioTracks("recording.mov"))
    #expect(MeetingStoragePlan.mayHoldSeveralAudioTracks("recording.m4a"))
    #expect(MeetingStoragePlan.mayHoldSeveralAudioTracks("recording.wav"))
    #expect(!MeetingStoragePlan.mayHoldSeveralAudioTracks("meeting.wav"))
    #expect(!MeetingStoragePlan.mayHoldSeveralAudioTracks("meeting-recovered.wav"))
    #expect(!MeetingStoragePlan.mayHoldSeveralAudioTracks("meeting.m4a"))
}

@Test("A recording with more than two channels nobody read is refused, saying how many; stereo and mono are not (F801 review, F942)")
func shrinkRefusesMoreThanTwoChannels() {
    let idle = MeetingStoragePlan.LiveFacts()
    // An hour of four-channel 16-bit 48 kHz audio, so the size rule alone would shrink it.
    var four = disk("recording.wav", entries: [Entry(name: "recording.wav", bytes: 1_382_400_000)])
    four.channelCount = 4
    #expect(MeetingStoragePlan.unavailability(disk: four, live: idle) == .multipleChannels(count: 4))
    var three = four
    three.channelCount = 3
    #expect(MeetingStoragePlan.unavailability(disk: three, live: idle) == .multipleChannels(count: 3))
    // Stereo is mixed by the encode (F796), mono is what it makes, and a count nobody could read is
    // judged by the other rules as before — the encode's own checks still run.
    let shrinkable: [Int?] = [2, 1, nil]
    for count in shrinkable {
        var other = four
        other.channelCount = count
        #expect(MeetingStoragePlan.unavailability(disk: other, live: idle) == nil, "\(String(describing: count))")
    }
    // Damage is said first, and several tracks before several channels: a copy keeps one track,
    // whatever its channels.
    var damaged = four
    damaged.hasIntegrityProblem = true
    #expect(MeetingStoragePlan.unavailability(disk: damaged, live: idle) == .damaged(rebuildOffered: false))
    var tracks = four
    tracks.audioTrackCount = 2
    #expect(MeetingStoragePlan.unavailability(disk: tracks, live: idle) == .multipleAudioTracks(count: 2))
    // Finishing an interrupted shrink encodes nothing and keeps the recording, which is already the
    // copy, so its channels are not the question there.
    var resume = disk("recording.m4a", entries: [Entry(name: "recording.m4a", bytes: 14_800_000),
                                                 Entry(name: "recording.wav", bytes: 1_382_400_000)])
    resume.channelCount = 4
    resume.otherRecordingSeconds = ["recording.wav": 3_600]
    #expect(MeetingStoragePlan.isResume(resume))
    #expect(MeetingStoragePlan.unavailability(disk: resume, live: idle) == nil)
    #expect(MeetingStoragePlan.Unavailability.multipleChannels(count: 4).message
        == "This recording has 4 channels, and they can't be read to mix them into one. A shrunk copy would keep only some of them, and the others would be deleted with the original, so it isn't shrunk.")
}

@Test("A compressed copy must carry the recording's level: silence, and a copy far off either way, are refused (F801)")
func shrinkLevelsMustAgree() {
    // Measured through Shrink's own encode: speech 0.993-0.997 of the original, white noise 0.537.
    #expect(MeetingStoragePlan.levelsAgree(original: 0.18005, compressed: 0.17944))
    #expect(MeetingStoragePlan.levelsAgree(original: 0.17303, compressed: 0.09285),
            "broadband noise loses what lies above 8 kHz, and that is not a wrong encode")
    #expect(!MeetingStoragePlan.levelsAgree(original: 0.21211, compressed: 0), "a silent encode")
    #expect(!MeetingStoragePlan.levelsAgree(original: 0.2, compressed: 0.049), "more than 12 dB quieter")
    #expect(MeetingStoragePlan.levelsAgree(original: 0.2, compressed: 0.05), "the band's lower edge is inside it")
    #expect(!MeetingStoragePlan.levelsAgree(original: 0.1, compressed: 0.41), "more than four times louder")
    // A silent recording has no sound to lose, so there is nothing to compare.
    #expect(MeetingStoragePlan.levelsAgree(original: 0, compressed: 0))
    #expect(MeetingStoragePlan.levelsAgree(original: 0.000_05, compressed: 0.3))
    // A level that is not a finite, non-negative number agrees with nothing.
    #expect(!MeetingStoragePlan.levelsAgree(original: .nan, compressed: 0.2))
    #expect(!MeetingStoragePlan.levelsAgree(original: 0.2, compressed: .infinity))
    #expect(!MeetingStoragePlan.levelsAgree(original: -0.2, compressed: 0.2))
}

// MARK: - F801 review (R2): a copy can keep the file's level and still lose a stretch of it

@Test("A copy is refused at the first audible stretch it lost, and quiet stretches are not judged (F801 review)")
func shrinkFindsTheFirstStretchTheCopyLost() {
    // A copy that kept the first fifth of 30 s of steady sound: window 1 keeps one second of five.
    let original = [Double](repeating: 0.2, count: 6)
    let partial: [Double] = [0.2, 0.2 * (1.0 / 5).squareRoot(), 0, 0, 0, 0]
    #expect(MeetingStoragePlan.levelsAgree(original: 0.2, compressed: 0.2 * (0.2).squareRoot()),
            "the whole-file band alone lets it through")
    #expect(MeetingStoragePlan.firstWindowLosingSound(original: original, compressed: partial, originalLevel: 0.2) == 2)
    // Every stretch kept, at the levels measured for real encodes, passes.
    let speech: [Double] = [0.13, 0.12, 0.14, 0.02, 0.13]
    #expect(MeetingStoragePlan.firstWindowLosingSound(
        original: speech, compressed: speech.map { $0 * 0.996 }, originalLevel: 0.12) == nil)
    #expect(MeetingStoragePlan.firstWindowLosingSound(
        original: original, compressed: original.map { $0 * 0.377 }, originalLevel: 0.2) == nil)
    // A stretch quieter than a tenth of the whole file's level is not judged: lost or not, it is not
    // where the recording's sound is.
    let pauses: [Double] = [0.2, 0.01, 0.2]
    #expect(MeetingStoragePlan.firstWindowLosingSound(
        original: pauses, compressed: [0.2, 0, 0.2], originalLevel: 0.16) == nil)
    // Lower bound only, and a level that is not a number is a loss.
    #expect(MeetingStoragePlan.firstWindowLosingSound(
        original: original, compressed: original.map { $0 * 3.9 }, originalLevel: 0.2) == nil)
    #expect(MeetingStoragePlan.firstWindowLosingSound(
        original: [0.2, 0.2], compressed: [0.2, .nan], originalLevel: 0.2) == 1)
    // Nothing measured, nothing judged: the fakes in the flow tests, and a copy one window short.
    #expect(MeetingStoragePlan.firstWindowLosingSound(original: [], compressed: [], originalLevel: 0.2) == nil)
    #expect(MeetingStoragePlan.firstWindowLosingSound(original: [0.2, 0.2], compressed: [0.2], originalLevel: 0.2) == nil)
}

// MARK: - F911: a link import's complete download beside the shorter WAV ffmpeg finished on SIGTERM

/// A recovered link import indexed against `recording.wav` (30 minutes) with its download beside it.
private func linkImport(download: String = "recording.webm", downloadBytes: Int64 = 83_000_000,
                        seconds: TimeInterval?) -> MeetingStoragePlan.DiskFacts {
    var facts = disk("recording.wav", entries: [Entry(name: "recording.wav", bytes: 57_600_044),
                                                Entry(name: download, bytes: downloadBytes),
                                                Entry(name: "source.json", bytes: 300)],
                     duration: 1_800)
    if let seconds { facts.otherRecordingSeconds = [download: seconds] }
    return facts
}

@Test("Shrink refuses to delete another recording that runs longer, or whose length is unknown (F911)")
func shrinkRefusesAnOtherRecordingThatMayHoldMore() {
    let idle = MeetingStoragePlan.LiveFacts()
    // The download runs an hour; the WAV ffmpeg finished on SIGTERM holds half of it.
    #expect(MeetingStoragePlan.unavailability(disk: linkImport(seconds: 3_600), live: idle)
            == .otherRecordingMayHoldMore(name: "recording.webm", seconds: 3_600))
    // Never measured — a WebM macOS cannot open — is not shown to be covered.
    #expect(MeetingStoragePlan.unavailability(disk: linkImport(seconds: nil), live: idle)
            == .otherRecordingMayHoldMore(name: "recording.webm", seconds: nil))
    // The output's own name is at risk too: the encode would replace it.
    #expect(MeetingStoragePlan.unavailability(disk: linkImport(download: "recording.m4a", seconds: 3_600), live: idle)
            == .otherRecordingMayHoldMore(name: "recording.m4a", seconds: 3_600))
    // Said before the busy states, which clear on their own.
    var busy = idle; busy.meetingBusy = true
    #expect(MeetingStoragePlan.unavailability(disk: linkImport(seconds: nil), live: busy)
            == .otherRecordingMayHoldMore(name: "recording.webm", seconds: nil))
    let longer = MeetingStoragePlan.Unavailability.otherRecordingMayHoldMore(name: "recording.webm", seconds: 3_600).message
    #expect(longer.contains("“recording.webm”") && longer.contains("1:00:00") && longer.contains("longer than this recording"), "\(longer)")
    let unknown = MeetingStoragePlan.Unavailability.otherRecordingMayHoldMore(name: "recording.webm", seconds: nil).message
    #expect(unknown.contains("“recording.webm”") && unknown.contains("can't be read"), "\(unknown)")
}

@Test("Another recording no longer than the recording, or empty, does not stop Shrink (F911)")
func shrinkAllowsAnOtherRecordingThatHoldsNoMore() {
    let idle = MeetingStoragePlan.LiveFacts()
    // The download and the WAV made from it were measured at most 32 ms apart.
    #expect(MeetingStoragePlan.unavailability(disk: linkImport(seconds: 1_800.032), live: idle) == nil)
    #expect(MeetingStoragePlan.unavailability(disk: linkImport(seconds: 1_800 + InterruptedLinkImportExtraction.lengthTolerance), live: idle) == nil)
    #expect(MeetingStoragePlan.unavailability(disk: linkImport(seconds: 1_800.6), live: idle) != nil)
    #expect(MeetingStoragePlan.unavailability(disk: linkImport(seconds: 900), live: idle) == nil)
    // An empty file holds nothing, measured or not.
    #expect(MeetingStoragePlan.unavailability(disk: linkImport(downloadBytes: 0, seconds: nil), live: idle) == nil)
    // Only the import's stem counts, and never the recording itself or a nested file.
    let others = MeetingStoragePlan.otherRecordings(
        in: [Entry(name: "recording.wav", bytes: 1), Entry(name: "recording.webm", bytes: 1),
             Entry(name: "recording.extracting.wav", bytes: 1), Entry(name: "sub/recording.mp4", bytes: 1),
             Entry(name: "recording", bytes: 1), Entry(name: "meeting.wav", bytes: 1)],
        recordingName: "recording.WAV"
    )
    #expect(others.map(\.name) == ["recording.webm"])
}

@Test("A resume does not remove a leftover that runs longer than the recording (F911)")
func shrinkResumeRefusesALongerLeftover() {
    // recording.m4a beside a longer recording.wav is not Shrink's own interrupted commit.
    var facts = disk("recording.m4a", entries: [Entry(name: "recording.m4a", bytes: 9_000_000),
                                                Entry(name: "recording.wav", bytes: 115_200_044)],
                     duration: 1_800)
    #expect(MeetingStoragePlan.isResume(facts))
    facts.otherRecordingSeconds = ["recording.wav": 3_600]
    #expect(MeetingStoragePlan.unavailability(disk: facts, live: .init())
            == .otherRecordingMayHoldMore(name: "recording.wav", seconds: 3_600))
    facts.otherRecordingSeconds = ["recording.wav": 1_800]
    #expect(MeetingStoragePlan.unavailability(disk: facts, live: .init()) == nil)
}
