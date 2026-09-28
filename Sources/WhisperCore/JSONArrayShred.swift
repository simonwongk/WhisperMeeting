import Foundation

/// Removes elements from a JSON array by their `"id"`, without decoding them into any model
/// (F552, F457).
///
/// The shred's one operation, shared by the retained history (`BackupJSONStore.shredHistory`) and
/// the index's other copies — a quarantined index, a restore's snapshot — so all of them remove a
/// deleted meeting the same way. Working on the JSON rather than through a `Codable` model is the
/// point: a model this build has drops what a newer build wrote and cannot read what it cannot
/// decode, and these files are exactly the copies someone recovers from.
public enum JSONArrayShred {
    /// `data`'s top-level array without the elements whose `"id"` string is one of `ids` (compared
    /// case-insensitively), serialized again, with how many elements remain — or nil when `data` is
    /// not a JSON array or holds none of them, so a caller leaves that file byte-for-byte alone.
    ///
    /// Everything else keeps its meaning: an element that is not an object, or has no string `id`,
    /// is kept. Formatting follows the stores' own encoder (pretty-printed, sorted keys), so a
    /// rewritten file reads like any other.
    public static func removingElements(withIDs ids: Set<String>, from data: Data) -> (data: Data, count: Int)? {
        let doomed = Set(ids.map { $0.lowercased() })
        guard !doomed.isEmpty,
              let elements = (try? JSONSerialization.jsonObject(with: data)) as? [Any]
        else { return nil }
        let kept = elements.filter { element in
            guard let id = (element as? [String: Any])?["id"] as? String else { return true }
            return !doomed.contains(id.lowercased())
        }
        guard kept.count != elements.count,
              let rewritten = try? JSONSerialization.data(
                  withJSONObject: kept, options: [.prettyPrinted, .sortedKeys]
              )
        else { return nil }
        return (rewritten, kept.count)
    }
}
