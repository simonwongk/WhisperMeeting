import Foundation

/// A meeting's transcript lined up against the captions its video page published (F740), to read and
/// never to adopt.
///
/// A link import keeps the page's own captions (`MeetingRecord.referenceSegments`, parsed by
/// `SubtitleParser`, pinned to the video's own language and stripped of speaker labels). Until F740
/// nothing showed them. The user chose a read-only comparison: where the captions and the transcript
/// say the same thing, where they differ, and which lines the captions do not cover — with no way to
/// copy caption text into the transcript, because a page's language label is the uploader's, not
/// what was spoken, and the product keeps transcripts in the spoken language.
///
/// Read-only by construction: a `Row` carries no replacement and nothing here returns segments. The
/// alignment is `TranscriptComparison.compare`'s, Second Opinion's: one row per transcript line,
/// matched by time overlap (by normalised text where a side is untimed), case and punctuation
/// ignored — captions are often lower-case and unpunctuated.
public enum CaptionComparison {
    public struct Row: Sendable, Equatable {
        public enum Kind: Sendable, Equatable {
            /// The captions say the same words (case and punctuation aside).
            case same
            /// The captions overlap this line and say something else.
            case differs
            /// No caption overlaps this line.
            case notInCaptions
        }

        public let kind: Kind
        public let start: Double?
        public let transcriptText: String
        /// What the captions say over this line; nil for `.notInCaptions`.
        public let captionText: String?

        public init(kind: Kind, start: Double?, transcriptText: String, captionText: String?) {
            self.kind = kind
            self.start = start
            self.transcriptText = transcriptText
            self.captionText = captionText
        }
    }

    /// One row per line of `transcript`, in order. Empty when either side is empty: with no captions
    /// there is nothing to compare, and the caller says so rather than listing every line as missing.
    public static func compare(transcript: [TranscriptSegment], captions: [TranscriptSegment]) -> [Row] {
        guard !transcript.isEmpty, !captions.isEmpty else { return [] }
        return TranscriptComparison.compare(transcript, captions).map { span in
            switch span.kind {
            case .agree:
                return Row(kind: .same, start: span.start, transcriptText: span.primaryText, captionText: span.secondaryText)
            case .diverge:
                return Row(kind: .differs, start: span.start, transcriptText: span.primaryText, captionText: span.secondaryText)
            case .nonOverlapping:
                return Row(kind: .notInCaptions, start: span.start, transcriptText: span.primaryText, captionText: nil)
            }
        }
    }
}
