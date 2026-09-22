import AVFoundation
import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F369, F376 — the two shapes this repo keeps rediscovering, each now with a derived guard.
//
// **`Int(Double)` traps.** Not saturates — traps, taking the process down. It was found five times
// in one day on 2026-09-17, a sweep then found four more, and F362 and F376 found two more after
// that. Every instance shared the same two properties: `isFinite` did not help (`1e30` is finite
// and past `Int.max`), and where there was a clamp it was on the wrong side of the conversion.
//
// **`max(x, y)` is `y >= x ? y : x`,** so operand order decides whether NaN survives.
// `max(fraction, 0)` returns NaN; `max(0, fraction)` returns 0. Four sites in the repo put the
// constant first and were therefore NaN-sanitizing; `AppModel.apply(diarizationProgress:)` was the
// sole outlier, and its consumer did `Int((fraction * 100).rounded())` with no guard.
//
// Both guards are source scans because the property is about **every** site, present and future,
// and a behavioural test can only ever cover the sites someone remembered.

private let integerTypes = [
    "Int", "Int8", "Int16", "Int32", "Int64",
    "UInt", "UInt8", "UInt16", "UInt32", "UInt64",
    "AVAudioFrameCount", "AVAudioFramePosition",
]

/// Initializers that cannot trap. `saturating:` is this repo's own (`SaturatingConversion.swift`);
/// the rest are the standard library's.
private let safeLabels = [
    "saturating:", "clampedAudioSample:",   // this repo's own — `SaturatingConversion.swift`
    "exactly:", "clamping:", "bitPattern:", "truncatingIfNeeded:",   // the standard library's
]

/// Tokens that mean the argument is floating-point, so the conversion is the trapping kind.
private let floatingTokens = [".rounded(", "ceil(", "floor(", "Double(", "Float(", "TimeInterval("]

private struct Conversion {
    let file: String
    let line: Int
    let text: String
}

/// Every `SomeIntegerType( … )` in `code`, with its balanced argument text.
private func integerConversions(in code: String, file: String) -> [Conversion] {
    let characters = Array(code)
    var found: [Conversion] = []
    for type in integerTypes {
        let needle = Array(type + "(")
        var index = 0
        while index + needle.count <= characters.count {
            defer { index += 1 }
            guard Array(characters[index..<(index + needle.count)]) == needle else { continue }
            // `Point(` must not match `Int(`, and `.Int(` is not a conversion either.
            if index > 0 {
                let before = characters[index - 1]
                if before.isLetter || before.isNumber || before == "_" || before == "." { continue }
            }
            var depth = 0
            var cursor = index + needle.count - 1
            var end = cursor
            while cursor < characters.count {
                if characters[cursor] == "(" { depth += 1 }
                if characters[cursor] == ")" {
                    depth -= 1
                    if depth == 0 { end = cursor; break }
                }
                cursor += 1
            }
            guard end > index else { continue }
            let argument = String(characters[(index + needle.count)...end])
            let line = characters[0..<index].filter { $0 == "\n" }.count + 1
            found.append(Conversion(file: file, line: line, text: type + "(" + argument))
        }
    }
    return found
}

