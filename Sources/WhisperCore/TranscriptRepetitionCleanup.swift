import Foundation

/// Removes what a decode that got stuck repeating itself leaves in a transcript (F422).
///
/// F186 and F261 only *warn*, and only past bars set for accusing a whole transcript: one line
/// making up half of it, or one unit repeated twenty times inside a single line. The user asked for
/// this class to be fixed rather than flagged, and the exhibit that prompted it slipped under both
/// bars — sixteen `操！` lines in a 433-line lecture, left behind after F260's guard stopped the loop.
///
/// So the bars here are set for *removing a copy*, not for calling a transcript broken. Removing the
/// fourth "Yeah." in a row loses nothing a reader needs; a false alarm tells the user a good
/// transcript is broken. The first line of a run and one copy of an in-line unit always survive, so
/// nothing that was said disappears — only its echoes. The recording is never read.
public enum TranscriptRepetitionCleanup {
    /// Consecutive lines with the same words, this many or more, are a loop. People do say "Bye.
    /// Bye. Bye." — three, not four — and "Bye." ×21 was one of the library's exhibits.
    public static let minimumRepeatedLines = 4
    /// A unit repeated this many times back to back inside one line is a loop. A read-only scan of
    /// the user's library (2026-09-23) found emphasis and laughter below it — nine "blah"s, six
    /// "哈"s, six "对"s — and one ", yeah" ×10 at the bar, which this removes down to one.
    public static let minimumInlineRepeats = 10
    /// Only short units loop in practice (a token or two), the same bound F261 uses.
    public static let maximumInlineUnitLength = 16

    public struct Result: Sendable, Equatable {
        public let segments: [TranscriptSegment]
        /// Copies removed: whole lines, plus in-line units. Zero means the input came back unchanged.
        public let removedCount: Int
    }

    /// Collapses in-line runs first, then runs of identical lines — in that order, so five lines
    /// that each loop "okay, okay, …" become five identical lines and then one.
    ///
    /// A segment whose text had nothing to collapse keeps its text byte for byte, so a healthy
    /// transcript comes back equal to its input.
    public static func clean(_ segments: [TranscriptSegment]) -> Result {
        var removed = 0
        let inlineCleaned = segments.map { segment -> TranscriptSegment in
            let collapsed = collapseInlineRuns(segment.text)
            guard collapsed.removedCount > 0 else { return segment }
            removed += collapsed.removedCount
            var copy = segment
            copy.text = collapsed.text
            return copy
        }

        var result: [TranscriptSegment] = []
        result.reserveCapacity(inlineCleaned.count)
        var index = 0
        while index < inlineCleaned.count {
            let key = lineKey(inlineCleaned[index].text)
            var runEnd = index + 1
            // An empty key ("…", "—") says nothing about what was heard, so it never starts a run.
            if !key.isEmpty {
                while runEnd < inlineCleaned.count, lineKey(inlineCleaned[runEnd].text) == key {
                    runEnd += 1
                }
            }
            let run = inlineCleaned[index..<runEnd]
            if run.count >= minimumRepeatedLines {
                var kept = inlineCleaned[index]
                // The kept line spans the whole loop, so playback highlights it for the stretch the
                // copies covered. Only a line that already has a start is widened: an untimed line
                // stays untimed rather than borrowing a time from a copy.
                if kept.start != nil, let latest = run.compactMap(\.end).max(),
                   latest > (kept.end ?? -Double.infinity) {
                    kept.end = latest
                }
                result.append(kept)
                removed += run.count - 1
            } else {
                result.append(contentsOf: run)
            }
            index = runEnd
        }
        return Result(segments: result, removedCount: removed)
    }

    /// The same in-line collapse for untimed text — the Qwen fallback when alignment fails entirely
    /// and there are no lines to compare.
    public static func cleanText(_ text: String) -> (text: String, removedCount: Int) {
        collapseInlineRuns(text)
    }

    /// The notice beside Remove Repeated Lines, for a transcript made before this cleanup existed.
    /// The count is plain `Int` interpolation, which never groups digits by the host locale (F400).
    public static func removableNotice(count: Int) -> String {
        let one = count == 1
        return "This transcript has \(count) repeated \(one ? "copy" : "copies") of a phrase the recognizer "
            + "got stuck on. Removing \(one ? "it" : "them") keeps the first one; the recording is unchanged."
    }

    /// What the detail view says once copies were removed, generated from the meeting's stored count
    /// rather than stored as a sentence (F273's rule).
    public static func removedNote(count: Int) -> String {
        let one = count == 1
        return "\(count) repeated \(one ? "copy" : "copies") of a phrase the recognizer got stuck on "
            + "\(one ? "was" : "were") removed, keeping the first. The recording is unchanged."
    }

    /// Lowercased letters and digits only, so "Yeah." / "yeah" / "YEAH!" are one line and "…" is
    /// no line at all.
    private static func lineKey(_ text: String) -> String {
        String(
            text.precomposedStringWithCanonicalMapping
                .lowercased()
                .unicodeScalars
                .filter { CharacterSet.alphanumerics.contains($0) }
        )
    }

    /// Keeps one copy of every unit (at most `maximumInlineUnitLength` characters) that repeats at
    /// least `minimumInlineRepeats` times in a row. The shortest unit wins at each position, so a
    /// `"No, "` loop is cut as `"No, "` and not as `"No, No, "`. A unit containing a digit is a
    /// number, never a loop: 10000000000000 must stay 10000000000000.
    private static func collapseInlineRuns(_ text: String) -> (text: String, removedCount: Int) {
        let characters = Array(text)
        guard characters.count >= minimumInlineRepeats else { return (text, 0) }

        var output: [Character] = []
        output.reserveCapacity(characters.count)
        var removed = 0
        var position = 0
        while position < characters.count {
            var collapsedHere = false
            for unitLength in 1...maximumInlineUnitLength {
                // A run needs this much room to exist at all; longer units need even more, so stop.
                guard position + unitLength * minimumInlineRepeats <= characters.count else { break }
                // Cheap first-character reject keeps the scan linear on ordinary text.
                guard characters[position] == characters[position + unitLength] else { continue }
                var repeats = 1
                var next = position + unitLength
                while next + unitLength <= characters.count,
                      blocksMatch(characters, position, next, length: unitLength) {
                    repeats += 1
                    next += unitLength
                }
                guard repeats >= minimumInlineRepeats,
                      !characters[position..<(position + unitLength)].contains(where: \.isNumber)
                else { continue }
                output.append(contentsOf: characters[position..<(position + unitLength)])
                removed += repeats - 1
                position = next
                collapsedHere = true
                break
            }
            if !collapsedHere {
                output.append(characters[position])
                position += 1
            }
        }
        guard removed > 0 else { return (text, 0) }
        return (String(output).trimmingCharacters(in: .whitespacesAndNewlines), removed)
    }

    /// Element-wise block comparison — no sub-array per candidate position.
    private static func blocksMatch(
        _ characters: [Character],
        _ left: Int,
        _ right: Int,
        length: Int
    ) -> Bool {
        for offset in 0..<length where characters[left + offset] != characters[right + offset] {
            return false
        }
        return true
    }
}
