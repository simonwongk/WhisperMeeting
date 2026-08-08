import Foundation
import WhisperCore

/// Maps the app's live meeting records into the privacy-safe `DiagnosticsInput` (F86 → delivers F70).
/// Sensitive values — the transcript text and the Claude summary — go ONLY into the input's
/// deliberately-carried-but-never-emitted slots; vocabulary is passed for its count alone; and the
/// title and recording path are not mapped at all. Every structural field gets structural data. Kept
/// as a pure seam (not inline in the view) so the exclusion is unit-tested. `recordingBytes` is
/// injected so the mapping is testable without real files — `AppModel` passes a FileManager-backed one.
enum DiagnosticsExport {
    static func input(
        meetings: [MeetingRecord],
        vocabulary: [String],
        recordingBytes: (MeetingRecord) -> Int64?
    ) -> DiagnosticsInput {
        let mapped = meetings.map { meeting in
            DiagnosticsInput.Meeting(
                id: meeting.id.uuidString,
                createdAtEpoch: Int(meeting.createdAt.timeIntervalSince1970),
                durationSeconds: Int(meeting.duration.rounded()),
                status: meeting.status.rawValue,
                languageCode: meeting.languageCode,
                segmentCount: meeting.segments.count,
                markerCount: meeting.markers?.count ?? 0,
                recordingBytes: recordingBytes(meeting),
                errorMessage: meeting.errorMessage,
                // Sensitive — carried so the builder proves it never emits them.
                transcriptText: meeting.transcriptText,
                summary: meeting.summary.map { summary in
                    ([summary.summary] + summary.keyPoints + summary.actionItems.map(\.text)).joined(separator: "\n")
                }
            )
        }
        return DiagnosticsInput(meetings: mapped, vocabulary: vocabulary)
    }
}
