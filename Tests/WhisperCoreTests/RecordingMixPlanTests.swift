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

@Test("A track too quiet to measure in the copy, a copy gone silent, a channel the reading lost, too many channels (F942 review R2, F978)")
func mixedCopyFailsClosed() {
    // Track 2 sounds but is 30 dB under track 1, too quiet beside it to be measured in the copy: refused
    // there (F978), where it used to be judged nowhere and the window passed.
    let buried = [[sine(300, 1.0)], [sine(800, 0.03)]]
    #expect(finding(buried, copy: mixedCopy(buried), level: 0.1) == .trackMasked(window: 0, track: 1))
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

@Test("A mix runs at most the audio its tracks hold and as much silence again, or a minute (F942 second review)")
func longestMixFollowsTheAudioHeld() {
    #expect(RecordingMixPlan.longestMix(heldSeconds: 2) == 62, "two 1 s tracks: a minute of silence at most")
    #expect(RecordingMixPlan.longestMix(heldSeconds: 12) == 72, "the review's N16 file holds 12 s; it claimed 3606")
    #expect(RecordingMixPlan.longestMix(heldSeconds: 3_600) == 7_200)
    #expect(RecordingMixPlan.longestMix(heldSeconds: 0) == 60)
    #expect(RecordingMixPlan.longestMix(heldSeconds: -5) == 60)
    #expect(RecordingMixPlan.longestMix(heldSeconds: .nan) == 60)
    #expect(RecordingMixPlan.longestMix(heldSeconds: .infinity) == 60, "not a length, so none")
}

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

// MARK: - F980: every threshold of the audit pinned, and the new refusals

/// An audit of these windows, each `(channels, copy)`, with each channel's native level per window its own
/// RMS there (the recording's decode and the audit's read agree).
private func auditOf(_ windows: [([[Double]], [Double])], trackChannels: [Int]) -> (RecordingMixPlan.Audit, [[Double]]) {
    let audit = RecordingMixPlan.Audit(trackChannels: trackChannels, sampleRate: 16_000,
                                       windows: windows.map { window($0.0, copy: $0.1) })
    let channels = windows[0].0.count
    let native: [[Double]] = (0..<channels).map { channel in
        windows.map { w in (w.0[channel].reduce(0) { $0 + $1 * $1 } / Double(w.0[channel].count)).squareRoot() }
    }
    return (audit, native)
}

@Test("A track's step is where the copy follows it best, the smaller on a tie, none when nothing projects (F980)")
func alignmentPicksEachTracksStep() {
    let span = 2 * RecordingMixPlan.alignmentFrames + 1
    #expect(span == 33, "±16 frames a window: a millisecond at 16 kHz, past the measured 5 between seconds")
    var one = [Double](repeating: 0, count: span), two = [Double](repeating: 0, count: span)
    one[RecordingMixPlan.alignmentFrames + 5] = 3   // track 1 best at +5
    two[RecordingMixPlan.alignmentFrames - 2] = 1   // track 2's two channels: 4 at −2 and 4 at +7 tie → −2
    var twoB = [Double](repeating: 0, count: span)
    twoB[RecordingMixPlan.alignmentFrames - 2] = 3; twoB[RecordingMixPlan.alignmentFrames + 7] = 4
    // Energies of 1 at every lag: a projection counts from 0.95 × weight × 0.6 of the track's energy there.
    let ones = [Double](repeating: 1, count: span)
    let steps: [Int?] = RecordingMixPlan.alignment(projectionsByLag: [one, two, twoB], energiesByLag: [ones, ones, ones], copySquares: 0, trackChannels: [1, 2])
    #expect(steps == [5, -2])
    // Nothing positive: a silent track, or one in opposite polarity everywhere, is not found.
    let negative = [Double](repeating: -1, count: span)
    #expect(RecordingMixPlan.alignment(projectionsByLag: [negative], energiesByLag: [ones], copySquares: 0, trackChannels: [1]) == [nil])
    #expect(RecordingMixPlan.alignment(projectionsByLag: [[Double](repeating: 0, count: span)], energiesByLag: [ones], copySquares: 0, trackChannels: [1]) == [nil])
    // Nor a projection under the fit a present track makes: 0.5 of an energy of 1 is under 0.57; 0.6 is found.
    var faint = [Double](repeating: 0, count: span)
    faint[RecordingMixPlan.alignmentFrames + 3] = 0.5
    #expect(RecordingMixPlan.alignment(projectionsByLag: [faint], energiesByLag: [ones], copySquares: 0, trackChannels: [1]) == [nil])
    faint[RecordingMixPlan.alignmentFrames + 3] = 0.6
    #expect(RecordingMixPlan.alignment(projectionsByLag: [faint], energiesByLag: [ones], copySquares: 0, trackChannels: [1]) == [3])
    // An anchor that is not a measurable part of the copy is not one: the same 0.6 of an energy of 1, beside
    // a copy energy of 300 (1/300 of it, past 24 dB), is not found; beside 200, it is.
    #expect(RecordingMixPlan.alignment(projectionsByLag: [faint], energiesByLag: [ones], copySquares: 300, trackChannels: [1]) == [nil])
    #expect(RecordingMixPlan.alignment(projectionsByLag: [faint], energiesByLag: [ones], copySquares: 200, trackChannels: [1]) == [3])
    // A wider search, for a track not found in the windows before: the span follows the projections given.
    var wide = [Double](repeating: 0, count: 2 * 48 + 1)
    wide[48 - 40] = 2
    #expect(RecordingMixPlan.alignment(projectionsByLag: [wide], energiesByLag: [[Double](repeating: 1, count: 2 * 48 + 1)], copySquares: 0, trackChannels: [1]) == [-40])
    #expect(RecordingMixPlan.widestAlignment == 256 && RecordingMixPlan.alignmentReach == 4_800)
    // A track that drifted past the reach is refused before anything else is judged.
    let drifted = RecordingMixPlan.Audit(trackChannels: [1, 1], sampleRate: 16_000, windows: [], outOfStep: (window: 7, track: 1))
    #expect(RecordingMixPlan.firstFinding(drifted, nativeChannelWindows: [], nativeLevel: 0.1) == .trackOutOfStep(window: 7, track: 1))
    // Tracks followed together, against the mix's own read (F998): the copy drifted, not one track.
    let copyDrifted = RecordingMixPlan.Audit(trackChannels: [1, 1], sampleRate: 16_000, windows: [], outOfStep: (window: 7, track: nil))
    #expect(RecordingMixPlan.firstFinding(copyDrifted, nativeChannelWindows: [], nativeLevel: 0.1) == .trackOutOfStep(window: 7, track: nil))
    #expect(copyDrifted != drifted)
}

@Test("The per-track fit the app re-aligns against gives each track the copy's coefficient for it (F980)")
func trackFitGivesEachTracksCoefficient() {
    // A stereo track beside a mono one, the copy holding the mono one at half: the fit says so per track.
    let tracks = [[sine(300, 0.2), sine(500, 0.2)], [sine(800, 0.2)]]
    let full = mixedCopy([tracks[0]]), half = mixedCopy([[[Double](repeating: 0, count: 16_000)], tracks[1]]).map { 0.5 * $0 }
    let copy = full.indices.map { full[$0] + half[$0] }
    let w = window(tracks.flatMap { $0 }, copy: copy)
    let fit = RecordingMixPlan.trackFit(gram: w.gram, projection: w.projection, trackChannels: [2, 1]).coefficients
    #expect(abs(fit[0] / RecordingMixPlan.gain - 1) < 0.01 && abs(fit[1] / RecordingMixPlan.gain - 0.5) < 0.01, "\(fit)")
    let undefined = RecordingMixPlan.trackFit(gram: [1], projection: [1], trackChannels: [1, 1]).coefficients
    #expect(undefined.count == 2 && undefined[0].isNaN && undefined[1].isNaN, "mismatched sums: undefined")
}

@Test("Anything that is not a number refuses: a channel's native level, its reading, or the copy (F980 D2)")
func auditRefusesWhatIsNotANumber() {
    let call = [[sine(300, 0.2)], [sine(800, 0.1)]]
    var bad = sine(800, 0.1); bad[7] = .nan
    let nanChannel = [[sine(300, 0.2)], [bad]]
    #expect(finding(nanChannel, copy: mixedCopy(call)) == .notANumber(window: 0, channel: 1))
    #expect(finding(call, copy: mixedCopy(call), native: [[0.14], [.infinity]]) == .notANumber(window: 0, channel: 1))
    #expect(finding(call, copy: mixedCopy(call), level: .nan) == .notANumber(window: 0, channel: nil))
    var copy = mixedCopy(call); copy[3] = .nan
    #expect(finding(call, copy: copy) == .notANumber(window: 0, channel: nil))
    let mismatched = RecordingMixPlan.Audit(trackChannels: [1, 1], sampleRate: 16_000,
                                            windows: [.init(frames: 16_000, gram: [1], projection: [0], copySquares: 0)])
    #expect(RecordingMixPlan.firstFinding(mismatched, nativeChannelWindows: [[0.3], [0.3]], nativeLevel: 0.3) == .unreadableWindow(window: 0),
            "a window the audit could not measure is a refusal, not a skip (second review P3)")
}

