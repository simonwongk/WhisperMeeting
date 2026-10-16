import Foundation
import Testing
@testable import WhisperCore

// F1001 — the judgement Shrink makes before it deletes a two-channel original: the user's rule (2026-10-15),
// "Refuse any with cancellation" — the channels must not cancel each other when mixed into one, stretch by
// stretch and band by band, and the copy must hold the mix. Pure: the measure is what
// `RecordingMixer.channelPresence` reads; the app-level tests drive it through the real encoder
// (`ShrinkStereoCancellationTests`).

private typealias Measure = RecordingMixPlan.ChannelPresence.Measure
private typealias Stretch = RecordingMixPlan.ChannelPresence.Stretch
private typealias Presence = RecordingMixPlan.ChannelPresence

private let held = Measure(energy: 1, missing: 0)
private let bandCount = RecordingMixPlan.cancellationBands.count - 1

/// A stretch at `start` seconds, level 0.1, every band holding `band` (or `held`).
private func stretch(_ start: Double, level: Double = 0.1, _ bands: [Int: Measure] = [:]) -> Stretch {
    Stretch(start: start, level: level, bands: (0..<bandCount).map { bands[$0] ?? held })
}

/// Stretches every half second over `seconds`.
private func stretches(_ seconds: Double, _ override: [Double: [Int: Measure]] = [:]) -> [Stretch] {
    stride(from: 0.0, to: seconds, by: 0.512).map { stretch($0, override[$0] ?? [:]) }
}

/// Two channels sounding at 0.1 in each of `windows` windows.
private func sounding(_ windows: Int) -> [[Double]] { [[Double](repeating: 0.1, count: windows), [Double](repeating: 0.1, count: windows)] }

@Test("The constants the rule rests on are the measured ones (F1001)")
func channelPresenceConstantsArePinned() {
    // Measured in F1001's second round (gates/r2-03-harness.txt, r2-10-production.txt): moving any of these
    // moved a probe across the line, so a change to one is a change to what Shrink deletes.
    #expect(RecordingMixPlan.mostCancelledShare == 0.1)
    #expect(RecordingMixPlan.cancellationFrameSeconds == 0.064)
    #expect(RecordingMixPlan.cancellationGroupFrames == 16)
    #expect(RecordingMixPlan.cancellationBands == [80, 250, 500, 1_000, 2_000, 4_000, 7_800])
    #expect(RecordingMixPlan.judgedBandShare == 0.05)
    #expect(RecordingMixPlan.cancellationMinimumCoherence == 0.7)
    #expect(RecordingMixPlan.cancellationMinimumFrames == 3)
    #expect(RecordingMixPlan.alignmentFrames16k == 48)
    #expect(RecordingMixPlan.alignmentCandidates == 2)
    #expect(RecordingMixPlan.alignmentMinimumCorrelation == 0.3)
    #expect(RecordingMixPlan.mostCopyMissingShare == 0.05)
    #expect(RecordingMixPlan.presenceShare == 0.25)
    #expect(RecordingMixPlan.presenceGroupFrames == 4)
    #expect(RecordingMixPlan.presenceBand == 80...4_000)
}

@Test("A bin cancels only where its channels are opposite, consistently, over several frames (F1001)")
func channelPresenceCountsOnlyCoherentOppositeBins() {
    #expect(RecordingMixPlan.cancels(alignedReal: -2, coherence: 1, frames: 16) == 2, "a voice in opposite polarity")
    #expect(RecordingMixPlan.cancels(alignedReal: -2, coherence: 0.7, frames: 3) == 2, "at both bounds")
    #expect(RecordingMixPlan.cancels(alignedReal: 2, coherence: 1, frames: 16) == 0, "in phase adds")
    #expect(RecordingMixPlan.cancels(alignedReal: -2, coherence: 0.69, frames: 16) == 0, "independent voices beating")
    #expect(RecordingMixPlan.cancels(alignedReal: -2, coherence: 1, frames: 2.9) == 0, "one frame looks coherent")
    #expect(RecordingMixPlan.cancels(alignedReal: .nan, coherence: 1, frames: 16) == 0)
}

@Test("A copy holds a bin of the mix from a quarter of its energy (F1001)")
func channelPresenceFindsABinFromAQuarter() {
    #expect(RecordingMixPlan.soundFound(projection: 0.25, energy: 1, weight: 1))
    #expect(!RecordingMixPlan.soundFound(projection: 0.249, energy: 1, weight: 1))
    #expect(RecordingMixPlan.soundFound(projection: 0, energy: 0, weight: 1), "no energy is nothing to hold")
    #expect(!RecordingMixPlan.soundFound(projection: .nan, energy: 1, weight: 1))
}

