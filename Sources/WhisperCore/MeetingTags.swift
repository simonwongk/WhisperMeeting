import Foundation

/// Pure normalization and matching for user-applied meeting tags (labels, never speaker identity).
/// Framework-free so it is unit-testable; the store persists the normalized result and the UI filters
/// with `matches` (F67).
public enum MeetingTags {
    public static let maxCount = 12
    public static let maxLength = 32

    public enum MatchMode: Sendable, Equatable {
        case all // AND — the meeting must carry every selected tag
        case any // OR  — the meeting must carry at least one
    }

    /// Trim, drop empties, cap each tag's length, dedupe case-insensitively keeping the first
    /// spelling, and cap the total count.
    public static func normalized(_ raw: [String]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for tag in raw {
            let trimmed = tag.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let capped = String(trimmed.prefix(maxLength))
            if seen.insert(capped.lowercased()).inserted {
                result.append(capped)
                if result.count >= maxCount { break }
            }
        }
        return result
    }

    /// Whether a meeting's tags satisfy the selected filter under the given mode. An empty selection
    /// matches everything (no filter applied).
    public static func matches(meetingTags: [String], selected: [String], mode: MatchMode) -> Bool {
        let wanted = selected.map { $0.lowercased() }.filter { !$0.isEmpty }
        guard !wanted.isEmpty else { return true }
        let have = Set(meetingTags.map { $0.lowercased() })
        switch mode {
        case .all: return wanted.allSatisfy(have.contains)
        case .any: return wanted.contains(where: have.contains)
        }
    }
}
