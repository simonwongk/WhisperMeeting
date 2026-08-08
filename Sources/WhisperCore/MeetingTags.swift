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

    /// Split live-typed editor input at commas/newlines: every part before the last separator is
    /// ready to commit; the text after it stays in the field as the in-progress tag (F171). Ready
    /// parts are trimmed and empties dropped; the remainder only loses leading whitespace so the
    /// user's in-flight typing is preserved.
    public static func liveSplit(_ draft: String) -> (ready: [String], remainder: String) {
        guard draft.contains(where: { $0 == "," || $0 == "\n" }) else {
            return ([], draft)
        }
        var parts = draft.components(separatedBy: CharacterSet(charactersIn: ",\n"))
        let tail = parts.removeLast()
        let ready = parts
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        return (ready, String(tail.drop(while: \.isWhitespace)))
    }

    /// Library tags offered for one-click reuse in the editor (F171): tags used on any meeting
    /// that are not already applied, deduped case-insensitively keeping the first-seen spelling,
    /// filtered by a case-insensitive substring query, in first-appearance order, capped at
    /// `limit` so the row stays scannable.
    public static func reuseSuggestions(
        library: [[String]], applied: [String], query: String, limit: Int = 5
    ) -> [String] {
        guard limit > 0 else { return [] }
        let appliedKeys = Set(applied.map { $0.lowercased() })
        let needle = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        var seen = Set<String>()
        var result: [String] = []
        for tags in library {
            for tag in tags {
                let key = tag.lowercased()
                guard !appliedKeys.contains(key), seen.insert(key).inserted else { continue }
                guard needle.isEmpty || key.contains(needle) else { continue }
                result.append(tag)
                if result.count >= limit { return result }
            }
        }
        return result
    }

    /// The distinct tags used across a library of meetings' tag lists, deduped case-insensitively
    /// keeping the first-seen spelling, in first-appearance order (F180). One tested helper so the
    /// Ask-Meetings scope selector and the tag reuse editor don't each open-code the same loop.
    public static func distinct(across library: [[String]]) -> [String] {
        var seen = Set<String>()
        var result: [String] = []
        for tags in library {
            for tag in tags where seen.insert(tag.lowercased()).inserted {
                result.append(tag)
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
