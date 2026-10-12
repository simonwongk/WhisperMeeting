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
    let languages = [Track(channels: 1, alternateGroup: 0, language: "eng"), Track(channels: 1, alternateGroup: 0, language: "fra")]
    #expect(RecordingMixPlan.decision(for: languages) == .unsupported(.alternateTracks(count: 2)))
    // Review R3: ffmpeg groups every audio track it writes and tags them `und`; a group whose tracks share
    // a language, or carry none, holds parts of one recording, and is mixed.
    let ffmpeg = [Track(channels: 1, alternateGroup: 0, language: "und"), Track(channels: 1, alternateGroup: 0, language: "und")]
    #expect(RecordingMixPlan.decision(for: ffmpeg) == .mixEveryChannel(channels: 2))
    let untagged = [Track(channels: 1, alternateGroup: 0), Track(channels: 1, alternateGroup: 0)]
    #expect(RecordingMixPlan.decision(for: untagged) == .mixEveryChannel(channels: 2))
    let same = [Track(channels: 1, alternateGroup: 0, language: "eng"), Track(channels: 1, alternateGroup: 0, language: "ENG ")]
    #expect(RecordingMixPlan.decision(for: same) == .mixEveryChannel(channels: 2))
    let oneTagged = [Track(channels: 1, alternateGroup: 0, language: "eng"), Track(channels: 1, alternateGroup: 0)]
    #expect(RecordingMixPlan.decision(for: oneTagged) == .mixEveryChannel(channels: 2), "both must be set to differ")
    let apart = [Track(channels: 1, language: "eng"), Track(channels: 1, language: "fra")]
    #expect(RecordingMixPlan.decision(for: apart) == .mixEveryChannel(channels: 2), "languages outside a group play together")
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

@Test("Mixing Shrink is off as shipped, until F980 proves its check of a mixed copy (F942, F980)")
func shrinkMixingSwitchIsOff() {
    #expect(MeetingStoragePlan.shrinkMixesRecordings == false)
}

@Test("As shipped, Shrink refuses a recording it would mix, saying it isn't available yet (F942, F980)")
func shrinkRefusesWhatItWouldMixWhileHeldBack() {
    let idle = MeetingStoragePlan.LiveFacts()
    var call = disk("recording.mov")
    call.audioTrackCount = 2
    call.channelCount = 1
    call.audioTracks = [Track(channels: 1), Track(channels: 1)]
    #expect(MeetingStoragePlan.unavailability(disk: call, live: idle) == .mixingNotAvailableYet(tracks: 2, channels: 2))
    #expect(MeetingStoragePlan.Unavailability.mixingNotAvailableYet(tracks: 2, channels: 2).message
        == "This recording has 2 audio tracks; shrinking it isn't available yet, so its audio is kept as it is.")
    var surround = disk("recording.wav", bytes: 1_382_400_000)
    surround.channelCount = 6
    surround.audioTracks = [Track(channels: 6)]
    #expect(MeetingStoragePlan.unavailability(disk: surround, live: idle) == .mixingNotAvailableYet(tracks: 1, channels: 6))
    #expect(MeetingStoragePlan.Unavailability.mixingNotAvailableYet(tracks: 1, channels: 6).message
        == "This recording has 6 channels; shrinking it isn't available yet, so its audio is kept as it is.")
    var many = surround
    many.channelCount = 24
    many.audioTracks = [Track(channels: 24)]
    #expect(MeetingStoragePlan.unavailability(disk: many, live: idle) == .mixingNotAvailableYet(tracks: 1, channels: 24))
    // Alternates and unread tracks keep their own reasons, which mixing would not change.
    var languages = call
    languages.audioTracks = [Track(channels: 1, alternateGroup: 0, language: "eng"), Track(channels: 1, alternateGroup: 0, language: "fra")]
    #expect(MeetingStoragePlan.unavailability(disk: languages, live: idle) == .alternateAudioTracks(count: 2))
    var unread = call
    unread.audioTracks = nil
    #expect(MeetingStoragePlan.unavailability(disk: unread, live: idle) == .multipleAudioTracks(count: 2))
    // One track of one or two channels is the encode's own, and still shrinks.
    var stereo = disk("recording.wav")
    stereo.channelCount = 2
    #expect(MeetingStoragePlan.unavailability(disk: stereo, live: idle) == nil)
}