@Test("Tracks that cancel each other when summed are found; a track that merely subtracts a little is not (F980)")
func auditFindsTracksThatCancelEachOther() {
    let voice = sine(300, 0.3)
    let inverted = [[voice], [voice.map { -$0 }]]
    #expect(finding(inverted, copy: mixedCopy(inverted)) == .tracksCancel(window: 0))
    // −0.5 keeps a fifth of the sum's energy, under `minimumOwnMix`; −0.4 keeps 0.31, which stands.
    let half = [[voice], [voice.map { -0.5 * $0 }]]
    #expect(finding(half, copy: mixedCopy(half)) == .tracksCancel(window: 0))
    let less = [[voice], [voice.map { -0.4 * $0 }]]
    #expect(finding(less, copy: mixedCopy(less)) == nil)
    // Within a track the same bound: −0.5 of the other channel cancels, −0.4 does not.
    let partlyLess = [[sine(300, 0.2), sine(300, -0.08)], [sine(800, 0.2)]]
    #expect(finding(partlyLess, copy: mixedCopy(partlyLess)) == nil)
}

@Test("A track is measured in the copy only within 24 dB of it, and refused as too quiet beyond (F978)")
func auditMeasurableShareIsPinned() {
    // Track 2's share of the copy: a²/(1 + a²). 1/15 gives 1/226, measured; 1/17 gives 1/290, masked.
    let measured = [[sine(300, 1.0)], [sine(800, 1.0 / 15)]]
    #expect(finding(measured, copy: mixedCopy(measured)) == nil)
    let masked = [[sine(300, 1.0)], [sine(800, 1.0 / 17)]]
    #expect(finding(masked, copy: mixedCopy(masked)) == .trackMasked(window: 0, track: 1))
    // The same for a channel apart from the others, within one stereo track.
    let maskedChannel = [[sine(300, 1.0), sine(800, 1.0 / 17)]]
    #expect(finding(maskedChannel, copy: mixedCopy(maskedChannel)) == .channelMasked(window: 0, channel: 1))
}

