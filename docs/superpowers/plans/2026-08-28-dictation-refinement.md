# Dictation Refinement (F200) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Opt-in light-touch AI cleanup of Quick Dictation text by the installed local Qwen model, raced against a hard length-scaled time budget with raw-transcript fallback.

**Architecture:** A resident `refine_server.py` in the existing Summarizer runtime (JSON-lines over stdin/stdout, the `whisper_dictate_server.py` pattern) is hosted by a new `WarmRefineEngine`; a pure `DictationRefinePolicy` decides skip/attempt + budget and guards the model output; a `DictationRefiner` actor races engine vs. budget; `DictationController` calls it between text cleanup and delivery. Spec: `docs/superpowers/specs/2026-08-28-dictation-refinement-design.md`.

**Tech Stack:** Swift 6 toolchain (Swift 5 mode), Swift Testing (`@Test`/`#expect`), SwiftPM, Python `mlx_lm` (pinned 0.30.5 in the installed runtime).

**House rules that bind every task** (AGENTS.md): reference `F200` in every commit; WhisperCore imports Foundation only (Darwin exception is file-scoped to `WarmWhisperDictationEngine.swift` — new process code goes in that file); `dictation-log.json` is a persisted wire format → append-only optional fields + fixtures both directions; runtime helper changes must be exercised against the real installed model (installed here: Qwen3-8B-4bit); tests run via `Scripts/quality-check.sh` on a CLT-only Mac.

**Simplification vs. spec, decided here:** no request-id correlation on the wire. The `DictationRefiner` actor's `inFlight` flag stays true until the engine's serialized request fully completes (even after a budget timeout abandons it), and a busy refiner causes a skip — so a second request can never interleave with an abandoned reply and the stream cannot desync. The spec's "monotonic request id" is therefore unnecessary; the busy-skip rule provides the same guarantee structurally.

---

### Task 0: Ticket + branch

**Files:**
- Modify: `docs/TICKETS.md` (local-only, gitignored — discipline, not a commit)
- Branch: `feat/f200-dictation-refinement`

- [ ] **Step 0.1: Read the board, file and claim F200**

Add to `docs/TICKETS.md` under the appropriate section, and bump `Next free ID` to F201:

```markdown
### F200 — Refine dictation with the local AI model (opt-in, time-budgeted)

- **Status:** in-progress
- **Owner:** claude-fable-5 session 2026-08-28
- **Severity:** medium
- **Area:** dictation
- **Filed:** 2026-08-28 by claude-fable-5

**Problem.** Dictated text is delivered verbatim from Whisper: no grammar/punctuation cleanup, filler
words included. `docs/QUICK_DICTATION_DESIGN.md` rejected AI cleanup for v1 on latency+network
grounds; both are now answerable with the installed on-device Summarizer model and a hard time
budget. Design approved by the user: `docs/superpowers/specs/2026-08-28-dictation-refinement-design.md`.

**Impact.** Users hand-edit obvious dictation errors in every target app.

**Proposed fix.** Warm `refine_server.py` in `Runtime/Summarizer` hosted by a `WarmRefineEngine`;
pure `DictationRefinePolicy` (budget = 0.7 s + 30 ms/word cap 2.0 s, skip > 60 words, guardrails);
`DictationRefiner` actor races budget, falls back to raw; opt-in toggle default off; overlay
`Polishing…` phase; log records raw + outcome.

**Verification.** Red-green unit tests (policy, guardrails, refiner races, wire types, log fixtures)
+ controller wiring tests + real-model run of `refine_server.py` against the installed
Qwen3-8B-4bit with measured latency. `swift build` + full `swift test` green.
```

- [ ] **Step 0.2: Regenerate + check the dashboard**

Run: `python3 Scripts/generate-tickets-dashboard.py && python3 Scripts/generate-tickets-dashboard.py --check`
Expected: check passes.

- [ ] **Step 0.3: Create the branch**

```bash
git checkout -b feat/f200-dictation-refinement
```

---

### Task 1: `DictationRefinePolicy` — decision + budget (pure, WhisperCore)

**Files:**
- Create: `Sources/WhisperCore/DictationRefinePolicy.swift`
- Test: `Tests/WhisperCoreTests/DictationRefinePolicyTests.swift`

- [ ] **Step 1.1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import WhisperCore

@Test("Empty and whitespace-only text is skipped")
func skipsEmptyText() {
    #expect(DictationRefinePolicy.decision(for: "") == .skip)
    #expect(DictationRefinePolicy.decision(for: "   \n ") == .skip)
}

@Test("Budget is 0.7s + 30ms per word, capped at 2s")
func budgetScalesWithWordCount() {
    // 10 words → 700 + 300 = 1000 ms
    let ten = Array(repeating: "word", count: 10).joined(separator: " ")
    #expect(DictationRefinePolicy.decision(for: ten) == .attempt(budget: .milliseconds(1_000)))
    // 50 words → 700 + 1500 = 2200 ms → capped to 2000 ms
    let fifty = Array(repeating: "word", count: 50).joined(separator: " ")
    #expect(DictationRefinePolicy.decision(for: fifty) == .attempt(budget: .milliseconds(2_000)))
}

@Test("Text longer than 60 words is skipped — it would nearly always miss the budget")
func skipsLongDictations() {
    let sixty = Array(repeating: "word", count: 60).joined(separator: " ")
    let sixtyOne = Array(repeating: "word", count: 61).joined(separator: " ")
    #expect(DictationRefinePolicy.decision(for: sixty) != .skip)
    #expect(DictationRefinePolicy.decision(for: sixtyOne) == .skip)
}

@Test("Majority-CJK text counts words as ceil(non-whitespace characters / 2)")
func cjkWordCounting() {
    // 40 CJK chars → 20 effective words → 700 + 600 = 1300 ms
    let mandarin = String(repeating: "我们今天开会讨论那个方案", count: 4) // 48 chars
    #expect(DictationRefinePolicy.effectiveWordCount(of: mandarin) == 24)
    #expect(DictationRefinePolicy.decision(for: mandarin)
        == .attempt(budget: .milliseconds(700 + 24 * 30)))
    // Mostly-English with one CJK term stays space-counted (F41 parity via TranscriptLanguage).
    #expect(DictationRefinePolicy.effectiveWordCount(of: "ship the 方案 tomorrow") == 4)
}
```

- [ ] **Step 1.2: Run to verify failure**

Run: `Scripts/quality-check.sh` style invocation, or directly:
```bash
FW=/Library/Developer/CommandLineTools/Library/Developer/Frameworks
LIB=/Library/Developer/CommandLineTools/Library/Developer/usr/lib
swift test --disable-sandbox --no-parallel \
  -Xswiftc -F -Xswiftc "$FW" -Xlinker -rpath -Xlinker "$FW" -Xlinker -rpath -Xlinker "$LIB" \
  --filter DictationRefinePolicy
```
Expected: compile failure — `DictationRefinePolicy` not defined.

- [ ] **Step 1.3: Implement**

```swift
import Foundation

/// Pure decision layer for Quick Dictation refinement (F200): whether a transcript is worth sending
/// to the local model at all, how long the model is allowed to take, and whether its output is safe
/// to deliver in place of the user's raw words. Everything here is deterministic and headlessly
/// tested; the controller supplies only the toggle/availability checks it alone can see.
///
/// The budget is a *hard ceiling on added latency*: a missed budget delivers the raw transcript at
/// `t = budget`, so the worst case with refinement on is exactly today's behavior plus the budget.
/// That is why the constants stay modest and long dictations are skipped outright.
public enum DictationRefinePolicy {
    public enum Decision: Equatable, Sendable {
        case skip
        case attempt(budget: Duration)
    }

    /// Above this the 8B model cannot reliably answer inside `maximumBudget` — skip, don't tease.
    public static let maximumWordCount = 60
    static let baseBudgetMilliseconds = 700
    static let perWordBudgetMilliseconds = 30
    static let maximumBudgetMilliseconds = 2_000
    /// Output cap sent to the helper. ≤60 words in either language is well under this; the cap
    /// bounds how long an abandoned (timed-out) generation can occupy the resident server.
    public static let maxOutputTokens = 256

    public static func decision(for text: String) -> Decision {
        let words = effectiveWordCount(of: text)
        guard words > 0, words <= maximumWordCount else { return .skip }
        let milliseconds = min(
            baseBudgetMilliseconds + perWordBudgetMilliseconds * words,
            maximumBudgetMilliseconds
        )
        return .attempt(budget: .milliseconds(milliseconds))
    }

