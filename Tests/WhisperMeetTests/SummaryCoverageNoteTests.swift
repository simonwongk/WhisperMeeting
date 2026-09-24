import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F437 — the summary's "Not mentioned in this summary" note ran one regular-expression search over
// the whole transcript per vocabulary term, inside the view body: on every Notes keystroke, every
// keystroke in the transcript's Edit view, and every progress update the model published, on the
// main thread. It is now asked for from `.task(id:)` keyed on what it reads, and computed off the
// main thread.
//
// Where it runs is checked through a seam; that the view asks only from `.task(id:)` is checked on
// `ContentView`'s source, because this target cannot render a view (F174's standing reason).

@MainActor
private func makeModel() -> AppModel {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("SummaryCoverageNoteTests-\(UUID().uuidString)")
    try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let defaults = UserDefaults(suiteName: "WhisperMeet.SummaryCoverageNoteTests.\(UUID().uuidString)")!
    return AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(), defaults: defaults)
}

/// Which threads the seam ran on. Written from whatever thread the check runs on, so it locks.
private final class ThreadLog: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [Bool] = []

    func record() {
        lock.lock()
        entries.append(Thread.isMainThread)
        lock.unlock()
    }

    var ranOnMainThread: [Bool] {
        lock.lock()
        defer { lock.unlock() }
        return entries
    }
}

private let summary = MeetingSummary(
    summary: "The team agreed to ship the Kestrel release.",
    keyPoints: ["Hiring is paused."],
    actionItems: ["Send the Kestrel report"]
)
private let transcript = "We talked about the Kestrel release, the Fairhaven office and the CCP filing."
private let vocabulary = ["Kestrel", "Fairhaven", "CCP", "Tiananmen"]

@MainActor
@Test("The summary's coverage note is worked out off the main thread, and says what the core says (F437)")
func coverageNoteRunsOffTheMainThread() async {
    let model = makeModel()
    let log = ThreadLog()
    model.summaryCoverageCheck = { input in
        log.record()
        return SummaryCoverage.unmentioned(in: input.summary, transcript: input.transcript, terms: input.terms)
    }

    let terms = await model.unmentionedSummaryTerms(
        for: SummaryCoverageInput(summary: summary, transcript: transcript, terms: vocabulary)
    )

    #expect(terms == ["Fairhaven", "CCP"])
    #expect(terms == SummaryCoverage.unmentioned(in: summary, transcript: transcript, terms: vocabulary))
    #expect(log.ranOnMainThread == [false], """
        The coverage check ran on the main thread. It searches the whole transcript once per vocabulary \
        term — about 1.3 s for 105 terms over an hour's transcript before F437 — so on the main thread \
        every keystroke in the Edit view froze the window for that long.
        """)
}

@Test("The note's input changes exactly when the summary, the transcript or the vocabulary does (F437)")
func coverageInputTracksWhatTheNoteReads() {
    let input = SummaryCoverageInput(summary: summary, transcript: transcript, terms: vocabulary)
    #expect(input == SummaryCoverageInput(summary: summary, transcript: transcript, terms: vocabulary))

    var resummarized = summary
    resummarized.summary = "The team agreed to ship the Fairhaven release."
    #expect(input != SummaryCoverageInput(summary: resummarized, transcript: transcript, terms: vocabulary))
    #expect(input != SummaryCoverageInput(summary: summary, transcript: transcript + " More.", terms: vocabulary))
    #expect(input != SummaryCoverageInput(summary: summary, transcript: transcript, terms: vocabulary + ["Priya"]))
}

@Test("The summary note is asked for from .task(id:) and never computed in the view body (F437)")
func coverageNoteIsOffTheRenderPath() throws {
    // Booleans first, so a failure prints the sentence rather than the whole file.
    let source = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/ContentView.swift")
    let computesInline = source.contains("SummaryCoverage.unmentioned(")
    let keysTheTaskOnItsInput = source.contains(".task(id: coverageInput)")
    let asksTheModel = source.contains("await model.unmentionedSummaryTerms(for: coverageInput)")
    #expect(!computesInline, """
        ContentView computes the coverage note itself. The body runs on every Notes keystroke and every \
        progress update, and the note searches the whole transcript once per vocabulary term.
        """)
    #expect(keysTheTaskOnItsInput)
    #expect(asksTheModel)
}