@Test("A measured track, channel or mix must fit at 0.6 of what the mix gives it (F980)")
func auditMinimumFitIsPinned() {
    let call = [[sine(300, 0.2)], [sine(800, 0.2)]]
    func copyScaling(_ second: Double) -> [Double] {
        let a = mixedCopy([call[0]]), b = mixedCopy([call[1]])
        return a.indices.map { a[$0] + second * b[$0] }
    }
    #expect(finding(call, copy: copyScaling(0.55)) == .trackMissing(window: 0, track: 1))
    #expect(finding(call, copy: copyScaling(0.65)) == nil)
    let silent = [Double](repeating: 0, count: 16_000)
    let stereo = [[sine(300, 0.2), sine(800, 0.2)]]
    func stereoCopy(_ second: Double) -> [Double] {
        let a = mixedCopy([[sine(300, 0.2), silent]])
        let b = mixedCopy([[silent, sine(800, 0.2)]])
        return a.indices.map { a[$0] + second * b[$0] }
    }
    #expect(finding(stereo, copy: stereoCopy(0.55)) == .channelMissing(window: 0, channel: 1))
    #expect(finding(stereo, copy: stereoCopy(0.65)) == nil)
    // The whole mix: a copy at the right level that is another sound, and one four times too loud.
    let other = mixedCopy([[sine(1_100, 0.2)], [sine(1_700, 0.2)]])
    #expect(finding(call, copy: other) == .copyUnlikeMix(window: 0))
    #expect(finding(call, copy: mixedCopy(call).map { 4.5 * $0 }) == .copyUnlikeMix(window: 0))
    #expect(finding(call, copy: mixedCopy(call).map { 0.2 * $0 }) == .copyMissingSound(window: 0))
}

@Test("A track is fitted on its own only when a quarter of its energy is its own; shared sound is proven as the sum (F980 C4)")
func auditDistinctShareIsPinned() {
    // Track 2 = track 1 + d × another sound: its own share is d²/(1 + d²). The copy lacks that other sound.
    let voice = sine(300, 0.2), other = sine(800, 0.2)
    let cases: [(d: Double, expected: RecordingMixPlan.Finding?)] = [(0.5, nil), (0.7, .trackMissing(window: 0, track: 1))]
    for c in cases {
        let tracks = [[voice], [voice.indices.map { voice[$0] + c.d * other[$0] }]]
        let copy = mixedCopy([[voice], [voice]])
        #expect(finding(tracks, copy: copy) == c.expected, "d = \(c.d)")
    }
    // Identical tracks, and OBS's master beside its stems: nothing distinct, the sum shown by the mix's fit.
    let same = [[voice], [voice]]
    #expect(finding(same, copy: mixedCopy(same)) == nil)
    let obs = [[voice.indices.map { voice[$0] + other[$0] }], [voice], [other]]
    #expect(finding(obs, copy: mixedCopy(obs)) == nil)
}