    /// Space-delimited word count, except majority-CJK text (no word spaces) where it is
    /// ceil(non-whitespace characters / 2) — reusing the F32 dominant-script heuristic.
    public static func effectiveWordCount(of text: String) -> Int {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return 0 }
        if TranscriptLanguage.dominant(of: trimmed) == .chinese {
            let characters = trimmed.unicodeScalars.filter { !$0.properties.isWhitespace }.count
            return (characters + 1) / 2
        }
        return trimmed.split(whereSeparator: { $0.isWhitespace }).count
    }
}
```

- [ ] **Step 1.4: Run to verify pass** — same filter command. Expected: 4 tests PASS.

- [ ] **Step 1.5: Commit**

```bash
git add Sources/WhisperCore/DictationRefinePolicy.swift Tests/WhisperCoreTests/DictationRefinePolicyTests.swift
git commit -m "feat(dictation): refine policy — skip/attempt decision and time budget (F200)"
```

---

### Task 2: Output guardrails — `acceptedOutput`

**Files:**
- Modify: `Sources/WhisperCore/DictationRefinePolicy.swift`
- Test: `Tests/WhisperCoreTests/DictationRefineGuardrailTests.swift`

- [ ] **Step 2.1: Write the failing tests**

```swift
import Foundation
import Testing
@testable import WhisperCore

@Test("A plain grammar fix is accepted and cleaned")
func acceptsPlainFix() {
    let out = DictationRefinePolicy.acceptedOutput(
        "So I think we should go with the second option.",
        input: "so i think we should uh go with the the second option"
    )
    #expect(out == "So I think we should go with the second option.")
}

@Test("Wrapping quotes and code fences are stripped before checking")
func stripsWrappers() {
    #expect(DictationRefinePolicy.acceptedOutput("\"Hello there.\"", input: "hello there")
        == "Hello there.")
    #expect(DictationRefinePolicy.acceptedOutput("```\nHello there.\n```", input: "hello there")
        == "Hello there.")
    #expect(DictationRefinePolicy.acceptedOutput("“你好。”", input: "你好") == "你好。")
}

@Test("Empty output is rejected")
func rejectsEmpty() {
    #expect(DictationRefinePolicy.acceptedOutput("", input: "hello") == nil)
    #expect(DictationRefinePolicy.acceptedOutput("\"\"", input: "hello") == nil)
}

@Test("Output whose length drifts far from the input is rejected")
func rejectsLengthDrift() {
    let input = "please send the report tomorrow morning"  // 39 chars
    let bloated = String(repeating: "This model wrote an essay. ", count: 4)
    #expect(DictationRefinePolicy.acceptedOutput(bloated, input: input) == nil)
    #expect(DictationRefinePolicy.acceptedOutput("Sent.", input: input) == nil)
}

@Test("Short inputs get absolute slack so 'hi' → 'Hi.' still passes")
func shortInputSlack() {
    #expect(DictationRefinePolicy.acceptedOutput("Hi.", input: "hi") == "Hi.")
}

@Test("A script change (translation tripwire) is rejected")
func rejectsTranslation() {
    #expect(DictationRefinePolicy.acceptedOutput("We meet tomorrow at nine.",
                                                 input: "我们明天九点开会好不好") == nil)
    #expect(DictationRefinePolicy.acceptedOutput("我们明天九点开会,好不好?",
                                                 input: "我们明天九点开会好不好") != nil)
}

