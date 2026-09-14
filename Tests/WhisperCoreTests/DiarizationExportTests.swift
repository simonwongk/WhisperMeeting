import Foundation
import Testing
@testable import WhisperCore

// F220 — genuinely red before the change: `TranscriptExportFormat` has no `.labeledText`,
// `.labeledMarkdown` or `standardFormats`, and `TranscriptExportRequest` has nowhere to carry an
// overlay, so this file does not compile at all against the current exporter.
//
// The isolation test is the one that matters. Labels are a display overlay that must never reach a
// default output path, so it builds a request that DOES carry an alias and an overlay, renders every
// standard format from it, and proves none of them says the name. Everything else here pins the two
// new formats' own wording: a typed name is marked as the reader's own label, ambiguity gets its own
// words, an unlabeled line gets no prefix at all, and the file never claims anyone was identified.

private func labeledSegments() -> [TranscriptSegment] {
    [
        TranscriptSegment(speaker: nil, start: 0, end: 5, text: "first line"),
        TranscriptSegment(speaker: nil, start: 5, end: 10, text: "second line"),
        TranscriptSegment(speaker: nil, start: 10, end: 15, text: "third line"),
        TranscriptSegment(speaker: nil, start: 15, end: 20, text: "fourth line"),
        TranscriptSegment(speaker: nil, start: 20, end: 25, text: "fifth line"),
    ]
}

private func labeledRows() -> [SpeakerOverlayRow] {
    [
        SpeakerOverlayRow(segmentIndex: 0, label: .speaker(clusterID: 0)),
        SpeakerOverlayRow(segmentIndex: 1, label: .speaker(clusterID: 1)),
        SpeakerOverlayRow(segmentIndex: 2, label: .overlapping),
        SpeakerOverlayRow(segmentIndex: 3, label: .uncertain),
        SpeakerOverlayRow(segmentIndex: 4, label: .unlabeled),
    ]
}

/// Cluster 1 was renamed by the reader; cluster 0 was left with its anonymous label, so one
/// fixture covers both spellings and both must stay out of every standard format.
private func labeledRequest(
    rows: [SpeakerOverlayRow] = labeledRows(),
    speakerLabels: [Int: String] = [1: "Nadia"]
) -> TranscriptExportRequest {
    let segments = labeledSegments()
    return TranscriptExportRequest(
        title: "M",
        languageCode: "en",
        durationSeconds: 25,
        transcriptText: TranscriptFormatter.timestamped(segments),
        segments: segments,
        markers: [],
        speakerLabels: speakerLabels,
        speakerRows: rows
    )
}

private let bannedIdentityWords = ["recognized", "recognised", "identified", "verified"]

@Test("Every standard export format stays label-free even when the request carries labels (F220)")
func standardExportsNeverCarrySpeakerLabels() {
    let request = labeledRequest()
    #expect(TranscriptExportFormat.standardFormats.count == 9)
    for format in TranscriptExportFormat.standardFormats {
        let rendered = TranscriptExporter.render(format, request)
        #expect(!rendered.contains("Nadia"), "\(format) leaked an alias")
        #expect(!rendered.contains("Speaker 1"), "\(format) leaked a cluster label")
        #expect(!rendered.contains("Speaker 2"), "\(format) leaked a cluster label")
        #expect(!rendered.contains("your label"), "\(format) leaked the alias marker")
        #expect(!rendered.contains("Overlapping voices"), "\(format) leaked an overlap label")
        #expect(!rendered.contains("Unclear which voice"), "\(format) leaked an uncertainty label")
        // The transcript itself must still be there — a format that leaks nothing because it renders
        // nothing would pass every assertion above.
        #expect(!rendered.isEmpty, "\(format) rendered nothing")
    }
}

