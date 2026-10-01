import Foundation
@testable import WhisperCore

/// The Quick Dictation refine engine, built the way the app builds it.
///
/// `DictationController`'s initializer wraps this engine in its `DictationRefiner`. That code is
/// in the WhisperMeet target, which this test target cannot call into. The opt-in suites that run
/// the real refine helper (`RefineStageBenchTests` and F206's `RealModelDictationPerformanceTests`)
/// share this one copy rather than keeping one each. `refineBenchBuildsTheEngineTheAppBuilds` in
/// WhisperMeetTests compares the two argument lists as source and fails when they differ (F631).
enum ProductionRefineConstruction {
    static func engine() -> WarmRefineEngine {
        WarmRefineEngine(
            python: SummarizerRuntime.pythonExecutable(),
            script: SummarizerRuntime.refineHelperScript(),
            modelDirectory: SummarizerRuntime.modelDirectory(),
            primePrompt: DictationRefinePrompt.system(languageCode: nil)
        )
    }

    /// The budget timer the app's refiner runs: the same closure as `DictationRefiner.init`'s
    /// default `sleep`, written out here and passed explicitly.
    ///
    /// The bench cannot take the default argument itself. Run inside `swift test` (measured with
    /// Swift 6.3.3 from the Command Line Tools), a `DictationRefiner` built with the default `sleep`
    /// aborts the test process (signal 6,
    /// "freed pointer was not the last allocation") when that sleep returns, even with an engine
    /// that answers at once. The same closure compiled here does not, and neither does the default
    /// in a standalone executable built from the same WhisperCore sources, debug or release (F631
    /// evidence). So the bench passes this copy, and `refineBenchSleepsAsTheAppsRefinerSleeps` in
    /// WhisperMeetTests fails if it stops being the default's text.
    static let budgetSleep: DictationRefiner.Sleep = { try await Task.sleep(for: $0) }
}