@Test("A track sounds where it is within 20 dB of its own level over the recording, not the recording's (F980 D1)")
func auditAudibleShareIsPinned() {
    let loud = sine(300, 1.0), silent = [Double](repeating: 0, count: 16_000)
    let cases: [(quiet: Double, expected: RecordingMixPlan.Finding?)] = [(0.08, .trackMissing(window: 1, track: 1)), (0.06, nil)]
    for c in cases {
        // Track 2 at 1.0 in window 0 and at `quiet` in window 1; its RMS over both is about 0.50, a tenth
        // of which is 0.050: 0.08 (RMS 0.057) sounds there, 0.06 (RMS 0.042) does not. The copy lacks it in window 1.
        let w0 = ([loud, sine(800, 1.0)], mixedCopy([[loud], [sine(800, 1.0)]]))
        let w1 = ([loud, sine(800, c.quiet)], mixedCopy([[loud], [silent]]))
        let (audit, native) = auditOf([w0, w1], trackChannels: [1, 1])
        #expect(RecordingMixPlan.firstFinding(audit, nativeChannelWindows: native, nativeLevel: 0.6) == c.expected, "quiet \(c.quiet)")
    }
    // D1's shape: a quiet track whose channels cancel, under a tenth of the recording's level, is judged.
    let quietAntiphase = [[loud], [sine(800, 0.015), sine(800, -0.015)]]
    #expect(finding(quietAntiphase, copy: mixedCopy(quietAntiphase), level: 0.7) == .trackCancels(window: 0, track: 1))
}

@Test("Every window is judged, however short, and the reading is compared per native window (F980 N8, N9)")
func auditJudgesEveryWindow() {
    // A 0.3 s window alone, and one after four whole ones: the copy lacks track 2 in each. Track 2 is the
    // quieter, so the whole mix still fits and the track's own fit names it.
    let short = [[sine(300, 0.3, frames: 4_800)], [sine(800, 0.1, frames: 4_800)]]
    #expect(finding(short, copy: mixedCopy(short) { t, _ in t == 0 }) == .trackMissing(window: 0, track: 1))
    let whole = ([sine(300, 0.3), sine(800, 0.1)], mixedCopy([[sine(300, 0.3)], [sine(800, 0.1)]]))
    let tail = (short.flatMap { $0 }, mixedCopy(short) { t, _ in t == 0 })
    let (audit, native) = auditOf([whole, whole, whole, whole, tail], trackChannels: [1, 1])
    #expect(RecordingMixPlan.firstFinding(audit, nativeChannelWindows: native, nativeLevel: 0.14) == .trackMissing(window: 4, track: 1))
    // The recording's decode measures five seconds at a time: channel 2 read silent in audit windows 5 and
    // 6 is compared with its native level over the second five-second stretch, and named at window 5.
    let silent = [Double](repeating: 0, count: 16_000)
    let lost = ([sine(300, 0.3), silent], mixedCopy([[sine(300, 0.3)], [silent]]))
    let (audit2, _) = auditOf([whole, whole, whole, whole, whole, lost, lost], trackChannels: [1, 1])
    let nativeByFive: [[Double]] = [[0.21, 0.21], [0.07, 0.07]]
    #expect(RecordingMixPlan.firstFinding(audit2, nativeChannelWindows: nativeByFive, nativeLevel: 0.14) == .channelNotRead(window: 5, channel: 1))
    #expect(RecordingMixPlan.auditWindowSeconds == 1)
}

@Test("Sixteen channels are checked and seventeen refused up front (F980)")
func auditChannelBoundIsPinned() {
    let sixteen = RecordingMixPlan.Audit(trackChannels: [8, 8], sampleRate: 16_000, windows: [])
    #expect(RecordingMixPlan.firstFinding(sixteen, nativeChannelWindows: [], nativeLevel: 0.1) == nil)
    let seventeen = RecordingMixPlan.Audit(trackChannels: [8, 9], sampleRate: 16_000, windows: [])
    #expect(RecordingMixPlan.firstFinding(seventeen, nativeChannelWindows: [], nativeLevel: 0.1) == .tooManyChannels(count: 17))
}

