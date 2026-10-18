import Foundation

/// Which Chinese script dictation writes (F847).
///
/// Whisper Turbo returns some Simplified Mandarin dictations in Traditional characters, and Wave 8
/// lane C measured that it is not the level: bringing a quiet clip up to normal loudness did not
/// bring Simplified back (zh1 at −20, −30 and −40 dB stayed Traditional), and zh3 came back
/// Simplified at −40 dB but Traditional at −10. The user decided on 2026-10-16 (recorded on the
/// ticket): a setting — As heard, Simplified or Traditional — defaulting to the Mac's preferred
/// language, and dictation converts to it.
///
/// The conversion is ICU's, through Foundation (`Hant-Hans` and `Hans-Hant`). It is context-aware
/// where one Simplified character has two Traditional forms (头发 → 頭髮, 发现 → 發現), measured on
/// this Mac's ICU; a pair it gets wrong is the transform's, and As heard leaves the text alone.
public enum DictationChineseScript: String, CaseIterable, Sendable {
    case asHeard
    case simplified
    case traditional

    public var displayName: String {
        switch self {
        case .asHeard: "As heard"
        case .simplified: "Simplified"
        case .traditional: "Traditional"
        }
    }

    /// The default for a Mac whose preferred languages are `languages` (`Locale.preferredLanguages`):
    /// Simplified when any of them is Simplified Chinese (zh-Hans, zh-CN, zh-SG, or a bare zh, which
    /// `Locale.Language` fills in as Hans), otherwise Traditional when any is Traditional Chinese
    /// (zh-Hant, zh-TW, zh-HK), otherwise As heard.
    ///
    /// The user's decision of 2026-10-17 (recorded on F847): their Mac lists en-US, zh-Hant-US,
    /// zh-Hans-US, and they chose Simplified as its starting value. Round 2 took the first Chinese
    /// entry, which gave that Mac Traditional (the round-2 review's C1), so the order of the Chinese
    /// entries no longer decides; a Simplified entry anywhere does.
    public static func preferred(byLanguages languages: [String]) -> DictationChineseScript {
        let scripts = languages.compactMap { identifier -> String? in
            let language = Locale.Language(identifier: identifier)
            guard language.languageCode?.identifier == "zh" else { return nil }
            return language.script?.identifier
        }
        if scripts.contains("Hans") { return .simplified }
        if scripts.contains("Hant") { return .traditional }
        return .asHeard
    }

    /// `text` in this script. Only Han characters change; As heard returns it untouched.
    ///
    /// - `terms`: Business Vocabulary terms (and replacement-rule spellings), whose characters are
    ///   kept wherever the text holds them — as stored, or in their other script's form — because
    ///   ICU gets names wrong: in Traditional it writes the surname 范 as 範 and the surname 钟 as 鐘
    ///   (the round-2 review's C2). A name the user taught the app is kept as they wrote it, or as
    ///   heard.
    /// - `languageCode`: the reply's language (`DictationResult.languageCode`). Japanese is not
    ///   converted (C3): its kanji are not Chinese in either script. Every other language is,
    ///   so a code-switched English dictation's Chinese words are written in the chosen script.
    public func converted(_ text: String, keeping terms: [String] = [], languageCode: String? = nil) -> String {
        let transform: StringTransform
        switch self {
        case .asHeard: return text
        case .simplified: transform = StringTransform("Hant-Hans")
        case .traditional: transform = StringTransform("Hans-Hant")
        }
        guard languageCode != "ja", Self.hasHan(text) else { return text }
        func convert(_ piece: String) -> String {
            Self.hasHan(piece) ? (piece.applyingTransform(transform, reverse: false) ?? piece) : piece
        }
        let kept = Self.keptRanges(of: terms, in: text)
        guard !kept.isEmpty else { return convert(text) }
        var result = ""
        var cursor = text.startIndex
        for range in kept {
            result += convert(String(text[cursor..<range.lowerBound]))
            result += text[range]
            cursor = range.upperBound
        }
        result += convert(String(text[cursor...]))
        return result
    }

    private static func hasHan(_ text: String) -> Bool {
        text.unicodeScalars.contains { (0x3400...0x9FFF).contains($0.value) }
    }

    /// Where `text` holds a term with Han characters — as stored, or in its Simplified or
    /// Traditional form — longest first and without overlaps, in text order.
    private static func keptRanges(of terms: [String], in text: String) -> [Range<String.Index>] {
        var forms = Set<String>()
        for term in terms where hasHan(term) {
            forms.insert(term)
            for name in ["Hant-Hans", "Hans-Hant"] {
                if let other = term.applyingTransform(StringTransform(name), reverse: false) { forms.insert(other) }
            }
        }
        var kept: [Range<String.Index>] = []
        for form in forms.sorted(by: { $0.count > $1.count }) {
            var searchStart = text.startIndex
            while let found = text.range(of: form, range: searchStart..<text.endIndex) {
                if !kept.contains(where: { $0.overlaps(found) }) { kept.append(found) }
                searchStart = found.upperBound
            }
        }
        return kept.sorted { $0.lowerBound < $1.lowerBound }
    }
}
