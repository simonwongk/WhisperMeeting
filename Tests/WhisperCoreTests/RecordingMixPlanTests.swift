import Foundation
import Testing
@testable import WhisperCore

// F942, F953 — when a recording is mixed into one before anything listens to it, and how Shrink's
// planner treats a recording it can mix. Pure: the facts are what AVFoundation reports per track.

private typealias Track = RecordingMixPlan.Track
private typealias Entry = MeetingStoragePlan.FolderEntry

@Test("One track of one or two channels is left as it is; several tracks, or more channels, are mixed (F942)")
func mixPlanDecidesWhatIsMixed() {
    #expect(RecordingMixPlan.decision(for: []) == .asItIs)
    #expect(RecordingMixPlan.decision(for: [Track(channels: 1)]) == .asItIs)
    #expect(RecordingMixPlan.decision(for: [Track(channels: 2)]) == .asItIs, "the engines' decodes mix stereo (F796)")
    #expect(RecordingMixPlan.decision(for: [Track(channels: 4)]) == .mixEveryChannel(channels: 4))
    #expect(RecordingMixPlan.decision(for: [Track(channels: 6)]) == .mixEveryChannel(channels: 6), "5.1 too (F953)")
    #expect(RecordingMixPlan.decision(for: [Track(channels: 1), Track(channels: 1)]) == .mixEveryChannel(channels: 2))
    #expect(RecordingMixPlan.decision(for: [Track(channels: 2), Track(channels: 1)]) == .mixEveryChannel(channels: 3))
}

@Test("Alternate tracks are not mixed, and a track whose channels cannot be read is not either (F942)")
func mixPlanRefusesAlternatesAndTheUnreadable() {
    let languages = [Track(channels: 1, alternateGroup: 0), Track(channels: 1, alternateGroup: 0)]
    #expect(RecordingMixPlan.decision(for: languages) == .unsupported(.alternateTracks(count: 2)))
    // A group a track holds alone (say, with the video it belongs to) is not an alternative to anything.
    let own = [Track(channels: 1, alternateGroup: 0), Track(channels: 1, alternateGroup: 1)]
    #expect(RecordingMixPlan.decision(for: own) == .mixEveryChannel(channels: 2))
    #expect(RecordingMixPlan.decision(for: [Track(channels: 0), Track(channels: 1)]) == .unsupported(.unreadableTrack))
}