@Test("The standard format list excludes the labeled formats (F220)")
func labeledFormatsAreNotOfferedAsOrdinaryExports() {
    #expect(!TranscriptExportFormat.standardFormats.contains(.labeledText))
    #expect(!TranscriptExportFormat.standardFormats.contains(.labeledMarkdown))
    #expect(TranscriptExportFormat.standardFormats.count == 9)
    // The labeled pair is the ONLY difference: a tenth format added later lands in the standard list
    // by default, which is the safe direction to fail in only if someone notices — so pin it here.
    #expect(
        Set(TranscriptExportFormat.allCases).subtracting(TranscriptExportFormat.standardFormats)
            == [.labeledText, .labeledMarkdown]
    )
    #expect(TranscriptExportFormat.labeledText.fileExtension == "txt")
    #expect(TranscriptExportFormat.labeledMarkdown.fileExtension == "md")
}

@Test("A labeled export marks a typed name as the reader's own label and never claims identity (F220)")
func labeledExportMarksAliasesAsUserAssigned() {
    for format in [TranscriptExportFormat.labeledText, .labeledMarkdown] {
        let rendered = TranscriptExporter.render(format, labeledRequest())
        let lowercased = rendered.lowercased()
        #expect(rendered.contains("Nadia"), "\(format) dropped the alias")
        #expect(rendered.contains("(your label)"), "\(format) did not mark the alias as user-assigned")
        #expect(lowercased.contains("inferred"), "\(format) did not say the labels are inferred")
        #expect(lowercased.contains("anonymous"), "\(format) did not say the labels are anonymous")
        for banned in bannedIdentityWords {
            #expect(!lowercased.contains(banned), "\(format) said \"\(banned)\"")
        }
    }
}

@Test("Labeled plain text prefixes each line and leaves an unlabeled line bare (F220)")
func labeledTextRendersOnePrefixPerLine() {
    let lines = TranscriptExporter.render(.labeledText, labeledRequest())
        .split(separator: "\n", omittingEmptySubsequences: false)
        .map(String.init)
    #expect(lines.contains("00:00  Speaker 1: first line"))
    #expect(lines.contains("00:05  Nadia (your label): second line"))
    #expect(lines.contains("00:10  Overlapping voices: third line"))
    #expect(lines.contains("00:15  Unclear which voice: fourth line"))
    // No prefix at all — not an empty label, not a placeholder.
    #expect(lines.contains("00:20  fifth line"))
}

@Test("Labeled Markdown prefixes each line and leaves an unlabeled line bare (F220)")
func labeledMarkdownRendersOnePrefixPerLine() {
    let rendered = TranscriptExporter.render(.labeledMarkdown, labeledRequest())
    #expect(rendered.hasPrefix("# M\n"))
    #expect(rendered.contains("`00:00` **Speaker 1:** first line"))
    #expect(rendered.contains("`00:05` **Nadia** (your label): second line"))
    #expect(rendered.contains("`00:10` **Overlapping voices:** third line"))
    #expect(rendered.contains("`00:15` **Unclear which voice:** fourth line"))
    #expect(rendered.contains("\n`00:20` fifth line"))
}

@Test("A labeled export drops every label when the overlay no longer fits the transcript (F220)")
func labeledExportDropsLabelsWhenTheOverlayNoLongerFits() {
    // The overlay was computed against five segments; only two rows arrive, so row 1 is no longer
    // provably about segment 1. A wrong name is worse than no name: drop the lot.
    let request = labeledRequest(rows: Array(labeledRows().prefix(2)))
    let rendered = TranscriptExporter.render(.labeledText, request)
    #expect(!rendered.contains("Nadia"))
    #expect(!rendered.contains("Speaker 1"))
    #expect(!rendered.lowercased().contains("inferred"))
    #expect(rendered.contains("00:00  first line"))
}

@Test("A labeled export with no overlay at all is exactly the timestamped transcript (F220)")
func labeledExportWithoutAnOverlayIsTheOrdinaryTranscript() {
    let segments = labeledSegments()
    // Every existing call site constructs the request like this — the new parameters are defaulted,
    // so nothing breaks, and asking for a labeled export without an overlay explains nothing.
    let request = TranscriptExportRequest(
        title: "M",
        languageCode: "en",
        durationSeconds: 25,
        transcriptText: TranscriptFormatter.timestamped(segments),
        segments: segments
    )
    let labeled = TranscriptExporter.render(.labeledText, request)
        .trimmingCharacters(in: .whitespacesAndNewlines)
    #expect(labeled == TranscriptExporter.render(.timestampedText, request))
}
