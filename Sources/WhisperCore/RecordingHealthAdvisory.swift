import Foundation

/// A one-line, channel-level advisory for a completed recording's health rollup — shown on the meeting
/// detail so a user learns after the fact that (e.g.) no system audio was captured. Returns nil when
/// the recording was healthy. Channel-level only (microphone / system audio), never speaker identity
/// (F79, delivers F58).
public enum RecordingHealthAdvisory {
    public static func message(for report: RecordingHealthReport) -> String? {
        guard report.worstStatus != .good else { return nil }
        var notes: [String] = []
        if report.warnings.contains(.systemAudioNotDetected) || !report.systemAudioEverDetected {
            notes.append("No system (meeting) audio was detected during this recording.")
        }
        if report.warnings.contains(.systemAudioCaptureStopped) {
            notes.append("System audio capture stopped partway through.")
        }
        if report.warnings.contains(.microphoneCaptureStopped) {
            notes.append("Microphone capture stopped partway through.")
        }
        if report.warnings.contains(.microphoneClipping) {
            notes.append(clippingNote(
                subject: "The microphone",
                measured: report.microphoneFramesMeasured,
                atFullScale: report.microphoneFramesAtFullScale,
                worstSecond: report.microphoneWorstSecond,
                sustainedTail: " Move the microphone further away or lower its input level."
            ))
        }
        if report.warnings.contains(.systemAudioClipping) {
            notes.append(clippingNote(
                subject: "System audio",
                measured: report.systemAudioFramesMeasured,
                atFullScale: report.systemAudioFramesAtFullScale,
                worstSecond: report.systemAudioWorstSecond,
                // No action. Nothing here establishes that changing a source app's own volume
                // changes what the capture receives, and the live surfaces make the same
                // distinction — the microphone gets an instruction, system audio does not.
                sustainedTail: " The source may already have been at its limit before it reached this Mac."
            ))
        }
        if report.warnings.contains(.lowStorage) {
            notes.append("Storage ran low while recording.")
        }
        if report.warnings.contains(.captureWritesFailing) {
            // First in severity but placed with the other capture failures for reading order.
            // Says what was lost rather than what failed: a persistent write failure means the
            // audio after that point is simply not in the file (F386).
            notes.append(
                "Audio stopped being written to disk partway through, so part of this recording "
                + "was not saved. What was written before that point is intact."
            )
        }
        // A flagged report with nothing to say about it (F188). Every note above reads `warnings`,
        // so a report written by a NEWER build — whose status or whose only warning this build does
        // not recognise — used to fall out of here as `nil` and render no advisory at all: the user
        // was shown a clean recording precisely because it had been flagged. `worstStatus` is a gate
        // here and never text, so it cannot carry the severity on its own; this is the only place the
        // fact can surface. Reachable since the lenient decode landed, which maps an unknown status
        // to `.caution` and drops unknown warnings.
        guard !notes.isEmpty else {
            return """
                This recording was flagged, but by a newer version of WhisperMeet — this version \
                cannot describe why. The recording itself is untouched.
                """
        }
        return notes.joined(separator: " ")
    }

