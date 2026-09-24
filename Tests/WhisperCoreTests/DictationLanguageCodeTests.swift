import Foundation
import Testing
@testable import WhisperCore

// F447 — a pinned dictation language must reach refinement as the code the refine prompt keys on.
//
// When the user pins a language, Swift sends the helper `WhisperLanguage.commandLineValue` —
// "English" or "Chinese" — and every dictation helper echoes that string back as the reply's
// `language`: Qwen by copying it, Whisper because mlx_whisper returns `options.language` verbatim
// (installed 0.4.3, `decoding.py:558`, `transcribe.py:180`). `DictationRefinePrompt` recognises only
// "en" and "zh", so every pinned-language dictation was refined with neither its language sentence
// nor F244's script sentence — the prompt F244 measured converting 個→个.

private let neverSleep: DictationRefiner.Sleep = { _ in try await Task.sleep(for: .seconds(3600)) }

private final class RecordingRefineEngine: DictationRefineEngine, @unchecked Sendable {
    private let lock = NSLock()
    private var _requests: [RefineRequest] = []
    var requests: [RefineRequest] { lock.withLock { _requests } }
    func warmUp() async throws {}
    func refine(_ request: RefineRequest) async throws -> String {
        lock.withLock { _requests.append(request) }
        return request.text
    }
    func shutdown() {}
    func evict() async {}
}

@Test("Every pinned language a helper echoes back names itself in the refine prompt (F447)")
func everyPinnedLanguageNamesItselfInTheRefinePrompt() {
    // Derived from the cases, so a language added later is covered without editing this test.
    let unnamed = DictationRefinePrompt.system(languageCode: nil)
    for language in WhisperLanguage.allCases {
        guard let echoed = language.commandLineValue else { continue }
        let result = DictationResult(text: "text", languageCode: echoed)
        #expect(
            DictationRefinePrompt.system(languageCode: result.languageCode) != unnamed,
            "a dictation pinned to \(language) reached refinement as \(String(describing: result.languageCode))"
        )
    }
}

@Test("A pinned-Chinese Traditional dictation is refined with the Traditional-script prompt (F447)")
func pinnedChineseDictationKeepsItsScriptSentence() async throws {
    let tmp = FileManager.default.temporaryDirectory
        .appendingPathComponent("PinnedLanguage-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tmp) }

    // Replies the way both real helpers do for a pinned language: the request's own `language`,
    // verbatim — not a hardcoded answer, so the test cannot agree with the code by construction.
    let script = tmp.appendingPathComponent("echo-language.sh")
    try #"""
    printf '{"ready":true}\n'
    while IFS= read -r request; do
      language=$(printf '%s' "$request" | sed -n 's/.*"language":"\([^"]*\)".*/\1/p')
      printf '{"text":"我們星期二把版本出貨了 倫敦辦公室星期三才收到","language":"%s","error":null}\n' "$language"
    done
    """#.write(to: script, atomically: true, encoding: .utf8)

    let engine = WarmWhisperDictationEngine(
        python: URL(fileURLWithPath: "/bin/sh"),
        script: script,
        modelDirectory: tmp
    )
    defer { engine.shutdown() }

    let result = try await engine.transcribe(
        wavAt: tmp.appendingPathComponent("clip.wav"),
        language: .chinese,
        initialPrompt: nil
    )
    // DictationController hands exactly these two values to the refiner.
    let refineEngine = RecordingRefineEngine()
    let refiner = DictationRefiner(engine: refineEngine, sleep: neverSleep)
    _ = await refiner.attempt(text: result.text, languageCode: result.languageCode)

    let sent = refineEngine.requests.first?.systemPrompt ?? ""
    #expect(sent == DictationRefinePrompt.system(languageCode: "zh", script: .traditional), Comment(rawValue: sent))
}

@Test("Detected codes, and anything the app never sends, pass through the normaliser unchanged (F447)")
func reportedCodesPassThroughUnchanged() {
    #expect(WhisperLanguage.code(forReported: nil) == nil)
    // Automatic detection already reports codes; a region-tagged or unfamiliar one is not ours to
    // rewrite, and an empty string stays the empty string it was.
    for code in ["en", "zh", "zh-CN", "ja", "yue", ""] {
        #expect(WhisperLanguage.code(forReported: code) == code)
    }
    // The name is matched without regard to case, as openai-whisper's own tokenizer lookup lowers it.
    #expect(WhisperLanguage.code(forReported: "chinese") == "zh")
    #expect(WhisperLanguage.code(forReported: "ENGLISH") == "en")
}
