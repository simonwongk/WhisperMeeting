import Foundation
@testable import WhisperCore

/// F631 — the refine-stage bench: what F589's throwaway `refine_driver` did, committed so the next
/// model or prompt change can be measured again with one command instead of a rebuilt driver.
///
/// `dictation-ab.py` measures the recognizer. Its `--json` rows are this bench's input. Each raw
/// transcript goes through `DictationRefiner` with the input the app sends, and the per-word
/// verdict here says which embedded words survived recognition and which survived refinement.
///
/// Everything in this enum is pure and tested in the default gate (`RefineStageBenchTableTests`).
/// The real run is the opt-in `RefineStageBenchTests`. Both live in the test target, not in
/// WhisperCore, because nothing in the app uses them.
enum RefineStageBench {
    // MARK: - The per-word verdict, ported from dictation-ab.py

    /// `dictation-ab.py`'s `normalize(text)`, joined the way `word_diff` joins it. That is NFKC,
    /// then lowercase, then only the characters Python's `str.isalnum()` accepts: letters by
    /// general category, and anything with a numeric type. Whitespace and punctuation are gone, so
    /// "会议 纪要。" reads as "会议纪要".
    ///
    /// Swift's `isAlphabetic` would be the wrong port. It also accepts combining vowel signs, which
    /// Python drops, and then the two tables would disagree about the same word (F291's warning).
    static func normalized(_ text: String) -> String {
        let folded = text.precomposedStringWithCompatibilityMapping.lowercased()
        var kept = String.UnicodeScalarView()
        for scalar in folded.unicodeScalars where isAlphanumericInPython(scalar) {
            kept.append(scalar)
        }
        return String(kept)
    }

    private static func isAlphanumericInPython(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.properties.generalCategory {
        case .uppercaseLetter, .lowercaseLetter, .titlecaseLetter, .modifierLetter, .otherLetter:
            return true
        default:
            // isdecimal / isdigit / isnumeric: Numeric_Type Decimal, Digit or Numeric.
            return scalar.properties.numericType != nil
        }
    }

    /// `word_diff`'s verdict: the normalised word is not empty and occurs in the normalised
    /// hypothesis, compared code unit for code unit. It is a substring test, so "fix" counts as
    /// kept in "fixed", as it does in dictation-ab.py.
    static func isKept(_ word: String, in hypothesis: String) -> Bool {
        let needle = normalized(word)
        guard !needle.isEmpty else { return false }
        return normalized(hypothesis).range(of: needle, options: .literal) != nil
    }

    struct WordVerdict: Equatable, Sendable {
        let word: String
        let keptInRaw: Bool
        let keptInDelivered: Bool
    }

    static func wordVerdicts(words: [String], raw: String, delivered: String) -> [WordVerdict] {
        words.map {
            WordVerdict(word: $0, keptInRaw: isKept($0, in: raw), keptInDelivered: isKept($0, in: delivered))
        }
    }

    // MARK: - Input: what `dictation-ab.py --json` writes

    /// The language setting a `dictation-ab.py` run used. The script records it as `language`
    /// (null means Automatic). A file written before F631 has no such key, and that is reported as
    /// not recorded, never guessed as Automatic.
    enum LanguageSetting: Equatable, Sendable {
        case automatic
        case pinned(String)
        case notRecorded
    }

    struct RawWord: Decodable, Equatable, Sendable {
        let word: String
        /// dictation-ab.py's own verdict on the raw text, kept to check this port against.
        let kept: Bool
    }

    struct RawClip: Decodable, Sendable {
        let clip: String
        let text: String
        let reportedLanguage: String?
        /// Present only for clips whose reference lists embedded words (encs, cs).
        let words: [RawWord]?
        let helperError: String?

        enum CodingKeys: String, CodingKey {
            case clip, text, words
            case reportedLanguage = "reported_language"
            case helperError = "helper_error"
        }
    }

