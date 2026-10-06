import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F536 — Improve ▸ Correct Toward Vocabulary… ran the whole pass synchronously on the main actor
// (about 136 s at the 5,000-term cap, the app not responding) and could not be stopped. It now runs
// through `AppModel.proposeGlossaryCorrections(for:)`, off the main actor, with progress and Cancel.

@MainActor
private func makeModel(_ tag: String) throws -> (AppModel, URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("F536-\(tag)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let defaults = UserDefaults(suiteName: "F536.\(UUID().uuidString)")!
    return (AppModel(store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(), defaults: defaults), root)
}

@MainActor
private func addMeeting(_ model: AppModel, lines: [String]) -> UUID {
    let segments = lines.enumerated().map {
        TranscriptSegment(speaker: nil, start: Double($0.offset), end: Double($0.offset + 1), text: $0.element)
    }
    let id = UUID()
    model.store.upsert(MeetingRecord(
        id: id, title: "M", status: .completed,
        transcriptText: TranscriptFormatter.timestamped(segments), segments: segments
    ))
    return id
}

/// Polls `condition` on the main actor against the wall clock, with a cap far above any real wait.
@MainActor
private func waitUntil(_ condition: () -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(30)
    while Date() < deadline {
        if condition() { return true }
        try? await Task.sleep(for: .milliseconds(10))
    }
    return condition()
}

private final class PassProbe: @unchecked Sendable {
    private let lock = NSLock()
    private var ranOnMainThread: Bool?
    var sawMainThread: Bool? { lock.lock(); defer { lock.unlock() }; return ranOnMainThread }
    func record(isMain: Bool) { lock.lock(); ranOnMainThread = isMain; lock.unlock() }
}

@MainActor
@Test("Correct Toward Vocabulary finds Chinese mishearings through the app, and applies them in place (F536)")
func chineseCorrectionsThroughTheApp() async throws {
    let (model, root) = try makeModel("chinese")
    defer { try? FileManager.default.removeItem(at: root) }
    model.cjkWordSegmenter = dictionarySegmenterForApp(["明天", "下午", "三点", "请", "来", "开会", "讨论", "预算", "这个", "集群"])
    model.store.addVocabulary(["张经理", "预算", "Kubernetes"])
    let id = addMeeting(model, lines: ["对，张经里", "明天下午三点请张经里来开会", "讨论预算", "这个Kubernets集群"])

    let proposals = try #require(await model.proposeGlossaryCorrections(for: id))

    let expected: [GlossaryCorrection] = [
        GlossaryCorrection(segmentIndex: 0, from: "张经里", to: "张经理"),
        GlossaryCorrection(segmentIndex: 1, from: "张经里", to: "张经理"),
        GlossaryCorrection(segmentIndex: 3, from: "Kubernets", to: "Kubernetes"),
    ]
    #expect(proposals == expected)
    model.applyGlossaryCorrections(proposals, to: id)
    let lines = try #require(model.store.meeting(id: id)).segments.map(\.text)
    let applied: [String] = ["对，张经理", "明天下午三点请张经理来开会", "讨论预算", "这个Kubernetes集群"]
    #expect(lines == applied)
    #expect(model.glossaryCorrectionRun == nil)
}

@MainActor
@Test("The pass runs off the main actor, shows its progress, and Cancel stops it with no proposals (F536)")
func passRunsInTheBackgroundAndCancels() async throws {
    let (model, root) = try makeModel("cancel")
    defer { try? FileManager.default.removeItem(at: root) }
    model.store.addVocabulary(["Kubernetes"])
    let id = addMeeting(model, lines: ["we deployed cooper netties today"])
    let probe = PassProbe()
    model.glossaryCorrectionPass = { _, isCancelled, progress in
        probe.record(isMain: Thread.isMainThread)
        progress(0.5)
        // Stands in for a long pass: runs until the user cancels (capped, so a broken Cancel fails
        // the test instead of hanging it).
        let deadline = Date().addingTimeInterval(30)
        while !isCancelled(), Date() < deadline { usleep(1_000) }
        return [GlossaryCorrection(segmentIndex: 0, from: "cooper netties", to: "Kubernetes")]
    }

    let pass = Task { await model.proposeGlossaryCorrections(for: id) }
    let showedProgress = await waitUntil { model.glossaryCorrectionRun?.fractionDone == 0.5 }
    try #require(showedProgress, "the status line never showed the pass's progress")
    #expect(model.glossaryCorrectionRun?.meetingID == id)
    // The main actor is free while the pass runs — this test is running on it — and a second request
    // is refused rather than starting a second pass.
    #expect(await model.proposeGlossaryCorrections(for: id) == nil)

    model.cancelGlossaryCorrections()
    let result = await pass.value

    #expect(result == nil, "a cancelled pass must not present proposals")
    #expect(model.glossaryCorrectionRun == nil)
    #expect(probe.sawMainThread == false)
}

// MARK: - The menu item and status line (ContentView cannot be rendered in this target — F174)

@Test("Correct Toward Vocabulary goes through the background pass and its status line has Cancel (F536)")
func menuUsesTheBackgroundPass() throws {
    let source = try SourceAssertion.uncommentedSource("Sources/WhisperMeet/ContentView.swift")
    let callsThePass = source.contains("await model.proposeGlossaryCorrections(for: meetingID)")
    #expect(callsThePass)
    let callsTheOldSyncPass = source.contains("model.glossaryCorrections(for:")
    #expect(!callsTheOldSyncPass)
    let showsProgress = source.contains("ProgressView(value: run.fractionDone)")
    #expect(showsProgress)
    let offersCancel = source.contains("model.cancelGlossaryCorrections()")
    #expect(offersCancel)
    // The review sheet no longer re-checks every row against every term on each render.
    let rowRechecks = source.contains("GlossaryReviewDefaults.touchesProtectedTerm(proposal")
    #expect(!rowRechecks)
}

/// Greedy longest match over a small dictionary, other letters one character each — a fixed
/// segmentation so the test does not depend on this Mac's NLTokenizer dictionary.
private func dictionarySegmenterForApp(_ dictionary: Set<String>) -> CJKWordEvidence.Segmenter {
    let longest = dictionary.map(\.count).max() ?? 1
    return { text in
        var ranges: [Range<String.Index>] = []
        var index = text.startIndex
        while index < text.endIndex {
            guard text[index].isLetter || text[index].isNumber else {
                index = text.index(after: index)
                continue
            }
            var end = text.index(after: index)
            for length in stride(from: longest, to: 1, by: -1) {
                if let candidate = text.index(index, offsetBy: length, limitedBy: text.endIndex),
                   dictionary.contains(String(text[index..<candidate])) {
                    end = candidate
                    break
                }
            }
            ranges.append(index..<end)
            index = end
        }
        return ranges
    }
}
