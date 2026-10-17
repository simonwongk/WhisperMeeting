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

// MARK: - F949: the delete step and the facts the checks ran on

@Test("Only what the checks measured, unchanged, is removed; anything new or changed is kept (F949)")
func removableNowOnlyRemovesWhatWasMeasured() {
    // Every file carries the identity the meter reads (F1005); a measured file without one is never removed.
    func id(_ inode: UInt64) -> InterruptedLinkImportExtraction.FileIdentity {
        .init(device: 1, inode: inode, size: 1, modifiedSeconds: 1, modifiedNanoseconds: 0)
    }
    let measured = [Entry(name: "recording.wav", bytes: 5_760_000, logicalBytes: 5_760_044, identity: id(1)),
                    Entry(name: "recording.mp3", bytes: 1_000_000, logicalBytes: 1_000_000, identity: id(2)),
                    Entry(name: ".shrink-OLD.m4a", bytes: 9_000, identity: id(3)), Entry(name: "notes.md", bytes: 40, identity: id(4))]
    let current = [Entry(name: "recording.wav", bytes: 5_760_000, logicalBytes: 5_760_044, identity: id(1)),
                   Entry(name: "recording.mp3", bytes: 5_000_000, logicalBytes: 5_000_000, identity: id(2)),
                   Entry(name: "recording.webm", bytes: 3_000_000, logicalBytes: 3_000_000, identity: id(5)),
                   Entry(name: ".shrink-OLD.m4a", bytes: 9_000, identity: id(3)), Entry(name: "notes.md", bytes: 40, identity: id(4)),
                   Entry(name: "recording.m4a", bytes: 240_000, logicalBytes: 240_000, identity: id(6))]
    let now = MeetingStoragePlan.removableNow(current: current, measured: measured, keeping: "recording.m4a")
    #expect(now.remove.map(\.name) == [".shrink-OLD.m4a", "recording.wav"])
    #expect(Set(now.changed.map(\.name)) == ["recording.mp3", "recording.webm"], "grew; appeared")
    // A logical length that changed with the same allocation is a change too; a name in another case is the same file.
    let rewritten = [Entry(name: "Recording.WAV", bytes: 5_760_000, logicalBytes: 5_000_000, identity: id(1))]
    #expect(MeetingStoragePlan.removableNow(current: rewritten, measured: measured, keeping: "recording.m4a").changed.count == 1)
    let renamed = [Entry(name: "Recording.WAV", bytes: 5_760_000, logicalBytes: 5_760_044, identity: id(1))]
    #expect(MeetingStoragePlan.removableNow(current: renamed, measured: measured, keeping: "recording.m4a").remove.count == 1)
}

@Test("A file the checks measured is removed only while it is the same file: inode, size and modification time (F1005)")
func removableNowComparesTheMeasuredIdentity() {
    typealias Identity = InterruptedLinkImportExtraction.FileIdentity
    let measuredID = Identity(device: 1, inode: 7, size: 1_000_000, modifiedSeconds: 100, modifiedNanoseconds: 5)
    let measured = [Entry(name: "recording.mp3", bytes: 1_000_000, logicalBytes: 1_000_000, identity: measuredID)]
    func now(_ identity: Identity?) -> (remove: [Entry], changed: [Entry]) {
        MeetingStoragePlan.removableNow(current: [Entry(name: "recording.mp3", bytes: 1_000_000, logicalBytes: 1_000_000,
                                                        identity: identity)],
                                        measured: measured, keeping: "recording.m4a")
    }
    #expect(now(measuredID).remove.count == 1)
    #expect(now(Identity(device: 1, inode: 7, size: 1_000_000, modifiedSeconds: 101, modifiedNanoseconds: 5)).changed.count == 1,
            "rewritten in place at the same size")
    #expect(now(Identity(device: 1, inode: 8, size: 1_000_000, modifiedSeconds: 100, modifiedNanoseconds: 5)).changed.count == 1,
            "replaced by another file")
    #expect(now(nil).changed.count == 1, "a measured identity that cannot be read now is a change")
    // A measured listing that could not read a file's identity cannot show the file is the one measured: kept, not
    // judged by its sizes (review 1 of Wave 8 lane A, finding 6).
    let unidentified = [Entry(name: "recording.mp3", bytes: 1_000_000, logicalBytes: 1_000_000)]
    #expect(MeetingStoragePlan.removableNow(current: [Entry(name: "recording.mp3", bytes: 1_000_000, logicalBytes: 1_000_000,
                                                            identity: measuredID)],
                                            measured: unidentified, keeping: "recording.m4a").changed.count == 1)
}

