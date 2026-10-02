import Foundation

/// Turning an arbitrary `Error` into something a person can read, without losing what was thrown
/// (F366).
///
/// Swift bridges every `Error` to `NSError`, so `localizedDescription` always answers. For a type
/// that supplies no copy it answers *"The operation couldn't be completed. (Module.Type error 0.)"*
/// — a sentence shaped like an explanation, containing a case **index**. Used as user-facing copy
/// that is worse than saying nothing, because it looks as though the app tried to explain.
///
/// The repo's own error types now all conform to `LocalizedError` and are fine. The ones that
/// cannot be fixed here are the framework's: an `engine.start()` failure arrives as
/// `com.apple.coreaudio.avfaudio error -10851`, and nothing this app does will make AVFAudio write
/// English. So the caller supplies the sentence for that case, and the raw text goes to the
/// diagnostic log instead of to the user — the two are separate outputs on purpose, because the
/// support question that follows needs the code and the person reading the overlay does not.
public enum ErrorPresentation {
    /// The sentence to show: the error's own `errorDescription` when it has one, `fallback` when
    /// it does not.
    ///
    /// The test is conformance, not a list of known domains. A domain list would need editing every
    /// time a new framework call is added, and would be wrong by omission exactly when something
    /// unexpected failed — which is the only time this function matters.
    public static func sentence(for error: any Error, fallback: String) -> String {
        if let described = (error as? any LocalizedError)?.errorDescription, !isBlank(described) {
            return described
        }
        // Not ours, but not necessarily mute: Cocoa writes real sentences for file errors ("You
        // don't have permission to save the file…"), and replacing those with a generic fallback
        // would make this function a downgrade for the commonest case it sees. Only the bridge's
        // own placeholder is discarded.
        let bridged = error as NSError
        let described = bridged.localizedDescription
        if !isBlank(described), !isBridgePlaceholder(described, for: bridged) { return described }
        return fallback
    }

    /// Whether `described` is the Swift-to-NSError bridge's stand-in rather than real copy.
    ///
    /// Matched on the parenthetical the bridge appends: either `(<domain> error <code>.)` with the
    /// error's own domain, or, since F415, the same shape with any name in it, including Mach's
    /// `- <reason>` form. Foundation does not always print the domain it was given: it writes
    /// `NSOSStatusErrorDomain` as `(OSStatus error -10868.)`, an unrecognised `NSCocoaErrorDomain`
    /// code as `(Cocoa error 99999.)`, and `NSMachErrorDomain` as
    /// `(Mach error 5 - (os/kern) failure)`. The literal domain match alone let all three through
    /// as if they were sentences.
    ///
    /// Both, not the shape alone, because a domain can contain parentheses of its own: a private
    /// Swift type's is `Module.(unknown context at $10fb99424).Mute`, which the shape's `[^()]+`
    /// does not cross. The first draft of this fix dropped the literal match, and
    /// `placeholdersNamingTheirDomainStillFallBack` caught it.
    ///
    /// The shape is English. This comment used to say the parenthetical "carries no translatable
    /// words", which is false: Foundation's `FoundationErrors.loctable` localises it, as
    /// `(%1$@-Fehler %2$ld.)` in German and `（%1$@错误%2$ld。）` in Simplified Chinese. So this
    /// holds only where Foundation renders English, as the domain match did. WhisperMeet ships no
    /// localisations and declares no development region; which language Foundation then uses for
    /// its error text has not been verified.
    private static func isBridgePlaceholder(_ described: String, for error: NSError) -> Bool {
        described.contains("(\(error.domain) error \(error.code).)")
            || described.range(of: #"\([^()]+ error -?\d+(?:\.\)| - )"#, options: .regularExpression) != nil
    }

    private static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The specific text for a log: domain and code for an `NSError`, the case name and its
    /// associated values otherwise — **path-redacted, always** (F391).
    ///
    /// Never shown to a user and never truncated.
    ///
    /// **The redaction is the correction of a claim this comment used to make.** It said the
    /// function was "for errors that carry a numeric code and nothing private", which is false:
    /// `LocalWhisperError.processFailed(String)` and `QwenASRError` carry the helper subprocess's
    /// raw stderr — a Python traceback, full of absolute paths — and
    /// `DictationController.swift:832` interpolates this at `privacy: .public`. F154 exists to
    /// stop precisely that, and `publicLogDescription` was on the same line doing its job while
    /// this call walked around it. The sentence was wrong the moment it was written, and it is
    /// what made the call look safe to write at four sites.
    ///
    /// Redacting here rather than at each call site is deliberate: the fifth caller is how this
    /// comes back.
    public static func diagnostic(for error: any Error) -> String {
        // `String(describing:)` on one of this repo's enums gives the case name and its associated
        // values, which is the most specific thing available. On a framework `NSError` it gives a
        // long dump whose useful part is the domain and the code, so take those directly.
        if error is any LocalizedError {
            return DiagnosticsBundleBuilder.redactPaths(String(describing: error))
        }
        let bridged = error as NSError
        // Redacted too. A domain is not a path today, and nothing guarantees the next framework
        // agrees — this costs one regex over a short string on an error path.
        return DiagnosticsBundleBuilder.redactPaths("\(bridged.domain) \(bridged.code)")
    }
}

/// An error that exists to steer code, never to be read by a person (F366).
///
/// `ErrorCopyGuardTests` requires every `Error` in `Sources/` either to carry a sentence or to
/// declare itself silent by conforming here. The guard found every type that needed the second
/// answer, and none has "Error" in its name, so no hand-written list would have contained them.
/// `unsurfacedErrorsAreDeclaredInCode` pins who they are, derived from the guard's own exemption.
///
/// **In code, not in a comment, deliberately.** The guard strips comments before it reads a file,
/// so an exemption written as prose could not silence it even by accident; a conformance is
/// greppable, shows up in review as a line of code, and is the kind of thing somebody has to mean.
///
/// The alternative was to invent copy for a `Result` discriminator. That is worse than it sounds:
/// an `errorDescription` nobody displays still reads, to the next person, as a promise that it is
/// displayed somewhere — and they will quote it.
public protocol UnsurfacedError: Error {}