    /// One engine's results from one `dictation-ab.py` run: one condition of the bench.
    struct RawRun: Sendable {
        let engine: String
        let label: String
        let language: LanguageSetting
        let clips: [RawClip]
    }

    static func decodeRuns(from data: Data) throws -> [RawRun] {
        try JSONDecoder().decode([RawRun].self, from: data)
    }

    static func conditionLabel(for run: RawRun) -> String {
        switch run.language {
        case .automatic: return "\(run.label), Automatic"
        case let .pinned(language): return "\(run.label), \(language)"
        case .notRecorded: return "\(run.label), language not recorded"
        }
    }

    struct RefinerInput: Equatable, Sendable {
        let text: String
        let languageCode: String?
    }

    /// What `DictationController.transcribe(clip:)` hands `DictationRefiner.attempt` for this raw
    /// transcript. The text is `DictationTextCleanup.clean`ed. The language code is the one
    /// `DictationResult` normalises the helper's report to: a pinned helper echoes "English", and
    /// the app sends "en" (F447). The result is nil where the app does not refine at all, which is
    /// an empty transcript.
    ///
    /// The app also passes the user's Business Vocabulary as `protectedTerms`. The bench passes
    /// none, because it must never read user data.
    static func refinerInput(for clip: RawClip) -> RefinerInput? {
        let result = DictationResult(text: clip.text, languageCode: clip.reportedLanguage)
        let cleaned = DictationTextCleanup.clean(result.text)
        guard !cleaned.isEmpty else { return nil }
        return RefinerInput(text: cleaned, languageCode: result.languageCode)
    }

    /// Words on which this port and dictation-ab.py disagree about the RAW text, each named. The
    /// real run requires none: if any appear, the raw column here and that script's `--words`
    /// table no longer mean the same thing by "kept".
    static func rawVerdictDisagreements(in run: RawRun) -> [String] {
        run.clips.flatMap { clip in
            (clip.words ?? []).compactMap { word -> String? in
                let port = isKept(word.word, in: clip.text)
                guard port != word.kept else { return nil }
                return "\(clip.clip) \(word.word): dictation-ab.py says \(word.kept ? "kept" : "dropped"), "
                    + "this port says \(port ? "kept" : "dropped")"
            }
        }
    }

    // MARK: - Output

    /// Which of `DictationRefinePrompt`'s prompts a request carried. The prompt builder decides,
    /// not a match on its wording. The answers are "generic" (no language named), "en", "zh" (with
    /// or without the F244 script sentence, which the builder appends after the language one), and
    /// "other" for anything the builder does not produce. "—" means no request reached the helper.
    static func promptLanguage(of systemPrompt: String?) -> String {
        guard let systemPrompt else { return "—" }
        if systemPrompt == DictationRefinePrompt.system(languageCode: nil) { return "generic" }
        if systemPrompt == DictationRefinePrompt.system(languageCode: "en") { return "en" }
        if systemPrompt.hasPrefix(DictationRefinePrompt.system(languageCode: "zh")) { return "zh" }
        return "other"
    }

    /// One raw transcript's trip through the refiner.
    struct ClipResult: Sendable {
        let clip: String
        /// What the refiner was given: the cleaned raw transcript, or "" when nothing was attempted.
        let refinerInput: String
        /// What the app would paste. That is the refined text, or the raw text on every other
        /// outcome (`DictationRefiner`'s contract).
        let delivered: String
        /// Nil when the app would not have refined at all (an empty transcript).
        let outcome: DictationRefinement?
        /// The helper's own reply, if a request reached it. A rejection can be read only with it.
        let modelReply: String?
        /// `promptLanguage(of:)` of the request's system prompt.
        let prompt: String
        let words: [WordVerdict]
    }

    struct ConditionResult: Sendable {
        let label: String
        let clips: [ClipResult]
    }