@Test("A file whose tracks were not read, read as none, or read with no channels goes to the ffmpeg decode (F1004)")
func unreadRecordingsAreThoseWhoseChannelsAreNotShown() {
    var disk = MeetingStoragePlan.DiskFacts(
        recordingName: "recording.wav", recordingExists: true, inOwnFolder: true, hasIntegrityProblem: false,
        rebuildOffered: false, durationSeconds: 6,
        entries: ["recording.wav", "recording.webm", "recording.mp4", "recording.mka", "recording.m4a", "recording.caf"]
            .map { Entry(name: $0, bytes: 1_000) } + [Entry(name: "recording.ogg", bytes: 0)])
    disk.otherRecordingTracks = ["recording.mp4": [], "recording.mka": [.init(channels: 2), .init(channels: 0)],
                                 "recording.m4a": [.init(channels: 2)], "recording.caf": [.init(channels: 1)]]
    #expect(MeetingStoragePlan.unreadRecordingsToVerify(disk).map(\.name).sorted() == ["recording.mka", "recording.mp4", "recording.webm"],
            "nil, none listed (review 1 of Wave 8 lane A, finding 1) and a track of no channels; never an empty file")
}

@Test("The copy replaces a file named as the output only while it is the file the checks measured (F1005)")
func mayReplaceOnlyTheMeasuredOutput() {
    typealias Identity = InterruptedLinkImportExtraction.FileIdentity
    let id = Identity(device: 1, inode: 9, size: 240_000, modifiedSeconds: 10, modifiedNanoseconds: 0)
    let measured = [Entry(name: "Recording.M4A", bytes: 240_000, logicalBytes: 240_000, identity: id)]
    #expect(MeetingStoragePlan.mayReplaceOutput(named: "recording.m4a", current: nil, exists: false, measured: []))
    #expect(MeetingStoragePlan.mayReplaceOutput(named: "recording.m4a", current: id, exists: true, measured: measured))
    #expect(!MeetingStoragePlan.mayReplaceOutput(
        named: "recording.m4a", current: Identity(device: 1, inode: 9, size: 240_000, modifiedSeconds: 11, modifiedNanoseconds: 0),
        exists: true, measured: measured), "changed since")
    #expect(!MeetingStoragePlan.mayReplaceOutput(named: "recording.m4a", current: id, exists: true, measured: []), "appeared since")
    #expect(!MeetingStoragePlan.mayReplaceOutput(named: "recording.m4a", current: nil, exists: true, measured: measured))
    #expect(!MeetingStoragePlan.mayReplaceOutput(
        named: "recording.m4a", current: id, exists: true,
        measured: [Entry(name: "recording.m4a", bytes: 240_000, logicalBytes: 240_000)]), "never identified")
}

