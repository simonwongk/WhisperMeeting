import Foundation

/// Prepares an optional reference document for the on-device transcript-correction pass (F170).
///
/// The reference lets `LocalTranscriptCorrector` be guided toward spellings that live in a spec or
/// glossary the user chose, richer than the flat business-vocabulary list — without anything ever
/// leaving this Mac. It is capped so a large document can't crowd the transcript out of the local
/// model's context window; the F165 embeddings + retrieval idea is the escalation for a reference that
/// outgrows this cap.
public enum ReferenceDocument {
    /// Character cap for a reference handed to the local corrector (~2k tokens of guidance), chosen so
    /// the reference stays a nudge alongside the transcript rather than dominating the context window.
    public static let maxCharacters = 8_000

    /// Trims `text`; if it is still longer than `maxCharacters`, cuts it back to the last line boundary
    /// within the cap so the model is never handed a half-truncated final line (falling back to a hard
    /// character cut only when a single line already exceeds the cap). Returns `nil` when the document
    /// has no usable text, so the caller passes `reference: nil` and the corrector skips the reference.
    public static func prepared(_ text: String, maxCharacters: Int = maxCharacters) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        guard trimmed.count > maxCharacters else { return trimmed }

        let capped = String(trimmed.prefix(maxCharacters))
        if let lastNewline = capped.lastIndex(of: "\n") {
            let toLine = capped[..<lastNewline].trimmingCharacters(in: .whitespacesAndNewlines)
            if !toLine.isEmpty { return toLine }
        }
        // A single line longer than the cap: keep the hard character cut rather than dropping it.
        return capped.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
