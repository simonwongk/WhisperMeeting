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
}