@Test("The mix's kept read is held to a second read channel by channel, window by window, where the channel sounds (F1072)")
func readDisagreementJudgesEachChannelsLevel() {
    func levels(_ channels: [[Double]], frames: [Double]? = nil) -> RecordingMixPlan.ChannelLevels {
        RecordingMixPlan.ChannelLevels(levels: channels, frames: frames ?? [Double](repeating: 16_000, count: channels.first?.count ?? 0),
                                       sampleRate: 16_000)
    }
    let again = levels([[0.2, 0.2, 0.2, 0.2], [0.1, 0.1, 0.1, 0.1]])
    #expect(RecordingMixPlan.firstReadDisagreement(kept: again, again: again) == nil)
    // Within the band: a frame or two of offset moves a level well under 1 %.
    #expect(RecordingMixPlan.firstReadDisagreement(kept: levels([[0.2, 0.199, 0.2, 0.201], [0.1, 0.1, 0.0995, 0.1]]), again: again) == nil)
    // A quarter of a second of steady sound lost from window 2 of channel 2: 0.87 of its level.
    let quarterLost: Double = 0.1 * 0.75.squareRoot()
    #expect(RecordingMixPlan.firstReadDisagreement(kept: levels([[0.2, 0.2, 0.2, 0.2], [0.1, 0.1, quarterLost, 0.1]]), again: again)
            == .readsDisagree(window: 2, channel: 1))
    // More in the kept read than in the recording is a disagreement too.
    #expect(RecordingMixPlan.firstReadDisagreement(kept: levels([[0.2, 0.25, 0.2, 0.2], [0.1, 0.1, 0.1, 0.1]]), again: again)
            == .readsDisagree(window: 1, channel: 0))
    // Where the channel does not sound in either read (under a tenth of its level), nothing is judged.
    let quietWindow = levels([[0.2, 0.2, 0.2, 0.2], [0.1, 0.005, 0.1, 0.1]])
    #expect(RecordingMixPlan.firstReadDisagreement(kept: levels([[0.2, 0.2, 0.2, 0.2], [0.1, 0.001, 0.1, 0.1]]), again: quietWindow) == nil)
    // A track the kept read ended early: its last windows are silence there and sound here.
    #expect(RecordingMixPlan.firstReadDisagreement(kept: levels([[0.2, 0.2, 0.2, 0.2], [0.1, 0.1, 0, 0]]), again: again)
            == .readsDisagree(window: 2, channel: 1))
    // A few frames past the last boundary in one read are not a window; a whole window one read lacks is.
    let longer = levels([[0.2, 0.2, 0.2, 0.2, 0.3], [0.1, 0.1, 0.1, 0.1, 0.3]], frames: [16_000, 16_000, 16_000, 16_000, 3])
    #expect(RecordingMixPlan.firstReadDisagreement(kept: again, again: longer) == nil)
    let wholeWindowMore = levels([[0.2, 0.2, 0.2, 0.2, 0.2], [0.1, 0.1, 0.1, 0.1, 0.1]])
    #expect(RecordingMixPlan.firstReadDisagreement(kept: again, again: wholeWindowMore) == .readsDisagree(window: 4, channel: 0))
    // A different number of channels, or a level that is not a number.
    #expect(RecordingMixPlan.firstReadDisagreement(kept: levels([[0.2, 0.2, 0.2, 0.2]]), again: again) == .readsDisagree(window: 0, channel: 1))
    #expect(RecordingMixPlan.firstReadDisagreement(kept: levels([[0.2, .nan, 0.2, 0.2], [0.1, 0.1, 0.1, 0.1]]), again: again)
            == .notANumber(window: 1, channel: 0))
    #expect(RecordingMixPlan.readAgreementBand.lowerBound == 0.9)
    // F1073: a last window of 0.4 s both reads hold is judged (F1072 skipped one under half a second); one of
    // 0.2 s, an encoder's padding and little else, is not.
    let shortLast = levels([[0.2, 0.2], [0.1, 0.1]], frames: [16_000, 6_400])
    #expect(RecordingMixPlan.firstReadDisagreement(kept: levels([[0.2, 0.2], [0.1, 0.05]], frames: [16_000, 6_400]), again: shortLast)
            == .readsDisagree(window: 1, channel: 1))
    let padding = levels([[0.2, 0.2], [0.1, 0.1]], frames: [16_000, 3_200])
    #expect(RecordingMixPlan.firstReadDisagreement(kept: levels([[0.2, 0.2], [0.1, 0.05]], frames: [16_000, 3_200]), again: padding) == nil)
    #expect(RecordingMixPlan.shortestReadWindow == 0.25 && RecordingMixPlan.readAlignmentFloor == 0.5)
}