@Test("With the switch on, Shrink mixes a recording whose tracks it read, and refuses alternates and the unread (F942, F953)")
func shrinkMixesWhatItCanRead() {
    // The held-back path, which F980 starts from.
    let idle = MeetingStoragePlan.LiveFacts()
    var call = disk("recording.mov")
    call.audioTrackCount = 2
    call.channelCount = 1
    call.audioTracks = [Track(channels: 1), Track(channels: 1)]
    #expect(MeetingStoragePlan.needsMix(call))
    #expect(MeetingStoragePlan.unavailability(disk: call, live: idle, mixing: true) == nil)

    var poly = disk("recording.wav", bytes: 1_382_400_000)
    poly.channelCount = 4
    poly.audioTracks = [Track(channels: 4)]
    #expect(MeetingStoragePlan.unavailability(disk: poly, live: idle, mixing: true) == nil, "F953: whatever the layout")
    var many = poly
    many.channelCount = 24
    many.audioTracks = [Track(channels: 24)]
    #expect(MeetingStoragePlan.unavailability(disk: many, live: idle, mixing: true) == .tooManyChannelsToCheck(count: 24),
            "more than the copy's check fits one by one (review R2)")
    #expect(MeetingStoragePlan.Unavailability.tooManyChannelsToCheck(count: 24).message.contains("24 channels"))

    var languages = call
    languages.audioTracks = [Track(channels: 1, alternateGroup: 0, language: "eng"), Track(channels: 1, alternateGroup: 0, language: "fra")]
    #expect(MeetingStoragePlan.unavailability(disk: languages, live: idle, mixing: true) == .alternateAudioTracks(count: 2))
    #expect(MeetingStoragePlan.Unavailability.alternateAudioTracks(count: 2).message.contains("in different languages"))

    // Fail-closed: not read, or read as something that needs no mix while the counts say it does.
    var unread = call
    unread.audioTracks = nil
    #expect(MeetingStoragePlan.unavailability(disk: unread, live: idle, mixing: true) == .multipleAudioTracks(count: 2))
    var disagreeing = poly
    disagreeing.audioTracks = [Track(channels: 2)]
    #expect(MeetingStoragePlan.unavailability(disk: disagreeing, live: idle, mixing: true) == .multipleChannels(count: 4))
    var unreadable = call
    unreadable.audioTracks = [Track(channels: 0), Track(channels: 1)]
    #expect(MeetingStoragePlan.unavailability(disk: unreadable, live: idle, mixing: true) == .multipleAudioTracks(count: 2))

    // One track of one or two channels is the encode's own business, as before.
    var stereo = disk("recording.wav")
    stereo.channelCount = 2
    #expect(!MeetingStoragePlan.needsMix(stereo))
    #expect(MeetingStoragePlan.unavailability(disk: stereo, live: idle, mixing: true) == nil)
}

// MARK: - Review R2: showing that a mixed copy holds every track and channel

/// A sine of `amplitude` at `frequency`, `frames` long at 16 kHz.
private func sine(_ frequency: Double, _ amplitude: Double, frames: Int = 16_000) -> [Double] {
    (0..<frames).map { amplitude * sin(2 * Double.pi * frequency * Double($0) / 16_000) }
}

/// One window of an audit, measured from the channels (the tracks' in order) and a copy.
private func window(_ channels: [[Double]], copy: [Double]) -> RecordingMixPlan.Audit.Window {
    let count = channels.count
    var gram = [Double](repeating: 0, count: count * count)
    var projection = [Double](repeating: 0, count: count)
    for i in 0..<count {
        for (index, c) in copy.enumerated() { projection[i] += channels[i][index] * c }
        for j in 0..<count { for index in copy.indices { gram[i * count + j] += channels[i][index] * channels[j][index] } }
    }
    return .init(frames: Double(copy.count), gram: gram, projection: projection, copySquares: copy.reduce(0) { $0 + $1 * $1 })
}

