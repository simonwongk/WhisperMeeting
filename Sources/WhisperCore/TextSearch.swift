import Foundation

/// Case- and diacritic-insensitive substring matching used for filtering meetings. A query matches
/// when every whitespace-separated term appears in at least one of the provided fields (title,
/// transcript, …). Pure and testable.
public enum TextSearch {
    public static func matches(_ query: String, in fields: [String]) -> Bool {
        let terms = query
            .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
            .map(String.init)
        guard !terms.isEmpty else { return true }
        return terms.allSatisfy { term in
            // `range(of:options:)` compares in place without allocating a folded copy of the whole
            // field, so scanning long transcripts per keystroke stays cheap. Fields are ordered
            // cheapest-first (title before transcript) by the caller for an early hit.
            fields.contains { field in
                field.range(
                    of: term,
                    options: [.caseInsensitive, .diacriticInsensitive]
                ) != nil
            }
        }
    }
}