@Test("A judged band with more than a tenth cancelling refuses, naming where; a tenth is allowed (F1001)")
func channelPresenceRefusesACancellingBand() {
    let over = Measure(energy: 1, missing: 0.101), tenth = Measure(energy: 1, missing: 0.1)
    let refused = Presence(channels: 2, stretches: stretches(10, [1.024: [2: over]]), mix: [held, held])
    #expect(RecordingMixPlan.firstChannelNotInCopy(refused, nativeChannelWindows: sounding(2)) == .cancels(seconds: 1.024, band: 2))
    let allowed = Presence(channels: 2, stretches: stretches(10, [1.024: [2: tenth]]), mix: [held, held])
    #expect(RecordingMixPlan.firstChannelNotInCopy(allowed, nativeChannelWindows: sounding(2)) == nil)
}

@Test("A cancelling band is judged against its own stretch, so a loud stretch elsewhere hides nothing (F1001, F2-3)")
func channelPresenceJudgesEachStretchOnItsOwn() {
    // One loud stretch and one 40 dB quieter whose band 3 cancels throughout.
    var quiet = stretch(5.12, level: 0.001, [3: Measure(energy: 1e-6, missing: 1e-6)])
    for band in 0..<bandCount where band != 3 { quiet.bands[band] = Measure(energy: 1e-6, missing: 0) }
    let presence = Presence(channels: 2, stretches: [stretch(0, level: 0.1), quiet], mix: [held, held])
    #expect(RecordingMixPlan.firstChannelNotInCopy(presence, nativeChannelWindows: [[0.1, 0.001], [0.1, 0.001]])
        == .cancels(seconds: 5.12, band: 3))
    // Under silence, and in a band holding under a twentieth of the stretch, nothing is judged.
    let silent = Presence(channels: 2, stretches: [stretch(0, level: 0.000_09, [0: Measure(energy: 1, missing: 1)])], mix: [held])
    #expect(RecordingMixPlan.firstChannelNotInCopy(silent, nativeChannelWindows: [[0.000_09], [0.000_09]]) == nil)
    var thin = stretch(0)
    thin.bands[5] = Measure(energy: 0.2, missing: 0.2)
    #expect(RecordingMixPlan.firstChannelNotInCopy(Presence(channels: 2, stretches: [thin], mix: [held]), nativeChannelWindows: sounding(1)) == nil,
            "0.2 of 5.2 is under a twentieth")
}

@Test("More than a twentieth of the mix missing from the copy, where a channel sounds, refuses (F1001)")
func channelPresenceRefusesACopyMissingTheMix() {
    let leftOnly = Presence(channels: 2, stretches: stretches(10), mix: [held, Measure(energy: 1, missing: 0.051)])
    #expect(RecordingMixPlan.firstChannelNotInCopy(leftOnly, nativeChannelWindows: sounding(2)) == .copyMissing(window: 1))
    let twentieth = Presence(channels: 2, stretches: stretches(10), mix: [held, Measure(energy: 1, missing: 0.05)])
    #expect(RecordingMixPlan.firstChannelNotInCopy(twentieth, nativeChannelWindows: sounding(2)) == nil)
    // An encoder's near-silent tail is not judged: neither channel sounds there at a tenth of its level.
    let tail = Presence(channels: 2, stretches: stretches(10), mix: [held, Measure(energy: 1e-9, missing: 1e-9)])
    #expect(RecordingMixPlan.firstChannelNotInCopy(tail, nativeChannelWindows: [[0.1, 0.000_5], [0.1, 0.000_5]]) == nil)
}

@Test("A measure that does not fit the recording, or is not a number, refuses (F1001)")
func channelPresenceFailsClosed() {
    #expect(RecordingMixPlan.firstChannelNotInCopy(Presence(channels: 1, stretches: stretches(5), mix: [held]),
                                                   nativeChannelWindows: sounding(1)) == .unmeasured(window: 0, channel: nil))
    #expect(RecordingMixPlan.firstChannelNotInCopy(Presence(channels: 2, stretches: stretches(5), mix: [held]),
                                                   nativeChannelWindows: [[0.1]]) == .unmeasured(window: 0, channel: nil))
    // A read that stopped early, at 4 s: windows 1 and 2 sound and were never measured.
    #expect(RecordingMixPlan.firstChannelNotInCopy(Presence(channels: 2, stretches: stretches(4), mix: [held]),
                                                   nativeChannelWindows: sounding(3)) == .unmeasured(window: 1, channel: nil))
    // A stretch covers every window it overlaps: one from 9.728 s covers a recording's last 50 ms past 10 s.
    #expect(RecordingMixPlan.firstChannelNotInCopy(Presence(channels: 2, stretches: stretches(10), mix: [held, held, held]),
                                                   nativeChannelWindows: sounding(3)) == nil)
    var nan = stretches(10)
    nan[3].bands[1] = Measure(energy: .nan, missing: 0)
    #expect(RecordingMixPlan.firstChannelNotInCopy(Presence(channels: 2, stretches: nan, mix: [held, held]),
                                                   nativeChannelWindows: sounding(2)) == .unmeasured(window: 0, channel: nil))
    var level = stretches(10)
    level[12].level = .infinity
    #expect(RecordingMixPlan.firstChannelNotInCopy(Presence(channels: 2, stretches: level, mix: [held, held]),
                                                   nativeChannelWindows: sounding(2)) == .unmeasured(window: 1, channel: nil))
    #expect(RecordingMixPlan.firstChannelNotInCopy(Presence(channels: 2, stretches: stretches(10), mix: [held, Measure(energy: 1, missing: .nan)]),
                                                   nativeChannelWindows: sounding(2)) == .unmeasured(window: 1, channel: nil))
    #expect(RecordingMixPlan.firstChannelNotInCopy(Presence(channels: 2, stretches: stretches(10), mix: [held, held]),
                                                   nativeChannelWindows: [[0.1, .nan], [0.1, 0.1]]) == .unmeasured(window: 1, channel: 0))
}