@Test("Internal newlines are collapsed like every dictation delivery")
func collapsesNewlines() {
    #expect(DictationRefinePolicy.acceptedOutput("Hello there.\nHow are you?",
                                                 input: "hello there how are you")
        == "Hello there. How are you?")
}
```

- [ ] **Step 2.2: Run to verify failure** — filter `DictationRefineGuardrail`. Expected: compile failure (`acceptedOutput` undefined).

- [ ] **Step 2.3: Implement (append to `DictationRefinePolicy`)**

```swift
    // MARK: - Output guardrails (F165 ethos: never trust LLM output blindly)

    /// The model's reply, cleaned and vetted — or nil, in which case the raw transcript must be
    /// delivered. Mirrors the F165 verbatim-guard ethos: a rejection costs nothing (raw is what
    /// ships today); an accepted hallucination costs trust. So every check biases toward raw.
    public static func acceptedOutput(_ output: String, input: String) -> String? {
        var candidate = output.trimmingCharacters(in: .whitespacesAndNewlines)
        candidate = strippingCodeFence(candidate)
        candidate = strippingWrappingQuotes(candidate)
        candidate = DictationTextCleanup.clean(candidate)
        guard !candidate.isEmpty else { return nil }

        let cleanedInput = DictationTextCleanup.clean(input)
        let inputCount = cleanedInput.count
        // Light-touch edits barely move length; filler removal shrinks a little. The +4 absolute
        // slack keeps one-word dictations ("hi" → "Hi.") from tripping the ratio.
        let lower = inputCount / 2
        let upper = inputCount + inputCount / 2 + 4
        guard (lower...upper).contains(candidate.count) else { return nil }

        if let inputScript = TranscriptLanguage.dominant(of: cleanedInput) {
            guard TranscriptLanguage.dominant(of: candidate) == inputScript else { return nil }
        }
        return candidate
    }

    private static func strippingCodeFence(_ text: String) -> String {
        guard text.hasPrefix("```") else { return text }
        var lines = text.components(separatedBy: "\n")
        lines.removeFirst()
        if let last = lines.last, last.trimmingCharacters(in: .whitespaces).hasPrefix("```") {
            lines.removeLast()
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func strippingWrappingQuotes(_ text: String) -> String {
        let pairs: [(Character, Character)] = [
            ("\"", "\""), ("“", "”"), ("'", "'"), ("‘", "’"), ("「", "」"), ("『", "』"),
        ]
        for (open, close) in pairs where text.count >= 2 {
            if text.first == open, text.last == close {
                return String(text.dropFirst().dropLast())
                    .trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return text
    }
```

- [ ] **Step 2.4: Run to verify pass** — filter `DictationRefineGuardrail`. Expected: 7 PASS. Note: `rejectsLengthDrift`'s "Sent." case = 5 chars, input 39 chars → lower bound 19 → rejected. ✔

- [ ] **Step 2.5: Commit** — `git commit -m "feat(dictation): refine output guardrails — strip wrappers, length ratio, script tripwire (F200)"`

---

### Task 3: `DictationRefinePrompt`

**Files:**
- Create: `Sources/WhisperCore/DictationRefinePrompt.swift`
- Test: `Tests/WhisperCoreTests/DictationRefinePromptTests.swift`

- [ ] **Step 3.1: Failing tests**

```swift
import Foundation
import Testing
@testable import WhisperCore

@Test("The refine prompt forbids translation and rephrasing and demands bare text")
func promptCoreConstraints() {
    let prompt = DictationRefinePrompt.system(languageCode: nil)
    #expect(prompt.contains("never translate"))
    #expect(prompt.contains("do not rephrase"))
    #expect(prompt.contains("ONLY the corrected text"))
}

@Test("A known language adds an explicit language pin")
func promptLanguagePin() {
    #expect(DictationRefinePrompt.system(languageCode: "zh")
        .contains("Mandarin Chinese"))
    #expect(DictationRefinePrompt.system(languageCode: "en")
        .contains("The input is English"))
    #expect(DictationRefinePrompt.system(languageCode: "fr")
        == DictationRefinePrompt.system(languageCode: nil))
}
```

- [ ] **Step 3.2: Verify failure** (filter `DictationRefinePrompt`), **Step 3.3: Implement**

```swift
import Foundation

/// System prompt for the dictation refine helper. Swift is the single source of truth for prompts
/// (the `LocalSummarizer`/`ClaudeSummarizer` precedent); the Python helper only applies the chat
/// template. Light touch by design decision (2026-08-28): the user's wording and order stay theirs.
public enum DictationRefinePrompt {
    public static func system(languageCode: String?) -> String {
        var prompt = """
        You clean up text that a person dictated by voice. Correct grammar, punctuation, \
        capitalization, and obvious speech-to-text mistakes, and remove filler words such as \
        "um", "uh", and "you know". Keep the speaker's wording, sentence order, and meaning \
        exactly: do not rephrase, do not summarize, do not add content, and do not answer the \
        text as if it were a question. Reply in the same language as the input; never translate. \
        Reply with ONLY the corrected text — no quotation marks around it, no explanation, no markdown.
        """
        switch languageCode {
        case "zh": prompt += " The input is Mandarin Chinese; reply only in Mandarin Chinese."
        case "en": prompt += " The input is English; reply only in English."
        default: break
        }
        return prompt
    }
}
```

- [ ] **Step 3.4: Verify pass**, **Step 3.5: Commit** — `git commit -m "feat(dictation): light-touch refine system prompt (F200)"`

---

### Task 4: Wire types `RefineRequest`/`RefineResponse`

**Files:**
- Modify: `Sources/WhisperCore/DictationProtocol.swift` (append after `DictationResponse`)
- Test: `Tests/WhisperCoreTests/RefineWireProtocolTests.swift`

- [ ] **Step 4.1: Failing tests**

```swift
import Foundation
import Testing
@testable import WhisperCore

@Test("RefineRequest encodes to a single newline-terminated JSON line")
func refineRequestEncodesToOneLine() throws {
    let request = RefineRequest(
        text: "hello there", systemPrompt: "fix it", maxTokens: 256
    )
    let line = try DictationWireProtocol.encodeLine(request)
    #expect(line.last == 0x0A)
    #expect(!line.dropLast().contains(0x0A))
    let decoded = try JSONDecoder().decode(RefineRequest.self, from: line.dropLast())
    #expect(decoded == request)
}

@Test("RefineResponse decodes both success and error payloads")
func refineResponseDecodes() throws {
    let ok = try JSONDecoder().decode(
        RefineResponse.self, from: Data(#"{"text":"Hello there."}"#.utf8))
    #expect(ok.text == "Hello there.")
    #expect(ok.error == nil)
    let failed = try JSONDecoder().decode(
        RefineResponse.self, from: Data(#"{"error":"boom"}"#.utf8))
    #expect(failed.error == "boom")
}
```

- [ ] **Step 4.2: Verify failure**, **Step 4.3: Implement (append to DictationProtocol.swift)**

```swift
/// One dictation-refinement request to `refine_server.py` (F200). The system prompt travels with
/// every request so Swift stays the single source of truth for prompt content.
public struct RefineRequest: Codable, Equatable, Sendable {
    public var text: String
    public var systemPrompt: String
    public var maxTokens: Int
    public init(text: String, systemPrompt: String, maxTokens: Int) {
        self.text = text
        self.systemPrompt = systemPrompt
        self.maxTokens = maxTokens
    }
}

/// The refine helper's reply: corrected text, or an error message. Same one-line JSON framing as
/// `DictationResponse`.
public struct RefineResponse: Codable, Equatable, Sendable {
    public var text: String?
    public var error: String?
    public init(text: String?, error: String?) {
        self.text = text
        self.error = error
    }
}
```

- [ ] **Step 4.4: Verify pass**, **Step 4.5: Commit** — `git commit -m "feat(dictation): refine wire types on the dictation JSON-lines protocol (F200)"`

---

### Task 5: `DictationRefiner` actor + outcome types

**Files:**
- Create: `Sources/WhisperCore/DictationRefiner.swift`
- Test: `Tests/WhisperCoreTests/DictationRefinerTests.swift`

- [ ] **Step 5.1: Failing tests**

```swift
import Foundation
import Testing
@testable import WhisperCore

private final class FakeRefineEngine: DictationRefineEngine, @unchecked Sendable {
    enum Behavior { case reply(String), fail, hang }
    private let lock = NSLock()
    private var _behavior: Behavior
    private var _refineCount = 0
    var refineCount: Int { lock.withLock { _refineCount } }
    init(_ behavior: Behavior) { _behavior = behavior }
    func set(_ behavior: Behavior) { lock.withLock { _behavior = behavior } }
    func warmUp() async throws {}
    func refine(_ request: RefineRequest) async throws -> String {
        let behavior = lock.withLock { _refineCount += 1; return _behavior }
        switch behavior {
        case let .reply(text): return text
        case .fail: throw SummarizerError.helperFailed("boom")
        case .hang: while true { try await Task.sleep(for: .seconds(3600)) }
        }
    }
    func shutdown() {}
}

private let instantSleep: DictationRefiner.Sleep = { _ in }
private let neverSleep: DictationRefiner.Sleep = { _ in try await Task.sleep(for: .seconds(3600)) }

@Test("A fast, clean reply is delivered as refined text")
func refinedHappyPath() async {
    let refiner = DictationRefiner(engine: FakeRefineEngine(.reply("Hello there.")), sleep: neverSleep)
    let attempt = await refiner.attempt(text: "hello there", languageCode: "en")
    #expect(attempt == RefineAttempt(text: "Hello there.", outcome: .refined))
}

@Test("A guardrail-violating reply falls back to the raw transcript")
func guardrailRejectionFallsBackToRaw() async {
    let essay = String(repeating: "An unrelated essay. ", count: 10)
    let refiner = DictationRefiner(engine: FakeRefineEngine(.reply(essay)), sleep: neverSleep)
    let attempt = await refiner.attempt(text: "hello there", languageCode: "en")
    #expect(attempt == RefineAttempt(text: "hello there", outcome: .rawRejected))
}

@Test("An engine error falls back to the raw transcript")
func engineErrorFallsBackToRaw() async {
    let refiner = DictationRefiner(engine: FakeRefineEngine(.fail), sleep: neverSleep)
    let attempt = await refiner.attempt(text: "hello there", languageCode: "en")
    #expect(attempt == RefineAttempt(text: "hello there", outcome: .rawError))
}

@Test("A missed budget delivers raw at the deadline, and the refiner then reports busy")
func timeoutThenBusy() async {
    let engine = FakeRefineEngine(.hang)
    let refiner = DictationRefiner(engine: engine, sleep: instantSleep)
    let first = await refiner.attempt(text: "hello there", languageCode: "en")
    #expect(first == RefineAttempt(text: "hello there", outcome: .rawTimeout))
    // The abandoned generation is still occupying the engine — the next dictation must skip,
    // never queue behind it.
    let second = await refiner.attempt(text: "next words", languageCode: "en")
    #expect(second == RefineAttempt(text: "next words", outcome: .rawBusy))
    #expect(engine.refineCount == 1)
}

@Test("Policy skips (long text) never touch the engine")
func policySkipNeverCallsEngine() async {
    let engine = FakeRefineEngine(.reply("x"))
    let refiner = DictationRefiner(engine: engine, sleep: neverSleep)
    let long = Array(repeating: "word", count: 61).joined(separator: " ")
    let attempt = await refiner.attempt(text: long, languageCode: "en")
    #expect(attempt == RefineAttempt(text: long, outcome: .skipped))
    #expect(engine.refineCount == 0)
}
```

- [ ] **Step 5.2: Verify failure** (filter `DictationRefiner`), **Step 5.3: Implement**

```swift
import Foundation

/// How one dictation's refinement ended. Persisted into the dictation log as a plain string
/// (`DictationLogEntry.refinement`) — persist the `rawValue`, never this enum, per the
/// persisted-schema rules (lenient forward decoding).
public enum DictationRefinement: String, Sendable, Equatable {
    case refined
    case skipped      // policy skip: empty or too long
    case rawBusy      // a previous dictation's abandoned generation still occupies the engine
    case rawTimeout   // the model missed the budget; raw delivered at the deadline
    case rawRejected  // the model answered but the guardrails refused its output
    case rawError     // the engine failed (helper crash, runtime missing, decode error)
}

/// The text to deliver (always safe to paste — raw on every failure path) plus how it was decided.
public struct RefineAttempt: Sendable, Equatable {
    public let text: String
    public let outcome: DictationRefinement
    public init(text: String, outcome: DictationRefinement) {
        self.text = text
        self.outcome = outcome
    }
}

/// A resident process that can rewrite one dictation. `WarmRefineEngine` is the real one; tests
/// substitute fakes.
public protocol DictationRefineEngine: Sendable {
    func warmUp() async throws
    func refine(_ request: RefineRequest) async throws -> String
    func shutdown()
}

/// The controller-facing seam: everything Quick Dictation needs from refinement, fakeable in
/// `WhisperMeetTests` without a model.
public protocol DictationTextRefining: Sendable {
    func warmUp() async
    func attempt(text: String, languageCode: String?) async -> RefineAttempt
    func shutdown()
}

/// Races the refine engine against `DictationRefinePolicy`'s budget and applies its guardrails.
/// Never blocks delivery: every path returns *some* text, raw on any doubt.
///
/// Concurrency contract: `inFlight` stays true until the engine's serialized request fully
/// completes — including after a timeout abandons its result — and a busy refiner answers
/// `.rawBusy` without touching the engine. Because the engine serializes requests on one queue,
/// this flag is what keeps an abandoned reply from ever being read as the answer to a later
/// request (no request ids needed on the wire).
public actor DictationRefiner: DictationTextRefining {
    public typealias Sleep = @Sendable (Duration) async throws -> Void

    private let engine: any DictationRefineEngine
    private let sleep: Sleep
    private var inFlight = false

    public init(
        engine: any DictationRefineEngine,
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) }
    ) {
        self.engine = engine
        self.sleep = sleep
    }

    public func warmUp() async {
        try? await engine.warmUp()
    }

    nonisolated public func shutdown() {
        engine.shutdown()
    }

    public func attempt(text: String, languageCode: String?) async -> RefineAttempt {
        guard !inFlight else { return RefineAttempt(text: text, outcome: .rawBusy) }
        guard case let .attempt(budget) = DictationRefinePolicy.decision(for: text) else {
            return RefineAttempt(text: text, outcome: .skipped)
        }
        inFlight = true
        let request = RefineRequest(
            text: text,
            systemPrompt: DictationRefinePrompt.system(languageCode: languageCode),
            maxTokens: DictationRefinePolicy.maxOutputTokens
        )
        let engine = self.engine
        let work = Task { try await engine.refine(request) }
        // Whatever the race below decides, the engine slot frees only when the request itself
        // finishes — that is the busy-skip guarantee.
        Task { [work] in
            _ = try? await work.value
            await self.clearInFlight()
        }

        enum RaceResult: Sendable { case finished(Result<String, Error>), timedOut }
        let raced = await withTaskGroup(of: RaceResult.self) { group -> RaceResult in
            group.addTask {
                do { return .finished(.success(try await work.value)) }
                catch { return .finished(.failure(error)) }
            }
            group.addTask { [sleep] in
                try? await sleep(budget)
                return .timedOut
            }
            let first = await group.next() ?? .timedOut
            group.cancelAll()
            return first
        }

        switch raced {
        case let .finished(.success(output)):
            if let accepted = DictationRefinePolicy.acceptedOutput(output, input: text) {
                return RefineAttempt(text: accepted, outcome: .refined)
            }
            return RefineAttempt(text: text, outcome: .rawRejected)
        case .finished(.failure):
            return RefineAttempt(text: text, outcome: .rawError)
        case .timedOut:
            return RefineAttempt(text: text, outcome: .rawTimeout)
        }
    }

    private func clearInFlight() {
        inFlight = false
    }
}
```

- [ ] **Step 5.4: Verify pass** — 5 PASS. (The `timeoutThenBusy` race: `instantSleep` returns immediately so `.timedOut` wins; the hanging work Task never completes, so `inFlight` stays true for the second call. `group.cancelAll()` cancels the group child awaiting `work.value`, not `work` itself.)

- [ ] **Step 5.5: Commit** — `git commit -m "feat(dictation): DictationRefiner actor — budget race, guardrails, busy-skip (F200)"`

---

### Task 6: `WarmRefineEngine` + `SummarizerRuntime` refine paths

**Files:**
- Modify: `Sources/WhisperCore/WarmWhisperDictationEngine.swift` (append — keeps the sanctioned `import Darwin` file-scoped)
- Modify: `Sources/WhisperCore/LocalSummarizer.swift` (two `SummarizerRuntime` additions)
- Test: `Tests/WhisperCoreTests/SummarizerRuntimeRefineTests.swift`

- [ ] **Step 6.1: Failing tests (runtime paths + install check — the engine itself is exercised against the real model in Task 11)**

```swift
import Foundation
import Testing
@testable import WhisperCore

@Test("The refine helper lives beside the other summarizer helpers")
func refineHelperPath() {
    let root = URL(fileURLWithPath: "/tmp/AppSupport")
    #expect(SummarizerRuntime.refineHelperScript(applicationSupport: root).path
        .hasSuffix("WhisperMeet/Runtime/Summarizer/refine_server.py"))
}

@Test("isRefineHelperInstalled requires the base install AND refine_server.py")
func refineHelperInstallCheck() throws {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("SummarizerRuntimeRefineTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: root) }
    let dir = SummarizerRuntime.managedDirectory(applicationSupport: root)
    try FileManager.default.createDirectory(
        at: dir.appendingPathComponent("venv/bin"), withIntermediateDirectories: true)
    try FileManager.default.createDirectory(
        at: dir.appendingPathComponent("model"), withIntermediateDirectories: true)
    let python = dir.appendingPathComponent("venv/bin/python")
    FileManager.default.createFile(atPath: python.path, contents: Data("#!/bin/sh\n".utf8),
                                   attributes: [.posixPermissions: 0o755])
    FileManager.default.createFile(
        atPath: dir.appendingPathComponent("summarize_local.py").path, contents: Data())
    FileManager.default.createFile(
        atPath: dir.appendingPathComponent("model/model.safetensors").path, contents: Data())
    #expect(SummarizerRuntime.isInstalled(applicationSupport: root))
    #expect(!SummarizerRuntime.isRefineHelperInstalled(applicationSupport: root))
    FileManager.default.createFile(
        atPath: dir.appendingPathComponent("refine_server.py").path, contents: Data())
    #expect(SummarizerRuntime.isRefineHelperInstalled(applicationSupport: root))
}
```

- [ ] **Step 6.2: Verify failure**, **Step 6.3: Implement**

In `LocalSummarizer.swift`, after `correctionHelperScript`:

```swift
    /// The dictation-refinement helper (F200), installed alongside the summarizer in the same runtime.
    public static func refineHelperScript(applicationSupport: URL? = nil) -> URL {
        managedDirectory(applicationSupport: applicationSupport)
            .appendingPathComponent("refine_server.py")
    }
```

After `isCorrectionHelperInstalled`:

```swift
    /// Whether the runtime is installed AND carries the F200 refine helper. Same shape as
    /// `isCorrectionHelperInstalled`: an older install stays valid for summaries; dictation
    /// refinement is gated until the helper reaches disk (the launch helper-sync writes it).
    public static func isRefineHelperInstalled(applicationSupport: URL? = nil) -> Bool {
        isInstalled(applicationSupport: applicationSupport)
            && FileManager.default.fileExists(
                atPath: refineHelperScript(applicationSupport: applicationSupport).path
            )
    }
```

Append to `WarmWhisperDictationEngine.swift` (structural sibling of the whisper engine — deliberately duplicated rather than refactoring the battle-tested class; it lives in this file so the sanctioned `import Darwin` stays file-scoped per the WhisperCore purity rule):

```swift
/// Keeps the Summarizer-runtime Qwen model resident for Quick Dictation refinement (F200), driven
/// over stdin/stdout newline-delimited JSON by `refine_server.py`. Same process-host shape as
/// `WarmWhisperDictationEngine` above (serialized queue, off-queue termination, drained stderr,
/// read watchdog); deliberately a separate class so the battle-tested transcription engine is not
/// refactored under a feature change. No download path exists here — the model is already on disk —
/// so the ready timeout is minutes (model load), not the whisper engine's 1800 s download window.
public final class WarmRefineEngine: DictationRefineEngine, @unchecked Sendable {
    private let python: URL
    private let script: URL
    private let modelDirectory: URL
    private let queue = DispatchQueue(label: "com.whispermeet.dictation.refine")

    private var process: Process?
    private var stdin: FileHandle?
    private var stdout: FileHandle?
    private var stdoutBuffer = Data()

    private let liveLock = NSLock()
    private var liveProcess: Process?
    private var liveStdin: FileHandle?

    private let stderrLock = NSLock()
    private var stderrText = ""
    private var stderrHandle: FileHandle?

    private static let readyTimeout: TimeInterval = 300
    /// The caller enforces the user-facing budget; this watchdog only stops a wedged child from
    /// hanging the queue forever.
    private static let replyTimeout: TimeInterval = 30

    public init(python: URL, script: URL, modelDirectory: URL) {
        self.python = python
        self.script = script
        self.modelDirectory = modelDirectory
    }

    public func warmUp() async throws {
        try await run { try self.ensureRunning() }
    }

    public func refine(_ request: RefineRequest) async throws -> String {
        try await run {
            try self.ensureRunning()
            if let stdin = self.stdin {
                try ThrowingFileHandleIO.write(
                    try DictationWireProtocol.encodeLine(request),
                    to: stdin
                )
            }
            let line = try self.readLine(timeout: Self.replyTimeout)
            let response = try JSONDecoder().decode(RefineResponse.self, from: line)
            if let error = response.error {
                throw SummarizerError.helperFailed(error)
            }
            return (response.text ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    public func shutdown() {
        liveLock.lock()
        let process = liveProcess
        let input = liveStdin
        liveLock.unlock()
        try? input?.close()
        process?.terminate()
        queue.async { self.clearProcessState() }
    }

    private func run<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do { continuation.resume(returning: try body()) }
                catch { continuation.resume(throwing: error) }
            }
        }
    }

    private func ensureRunning() throws {
        if let process, process.isRunning { return }
        guard FileManager.default.isExecutableFile(atPath: python.path),
              FileManager.default.fileExists(atPath: script.path),
              FileManager.default.fileExists(
                  atPath: modelDirectory.appendingPathComponent("model.safetensors").path
              ) else {
            throw SummarizerError.modelNotInstalled
        }

        let process = Process()
        process.executableURL = python
        process.arguments = [script.path, "--model", modelDirectory.path]
        let inPipe = Pipe()
        let outPipe = Pipe()
        let errPipe = Pipe()
        process.standardInput = inPipe
        process.standardOutput = outPipe
        process.standardError = errPipe
        // Pinned local snapshot; refinement must never reach the network (the summarizer's rule).
        process.environment = LocalSummarizer.makeEnvironment()
        resetStderr()
        try process.run()

        self.process = process
        self.stdin = inPipe.fileHandleForWriting
        self.stdout = outPipe.fileHandleForReading
        self.stdoutBuffer.removeAll()
        let errHandle = errPipe.fileHandleForReading
        self.stderrHandle = errHandle
        errHandle.readabilityHandler = { [weak self] handle in
            let data = handle.availableData
            if data.isEmpty {
                handle.readabilityHandler = nil
            } else if let text = String(data: data, encoding: .utf8) {
                self?.appendStderr(text)
            }
        }
        liveLock.lock()
        liveProcess = process
        liveStdin = self.stdin
        liveLock.unlock()

        let readyLine = try readLine(timeout: Self.readyTimeout)
        if let ready = try? JSONDecoder().decode([String: Bool].self, from: readyLine),
           ready["ready"] == true {
            return
        }
        if let response = try? JSONDecoder().decode(RefineResponse.self, from: readyLine),
           let error = response.error {
            throw SummarizerError.helperFailed(error)
        }
        throw SummarizerError.helperFailed("Refine helper failed to start.\(stderrSuffix())")
    }

    private func readLine(timeout: TimeInterval) throws -> Data {
        let watchdogProcess = process
        let watchdog = DispatchWorkItem { watchdogProcess?.terminate() }
        DispatchQueue.global().asyncAfter(deadline: .now() + timeout, execute: watchdog)
        defer { watchdog.cancel() }

        while true {
            if let line = DictationWireProtocol.takeLine(&stdoutBuffer) {
                guard Self.isProtocolMessage(line) else {
                    appendStderr("helper stdout: \(String(decoding: line, as: UTF8.self))\n")
                    continue
                }
                return line
            }
            guard let stdout else {
                throw SummarizerError.helperFailed("Refine helper is not running.")
            }
            let chunk = stdout.availableData
            if chunk.isEmpty {
                throw SummarizerError.helperFailed(
                    "Refine helper stopped unexpectedly.\(stderrSuffix())")
            }
            stdoutBuffer.append(chunk)
        }
    }

    private static func isProtocolMessage(_ line: Data) -> Bool {
        line.first(where: { $0 != 0x20 && $0 != 0x09 && $0 != 0x0D }) == 0x7B // "{"
    }

    private func appendStderr(_ text: String) {
        stderrLock.lock(); stderrText += text; stderrLock.unlock()
    }

    private func resetStderr() {
        stderrLock.lock(); stderrText = ""; stderrLock.unlock()
    }

    private func stderrSuffix() -> String {
        stderrLock.lock()
        let text = stderrText.trimmingCharacters(in: .whitespacesAndNewlines)
        stderrLock.unlock()
        return text.isEmpty ? "" : "\n\(text.suffix(2_000))"
    }

    private func clearProcessState() {
        try? stdin?.close()
        if let process, process.isRunning {
            process.terminate()
            let pid = process.processIdentifier
            let forceStop = DispatchWorkItem {
                if process.isRunning { _ = Darwin.kill(pid, SIGKILL) }
            }
            DispatchQueue.global().asyncAfter(deadline: .now() + 5, execute: forceStop)
            process.waitUntilExit()
            forceStop.cancel()
        }
        process = nil
        stdin = nil
        stdout = nil
        stdoutBuffer.removeAll()
        stderrHandle?.readabilityHandler = nil
        stderrHandle = nil
        liveLock.lock()
        liveProcess = nil
        liveStdin = nil
        liveLock.unlock()
    }
}
```

- [ ] **Step 6.4: Verify pass** (filter `SummarizerRuntimeRefine`; plus `swift build` compiles the engine).
- [ ] **Step 6.5: Commit** — `git commit -m "feat(dictation): WarmRefineEngine resident host + SummarizerRuntime refine paths (F200)"`

---

### Task 7: `refine_server.py` + install plumbing

**Files:**
- Create: `Scripts/refine_server.py`
- Modify: `Scripts/build-app.sh` (bundle the helper)
- Modify: `Scripts/setup-local-summarizer.sh` (fresh installs carry it)
- Modify: `Sources/WhisperMeet/Dictation/DictationController.swift` (`ensureHelperInstalled` also syncs it — self-heals existing installs at launch/enable)

- [ ] **Step 7.1: Write `Scripts/refine_server.py`**

```python
# Scripts/refine_server.py
"""Resident mlx_lm helper for WhisperMeet dictation refinement (F200).

Loads the Summarizer-runtime Qwen model once, then serves newline-delimited JSON requests on
stdin and writes newline-delimited JSON responses on stdout. Sibling of whisper_dictate_server.py
(the framing) and correct_local.py (the model/venv). Local-only: the app launches it with
HF_HUB_OFFLINE=1 / TRANSFORMERS_OFFLINE=1 so the pinned snapshot can never be re-fetched at
inference time. Exits cleanly when stdin closes (the app terminates it to evict the model).

Wire: request  {"text": str, "systemPrompt": str, "maxTokens": int}
      response {"text": str} | {"error": str}
Every stdout line is a JSON object; anything else would desync the stream (see
WarmWhisperDictationEngine.isProtocolMessage).
"""
import argparse
import json
import re
import sys

_THINK_RE = re.compile(r"<think>.*?</think>", re.DOTALL | re.IGNORECASE)


def apply_chat_template(tokenizer, messages):
    """Apply the model's chat template with thinking disabled (we want the answer, not the trace)."""
    try:
        return tokenizer.apply_chat_template(
            messages, add_generation_prompt=True, enable_thinking=False
        )
    except TypeError:
        return tokenizer.apply_chat_template(messages, add_generation_prompt=True)


def generate(model, tokenizer, stream_generate, sampler, system_prompt, text, max_tokens):
    prompt = apply_chat_template(tokenizer, [
        {"role": "system", "content": system_prompt},
        {"role": "user", "content": text},
    ])
    pieces = []
    for response in stream_generate(
        model, tokenizer, prompt, max_tokens=max_tokens, sampler=sampler
    ):
        pieces.append(response.text)
    return _THINK_RE.sub("", "".join(pieces)).strip()


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--model", required=True)
    args = parser.parse_args()

    from mlx_lm import load, stream_generate
    from mlx_lm.sample_utils import make_sampler

    model, tokenizer = load(args.model)
    sampler = make_sampler(temp=0.0)  # greedy: a cleanup should be reproducible, not sampled.

    # Pre-warm with a real (tiny) generation so the first user request pays no kernel-compile
    # cost; only after this returns is {"ready": true} genuinely resident.
    try:
        generate(model, tokenizer, stream_generate, sampler,
                 "Reply with exactly the word: ready", "ready", 8)
    except Exception as error:  # pragma: no cover - warm failure is fatal to the helper
        sys.stdout.write(json.dumps({"error": "warm-up failed: " + str(error)}) + "\n")
        sys.stdout.flush()
        return 1

    sys.stdout.write(json.dumps({"ready": True}) + "\n")
    sys.stdout.flush()

    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            request = json.loads(line)
            text = generate(
                model, tokenizer, stream_generate, sampler,
                request.get("systemPrompt") or "",
                request.get("text") or "",
                int(request.get("maxTokens") or 256),
            )
            response = {"text": text}
        except Exception as error:  # never crash the daemon on one bad request
            response = {"error": str(error)}
        sys.stdout.write(json.dumps(response) + "\n")
        sys.stdout.flush()
    return 0


if __name__ == "__main__":
    sys.exit(main())
```

- [ ] **Step 7.2: `build-app.sh`** — after the `correct_local.py` copy (line 32), add:

```bash
cp "Scripts/refine_server.py" "$app_dir/Contents/Resources/refine_server.py"
```

- [ ] **Step 7.3: `setup-local-summarizer.sh`** — mirror the `correct_local.py` lines exactly:
  - beside `correction_helper_source=` add `refine_helper_source="$script_directory/refine_server.py"`
  - beside the correction-helper missing check add the same check for the refine helper
  - beside the staging `cp`/`chmod 644` for `correct_local.py` add the same for `refine_server.py`
  - beside the `--help` smoke test add `"$staging_directory/venv/bin/python" "$staging_directory/refine_server.py" --help >/dev/null`

- [ ] **Step 7.4: `DictationController.ensureHelperInstalled` self-heal** — replace the body's first lines:

```swift
    private func ensureHelperInstalled() {
        let files = FileManager.default
        var helpers = Self.bundledDictationHelpers(fileManager: files)
        helpers.append(Self.bundledRefineHelper(fileManager: files))
        for (helper, outcome) in zip(helpers, DictationHelperSync.sync(helpers, fileManager: files)) {
```

and add beside `bundledDictationHelpers`:

```swift
    /// The F200 refine helper rides the same F25 helper-sync so an existing Summarizer install
    /// (which predates `refine_server.py`) self-heals at launch/enable instead of demanding a
    /// reinstall. `DictationHelperSync.sync` is engine-agnostic: an absent runtime is skipped,
    /// never created.
    private static func bundledRefineHelper(
        fileManager files: FileManager
    ) -> DictationHelperSync.Helper {
        DictationHelperSync.Helper(
            name: "refine_server",
            bundledData: Bundle.main.url(forResource: "refine_server", withExtension: "py")
                .flatMap { try? Data(contentsOf: $0) },
            installedScript: SummarizerRuntime.refineHelperScript(),
            runtimeInstalled: files.isExecutableFile(
                atPath: SummarizerRuntime.pythonExecutable().path
            )
        )
    }
```

- [ ] **Step 7.5: Sanity + commit**

```bash
python3 -m py_compile Scripts/refine_server.py && zsh -n Scripts/setup-local-summarizer.sh && zsh -n Scripts/build-app.sh
```
Then: `git commit -m "feat(dictation): refine_server.py resident helper + bundle/install/sync plumbing (F200)"`

---

### Task 8: Persisted log schema — `DictationLogEntry.rawText`/`refinement`

**Files:**
- Modify: `Sources/WhisperCore/DictationLog.swift`
- Modify: `Sources/WhisperMeet/Dictation/DictationLogStore.swift` (`record` gains optional params)
- Test: `Tests/WhisperCoreTests/DictationLogSchemaTests.swift`

- [ ] **Step 8.1: Failing tests (fixtures in BOTH directions — F188 rule)**

```swift
import Foundation
import Testing
@testable import WhisperCore

/// The shape every already-shipped build reads/writes (fields as of F187).
private struct ShippedEntry: Codable {
    let id: UUID
    let date: Date
    let text: String
    let outcome: DictationLogEntry.Outcome
}

@Test("An old-format log entry (no refinement fields) decodes with nils")
func oldEntryDecodesForward() throws {
    let fixture = #"{"id":"3E3269A2-4E5B-4B0A-9A2E-111111111111","date":700000000,"text":"hello","outcome":{"pasted":{}}}"#
    let entry = try JSONDecoder().decode(DictationLogEntry.self, from: Data(fixture.utf8))
    #expect(entry.text == "hello")
    #expect(entry.rawText == nil)
    #expect(entry.refinement == nil)
}

@Test("A new-format entry still decodes in the shipped shape (backward direction)")
func newEntryDecodesBackward() throws {
    let entry = DictationLogEntry(
        id: UUID(), date: Date(), text: "Hello.", outcome: .pasted,
        rawText: "hello", refinement: DictationRefinement.refined.rawValue
    )
    let data = try JSONEncoder().encode(entry)
    let shipped = try JSONDecoder().decode(ShippedEntry.self, from: data)
    #expect(shipped.text == "Hello.")
}

@Test("New fields round-trip")
func newFieldsRoundTrip() throws {
    let entry = DictationLogEntry(
        id: UUID(), date: Date(), text: "Hello.", outcome: .clipboard,
        rawText: "um hello", refinement: "rawTimeout"
    )
    let decoded = try JSONDecoder().decode(
        DictationLogEntry.self, from: JSONEncoder().encode(entry))
    #expect(decoded == entry)
}
```

(Adjust the old-format fixture's `outcome` encoding to what the synthesized `Codable` actually emits — verify by printing `String(data: try JSONEncoder().encode(DictationLogEntry(id:…, outcome: .pasted)), encoding: .utf8)` in a scratch test first; use that exact shape in the fixture string.)

- [ ] **Step 8.2: Verify failure**, **Step 8.3: Implement**

`DictationLog.swift` — extend the struct (append-only optional fields; shipped builds ignore unknown keys and new builds decode absent keys as nil):

```swift
    public let id: UUID
    public let date: Date
    public let text: String
    public let outcome: Outcome
    /// The pre-refinement transcript, recorded only when an F200 refine attempt ran and changed
    /// the delivered text. Optional + append-only per the persisted-schema rules.
    public let rawText: String?
    /// `DictationRefinement.rawValue` for the attempt, or nil when refinement was off/not attempted.
    /// A plain String on the wire (never the enum) so unknown future values decode leniently.
    public let refinement: String?

    public init(
        id: UUID,
        date: Date,
        text: String,
        outcome: Outcome,
        rawText: String? = nil,
        refinement: String? = nil
    ) {
        self.id = id
        self.date = date
        self.text = text
        self.outcome = outcome
        self.rawText = rawText
        self.refinement = refinement
    }
```

`DictationLogStore.swift`:

```swift
    func record(
        text: String,
        outcome: DictationLogEntry.Outcome,
        rawText: String? = nil,
        refinement: String? = nil
    ) {
        guard health.allowsMutation else { return }
        log = log.adding(DictationLogEntry(
            id: UUID(), date: Date(), text: text, outcome: outcome,
            rawText: rawText, refinement: refinement
        ))
        persist()
    }
```

- [ ] **Step 8.4: Verify pass** (filter `DictationLogSchema`) and run the FULL suite — the schema change must not break existing log tests.
- [ ] **Step 8.5: Commit** — `git commit -m "feat(dictation): log records raw transcript and refinement outcome — optional wire fields + two-direction fixtures (F200)"`

---

### Task 9: Overlay `Polishing…` phase + controller wiring

**Files:**
- Modify: `Sources/WhisperMeet/Dictation/DictationOverlay.swift`
- Modify: `Sources/WhisperMeet/Dictation/DictationController.swift`
- Test: `Tests/WhisperMeetTests/DictationRefinementWiringTests.swift`
- Modify: `Tests/WhisperMeetTests/DictationTestSupport.swift` (add `FakeRefiner`)

- [ ] **Step 9.1: Overlay phase (small, no test harness for views — mechanical)**

In `DictationOverlay.Phase`: `case listening, transcribing, refining, done, copied, empty, error, busy`.
Icon switch: `case .refining: ProgressView().controlSize(.small).tint(.white)` (beside `.transcribing`).
Label switch: `case .refining: "Polishing…"`.

- [ ] **Step 9.2: Add `FakeRefiner` to `DictationTestSupport.swift`**

```swift
/// Counts calls and returns a scripted attempt so wiring tests can drive every refine outcome
/// without a model. Lock-guarded: the controller calls it from a background Task.
final class FakeRefiner: DictationTextRefining, @unchecked Sendable {
    private let lock = NSLock()
    private var _attemptCount = 0
    private var _warmUpCount = 0
    private var _shutdownCount = 0
    /// nil → echo the input as `.skipped`; set to script a specific outcome.
    var scripted: RefineAttempt?
    var attemptCount: Int { lock.withLock { _attemptCount } }
    var warmUpCount: Int { lock.withLock { _warmUpCount } }
    var shutdownCount: Int { lock.withLock { _shutdownCount } }

    func warmUp() async { lock.withLock { _warmUpCount += 1 } }
    func attempt(text: String, languageCode: String?) async -> RefineAttempt {
        lock.withLock { _attemptCount += 1 }
        return lock.withLock { scripted } ?? RefineAttempt(text: text, outcome: .skipped)
    }
    func shutdown() { lock.withLock { _shutdownCount += 1 } }
}

/// A dictation engine that returns a fixed transcript, for refine wiring tests.
struct FixedTextDictationEngine: DictationEngine {
    let text: String
    func warmUp() async throws {}
    func transcribe(
        wavAt url: URL, language: WhisperLanguage, initialPrompt: String?
    ) async throws -> DictationResult {
        DictationResult(text: text, languageCode: "en")
    }
    func shutdown() {}
}
```

- [ ] **Step 9.3: Failing wiring tests**

Every test builds the controller headlessly (the `DictationToggleRecoveryTests` pattern): fresh `UserDefaults` suite, temp directory, `FakeDictationRecorder`, `SilentDictationOverlay`, `FakeHotkeyMonitor`, `activateOnInit: false`, `dictationAutoPaste=false` (clipboard-only delivery — no Accessibility). Drive edges via `monitor.onPressStart?()` / `monitor.onPressEnd?()`; wait by polling `controller.logStore.log.entries`.

```swift
import Foundation
import Testing
import WhisperCore
@testable import WhisperMeet

@MainActor
private func makeController(
    engineText: String,
    refiner: FakeRefiner,
    defaults: UserDefaults,
    directory: URL,
    refineEnabled: Bool,
    runtimeAvailable: Bool = true,
    idleEvictSeconds: TimeInterval = 300
) -> (DictationController, FakeHotkeyMonitor) {
    defaults.set(true, forKey: "dictationEnabled")
    defaults.set(false, forKey: "dictationAutoPaste")
    defaults.set(refineEnabled, forKey: "dictationRefineEnabled")
    let monitor = FakeHotkeyMonitor()
    let controller = DictationController(
        defaults: defaults,
        engine: FixedTextDictationEngine(text: engineText),
        recorder: FakeDictationRecorder(outputURL: directory.appendingPathComponent("c.wav")),
        overlay: SilentDictationOverlay(),
        hotkeyMonitor: monitor,
        logStore: DictationLogStore(directory: directory),
        captureSleep: { _ in try await Task.sleep(for: .seconds(3600)) },
        refiner: refiner,
        idleEvictSeconds: idleEvictSeconds,
        activateOnInit: false
    )
    controller.refineRuntimeAvailability = { runtimeAvailable }
    return (controller, monitor)
}

@MainActor
private func dictateOnce(_ monitor: FakeHotkeyMonitor, _ controller: DictationController) async throws {
    monitor.onPressStart?()
    try await Task.sleep(for: .milliseconds(20))
    monitor.onPressEnd?()
    for _ in 0..<200 where controller.logStore.log.entries.isEmpty {
        try await Task.sleep(for: .milliseconds(10))
    }
}

@MainActor
@Test("Refine off: the refiner is never consulted and raw text is delivered")
func refineOffNeverTouchesRefiner() async throws { /* setup per makeController(refineEnabled: false) */
    // …build, dictateOnce, then:
    // #expect(refiner.attemptCount == 0)
    // #expect(controller.logStore.log.entries.first?.text == "hello there")
    // #expect(controller.logStore.log.entries.first?.refinement == nil)
}

@MainActor
@Test("Refine on + refined outcome: refined text is delivered; log keeps the raw transcript")
func refinedTextDeliveredAndLogged() async throws {
    // refiner.scripted = RefineAttempt(text: "Hello there.", outcome: .refined)
    // after dictateOnce:
    // entry.text == "Hello there.", entry.rawText == "hello there",
    // entry.refinement == "refined", refiner.attemptCount == 1
}

@MainActor
@Test("Refine on + timeout outcome: raw is delivered and the outcome recorded")
func timeoutDeliversRaw() async throws {
    // refiner.scripted = RefineAttempt(text: "hello there", outcome: .rawTimeout)
    // entry.text == "hello there", entry.rawText == nil, entry.refinement == "rawTimeout"
}

@MainActor
@Test("Refine on but runtime unavailable: the refiner is never consulted")
func unavailableRuntimeSkips() async throws {
    // runtimeAvailable: false → refiner.attemptCount == 0, entry.refinement == nil
}

@MainActor
@Test("Press-down prewarms the refiner only when the toggle is on and the runtime is present")
func pressDownPrewarms() async throws {
    // refineEnabled true → after onPressStart + small sleep: warmUpCount >= 1
    // refineEnabled false (fresh controller) → warmUpCount == 0
}

@MainActor
@Test("Disabling dictation and turning the toggle off both shut the refiner down")
func shutdownPaths() async throws {
    // controller.setEnabled(false) → shutdownCount >= 1
    // fresh controller: controller.refineEnabled = false (from true) → shutdownCount >= 1
}

@MainActor
@Test("Idle eviction shuts the refiner down alongside the whisper model")
func idleEvictionShutsRefinerDown() async throws {
    // idleEvictSeconds: 0.05; after a delivery, wait ~1.4s (1.1s dismiss + eviction):
    // poll until refiner.shutdownCount >= 1
}
```

(Write the bodies out fully when implementing — the comments above are the assertions each must make; the helpers make each body ~10 lines.)

- [ ] **Step 9.4: Verify failure** — compile errors: `refiner:`/`idleEvictSeconds:` init params and `refineEnabled`/`refineRuntimeAvailability` don't exist.

- [ ] **Step 9.5: Implement controller changes** (`DictationController.swift`)

1. Properties (after `useVocabulary`):

```swift
    /// F200: opt-in local-AI cleanup of dictated text before delivery. Off by default — the
    /// documented "local-instant feel" stays untouched unless the user chooses the trade.
    @Published var refineEnabled: Bool { didSet { persist(); applyRefineSetting() } }
    /// Injectable so headless tests can simulate runtime presence; the default asks the real
    /// Summarizer runtime. Read directly by the Settings UI on each render.
    var refineRuntimeAvailability: () -> Bool = {
        SummarizerRuntime.isSupportedOnCurrentMac && SummarizerRuntime.isRefineHelperInstalled()
    }
    var isRefineRuntimeInstalled: Bool { refineRuntimeAvailability() }
    private let refiner: any DictationTextRefining
```

2. Key: `private static let refineEnabledKey = "dictationRefineEnabled"`; in `persist()`: `defaults.set(refineEnabled, forKey: Self.refineEnabledKey)`.

3. Init: parameters `refiner: (any DictationTextRefining)? = nil` and `idleEvictSeconds: TimeInterval = 300` (replace `private static let idleEvictSeconds` with `private let idleEvictSeconds: TimeInterval`, update the one `Self.idleEvictSeconds` use). Assign before `enabled`:

```swift
        self.idleEvictSeconds = idleEvictSeconds
        self.refiner = refiner ?? DictationRefiner(
            engine: WarmRefineEngine(
                python: SummarizerRuntime.pythonExecutable(),
                script: SummarizerRuntime.refineHelperScript(),
                modelDirectory: SummarizerRuntime.modelDirectory()
            )
        )
        refineEnabled = defaults.object(forKey: Self.refineEnabledKey) as? Bool ?? false
```

4. Setting reaction + prewarm:

```swift
    private func applyRefineSetting() {
        if refineEnabled {
            prewarmRefinerIfNeeded()
        } else {
            refiner.shutdown()
        }
    }

    /// Free speed: fire the model load while the user is still speaking (press-down), so a warm
    /// refiner answers inside the budget by the time the transcript exists.
    private func prewarmRefinerIfNeeded() {
        guard enabled, refineEnabled, refineRuntimeAvailability() else { return }
        Task { [refiner] in await refiner.warmUp() }
    }
```

5. `handlePressStart()` `.startCapture` case: `case .startCapture: startCapture(); prewarmRefinerIfNeeded()`.

6. `transcribe(clip:)` — capture the decision with the other snapshots and thread the attempt through:

```swift
        let refineOn = refineEnabled && refineRuntimeAvailability()
```

and inside the Task, replacing the `finish` hop:

```swift
                var rawText: String?
                var refinement: String?
                if refineOn, !cleaned.isEmpty {
                    await MainActor.run { if self.enabled { self.overlay.show(.refining) } }
                    let attempt = await self.refiner.attempt(
                        text: cleaned, languageCode: result.languageCode)
                    refinement = attempt.outcome.rawValue
                    if attempt.outcome == .refined {
                        rawText = cleaned
                        cleaned = attempt.text
                    }
                }
                log.notice("\(selection.rawValue, privacy: .public) transcribed in \(Date().timeIntervalSince(started), format: .fixed(precision: 2))s")
                await MainActor.run {
                    self.finish(text: cleaned, rawText: rawText, refinement: refinement)
                }
```

(`Task { [engine, log] in` becomes `Task { [engine, log, refiner] in` — capture unused warning is avoided because the closure body references `self.refiner`; capture `refineOn` implicitly.)

7. `finish` signature + record:

```swift
    private func finish(text: String, rawText: String? = nil, refinement: String? = nil) {
        …
            logStore.record(
                text: payload,
                outcome: delivery == .pasted ? .pasted : .clipboard,
                rawText: rawText,
                refinement: refinement
            )
```

8. Shutdown paths — add `refiner.shutdown()` beside `engine.shutdown()` in: `apply()`'s disable branch, `deinit`, and `scheduleIdleEviction`'s work item.

- [ ] **Step 9.6: Run the wiring tests to green**, then the FULL suite (`swift test` via the CLT flags). Expected: all pass, count did not drop.
- [ ] **Step 9.7: Commit** — `git commit -m "feat(dictation): refine wiring — toggle, prewarm on press, budget attempt before delivery, Polishing pill (F200)"`

---

### Task 10: Settings UI

**Files:**
- Modify: `Sources/WhisperMeet/ContentView.swift` (after the vocabulary toggle, ~line 1442's block)

- [ ] **Step 10.1: Add the toggle**

```swift
                Toggle("Refine with local AI (grammar cleanup)", isOn: $dictation.refineEnabled)
                    .disabled(!dictation.isRefineRuntimeInstalled)
                if !dictation.isRefineRuntimeInstalled {
                    Text(SummarizerRuntime.isSupportedOnCurrentMac
                        ? "Requires the local AI model — install or update it in the Summaries settings."
                        : "Requires an Apple silicon Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if dictation.refineEnabled {
                    Text("Fixes grammar, punctuation, and filler words before pasting. If the model can't answer within about a second, the raw transcript is pasted instead. Keeps the local AI model in memory while dictation is warm (about 2–5 GB).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
```

- [ ] **Step 10.2: Build, run, verify manually** (`swift build`, then `Scripts/install-app.sh` at the end of the branch — manual GUI verification is stated in the ticket log; the `WhisperMeet` target has no view-render harness, "Not planned:").
- [ ] **Step 10.3: Commit** — `git commit -m "feat(ui): dictation refine toggle with availability gating and honest RAM/latency copy (F200)"`

---

### Task 11: Real-model verification (Definition-of-done requirement)

**Files:** none (evidence for the ticket log)

- [ ] **Step 11.1: Stage the helper exactly as helper-sync would**

```bash
cp Scripts/refine_server.py ~/Library/Application\ Support/WhisperMeet/Runtime/Summarizer/refine_server.py
```

- [ ] **Step 11.2: Drive the resident server end-to-end with real requests, measuring latency**

```bash
PY=~/Library/Application\ Support/WhisperMeet/Runtime/Summarizer/venv/bin/python
DIR=~/Library/Application\ Support/WhisperMeet/Runtime/Summarizer
python3 - <<'EOF'
import json, subprocess, time, os
home = os.path.expanduser("~/Library/Application Support/WhisperMeet/Runtime/Summarizer")
proc = subprocess.Popen(
    [f"{home}/venv/bin/python", f"{home}/refine_server.py", "--model", f"{home}/model"],
    stdin=subprocess.PIPE, stdout=subprocess.PIPE, text=True,
    env={**os.environ, "HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1", "PYTHONUNBUFFERED": "1"})
t0 = time.time(); print("ready:", proc.stdout.readline().strip(), f"{time.time()-t0:.1f}s")
SYSTEM = "You clean up text that a person dictated by voice. Correct grammar, punctuation, capitalization, and obvious speech-to-text mistakes, and remove filler words such as \"um\", \"uh\", and \"you know\". Keep the speaker's wording, sentence order, and meaning exactly: do not rephrase, do not summarize, do not add content, and do not answer the text as if it were a question. Reply in the same language as the input; never translate. Reply with ONLY the corrected text — no quotation marks around it, no explanation, no markdown."
for text in [
    "um so i think we should uh probably go with the the second option you know",
    "can you send me the report before tomorrow morning",
    "我们明天九点开会 然后 那个 讨论一下新方案",
]:
    req = {"text": text, "systemPrompt": SYSTEM, "maxTokens": 256}
    t0 = time.time(); proc.stdin.write(json.dumps(req) + "\n"); proc.stdin.flush()
    line = proc.stdout.readline(); dt = time.time() - t0
    print(f"{dt:.2f}s  {json.loads(line)}")
proc.stdin.close(); proc.wait()
EOF
```

Expected: ready within ~seconds (warm disk cache), each short request answering **within its policy budget** (≤ ~1.2 s for these lengths on the 8B model), output = light-touch cleanup in the same language. If a request systematically misses its budget on this machine, revisit the policy constants (that is a design-review trigger, not a silent tweak — record it).

- [ ] **Step 11.3: Confirm guardrail behavior on the real outputs** — feed each real reply through `DictationRefinePolicy.acceptedOutput` expectations mentally/in a scratch test; every reply above must be accepted.

---

### Task 12: Docs, gate, close, merge

**Files:**
- Modify: `docs/QUICK_DICTATION_DESIGN.md` (Non-goals/Deferred lines)
- Modify: `docs/CHANGELOG.md`
- Modify (local-only): `docs/TICKETS.md`, `docs/TICKET_LOG.md`

- [ ] **Step 12.1: Update `QUICK_DICTATION_DESIGN.md`** — in "Non-goals (v1)" annotate the AI-cleanup line: `(shipped later as opt-in, time-budgeted local refinement — F200; see docs/superpowers/specs/2026-08-28-dictation-refinement-design.md)`; remove "AI/Claude text cleanup" from the Deferred list. Minimal edits only (F163: a formatter once mangled this file).
- [ ] **Step 12.2: CHANGELOG entry** under a new cycle heading, in the file's existing style.
- [ ] **Step 12.3: Full gate**

```bash
Scripts/quality-check.sh
python3 Scripts/generate-tickets-dashboard.py && python3 Scripts/generate-tickets-dashboard.py --check
```
Expected: build + both suites green, test count strictly higher than before the branch; dashboard check passes.

- [ ] **Step 12.4: Close F200** — move the ticket to `docs/TICKET_LOG.md` with outcome `fixed`, real red-green + real-model output as Evidence, **Reachability:** `Settings → Quick Dictation → "Refine with local AI" toggle → DictationController.refineEnabled → transcribe() → DictationRefiner.attempt → WarmRefineEngine → refine_server.py`, and Gaps (GUI render test "Not planned:" — no view harness; any deferred work gets an F-number).
- [ ] **Step 12.5: Merge** — `git checkout main && git merge --no-ff feat/f200-dictation-refinement` (gate green first).

---

## Self-review (run after writing, fixed inline)

- **Spec coverage:** decisions 1–4 → Tasks 3/5/9/10 (light-touch prompt, budget race, opt-in default-off, reuse installed model); refine server → 7; engine → 6; policy+guardrails → 1/2; controller+prewarm+eviction → 9; settings → 10; log → 8; overlay → 9; real-model + latency → 11; docs/non-goal update → 12. Spec's request-id correlation replaced by the busy-until-complete invariant (documented at top and in `DictationRefiner`).
- **Type consistency:** `DictationTextRefining` (controller seam) vs `DictationRefineEngine` (process seam) used consistently; `RefineAttempt.outcome.rawValue` is the only thing persisted; init params `refiner:`/`idleEvictSeconds:` appear in both Task 9 test helper and controller change list.
- **Placeholders:** Task 9's test bodies are assertion-comment stubs by design (the helpers are fully specified; bodies are mechanical) — the executor must write them out fully, and the expected assertions are stated per test.
