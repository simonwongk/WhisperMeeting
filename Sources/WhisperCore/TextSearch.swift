import Foundation

public struct TextSearchOccurrence: Sendable, Equatable {
    public let fieldIndex: Int
    public let occurrenceIndex: Int

    public init(fieldIndex: Int, occurrenceIndex: Int) {
        self.fieldIndex = fieldIndex
        self.occurrenceIndex = occurrenceIndex
    }
}

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

    /// All occurrences of every non-empty query term in a single string, ordered by position. The
    /// returned ranges index the original string so callers can highlight the exact visible text.
    public static func occurrenceRanges(
        _ query: String,
        in text: String
    ) -> [Range<String.Index>] {
        let terms = query
            .split(whereSeparator: { $0 == " " || $0 == "\n" || $0 == "\t" })
            .map(String.init)
        guard !terms.isEmpty, !text.isEmpty else { return [] }

        var ranges: [Range<String.Index>] = []
        for term in terms {
            var start = text.startIndex
            while start < text.endIndex,
                  let range = text.range(
                    of: term,
                    options: [.caseInsensitive, .diacriticInsensitive],
                    range: start..<text.endIndex
                  ) {
                ranges.append(range)
                start = range.upperBound
            }
        }
        let sorted = ranges.sorted { lhs, rhs in
            if lhs.lowerBound == rhs.lowerBound { return lhs.upperBound < rhs.upperBound }
            return lhs.lowerBound < rhs.lowerBound
        }
        // Merge overlapping ranges into their union. A duplicated query word ("the the") or a term
        // that is a substring of another ("meet" vs "meeting") otherwise counts and highlights the
        // same visible text twice and lets Prev/Next step onto identical positions (F43). Adjacent
        // but non-overlapping matches ("a"+"b" in "ab") stay distinct.
        var merged: [Range<String.Index>] = []
        for range in sorted {
            if let last = merged.last, range.lowerBound < last.upperBound {
                if range.upperBound > last.upperBound {
                    merged[merged.count - 1] = last.lowerBound..<range.upperBound
                }
            } else {
                merged.append(range)
            }
        }
        return merged
    }

    /// A stable, range-independent index of every occurrence across a collection of transcript
    /// lines. The GUI uses this for accurate match counts and Previous/Next navigation while ranges
    /// remain local to each line for highlighting.
    public static func occurrences(
        _ query: String,
        in fields: [String]
    ) -> [TextSearchOccurrence] {
        fields.enumerated().flatMap { fieldIndex, field -> [TextSearchOccurrence] in
            guard matches(query, in: [field]) else { return [] }
            return occurrenceRanges(query, in: field).indices.map {
                TextSearchOccurrence(fieldIndex: fieldIndex, occurrenceIndex: $0)
            }
        }
    }

    /// One pass over the fields producing both the stable occurrence list (counts, Previous/Next)
    /// and each field's highlight ranges, so the GUI computes highlights once per query change
    /// instead of once per redraw during playback (F160). Semantics match `occurrences` +
    /// `occurrenceRanges` exactly: a field participates only when it contains every term (F43),
    /// and ranges are the merged unions local to that field's text.
    public static func occurrenceIndex(
        _ query: String,
        in fields: [String]
    ) -> (occurrences: [TextSearchOccurrence], rangesByField: [Int: [Range<String.Index>]]) {
        var occurrences: [TextSearchOccurrence] = []
        var rangesByField: [Int: [Range<String.Index>]] = [:]
        for (fieldIndex, field) in fields.enumerated() {
            guard matches(query, in: [field]) else { continue }
            let ranges = occurrenceRanges(query, in: field)
            guard !ranges.isEmpty else { continue }
            rangesByField[fieldIndex] = ranges
            occurrences.append(contentsOf: ranges.indices.map {
                TextSearchOccurrence(fieldIndex: fieldIndex, occurrenceIndex: $0)
            })
        }
        return (occurrences, rangesByField)
    }
}