@Test("No integer conversion of a floating-point value can trap (F376)")
func noIntegerConversionOfADoubleCanTrap() throws {
    var examined = 0
    var offenders: [String] = []
    for url in try SourceAssertion.swiftFileURLs(under: "Sources") {
        // The safe initializers' own bodies necessarily contain the unsafe conversion — that is
        // what they are: a range check followed by the bare call. Excluded by file, and by the one
        // file, so the exclusion cannot quietly grow.
        guard url.lastPathComponent != "SaturatingConversion.swift" else { continue }
        let code = SourceAssertion.stripComments(
            try String(contentsOf: url, encoding: .utf8), blankStringLiterals: true
        )
        for conversion in integerConversions(in: code, file: url.lastPathComponent) {
            // Leading whitespace trimmed before the label check: a call wrapped across lines —
            // `AVAudioFrameCount(\n    saturating: …)` — is the same call, and the first version of
            // this guard accused `DictationTapConverter`, which had been correct since F356.
            let inner = conversion.text.drop(while: { $0 != "(" }).dropFirst()
                .drop(while: { $0.isWhitespace })
            guard floatingTokens.contains(where: { inner.contains($0) }) else { continue }
            examined += 1
            guard !safeLabels.contains(where: { inner.hasPrefix($0) }) else { continue }
            // `Double(x)` / `Float(x)` INSIDE the argument is common and harmless — what matters is
            // whether the outermost value being converted is floating-point. A conversion whose
            // argument is only `Double(someInt) * Double(other)` still produces a Double, so it
            // counts; one that is `Int64(MemoryLayout<Float>.size)` does not, because `Float(` there
            // is a type name inside a generic, not a conversion.
            guard !inner.contains("MemoryLayout<") else { continue }
            offenders.append("\(conversion.file):\(conversion.line): \(conversion.text.prefix(110))")
        }
    }
    // Anti-vacuity, with the number derived rather than picked: the scan finds 15 floating-point
    // integer conversions in `Sources/` today. The floor is set below that so removing a couple of
    // call sites is not a failure, and far enough above zero that a regex which stopped matching
    // could not pass as "clean" — which is the failure mode every guard in this repo has to answer.
    #expect(examined >= 12, "the scan examined only \(examined) conversions — it is broken, not clean")
    #expect(
        offenders.isEmpty,
        "\(offenders.count) integer conversions of a floating-point value can trap:\n\(offenders.joined(separator: "\n"))"
    )
}

@Test("Every clamp in the repo puts the constant first, so NaN cannot survive it (F369)")
func everyClampIsNaNSanitizing() throws {
    // `max(_ x: T, _ y: T)` is `y >= x ? y : x` and `min(_ x: T, _ y: T)` is `y < x ? y : x`, so a
    // NaN second operand fails the comparison and the FIRST operand is returned. Constant first
    // therefore yields the constant for NaN; variable first yields the NaN.
    var offenders: [String] = []
    let pattern = #"\b(min|max)\(\s*([A-Za-z_][\w.]*)\s*,\s*(-?[\d_.]+)\s*\)"#
    let regex = try NSRegularExpression(pattern: pattern)
    for url in try SourceAssertion.swiftFileURLs(under: "Sources") {
        let code = SourceAssertion.stripComments(
            try String(contentsOf: url, encoding: .utf8), blankStringLiterals: true
        )
        for match in regex.matches(in: code, range: NSRange(code.startIndex..., in: code)) {
            guard let whole = Range(match.range, in: code) else { continue }
            let line = code[code.startIndex..<whole.lowerBound].filter { $0 == "\n" }.count + 1
            offenders.append("\(url.lastPathComponent):\(line): \(code[whole])")
        }
    }
    #expect(
        offenders.isEmpty,
        "\(offenders.count) clamps put the variable first, so a NaN passes straight through:\n\(offenders.joined(separator: "\n"))"
    )
}

@Test("A NaN progress value publishes a finite fraction, and the view survives it (F369)")
@MainActor
func aNaNProgressIsSanitizedAtBothEnds() {
    let model = AppModel(
        store: MeetingStore(rootDirectory: FileManager.default.temporaryDirectory
            .appendingPathComponent("NaNProgress-\(UUID().uuidString)", isDirectory: true)),
        recorder: AudioCaptureEngine(),
        defaults: UserDefaults(suiteName: "WhisperMeet.NaNProgress.\(UUID().uuidString)")!
    )
    model.apply(diarizationProgress: .nan)
    let published = model.diarizationProgress
    #expect(published?.isFinite == true, "\(String(describing: published))")
    #expect((published ?? -1) >= 0 && (published ?? 2) <= 1)

    // The consumer, separately — two checks with different blind spots, which is what AGENTS.md's
    // F304 paragraph argues for. `Int(Double.nan)` traps, so this is the line that would take the
    // app down if the clamp above ever stopped sanitizing.
    #expect(Int(saturating: Double.nan * 100) == 0)
    #expect(Int(saturating: Double.infinity * 100) == .max)

    model.apply(diarizationProgress: 5)
    #expect(model.diarizationProgress == 1)
    model.apply(diarizationProgress: -5)
    #expect(model.diarizationProgress == 0)
}