/// The copy a mix of these tracks makes: each track's channels combined by the plan's weight, the sum at
/// the mix's gain. `keep` leaves channels out, standing for a mix that lost them.
private func mixedCopy(_ tracks: [[[Double]]], keep: (Int, Int) -> Bool = { _, _ in true }) -> [Double] {
    let frames = tracks[0][0].count
    var copy = [Double](repeating: 0, count: frames)
    for (t, channels) in tracks.enumerated() {
        let weight = RecordingMixPlan.channelWeight(channels: channels.count)
        for (c, samples) in channels.enumerated() where keep(t, c) {
            for index in 0..<frames { copy[index] += RecordingMixPlan.gain * weight * samples[index] }
        }
    }
    return copy
}

private func finding(_ tracks: [[[Double]]], copy: [Double], level: Double = 0.1,
                     native: [[Double]]? = nil) -> RecordingMixPlan.Finding? {
    let channels = tracks.flatMap { $0 }
    let audit = RecordingMixPlan.Audit(trackChannels: tracks.map(\.count), sampleRate: 16_000,
                                       windows: [window(channels, copy: copy)])
    let nativeWindows = native ?? channels.map { samples in [(samples.reduce(0) { $0 + $1 * $1 } / Double(samples.count)).squareRoot()] }
    return RecordingMixPlan.firstFinding(audit, nativeChannelWindows: nativeWindows, nativeLevel: level)
}

@Test("A copy that is the mix of every track and channel is shown to hold them (F942 review R2)")
func mixedCopyHoldingEverythingIsShown() {
    let call = [[sine(300, 0.2)], [sine(800, 0.1)]]
    #expect(finding(call, copy: mixedCopy(call)) == nil)
    let stereoAndMono = [[sine(300, 0.2), sine(500, 0.2)], [sine(800, 0.2)]]
    #expect(finding(stereoAndMono, copy: mixedCopy(stereoAndMono)) == nil)
    // The same voice on both sides of a stereo track (dual mono): the two channels share one fit.
    let dualMono = [[sine(300, 0.2), sine(300, 0.2)], [sine(800, 0.2)]]
    #expect(finding(dualMono, copy: mixedCopy(dualMono)) == nil)
}

@Test("A track missing under another, or a channel missing beside another, is found (F942 review R2, M8)")
func mixedCopyMissingATrackOrChannelIsFound() {
    // Track 2 sounds only over track 1, never alone.
    let call = [[sine(300, 0.2)], [sine(800, 0.1)]]
    #expect(finding(call, copy: mixedCopy(call) { t, _ in t == 0 }) == .trackMissing(window: 0, track: 1))
    // Two sides of one stereo track sounding at once, the quieter one lost: the track still fits at nine
    // tenths (its loud side carries it), so only the fit of each channel shows the loss.
    let sides = [[sine(300, 0.3), sine(500, 0.1)]]
    #expect(finding(sides, copy: mixedCopy(sides) { _, c in c == 0 }) == .channelMissing(window: 0, channel: 1))
}

@Test("A track whose channels cancel is found, whatever sounds over it (F942 review R2)")
func mixedTrackWhoseChannelsCancelIsFound() {
    let antiphase = [[sine(300, 0.2), sine(300, -0.2)], [sine(800, 0.2)]]
    #expect(finding(antiphase, copy: mixedCopy(antiphase)) == .trackCancels(window: 0, track: 0))
    // Half cancelled (one side at -0.5 of the other) keeps a fifth of its sound: below a quarter.
    let partly = [[sine(300, 0.2), sine(300, -0.1)], [sine(800, 0.2)]]
    #expect(finding(partly, copy: mixedCopy(partly)) == .trackCancels(window: 0, track: 0))
}

@Test("A track never measurable in the copy, a copy gone silent, a channel the reading lost, too many channels (F942 review R2)")
func mixedCopyFailsClosed() {
    // Track 2 sounds (above a tenth of the given level) but is always 30 dB under track 1: never measured.
    let buried = [[sine(300, 1.0)], [sine(800, 0.03)]]
    #expect(finding(buried, copy: mixedCopy(buried), level: 0.1) == .trackNeverMeasured(track: 1))
    let call = [[sine(300, 0.2)], [sine(800, 0.1)]]
    #expect(finding(call, copy: [Double](repeating: 0, count: 16_000)) == .copyMissingSound(window: 0))
    // The recording's own decode heard channel 2 at 0.5; the mixer's reading of it was silent.
    let lost = [[sine(300, 0.2)], [[Double](repeating: 0, count: 16_000)]]
    #expect(finding(lost, copy: mixedCopy(lost), native: [[0.14], [0.5]]) == .channelNotRead(window: 0, channel: 1))
    let many = RecordingMixPlan.Audit(trackChannels: [17], sampleRate: 16_000, windows: [])
    #expect(RecordingMixPlan.firstFinding(many, nativeChannelWindows: [], nativeLevel: 0.1) == .tooManyChannels(count: 17))
}