@Test("A dataless other recording is not taken for empty: its logical length counts (F949)")
func otherRecordingAtRiskReadsTheLogicalLength() {
    // iCloud Optimize Storage or a File Provider placeholder: nothing on disk, the whole download elsewhere.
    var facts = disk("recording.wav", entries: [Entry(name: "recording.wav", bytes: 115_200_000),
                                                Entry(name: "recording.webm", bytes: 0, logicalBytes: 72_000_000)])
    #expect(MeetingStoragePlan.otherRecordingAtRisk(facts)?.name == "recording.webm", "unmeasured, so at risk")
    #expect(MeetingStoragePlan.unavailability(disk: facts, live: .init())
            == .otherRecordingMayHoldMore(name: "recording.webm", seconds: nil))
    // Truly empty, by both sizes, holds nothing, as before; and a size never read is judged by bytes alone.
    facts.entries[1] = Entry(name: "recording.webm", bytes: 0, logicalBytes: 0)
    #expect(MeetingStoragePlan.otherRecordingAtRisk(facts) == nil)
    facts.entries[1] = Entry(name: "recording.webm", bytes: 0)
    #expect(MeetingStoragePlan.otherRecordingAtRisk(facts) == nil)
}

// MARK: - F955: a resume's leftovers, by their tracks and channels

@Test("A resume checks the copy against a leftover a mix must hold, and keeps one it cannot check (F955)")
func resumeLeftoverTracksDecideWhatIsChecked() {
    let idle = MeetingStoragePlan.LiveFacts()
    var resume = disk("recording.m4a", entries: [Entry(name: "recording.m4a", bytes: 14_800_000),
                                                 Entry(name: "recording.mov", bytes: 900_000_000)])
    resume.otherRecordingSeconds = ["recording.mov": 3_600]
    // One track: its length is the whole question, as before (F911).
    resume.otherRecordingTracks = ["recording.mov": [RecordingMixPlan.Track(channels: 2)]]
    #expect(MeetingStoragePlan.unavailability(disk: resume, live: idle) == nil)
    #expect(MeetingStoragePlan.otherRecordingsToVerify(resume).isEmpty)
    // Two tracks: as shipped, kept, while Shrink of a recording that needs mixing is held back (F980).
    resume.otherRecordingTracks = ["recording.mov": [RecordingMixPlan.Track(channels: 1), RecordingMixPlan.Track(channels: 1)]]
    #expect(MeetingStoragePlan.unavailability(disk: resume, live: idle)
            == .otherRecordingHasMoreTracks(name: "recording.mov", tracks: 2, channels: 2))
    // With the switch on: allowed, and the resume checks the copy against it before removing it.
    #expect(MeetingStoragePlan.unavailability(disk: resume, live: idle, mixing: true) == nil)
    #expect(MeetingStoragePlan.otherRecordingsToVerify(resume).map(\.name) == ["recording.mov"])
    // Alternates are never mixed, so no copy holds them both: kept, saying why.
    resume.otherRecordingTracks = ["recording.mov": [RecordingMixPlan.Track(channels: 1, alternateGroup: 0, language: "eng"),
                                                     RecordingMixPlan.Track(channels: 1, alternateGroup: 0, language: "fra")]]
    #expect(MeetingStoragePlan.unavailability(disk: resume, live: idle, mixing: true)
            == .otherRecordingHasMoreTracks(name: "recording.mov", tracks: 2, channels: 2))
    #expect(MeetingStoragePlan.Unavailability.otherRecordingHasMoreTracks(name: "recording.mov", tracks: 2, channels: 2)
        .message.contains("“recording.mov”, which has 2 audio tracks"))
    // Outside a resume nothing checks the copy against another recording, so one a mix must hold is kept.
    var encode = disk("recording.wav", entries: [Entry(name: "recording.wav", bytes: 1_382_400_000),
                                                 Entry(name: "recording.caf", bytes: 1_382_400_000)])
    encode.otherRecordingSeconds = ["recording.caf": 3_600]
    encode.otherRecordingTracks = ["recording.caf": [RecordingMixPlan.Track(channels: 4)]]
    #expect(MeetingStoragePlan.unavailability(disk: encode, live: idle)
            == .otherRecordingHasMoreTracks(name: "recording.caf", tracks: 1, channels: 4))
    #expect(MeetingStoragePlan.Unavailability.otherRecordingHasMoreTracks(name: "recording.caf", tracks: 1, channels: 4)
        .message.contains("which has 4 channels"))
}
