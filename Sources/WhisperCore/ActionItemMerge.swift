import Foundation

/// Carries a user's action-item edits across a re-summarization (F307).
///
/// `performSummarization` used to replace the whole summary — `$0.summary = resolved` — and
/// `ActionItem` holds three fields the model never produces and the user does: `done`, and `owner`
/// and `due`, both documented "Optional, user-entered". So ticking off four items, assigning two
/// owners and a due date, then re-summarizing — which is the entire reason the style and template
/// controls exist — cleared every one of them. Nothing warned and nothing failed; the checkboxes
/// were simply empty again.
public enum ActionItemMerge {
    /// `fresh` with each item's user-entered fields restored from a matching `previous` item, then
    /// any previously-edited item the new summary dropped appended.
    ///
    /// **Matching is exact after normalisation, deliberately not fuzzy.** Carrying a tick onto a
    /// *different* task is worse than losing it: a wrong `done` is a task the user believes is
    /// handled and is not, while a lost tick is visibly lost and one click to restore. So
    /// whitespace and case are forgiven and nothing else is — a reworded item starts clean.
    ///
    /// **Only the three user-entered fields carry.** `text`, `quote` and `timestamp` belong to this
    /// summarization; carrying an old quote forward would attach evidence to a sentence that no
    /// longer says it.
    ///
    /// **An edited item the new summary dropped is kept.** The user looked at that task and did
    /// something about it, which is a stronger signal than the model no longer mentioning it — and
    /// deleting their record of having handled it is the loss this whole function exists to stop.
    /// An *untouched* dropped item is genuinely dropped: this is a merge, not an archive.
    public static func carryingUserEdits(
        from previous: [ActionItem], onto fresh: [ActionItem]
    ) -> [ActionItem] {
        // Each previous edit is consumed once, so a model that repeats an item does not multiply a
        // single tick across every repetition. Degenerate, but a repeat is cheap to guard and
        // confusing to debug.
        var available = previous.enumerated().reduce(into: [String: [Int]]()) { index, entry in
            index[normalized(entry.element.text), default: []].append(entry.offset)
        }
        var consumed = Set<Int>()

        var merged = fresh.map { item -> ActionItem in
            let key = normalized(item.text)
            guard var indices = available[key], let match = indices.first else { return item }
            indices.removeFirst()
            available[key] = indices
            consumed.insert(match)
            var carried = item
            carried.done = previous[match].done
            carried.owner = previous[match].owner
            carried.due = previous[match].due
            return carried
        }

        // Appended after the new summary's own items, so the model's current view leads and the
        // kept ones read as leftovers, which is what they are.
        for (offset, item) in previous.enumerated()
        where !consumed.contains(offset) && wasEdited(item) {
            merged.append(item)
        }
        return merged
    }

    /// Whether the user has touched this item. A blank `owner` or `due` does not count: a field
    /// opened and left empty must not pin an item the model dropped, or clearing a typo would make
    /// that item permanent.
    static func wasEdited(_ item: ActionItem) -> Bool {
        if item.done { return true }
        for field in [item.owner, item.due] {
            if let field, !field.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return true
            }
        }
        return false
    }

    private static func normalized(_ text: String) -> String {
        text.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
    }
}
