import Foundation

/// What happened to the terms offered to `MeetingStore.addVocabulary` (F525).
///
/// The Add box and Import Documents… used to work out "added" themselves by diffing the list before
/// and after, which cannot see a term that was turned away, and Suggest Vocabulary said nothing at
/// all. At the 5,000-term ceiling the store kept the alphabetically-first 5,000 of old + new, so a
/// new term could silently evict a reviewed one (Mandarin first — CJK sorts after Latin) while the
/// screen said "Saved 3 terms." The store now refuses what does not fit and says so here.
struct VocabularyAddition: Equatable, Sendable {
    /// New terms that entered the list.
    var added = 0
    /// Offered terms the list already had (after trimming), so nothing was needed.
    var alreadySaved = 0
    /// New terms turned away because the list is at `MeetingStore.maxStoredVocabularyTerms`.
    var refusedAtLimit = 0
    /// Those terms, in the order offered, so the Add box can keep them for the user.
    var refusedTerms: [String] = []
    /// Nothing was added: the list or the library is read-only, or the save did not land and the list
    /// was put back as it is on disk (F663). The store has already said why through
    /// `storageErrorMessage`; this only lets a caller keep the user's typing.
    var wasRefused = false

    /// The sentence for the Add box and Import Documents… (`candidates` for an import, whose terms
    /// are extracted rather than typed and so are worth reviewing).
    func message(candidates: Bool = false) -> String {
        let noun = candidates ? "candidate term" : "term"
        var sentences: [String] = []
        if wasRefused {
            // Not named here: the store's refusal already set `storageErrorMessage`, and saying it
            // twice in two wordings is how two explanations start to disagree (F196).
            sentences.append("Nothing was added.")
        } else if added > 0 {
            sentences.append("Saved \(added) \(noun)\(added == 1 ? "" : "s").")
            if candidates {
                sentences.append("Remove anything that should not influence transcription.")
            }
        } else if refusedAtLimit == 0 {
            sentences.append("Nothing new was added. Those terms are already saved.")
        }
        if let limit = limitSentence {
            sentences.append(limit)
        }
        return sentences.joined(separator: " ")
    }

    /// Said whenever anything was turned away at the ceiling, and only then. Suggest Vocabulary shows
    /// it on its own, as an alert, since that path had no message at all.
    var limitSentence: String? {
        guard refusedAtLimit > 0 else { return nil }
        let limit = MeetingStore.maxStoredVocabularyTerms.formatted()
        let count = refusedAtLimit == 1 ? "1 new term was" : "\(refusedAtLimit) new terms were"
        return "\(count) not added because the list is at its \(limit)-term limit. Your saved terms were kept; remove ones you no longer need to make room."
    }
}

/// What happened to a replacement rule offered to `MeetingStore.addReplacementRule` (F525).
///
/// At 500 rules the store used to return without a word while the editor cleared both fields, so
/// the rule the user typed vanished as if saved. The editor now keeps the fields unless the rule was
/// added, and shows `message` for the other outcomes.
enum ReplacementRuleAddition: Equatable, Sendable {
    case added
    /// The same `heard → preferred` pair is already in the list.
    case duplicate
    /// The list is at `MeetingStore.maxReplacementRules`.
    case atLimit
    /// Empty after trimming, or `heard` equals `preferred`, so the rule could change nothing.
    case noChange
    /// The list or the library is read-only, or the save did not land (F663); the store has already
    /// set `storageErrorMessage`.
    case refused

    /// The sentence beside the rule editor, or nil when there is nothing to say (added, or refused —
    /// whose reason the store already reported).
    var message: String? {
        switch self {
        case .added, .refused:
            return nil
        case .duplicate:
            return "That rule is already in the list."
        case .atLimit:
            return "This rule was not added: the list already has \(MeetingStore.maxReplacementRules.formatted()) rules, the most it keeps. Remove one you no longer need, then add this one again."
        case .noChange:
            return "This rule would change nothing: Heard and Preferred are empty or the same."
        }
    }
}
