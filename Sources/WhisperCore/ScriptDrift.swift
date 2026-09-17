import Foundation

/// Whether a model handed back the user's Chinese in a different script than they used (F245).
///
/// The gap this fills is specific. `DictationRefinePolicy.acceptedOutput` already refuses an output
/// whose *language* differs from the input — `DictationRefineGuardrailTests.rejectsTranslation`
/// pins it — because a translation is not a cleanup. A **script** change is the same kind of event:
/// the model answered in a writing system the user did not use. The existing tripwire cannot see it,
/// because `TranscriptLanguage.dominant` answers "which language" and Traditional and Simplified are
/// one language.
///
/// Measured, not supposed. On 2026-09-17 F244's harness sent one Traditional dictation line through
/// the installed model's refinement path and got Simplified back, on neutral business content, and
/// `RefinementGuardVectorTests` asserted that the shipped guard **accepted** it — so the app was
/// pasting Simplified over a Traditional dictation.
///
/// Its cost is measured too, because this sits on the dictation path and F200's budget is 800 ms
/// plus 20 ms per word: **36 µs** per call on a 126-character dictation, and **0.95 ms** once to
/// build `ChineseScript`'s two 3,800-character sets on first use. Neither is worth an optimisation
/// and both are worth a number, so nobody has to wonder.
public enum ScriptDrift {
    /// Whether `text` reads as Traditional: it contains Traditional-only characters and no
    /// Simplified-only ones.
    ///
    /// Deliberately conservative. Mixed text answers `false`, so the check below stays silent
    /// rather than guessing about a document that is already inconsistent.
    public static func looksTraditional(_ text: String) -> Bool {
        var sawTraditional = false
        for character in text {
            if ChineseScript.simplifiedOnly.contains(character) { return false }
            if ChineseScript.traditionalOnly.contains(character) { sawTraditional = true }
        }
        return sawTraditional
    }

    /// Simplified-only characters in `output` that `source` did not contain, in order of first
    /// appearance.
    ///
    /// Source-relative because a Simplified writer's own characters are their business — flagging
    /// them would measure the corpus rather than the model, which is the rule F244's scorer already
    /// follows for the same reason.
    public static func introducedSimplified(in output: String, comparedTo source: String) -> [Character] {
        let inSource = Set(source)
        var seen = Set<Character>()
        var introduced: [Character] = []
        for character in output where ChineseScript.simplifiedOnly.contains(character) {
            guard !inSource.contains(character), !seen.contains(character) else { continue }
            seen.insert(character)
            introduced.append(character)
        }
        return introduced
    }

    /// The directional check a guard can act on: Traditional in, Simplified characters out.
    ///
    /// Both halves are needed. Without `looksTraditional` a source-relative rule fires on a
    /// Simplified user's perfectly good refinement the moment it introduces a word they did not
    /// dictate — which would take refinement away from them entirely. Without the
    /// introduced-character test, any Traditional input whose output merely *contains* Simplified
    /// forms would trip, including one the user wrote that way.
    ///
    /// Known blind spot: a conversion into a character shared by both scripts is invisible — `后`
    /// maps to `後 后`, so it is evidence of neither. A real conversion touches many characters, so
    /// the rest still catch it; a dictation short enough to convert only that way would pass. That
    /// is the accepted limit, and it errs toward accepting, which is the direction that cannot
    /// silently take a working feature away.
    public static func isSimplifyingConversion(source: String, output: String) -> Bool {
        guard looksTraditional(source) else { return false }
        return !introducedSimplified(in: output, comparedTo: source).isEmpty
    }
}
