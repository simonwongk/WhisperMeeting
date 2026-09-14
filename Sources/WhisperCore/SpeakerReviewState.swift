import Foundation

/// What the transcript's speaker-review banner is showing right now (F220).
///
/// One case per outcome a person would act on differently — which is the whole point. Four of these
/// end with no labels on screen (`unreadable`, `stale`, `noTurnsFound`, `singleVoice`,
/// `noConfidentLabels`), and collapsing them into a single empty transcript would leave someone who
/// deliberately ran an analysis staring at a screen that looks exactly like one that was never
/// analyzed. Each says what happened and what to do next instead.
///
/// Deliberately payload-free: the cluster list, the live progress fraction and the reason a rerun is
/// unavailable are all published separately by `AppModel`, so this stays a plain value the copy can
/// switch over and a test can enumerate.
public enum SpeakerReviewState: String, Sendable, Equatable, CaseIterable {
    /// No analysis has ever been saved for this meeting. The banner is hidden entirely — an untouched
    /// transcript should not carry a notice about a feature its owner never used.
    case notAnalyzed
    /// A run is in flight. Progress and Cancel are the only actions.
    case analyzing
    /// A saved result exists but could not be read — damaged, written by a newer build, or refused by
    /// the OS. Distinct from `notAnalyzed`, whose advice ("analyze this meeting") would silently skip
    /// past the fact that something the user already produced is now unreachable.
    case unreadable
    /// The saved result was computed against different transcript timings, so its labels no longer
    /// line up with these lines. Labels are withheld; the file itself is kept.
    case stale
    /// The analysis completed and found no speech to separate. Nothing to label, nothing wrong.
    case noTurnsFound
    /// Exactly one voice was told apart. Not an error — a real monologue produces this, and so does a
    /// failed separation of two similar voices — and labelling every line "Speaker 1" would be
    /// worthless in the first case and actively misleading in the second (the F216/F217 rule).
    case singleVoice
    /// More than one voice was told apart, but no single line was clearly enough one of them to label
    /// under the overlay's coverage floor and margin. Saying "only one voice" here would be false.
    case noConfidentLabels
    /// Labels are on screen.
    case labeled

    /// Whether the review banner appears at all.
    public var showsReviewBanner: Bool { self != .notAnalyzed }

    /// Whether a saved result exists on disk for this meeting — the gate for Clear and Analyze Again.
    public var hasStoredAnalysis: Bool {
        switch self {
        case .notAnalyzed, .analyzing: return false
        case .unreadable, .stale, .noTurnsFound, .singleVoice, .noConfidentLabels, .labeled: return true
        }
    }

    /// Rename is offered only when clusters are actually on screen. With one voice distinguished there
    /// is nothing safe to name: the name would also cover whoever the runtime failed to separate.
    public var offersRename: Bool { self == .labeled }

    public var offersClear: Bool { hasStoredAnalysis }

    public var offersAnalyzeAgain: Bool { hasStoredAnalysis }
}