@Test("A resume checks a leftover of one track of two channels, and nothing else (F1001)")
func channelPresenceListsTwoChannelLeftovers() {
    typealias Entry = MeetingStoragePlan.FolderEntry
    let disk = MeetingStoragePlan.DiskFacts(
        recordingName: "recording.m4a", recordingExists: true, inOwnFolder: true, hasIntegrityProblem: false,
        rebuildOffered: false, durationSeconds: 12,
        entries: [Entry(name: "recording.m4a", bytes: 50_000), Entry(name: "recording.wav", bytes: 2_000_000),
                  Entry(name: "recording.mp3", bytes: 300_000), Entry(name: "recording.mov", bytes: 900_000),
                  Entry(name: "recording.flac", bytes: 0)],
        audioTrackCount: nil,
        otherRecordingSeconds: ["recording.wav": 12, "recording.mp3": 12, "recording.mov": 12, "recording.flac": 12],
        channelCount: 1, audioTracks: nil,
        otherRecordingTracks: ["recording.wav": [.init(channels: 2)], "recording.mp3": [.init(channels: 1)],
                               "recording.mov": [.init(channels: 2), .init(channels: 2)], "recording.flac": [.init(channels: 2)]])
    #expect(MeetingStoragePlan.twoChannelRecordingsToVerify(disk).map(\.name) == ["recording.wav"],
            "a mono leftover as before, several tracks by F955's audit, an empty file holds nothing")
}

@Test("Two channels mix as left and right only when plain or marked front left and front right; otherwise Shrink refuses (F1001)")
func channelMaskDecidesLeftAndRight() {
    #expect(MeetingStoragePlan.channelsAreLeftRight(formatTag: 1, channels: 2, mask: nil), "a plain PCM WAV")
    #expect(MeetingStoragePlan.channelsAreLeftRight(formatTag: 3, channels: 2, mask: nil), "a plain float WAV")
    #expect(MeetingStoragePlan.channelsAreLeftRight(formatTag: 0xFFFE, channels: 2, mask: 0x3))
    #expect(!MeetingStoragePlan.channelsAreLeftRight(formatTag: 0xFFFE, channels: 2, mask: 0x4 | 0x8), "centre and LFE")
    #expect(!MeetingStoragePlan.channelsAreLeftRight(formatTag: 0xFFFE, channels: 2, mask: 0), "no positions")
    #expect(!MeetingStoragePlan.channelsAreLeftRight(formatTag: 0xFFFE, channels: 2, mask: nil), "a mask that was not read")
    #expect(MeetingStoragePlan.channelsAreLeftRight(formatTag: 0xFFFE, channels: 1, mask: 0x4), "one channel is not this rule's")
    // Any other container's layout, by channel label (R2-A).
    #expect(MeetingStoragePlan.channelsAreLeftRight(labels: nil), "no layout")
    #expect(MeetingStoragePlan.channelsAreLeftRight(labels: [1, 2]), "left, right")
    #expect(!MeetingStoragePlan.channelsAreLeftRight(labels: [3, 4]), "centre, LFE")
    #expect(!MeetingStoragePlan.channelsAreLeftRight(labels: []), "a layout that could not be read")
    var disk = MeetingStoragePlan.DiskFacts(
        recordingName: "recording.wav", recordingExists: true, inOwnFolder: true, hasIntegrityProblem: false,
        rebuildOffered: false, durationSeconds: 600,
        entries: [MeetingStoragePlan.FolderEntry(name: "recording.wav", bytes: 100_000_000)], channelCount: 2)
    #expect(MeetingStoragePlan.unavailability(disk: disk, live: .init()) == nil)
    disk.channelsNotLeftRight = "recording.wav"
    #expect(MeetingStoragePlan.unavailability(disk: disk, live: .init()) == .channelsNotLeftRight(name: "recording.wav"))
}
