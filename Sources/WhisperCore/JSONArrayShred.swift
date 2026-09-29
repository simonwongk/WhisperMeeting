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
    ///
    /// `removed` is the ids that were found, lowercased — so a caller can tell which deletions a
    /// copy it then fails to write still holds (F668).
    public static func removingElements(
        withIDs ids: Set<String>, from data: Data
    ) -> (data: Data, count: Int, removed: Set<String>)? {
        let doomed = Set(ids.map { $0.lowercased() })
        guard !doomed.isEmpty,
              let elements = (try? JSONSerialization.jsonObject(with: data)) as? [Any]
        else { return nil }
        var removed: Set<String> = []
        let kept = elements.filter { element in
            guard let id = (element as? [String: Any])?["id"] as? String,
                  doomed.contains(id.lowercased())
            else { return true }
            removed.insert(id.lowercased())
            return false
        }
        guard !removed.isEmpty,
              let rewritten = try? JSONSerialization.data(
                  withJSONObject: kept, options: [.prettyPrinted, .sortedKeys]
              )
        else { return nil }
        return (rewritten, kept.count, removed)
    }

    /// Whether `data` parses as a JSON array at all. A file that does not is one the shred can never
    /// clean, which is different from one that simply holds none of the ids (F668).
    public static func isArray(_ data: Data) -> Bool {
        (try? JSONSerialization.jsonObject(with: data)) is [Any]
    }

    /// The ids among `ids` whose text appears anywhere in `data`, compared case-insensitively and
    /// lowercased — for a file that does not parse, where there are no elements to look at, only
    /// bytes (F668). A mention is not proof of a record, but for a copy that cannot be cleaned it is
    /// the honest reason to say the text may still be there.
    public static func mentionedIDs(_ ids: Set<String>, in data: Data) -> Set<String> {
        let text = String(decoding: data, as: UTF8.self).lowercased()
        return Set(ids.map { $0.lowercased() }.filter { text.contains($0) })
    }
}