@Test("The fit shares a sound two regressors hold evenly, and gives a silent one nothing (F942 review R2)")
func leastSquaresIsDefinedWhenRegressorsCoincide() {
    // Two identical regressors, target twice one of them: each gets 1, and neither has energy of its own.
    let same = RecordingMixPlan.leastSquares(gram: [4, 4, 4, 4], projection: [8, 8], size: 2)
    #expect(abs(same.solution[0] - 1) < 1e-6 && abs(same.solution[1] - 1) < 1e-6)
    #expect(same.ownEnergy[0] < 1e-6)
    // An independent pair: the exact coefficients, all their energy their own.
    let apart = RecordingMixPlan.leastSquares(gram: [4, 0, 0, 9], projection: [2, 27], size: 2)
    #expect(abs(apart.solution[0] - 0.5) < 1e-6 && abs(apart.solution[1] - 3) < 1e-6)
    #expect(abs(apart.ownEnergy[1] - 9) < 1e-3)
    let silent = RecordingMixPlan.leastSquares(gram: [4, 0, 0, 0], projection: [2, 0], size: 2)
    #expect(abs(silent.solution[1]) < 1e-6)
}

// MARK: - Review of F942: placing a track's audio on the timeline, bounded by the audio's own length

@Test("A buffer is placed where its time says, and one timed past the audio's end is refused, not padded to (F942 review)")
func placementIsBoundedByTheAudiosOwnLength() {
    let limit = RecordingMixPlan.placementLimit(audioEnd: 10, rate: 16_000)
    #expect(limit == 176_000, "the audio's end and a second, at 16 kHz")
    // A track starting with the others.
    #expect(RecordingMixPlan.placement(firstFrame: 0, frames: 1_024, laneStart: 0, laneCount: 0, handed: 0, limit: limit)
            == .init(laneStart: 0, skip: 0, gap: 0))
    // A track starting 5 s late: placed there, with nothing stored for the silence before it.
    #expect(RecordingMixPlan.placement(firstFrame: 80_000, frames: 1_024, laneStart: 0, laneCount: 0, handed: 0, limit: limit)
            == .init(laneStart: 80_000, skip: 0, gap: 0))
    // Overlapping what is already placed, or what was handed on: those frames are dropped.
    #expect(RecordingMixPlan.placement(firstFrame: 900, frames: 1_024, laneStart: 0, laneCount: 1_000, handed: 0, limit: limit)
            == .init(laneStart: 0, skip: 100, gap: 0))
    #expect(RecordingMixPlan.placement(firstFrame: 900, frames: 1_024, laneStart: 0, laneCount: 0, handed: 1_000, limit: limit)
            == .init(laneStart: 1_000, skip: 100, gap: 0))
    // A gap inside a track is silence, bounded by the limit like everything else.
    #expect(RecordingMixPlan.placement(firstFrame: 2_000, frames: 1_024, laneStart: 0, laneCount: 1_000, handed: 0, limit: limit)
            == .init(laneStart: 0, skip: 0, gap: 1_000))
    // A corrupt timestamp — far past the audio, reaching past its end, or negative — is refused.
    #expect(RecordingMixPlan.placement(firstFrame: Int.max / 2, frames: 1_024, laneStart: 0, laneCount: 0, handed: 0, limit: limit) == nil)
    #expect(RecordingMixPlan.placement(firstFrame: limit - 10, frames: 1_024, laneStart: 0, laneCount: 0, handed: 0, limit: limit) == nil)
    #expect(RecordingMixPlan.placement(firstFrame: -1, frames: 1_024, laneStart: 0, laneCount: 0, handed: 0, limit: limit) == nil)
    // A limit is never computed from a length that is not a number, nor past what an Int holds.
    #expect(RecordingMixPlan.placementLimit(audioEnd: .nan, rate: 16_000) == 16_000)
    #expect(RecordingMixPlan.placementLimit(audioEnd: 1e30, rate: 48_000) == Int.max)
}
