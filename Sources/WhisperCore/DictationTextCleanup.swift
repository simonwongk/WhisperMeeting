import Foundation

/// Normalizes raw Whisper output for dictation: strips Whisper's leading space, collapses runs of
/// whitespace/newlines to single spaces, and trims. Returns "" when nothing meaningful remains.
public enum DictationTextCleanup {
    public static func clean(_ raw: String) -> String {
        raw
            .replacingOccurrences(of: #"\s+"#, with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