@Test("A capture converter ratio that would overflow yields no buffer instead of a trap (F376)")
func anOverflowingCaptureCapacityDoesNotTrap() throws {
    // `AVAudioFrameCount(saturating:)` clamps at `UInt32.max`, and the ticket's own instruction was
    // to check that the clamped value still READS correctly through the allocation that consumes
    // it — a saturated capacity is 4 GiB of frames, which `AVAudioPCMBuffer` refuses rather than
    // attempts. Refusal is the right answer; a trap is not, and neither is a 16 GiB allocation.
    let format = try #require(
        AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: 48_000, channels: 1, interleaved: false)
    )
    #expect(AVAudioFrameCount(saturating: Double.nan) == 0)
    #expect(AVAudioFrameCount(saturating: -1.0) == 0)
    #expect(AVAudioFrameCount(saturating: 1e30) == UInt32.max)
    // A zero capacity is accepted and yields an empty buffer — measured, not assumed, and it is
    // why `DictationTapConverter`'s `capacity > 0` guard is belt-and-braces rather than the thing
    // standing between the app and a raise.
    #expect(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 0) != nil)
    // The saturated one is refused, which is the answer that matters: 4 Gi frames is 16 GiB, and
    // refusing beats both trapping and attempting it.
    #expect(AVAudioPCMBuffer(pcmFormat: format, frameCapacity: .max) == nil)
}

// MARK: - F354, a NaN in a capture track

@Test("A NaN sample mixes to silence, not to a full-scale click (F354)")
func aNaNSampleIsSilenceNotFullScale() {
    // The clamp looks like it covers this and does not. `min(1, .nan)` returns **1** — `min(x, y)`
    // is `y < x ? y : x` and every comparison against NaN is false — so `Int16(max(-1, min(1,
    // .nan)) * 32767)` was **+32767**: one frame of full-scale, audible in `meeting.wav` as a
    // click, and identical in the file to legitimately loud audio. It did not trap, which is
    // exactly why nobody found it.
    #expect(FloatTrackMixer.mixedSample(system: .nan, microphone: 0) == 0)
    #expect(FloatTrackMixer.mixedSample(system: 0, microphone: .nan) == 0)
    #expect(FloatTrackMixer.mixedSample(system: .nan, microphone: .nan) == 0)
    // An infinity is NOT silenced, and writing this assertion the other way round is how the
    // distinction got found. Infinity has a sign and an ordering, so the clamp saturates it to the
    // rail — the right answer for "louder than representable" — and the mixer's limiter turns an
    // infinite sum into a finite 1.0 before the conversion even sees it. NaN has neither, which is
    // why it is the only case that needs an answer chosen for it.
    #expect(FloatTrackMixer.mixedSample(system: .infinity, microphone: 0) == 32_767)
    #expect(FloatTrackMixer.mixedSample(system: -.infinity, microphone: 0) == -32_767)

    // And ordinary audio is untouched — a fix that silenced real samples would pass every
    // assertion above.
    #expect(FloatTrackMixer.mixedSample(system: 0, microphone: 0) == 0)
    #expect(FloatTrackMixer.mixedSample(system: 0.5, microphone: 0) > 0)
    #expect(FloatTrackMixer.mixedSample(system: -0.5, microphone: 0) < 0)
    // Two full-scale tracks sum past the limiter's knee, so the result is just under the rail
    // (32685, not 32767) — F345's gain rule, unchanged by this.
    #expect(FloatTrackMixer.mixedSample(system: 1, microphone: 1) > 32_000)
}

@Test("The WAV writer treats a NaN sample the same way, which F354 did not name (F354)")
func theWAVWriterAlsoSilencesNaN() {
    // Found by the sweep, not by the ticket. `WAVWriter.pcm16Data` had the same clamp and therefore
    // the same defect, and it is the writer every dictation clip goes through.
    let data = WAVWriter.pcm16Data(from: [0, .nan, 0.5, -.infinity])
    let samples: [Int16] = data.withUnsafeBytes { raw in
        stride(from: 0, to: raw.count, by: 2).map {
            Int16(littleEndian: raw.loadUnaligned(fromByteOffset: $0, as: Int16.self))
        }
    }
    #expect(samples.count == 4)
    #expect(samples[1] == 0, "a NaN became \(samples[1])")
    #expect(samples[3] == -32_767, "an infinity saturates to the rail: \(samples[3])")
    #expect(samples[2] > 0, "real audio must survive")
}