    /// What to say about clipping, from the evidence rather than from the bare flag (F346).
    ///
    /// The sentence this replaces — "was clipping (too loud) at times" — was the defect, not just
    /// imprecise. It said the identical thing about a recording with 139 full-scale samples in 14.4
    /// million and one that is flat-topped for a seventh of its length, and it sent a real
    /// investigation after a capture-level fault that was actually in the mixer (F345).
    ///
    /// So the number is reported and the verdict is not. A count of N frames out of M cannot be
    /// wrong; only its interpretation can, and interpretation is the part that was wrong. The bands
    /// exist to keep the *tone* proportionate, not to decide anything the reader cannot re-derive
    /// from the figures in the same sentence.
    ///
    /// The `nil` band is every report written before F346 — and it deliberately does not keep the
    /// old wording, because the old wording is what is being removed.
    ///
    /// **The locator, added by F379.** The fraction above answers "how much of this recording
    /// clipped". It is the right answer for the case F346 was filed about — 139 full-scale samples
    /// in 14.4 million — and the wrong one for eight seconds of genuine clipping inside five
    /// minutes, which reads 0.09% and lands in the band that calls it "a small share". Eight
    /// seconds of flat-topped audio is not a small share of anything a listener cares about.
    ///
    /// So the worst second is reported *alongside* the total rather than instead of it, and only
    /// when it actually disagrees with it. F346 measured a longest-run figure and rejected it as a
    /// **severity** proxy; this uses it as a **locator**, which is the use that ticket left open.
    static func clippingNote(
        subject: String,
        measured: Int?,
        atFullScale: Int?,
        worstSecond: ClippedSecond? = nil,
        sustainedTail: String
    ) -> String {
        // `atFullScale >= 0` is not redundant with `<= measured` (F400): these arrive from
        // `meetings.json` through `try? decodeIfPresent(Int.self, …)`, which accepts any `Int`, and
        // a decoded `-5` satisfied `-5 <= 100` and printed "on -5 of 100 samples — about 1 in -20".
        guard let measured, let atFullScale, measured > 0, atFullScale >= 0, atFullScale <= measured else {
            return "\(subject) came close to full scale at times. "
                + "This recording predates the measurement that would say how close, or how often."
        }
        if atFullScale == 0 {
            return "\(subject) came close to full scale, but not one of its "
                + "\(grouped(measured)) samples reached it, so nothing was clipped."
        }
        let fraction = Double(atFullScale) / Double(measured)
        let burst = concentrationClause(
            overall: fraction, worstSecond: worstSecond, measuredTotal: measured
        )
        if fraction < 0.0001 {
            let oneIn = Int(saturating: (1 / fraction).rounded())
            return "\(subject) reached full scale on \(grouped(atFullScale)) of "
                + "\(grouped(measured)) samples — about 1 in \(grouped(oneIn)). "
                + (burst.isEmpty ? "That is far too few to be a level problem." : burst.trimmingCharacters(in: .whitespaces))
        }
        if fraction < 0.01 {
            return "\(subject) reached full scale on \(grouped(atFullScale)) of "
                + "\(grouped(measured)) samples (\(percent(fraction))) — a small share of the "
                + "recording, but enough that some of it may be distorted." + burst
        }
        return "\(subject) was at full scale for \(grouped(atFullScale)) of "
            + "\(grouped(measured)) samples (\(percent(fraction))). The waveform is flat-topped "
            + "there and will sound distorted." + burst + sustainedTail
    }

    /// " The worst second of it was N% at full scale, so the distortion is in one stretch rather
    /// than spread out." — or nothing at all.
    ///
    /// Two conditions, and both are needed. The worst second must be **substantially** clipped
    /// (≥1%), or a second holding three stray frames would be announced; and it must be **at least
    /// ten times** the overall fraction, or evenly-spread clipping would say "concentrated" about
    /// itself, since its worst second matches its average by definition. Together they are what
    /// makes the same total count produce different sentences depending on where it sits.
    private static func concentrationClause(
        overall: Double,
        worstSecond: ClippedSecond?,
        measuredTotal: Int
    ) -> String {
        guard let worstSecond, let peak = worstSecond.fraction else { return "" }
        // A second cannot be more than fully clipped, and cannot hold more frames than the whole
        // recording (F400). Both arrive decoded and unchecked, and both produced sentences that
        // contradict the total printed beside them — "200% at full scale" from a worst second of
        // 96,000 clipped frames inside 48,000. A clause that cannot be true locates nothing, so it
        // is dropped rather than clamped: the rest of the sentence is still worth printing.
        guard peak <= 1, worstSecond.framesMeasured <= measuredTotal else { return "" }
        guard peak >= 0.01, peak >= overall * 10 else { return "" }
        return " The worst second of it was \(percent(peak)) at full scale, so the distortion is "
            + "concentrated in one stretch rather than spread across the recording."
    }

    /// Digit grouping for this sentence, pinned rather than inherited (F400).
    ///
    /// A `NumberFormatter` with no locale follows `Locale.current`, while `percent` below uses
    /// `String(format:)` and always writes '.' as the decimal point. On a de_DE host the two met
    /// in one sentence — "13.136 of 14.400.000 samples (0.09%)" — with '.' as the grouping
    /// separator and the decimal point a clause apart. The copy around these numbers is English,
    /// so the numbers are formatted the same way, and the pair cannot drift again.
    ///
    /// `locale` is a parameter only so a test can show the formatter really is locale-sensitive;
    /// nothing in the app passes it.
    static func grouped(_ value: Int, locale: Locale = groupingLocale) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        formatter.locale = locale
        return formatter.string(from: NSNumber(value: value)) ?? String(value)
    }

    /// `en_US`, not `en_US_POSIX`. POSIX is the usual choice for a fixed format and is the wrong
    /// one here: it has no digit grouping at all, so it would have printed "14400000 samples".
    /// Caught by the test that asserts the grouped form, which is the only reason this sentence
    /// still has commas in it.
    static let groupingLocale = Locale(identifier: "en_US")

    private static func percent(_ fraction: Double) -> String {
        fraction >= 0.01
            ? String(format: "%.0f%%", fraction * 100)
            : String(format: "%.2f%%", fraction * 100)
    }

}
