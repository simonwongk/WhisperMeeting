import Foundation
import WhisperCore

/// F740: the video page's captions beside a link-imported meeting's transcript, read-only.
///
/// The captions were stored since F183 (`MeetingRecord.referenceSegments`) and shown nowhere. The
/// user chose a read-only comparison (2026-10-17, "Read-only compare view"): it shows where the
/// captions and the transcript differ and copies nothing over — so this layer reads the meeting and
/// returns rows, and never writes to the store.
extension AppModel {
    enum CaptionComparisonOutcome: Equatable {
        case rows([CaptionComparison.Row])
        /// Why there is no comparison, said in the sheet.
        case unavailable(String)
    }

    /// Whether `meeting` has captions to compare with — the Improve menu offers the comparison only
    /// then (a link import whose page published captions in the video's own language).
    nonisolated static func hasCaptions(_ meeting: MeetingRecord) -> Bool {
        !(meeting.referenceSegments ?? []).isEmpty
    }

    static let captionComparisonNoCaptionsMessage =
        "This meeting has no captions from its video page to compare with."
    static let captionComparisonNoLinesMessage =
        "This transcript has no lines to compare with the captions yet."
    static let captionComparisonMissingMessage = "This meeting is no longer in the library."

    /// The captions lined up against the transcript as the user left it (`searchablePassages`: the
    /// edited lines after a hand edit, the sentences of a transcript with no segments), off the main
    /// actor as Second Opinion's comparison is (F542). Read-only: nothing is written, so it works in a
    /// read-only library too.
    func compareWithCaptions(id: UUID) async -> CaptionComparisonOutcome {
        guard let meeting = store.meeting(id: id) else { return .unavailable(Self.captionComparisonMissingMessage) }
        let captions = meeting.referenceSegments ?? []
        guard !captions.isEmpty else { return .unavailable(Self.captionComparisonNoCaptionsMessage) }
        let lines = EditedTranscript.searchablePassages(transcriptText: meeting.transcriptText, segments: meeting.segments)
        guard !lines.isEmpty else { return .unavailable(Self.captionComparisonNoLinesMessage) }
        let compare = compareCaptions
        return .rows(await Task.detached(priority: .userInitiated) { compare(lines, captions) }.value)
    }
}
