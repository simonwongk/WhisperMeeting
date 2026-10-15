import Foundation
import Testing
@testable import WhisperCore

// F1001 — the judgement Shrink makes before it deletes a two-channel original: each channel's sound must be
// in the channels' mono mix, and the mix's in the copy, window by window. Pure: the measure is what
// `RecordingMixer.channelPresence` reads; the app-level tests drive it through the real encoder
// (`ShrinkStereoCancellationTests`).

private typealias Measure = RecordingMixPlan.ChannelPresence.Measure
private typealias Presence = RecordingMixPlan.ChannelPresence

private let held = Measure(energy: 1, missing: 0)

/// Two channels sounding at 0.1 in each of `windows` windows.
private func sounding(_ windows: Int) -> [[Double]] { [[Double](repeating: 0.1, count: windows), [Double](repeating: 0.1, count: windows)] }

@Test("A bin holds the sound it is checked for from a quarter of what is expected (F1001)")
func channelPresenceFindsABinFromAQuarter() {
    #expect(RecordingMixPlan.soundFound(projection: 0.5, energy: 1, weight: 0.5), "a channel heard alone")
    #expect(RecordingMixPlan.soundFound(projection: 0.125, energy: 1, weight: 0.5), "exactly a quarter")
    #expect(!RecordingMixPlan.soundFound(projection: 0.124, energy: 1, weight: 0.5))
    #expect(!RecordingMixPlan.soundFound(projection: 0, energy: 1, weight: 0.5), "cancelled in the mix")
    #expect(RecordingMixPlan.soundFound(projection: 0, energy: 0, weight: 0.5), "no energy is nothing to hold")
    #expect(!RecordingMixPlan.soundFound(projection: .nan, energy: 1, weight: 0.5))
    #expect(!RecordingMixPlan.soundFound(projection: 1, energy: .infinity, weight: 0.5))
}

@Test("A window with more than a quarter of a channel's sound missing from the mix is refused, naming the channel (F1001)")
func channelPresenceRefusesAChannelTheMixCancels() {
    let half = Measure(energy: 1, missing: 0.5), quarter = Measure(energy: 1, missing: 0.25)
    let midSide = Presence(channels: 2, windows: [[held, held], [half, half], [held, held]], mix: [held, held, held])
    #expect(RecordingMixPlan.firstChannelNotInCopy(midSide, nativeChannelWindows: sounding(3)) == .missing(window: 1, channel: 0))
    let right = Presence(channels: 2, windows: [[held, held], [held, half]], mix: [held, held])
    #expect(RecordingMixPlan.firstChannelNotInCopy(right, nativeChannelWindows: sounding(2)) == .missing(window: 1, channel: 1))
    let atTheBound = Presence(channels: 2, windows: [[quarter, quarter]], mix: [held])
    #expect(RecordingMixPlan.firstChannelNotInCopy(atTheBound, nativeChannelWindows: sounding(1)) == nil, "a quarter is allowed")
}

@Test("A window with more than a tenth of the mix's sound missing from the copy is refused (F1001)")
func channelPresenceRefusesACopyMissingTheMix() {
    let leftOnly = Presence(channels: 2, windows: [[held, held], [held, held]], mix: [held, Measure(energy: 1, missing: 0.11)])
    #expect(RecordingMixPlan.firstChannelNotInCopy(leftOnly, nativeChannelWindows: sounding(2)) == .copyMissing(window: 1))
    let tenth = Presence(channels: 2, windows: [[held, held]], mix: [Measure(energy: 1, missing: 0.1)])
    #expect(RecordingMixPlan.firstChannelNotInCopy(tenth, nativeChannelWindows: sounding(1)) == nil)
}

@Test("Only windows in which a channel sounds are judged, by its own level over the recording (F1001)")
func channelPresenceJudgesOnlySoundingWindows() {
    let lost = Measure(energy: 1, missing: 1)
    // The right channel is silent in window 1 and cancels there: nothing of it to lose. The left channel
    // is quiet in window 0 — a twentieth of its level elsewhere — under a tenth of its own level.
    let presence = Presence(channels: 2, windows: [[lost, held], [held, lost]], mix: [held, held])
    let native: [[Double]] = [[0.005, 0.1], [0.1, 0]]
    #expect(RecordingMixPlan.firstChannelNotInCopy(presence, nativeChannelWindows: native) == nil)
    // Silence throughout: nothing is judged.
    let silent = Presence(channels: 2, windows: [[lost, lost]], mix: [Measure(energy: 1, missing: 1)])
    #expect(RecordingMixPlan.firstChannelNotInCopy(silent, nativeChannelWindows: [[0], [0]]) == nil)
    // A sounding channel with no energy in the measured band has nothing this can judge.
    let outOfBand = Presence(channels: 2, windows: [[Measure(energy: 0, missing: 0), held]], mix: [held])
    #expect(RecordingMixPlan.firstChannelNotInCopy(outOfBand, nativeChannelWindows: sounding(1)) == nil)
}

@Test("A measure that does not fit the recording, or is not a number, refuses (F1001)")
func channelPresenceFailsClosed() {
    #expect(RecordingMixPlan.firstChannelNotInCopy(Presence(channels: 1, windows: [[held]], mix: [held]),
                                                   nativeChannelWindows: sounding(1)) == .unmeasured(window: 0, channel: 0))
    #expect(RecordingMixPlan.firstChannelNotInCopy(Presence(channels: 0, windows: [], mix: []),
                                                   nativeChannelWindows: []) == .unmeasured(window: 0, channel: 0))
    let short = Presence(channels: 2, windows: [[held, held]], mix: [held])
    #expect(RecordingMixPlan.firstChannelNotInCopy(short, nativeChannelWindows: sounding(3)) == .unmeasured(window: 1, channel: 0))
    let noMix = Presence(channels: 2, windows: [[held, held], [held, held]], mix: [held])
    #expect(RecordingMixPlan.firstChannelNotInCopy(noMix, nativeChannelWindows: sounding(2)) == .unmeasured(window: 1, channel: 0))
    let notANumber = Presence(channels: 2, windows: [[held, Measure(energy: 1, missing: .nan)]], mix: [held])
    #expect(RecordingMixPlan.firstChannelNotInCopy(notANumber, nativeChannelWindows: sounding(1)) == .unmeasured(window: 0, channel: 1))
    let nanMix = Presence(channels: 2, windows: [[held, held]], mix: [Measure(energy: .infinity, missing: 0)])
    #expect(RecordingMixPlan.firstChannelNotInCopy(nanMix, nativeChannelWindows: sounding(1)) == .unmeasured(window: 0, channel: 0))
    let nativeNaN: [[Double]] = [[0.1, .nan], [0.1, 0.1]]
    let fine = Presence(channels: 2, windows: [[held, held], [held, held]], mix: [held, held])
    #expect(RecordingMixPlan.firstChannelNotInCopy(fine, nativeChannelWindows: nativeNaN) == .unmeasured(window: 1, channel: 0))
}

@Test("A resume checks a leftover of one track of two channels channel by channel, and nothing else (F1001)")
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
