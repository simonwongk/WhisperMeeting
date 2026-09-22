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
    /// Matched on the parenthetical `(<domain> error <code>.)`, which the bridge appends verbatim
    /// and which carries no translatable words — so this holds in a locale where the sentence in
    /// front of it does not. Matching the English ("The operation couldn't be completed") would
    /// have been the obvious test and would silently stop working the day anything is localised,
    /// which is the kind of check that looks like a guard and is not.
    private static func isBridgePlaceholder(_ described: String, for error: NSError) -> Bool {
        described.contains("(\(error.domain) error \(error.code).)")
    }

    private static func isBlank(_ text: String) -> Bool {
        text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The raw text for a log: domain and code for an `NSError`, the Swift description otherwise.
    ///
    /// Never shown to a user and never truncated. `DiagnosticsBundleBuilder.publicLogDescription`
    /// is the redacting counterpart for anything that may carry a path; this one is for errors that
    /// carry a numeric code and nothing private.
    public static func diagnostic(for error: any Error) -> String {
        // `String(describing:)` on one of this repo's enums gives the case name and its associated
        // values, which is the most specific thing available. On a framework `NSError` it gives a
        // long dump whose useful part is the domain and the code, so take those directly.
        if error is any LocalizedError { return String(describing: error) }
        let bridged = error as NSError
        return "\(bridged.domain) \(bridged.code)"
    }
}

/// An error that exists to steer code, never to be read by a person (F366).
///
/// `ErrorCopyGuardTests` requires every `Error` in `Sources/` either to carry a sentence or to
/// declare itself silent by conforming here. Two types needed the second answer and the guard
/// found both — `WatchedFolderMonitor.Problem` and `AppModel.ImportRefusal` — neither of which has
/// "Error" in its name, so no hand-written list would have contained them.
///
/// **In code, not in a comment, deliberately.** The guard strips comments before it reads a file,
/// so an exemption written as prose could not silence it even by accident; a conformance is
/// greppable, shows up in review as a line of code, and is the kind of thing somebody has to mean.
///
/// The alternative was to invent copy for a `Result` discriminator. That is worse than it sounds:
/// an `errorDescription` nobody displays still reads, to the next person, as a promise that it is
/// displayed somewhere — and they will quote it.
public protocol UnsurfacedError: Error {}