    static func result(
        for raw: RawClip, input: RefinerInput?, attempt: RefineAttempt?,
        reply: String?, systemPrompt: String?
    ) -> ClipResult {
        let refined = input?.text ?? ""
        let delivered = attempt?.text ?? refined
        return ClipResult(
            clip: raw.clip, refinerInput: refined, delivered: delivered,
            outcome: attempt?.outcome, modelReply: reply,
            prompt: promptLanguage(of: systemPrompt),
            words: wordVerdicts(words: (raw.words ?? []).map(\.word), raw: refined, delivered: delivered)
        )
    }

    /// Embedded words the recognizer kept and refinement then lost.
    static func lostInRefinement(_ clip: ClipResult) -> [String] {
        clip.words.filter { $0.keptInRaw && !$0.keptInDelivered }.map(\.word)
    }

    /// Embedded words the recognizer lost and refinement restored.
    static func gainedInRefinement(_ clip: ClipResult) -> [String] {
        clip.words.filter { !$0.keptInRaw && $0.keptInDelivered }.map(\.word)
    }

    static func clipTable(_ conditions: [ConditionResult]) -> String {
        var lines = [
            "| condition | clip | outcome | prompt | lost in refinement | refiner input | delivered | model reply |",
            "|---|---|---|---|---|---|---|---|",
        ]
        for condition in conditions {
            for clip in condition.clips {
                let cells = [
                    cell(condition.label), cell(clip.clip), outcomeName(clip.outcome), clip.prompt,
                    changeCell(clip), quoted(clip.refinerInput), quoted(clip.delivered),
                    clip.modelReply.map(quoted) ?? "—",
                ]
                lines.append("| " + cells.joined(separator: " | ") + " |")
            }
        }
        return lines.joined(separator: "\n")
    }

    /// K = the word is kept verbatim, D = dropped, by dictation-ab.py's rule (`isKept`).
    static func wordTable(_ conditions: [ConditionResult]) -> String {
        var lines = [
            "| condition | clip | word | raw | delivered | outcome |",
            "|---|---|---|---|---|---|",
        ]
        for condition in conditions {
            for clip in condition.clips {
                for verdict in clip.words {
                    let cells = [
                        cell(condition.label), cell(clip.clip), cell(verdict.word),
                        mark(verdict.keptInRaw), mark(verdict.keptInDelivered), outcomeName(clip.outcome),
                    ]
                    lines.append("| " + cells.joined(separator: " | ") + " |")
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func outcomeName(_ outcome: DictationRefinement?) -> String {
        outcome?.rawValue ?? "not attempted"
    }

    private static func mark(_ kept: Bool) -> String { kept ? "K" : "D" }

    /// A transcript can contain "|", which would end its table cell.
    private static func cell(_ text: String) -> String {
        text.replacingOccurrences(of: "|", with: "\\|")
    }

    private static func quoted(_ text: String) -> String { "\"" + cell(text) + "\"" }

    private static func changeCell(_ clip: ClipResult) -> String {
        var parts: [String] = []
        let lost = lostInRefinement(clip)
        let gained = gainedInRefinement(clip)
        if !lost.isEmpty { parts.append(lost.map(cell).joined(separator: ", ")) }
        if !gained.isEmpty { parts.append("gained: " + gained.map(cell).joined(separator: ", ")) }
        return parts.isEmpty ? "—" : parts.joined(separator: "; ")
    }
}

extension RefineStageBench.RawRun: Decodable {
    private enum CodingKeys: String, CodingKey {
        case engine, label, language, clips
    }

    /// Declared in an extension so the memberwise initializer the unit tests use survives.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        engine = try container.decode(String.self, forKey: .engine)
        label = try container.decode(String.self, forKey: .label)
        clips = try container.decode([RefineStageBench.RawClip].self, forKey: .clips)
        if !container.contains(.language) {
            language = .notRecorded
        } else if try container.decodeNil(forKey: .language) {
            language = .automatic
        } else {
            language = .pinned(try container.decode(String.self, forKey: .language))
        }
    }
}
