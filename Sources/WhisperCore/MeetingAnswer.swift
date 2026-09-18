import Foundation

/// A written answer to an Ask Meetings question, and the passages it points at (F182).
public struct MeetingAnswer: Sendable, Equatable {
    public let text: String
    /// Zero-based indices into the passages the answer was grounded on, in citation order.
    public let citedPassages: [Int]

    public init(text: String, citedPassages: [Int]) {
        self.text = text
        self.citedPassages = citedPassages
    }
}

/// The prompt for answer synthesis (F182). The passages are F180's `[CitedResult]`, unchanged.
public enum MeetingAnswerPrompt {
    public static let system = """
    You answer a question using ONLY the numbered passages from the user's own meeting transcripts. \
    Rules:
    - Every sentence must end with the number of the passage it comes from, like [1] or [2].
    - Use only what the passages say. Do not add facts, names, numbers or reasons they do not contain.
    - Keep names and terms exactly as written in the passages. Do not translate, and keep the \
    passages' language and script (Traditional Chinese stays Traditional).
    - Answer in at most three sentences.
    - If the passages do not answer the question, reply with exactly \(MeetingAnswerPolicy.notFoundToken) and nothing else.
    """

    /// The user-side text: numbered passages with their meeting and time, then the question.
    public static func grounding(question: String, passages: [CitedResult]) -> String {
        let lines = passages.enumerated().map { index, passage -> String in
            let title = passage.meetingTitle.isEmpty ? "Untitled meeting" : passage.meetingTitle
            let place = passage.timestamp.map { "\(title), \(TranscriptFormatter.clock($0))" } ?? title
            return "[\(index + 1)] (\(place)) \(passage.snippet)"
        }
        let asked = question.trimmingCharacters(in: .whitespacesAndNewlines)
        return (lines + ["", "Question: \(asked)"]).joined(separator: "\n")
    }
}

/// Decides whether a synthesized answer may be shown (F182).
///
/// The fallback is always the passages themselves — which is what Ask Meetings shows anyway — so a
/// refusal costs the user nothing they had. That asymmetry is why this can be strict: the same
/// reasoning as F245's refinement guard, where a refusal only ever falls back to the raw text.
public enum MeetingAnswerPolicy {
    public static let notFoundToken = "NOT_IN_PASSAGES"

    public enum Refusal: Sendable, Equatable {
        case empty
        /// Nothing in the answer points at a passage, so none of it can be checked.
        case noCitation
        /// It cites a passage number that was never given.
        case citesMissingPassage
        /// It uses one of the user's vocabulary terms that neither the passages nor the question contain.
        case introducesTerm(String)
        /// The passages are in one Chinese script and the answer is in the other (F244).
        case scriptChanged
    }

    public enum Outcome: Sendable, Equatable {
        case answer(MeetingAnswer)
        case notFound
        case refused(Refusal)
    }

    public static func evaluate(
        _ raw: String, question: String, passages: [CitedResult], protectedTerms: [String]
    ) -> Outcome {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return .refused(.empty) }
        if text.contains(notFoundToken) { return .notFound }

        let cited = citations(in: text)
        guard !cited.isEmpty else { return .refused(.noCitation) }
        guard cited.allSatisfy({ (1...max(1, passages.count)).contains($0) }), !passages.isEmpty else {
            return .refused(.citesMissingPassage)
        }

        let source = passages.map(\.snippet).joined(separator: "\n") + "\n" + question
        if let invented = protectedTerms.first(where: {
            ProtectedTerms.contains(text, term: $0) && !ProtectedTerms.contains(source, term: $0)
        }) {
            return .refused(.introducesTerm(invented))
        }

        let passageText = passages.map(\.snippet).joined(separator: "\n")
        if let expected = ScriptDrift.form(of: passageText), let actual = ScriptDrift.form(of: text),
           expected != actual {
            return .refused(.scriptChanged)
        }

        var ordered: [Int] = []
        for number in cited where !ordered.contains(number - 1) { ordered.append(number - 1) }
        return .answer(MeetingAnswer(text: text, citedPassages: ordered))
    }

    /// The passage numbers written as `[n]`, in order of appearance.
    static func citations(in text: String) -> [Int] {
        guard let pattern = try? NSRegularExpression(pattern: "\\[(\\d{1,3})\\]") else { return [] }
        let range = NSRange(text.startIndex..., in: text)
        return pattern.matches(in: text, range: range).compactMap { match in
            Range(match.range(at: 1), in: text).flatMap { Int(text[$0]) }
        }
    }
}
