import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F182 — the AppModel side of a written answer: the model is only run when it is installed and
// idle, only the top passages are sent, the user's vocabulary is the protected-term list, and a
// failure leaves the passages on screen with a message rather than a broken answer.

@MainActor
private func makeModel(installed: Bool = true) throws -> AppModel {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("MeetingAnswerWiring-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let defaults = UserDefaults(suiteName: "F182.\(UUID().uuidString)")!
    let model = AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(), defaults: defaults)
    model.isSummarizerModelInstalled = { installed }
    model.refreshRuntime()
    return model
}

private func passages(_ count: Int) -> [CitedResult] {
    (0..<count).map {
        CitedResult(meetingID: UUID(), meetingTitle: "Planning", segmentIndex: $0, timestamp: 10,
                    snippet: "passage number \($0) about the discount", score: Double(count - $0))
    }
}

private actor Seen { var passages: [CitedResult] = []; func set(_ p: [CitedResult]) { passages = p } }

@MainActor
@Test("Only the top passages reach the model, and a cited answer comes back accepted (F182)")
func topPassagesGroundTheAnswer() async throws {
    let model = try makeModel()
    let seen = Seen()
    model.meetingAnswerRunner = { _, grounding in
        await seen.set(grounding)
        return "The discount is in passage two [2]."
    }
    let all = passages(9)
    let outcome = await model.writeMeetingAnswer(question: "discount?", passages: all)
    #expect(await seen.passages == Array(all.prefix(AppModel.answerPassageLimit)))
    #expect(outcome == .answer(MeetingAnswer(text: "The discount is in passage two [2].", citedPassages: [1])))
    #expect(!model.isAnsweringMeetingsQuestion)
}

@MainActor
@Test("The user's vocabulary is what the answer may not invent (F182, F245)")
func vocabularyProtectsTheAnswer() async throws {
    let model = try makeModel()
    model.store.addVocabulary(["Kestrel"])
    model.meetingAnswerRunner = { _, _ in "Kestrel gets the discount [1]." }
    let outcome = await model.writeMeetingAnswer(question: "discount?", passages: passages(2))
    #expect(outcome == .refused(.introducesTerm("Kestrel")))
}

@MainActor
@Test("Without the local model there is no answer and the model is never run (F182)")
func noModelNoAnswer() async throws {
    let model = try makeModel(installed: false)
    model.meetingAnswerRunner = { _, _ in Issue.record("the runner must not be called"); return "" }
    #expect(!model.canWriteMeetingAnswer)
    #expect(await model.writeMeetingAnswer(question: "q", passages: passages(2)) == nil)
}

@MainActor
@Test("A model failure leaves a plain message and no answer (F182)")
func failureIsReported() async throws {
    let model = try makeModel()
    model.meetingAnswerRunner = { _, _ in throw SummarizerError.unreadableResponse }
    #expect(await model.writeMeetingAnswer(question: "q", passages: passages(2)) == nil)
    #expect(model.alertMessage?.contains("could not write an answer") == true)
}

@Test("The Ask view offers the answer and clears it when the results change (F182)")
func askViewOffersTheAnswer() throws {
    let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("Sources/WhisperMeet/ContentView.swift")
    let source = try String(contentsOf: url, encoding: .utf8)
    #expect(source.contains("model.writeMeetingAnswer(question: question, passages: passages)"))
    #expect(source.contains("answerSection\n            List(results)"))
    #expect(source.components(separatedBy: "answerOutcome = nil").count >= 3)
}

/// The real installed model, on invented passages. Off unless asked for: it loads a 4 GB model.
///     REAL_MODEL_ANSWER=1 swift test --filter realModelAnswersFromInventedPassages
@Test("The installed model answers from invented passages and the policy judges it (F182, real model)",
      .enabled(if: ProcessInfo.processInfo.environment["REAL_MODEL_ANSWER"] == "1"))
func realModelAnswersFromInventedPassages() async throws {
    func p(_ n: Int, _ text: String) -> CitedResult {
        CitedResult(meetingID: UUID(), meetingTitle: "Planning", segmentIndex: n, timestamp: Double(60 * n), snippet: text, score: 1)
    }
    let cases: [(String, [CitedResult])] = [
        ("What discount did we agree for Kestrel?",
         [p(1, "So for Kestrel we agreed fifteen percent off the annual plan, starting in March."),
          p(2, "Osprey stays at list price until they sign the two-year contract."),
          p(3, "Let's move the offsite to the second week of May.")]),
        ("我們決定什麼時候發佈新版本?",
         [p(1, "我們決定新版本在十月十五號發佈，前提是測試全部通過。"),
          p(2, "設計團隊下週會把最後的畫面交給工程師。")]),
        ("Who is the new head of finance?",
         [p(1, "The offsite is the second week of May."), p(2, "Osprey stays at list price.")]),
    ]
    for (question, passages) in cases {
        let started = Date()
        let raw = try await LocalSummarizer().answerText(question: question, passages: passages)
        let outcome = MeetingAnswerPolicy.evaluate(raw, question: question, passages: passages, protectedTerms: ["Kestrel", "Osprey"])
        print("REAL Q: \(question)\nREAL RAW: \(raw)\nREAL OUTCOME: \(outcome)\nREAL SECONDS: \(Int(Date().timeIntervalSince(started)))\n")
    }
}