@Test("A sum of any number of inputs follows the capture mixer's rule exactly (F942, F345)")
func limitedSampleIsTheCaptureMixersRule() {
    let pairs: [(Float, Float)] = [(0, 0), (0.1, 0.2), (-0.4, 0.3), (0.8, 0.6), (-0.9, -0.9), (1, 1), (3, -0.5)]
    for (a, b) in pairs {
        #expect(FloatTrackMixer.limitedSample(sum: a + b) == FloatTrackMixer.mixedSample(system: a, microphone: b))
    }
    // A voice alone keeps 0.95 of its level, and no sum reaches full scale.
    #expect(FloatTrackMixer.limitedSample(sum: 0.5) == Int16(0.95 * 0.5 * Float(Int16.max)))
    let sums: [Float] = [1.5, 2, 4, 8, -8]
    for sum in sums { #expect(abs(Int(FloatTrackMixer.limitedSample(sum: sum))) < Int(Int16.max), "\(sum)") }
}

private func disk(_ name: String, bytes: Int64 = 900_000_000) -> MeetingStoragePlan.DiskFacts {
    MeetingStoragePlan.DiskFacts(recordingName: name, recordingExists: true, inOwnFolder: true,
                                 hasIntegrityProblem: false, rebuildOffered: false, durationSeconds: 3_600,
                                 entries: [Entry(name: name, bytes: bytes)])
}

@Test("Shrink mixes a recording whose tracks it read, and refuses alternates and the unread (F942, F953)")
func shrinkMixesWhatItCanRead() {
    let idle = MeetingStoragePlan.LiveFacts()
    var call = disk("recording.mov")
    call.audioTrackCount = 2
    call.channelCount = 1
    call.audioTracks = [Track(channels: 1), Track(channels: 1)]
    #expect(MeetingStoragePlan.needsMix(call))
    #expect(MeetingStoragePlan.unavailability(disk: call, live: idle) == nil)

    var poly = disk("recording.wav", bytes: 1_382_400_000)
    poly.channelCount = 4
    poly.audioTracks = [Track(channels: 4)]
    #expect(MeetingStoragePlan.unavailability(disk: poly, live: idle) == nil, "F953: whatever the layout")

    var languages = call
    languages.audioTracks = [Track(channels: 1, alternateGroup: 0), Track(channels: 1, alternateGroup: 0)]
    #expect(MeetingStoragePlan.unavailability(disk: languages, live: idle) == .alternateAudioTracks(count: 2))
    #expect(MeetingStoragePlan.Unavailability.alternateAudioTracks(count: 2).message.contains("alternatives"))

    // Fail-closed: not read, or read as something that needs no mix while the counts say it does.
    var unread = call
    unread.audioTracks = nil
    #expect(MeetingStoragePlan.unavailability(disk: unread, live: idle) == .multipleAudioTracks(count: 2))
    var disagreeing = poly
    disagreeing.audioTracks = [Track(channels: 2)]
    #expect(MeetingStoragePlan.unavailability(disk: disagreeing, live: idle) == .multipleChannels(count: 4))
    var unreadable = call
    unreadable.audioTracks = [Track(channels: 0), Track(channels: 1)]
    #expect(MeetingStoragePlan.unavailability(disk: unreadable, live: idle) == .multipleAudioTracks(count: 2))

    // One track of one or two channels is the encode's own business, as before.
    var stereo = disk("recording.wav")
    stereo.channelCount = 2
    #expect(!MeetingStoragePlan.needsMix(stereo))
    #expect(MeetingStoragePlan.unavailability(disk: stereo, live: idle) == nil)
}

@Test("Each channel of a mixed recording must reach the copy wherever it sounds (F942)")
func mixedCopyMustCarryEveryChannel() {
    // Two sides taking turns, one 5 s window each, at 0.2; the whole recording's level over both
    // channels is then 0.1.
    let channels: [[Double]] = [[0.2, 0, 0.2, 0], [0, 0.2, 0, 0.2]]
    // A mix holds each side at 0.95 of its level.
    #expect(MeetingStoragePlan.firstWindowLosingAChannel(channels: channels, compressed: [0.19, 0.19, 0.19, 0.19],
                                                         originalLevel: 0.1) == nil)
    // A copy that kept track 1 only: silent wherever track 2 spoke.
    #expect(MeetingStoragePlan.firstWindowLosingAChannel(channels: channels, compressed: [0.19, 0.0001, 0.19, 0.0001],
                                                         originalLevel: 0.1) == 1)
    // The floor is the band's lower bound times the mix's gain: just above it passes, just below fails.
    let floor = MeetingStoragePlan.levelRatioBand.lowerBound * RecordingMixPlan.gain * 0.2
    #expect(MeetingStoragePlan.firstWindowLosingAChannel(channels: [[0.2]], compressed: [floor * 1.01], originalLevel: 0.2) == nil)
    #expect(MeetingStoragePlan.firstWindowLosingAChannel(channels: [[0.2]], compressed: [floor * 0.99], originalLevel: 0.2) == 0)
    // A channel below a tenth of the recording's level is not judged; a copy that is not a number fails.
    #expect(MeetingStoragePlan.firstWindowLosingAChannel(channels: [[0.2], [0.009]], compressed: [0.19], originalLevel: 0.1) == nil)
    #expect(MeetingStoragePlan.firstWindowLosingAChannel(channels: [[0.2]], compressed: [.nan], originalLevel: 0.2) == 0)
    // A channel lost while another is as loud in the same stretch is not caught, as the doc says.
    #expect(MeetingStoragePlan.firstWindowLosingAChannel(channels: [[0.2], [0.2]], compressed: [0.19], originalLevel: 0.2) == nil)
}
