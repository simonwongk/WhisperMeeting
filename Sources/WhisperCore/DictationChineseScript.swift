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

    /// The default for a Mac whose preferred languages are `languages`, most preferred first
    /// (`Locale.preferredLanguages`): the script of the first Chinese one — zh-Hans, zh-CN or a bare
    /// zh is Simplified; zh-Hant, zh-TW or zh-HK is Traditional — and As heard when none is Chinese.
    ///
    /// I chose the first Chinese entry rather than only the first entry: a bilingual Mac set to
    /// English with Chinese second is exactly the user this setting is for, and the first entry
    /// alone would give that Mac As heard.
    public static func preferred(byLanguages languages: [String]) -> DictationChineseScript {
        for identifier in languages {
            let language = Locale.Language(identifier: identifier)
            guard language.languageCode?.identifier == "zh" else { continue }
            switch language.script?.identifier {
            case "Hans": return .simplified
            case "Hant": return .traditional
            default: return .asHeard
            }
        }
        return .asHeard
    }

    /// `text` in this script. Only Han characters change; As heard returns it untouched.
    public func converted(_ text: String) -> String {
        let transform: StringTransform
        switch self {
        case .asHeard: return text
        case .simplified: transform = StringTransform("Hant-Hans")
        case .traditional: transform = StringTransform("Hans-Hant")
        }
        guard text.unicodeScalars.contains(where: { (0x3400...0x9FFF).contains($0.value) }) else { return text }
        return text.applyingTransform(transform, reverse: false) ?? text
    }
}
