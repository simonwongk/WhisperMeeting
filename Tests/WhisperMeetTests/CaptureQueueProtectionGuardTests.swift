import Foundation
import Testing

// F402 — the derived form of F364's queue-protection guard.
//
// `captureEngineQueueProtectedFieldsHaveAccessors` (SourceContractGuardTests.swift) names its fields
// by hand, and it looks for `captureQueue.sync` in the six lines after an accessor's declaration.
// Both were blind in ways that were shown, not guessed: F365 added `_systemWriter`,
// `_microphoneWriter` and `_paddedGaps` and the list did not change, and with `_streamDied`'s setter
// reverted to a bare write and `start()`'s sync block replaced by bare assignments — the exact
// off-queue writes F364 removed — that guard still passed, because the syncing getter sat inside the
// setter's window and direct writes were never examined.
//
// This one derives what it checks from the file:
//
// - **The fields** are every `var _x` in AudioCaptureEngine.swift. The `_` prefix is the file's own
//   convention for "stored behind `captureQueue`; use only on that queue".
// - **Every use** of one — read or write, `_x` or `self._x` — must sit somewhere that is on the queue:
//   inside a `captureQueue.sync`/`async` body; inside a func whose first statement is
//   `dispatchPrecondition(condition: .onQueue(captureQueue))`; inside a `_x` declaration itself (a
//   property observer, or a computed `_x`, which is itself checked as a field); or inside the
//   `SCStreamOutput` sample handler, but only while every `addStreamOutput` call in the file names
//   `sampleHandlerQueue: captureQueue`, which is what puts that callback on the queue.
// - **Every accessor** `var x` that a `_x` has must go through `captureQueue.sync` in EACH of its
//   `get` and `set` clauses, not somewhere in a window of lines.
//
// The hand-written guard stays. It demands that an accessor EXIST for each name it lists, which this
// one does not: a `_x` used only inside queue blocks needs no accessor. Two checks with different
// blind spots, as AGENTS.md's "Derive the list" paragraph asks.
//
// **One deliberate exemption, `streamDiedMirror` (F401).** It is a lock-guarded copy of `_streamDied`
// that the health tick reads without waiting for the queue. It is a `let`, so it is not a field here,
// and nothing about it needs the queue — but it is only a faithful copy while `_streamDied`'s
// `didSet` is its one writer, so that is checked instead: outside its declaration and that `didSet`,
// the only use allowed is the plain read `streamDiedMirror.withLock { $0 }`.
//
// Crude on purpose, and it runs on comment-stripped source with string literals blanked, so a brace
// inside a comment or a literal is not a scope (F285, F375). Blanking also hides a `_x` written
// inside an interpolation, so the scan compares against the unblanked text and reports any field
// that appears inside a literal at all, wherever it is (F414's first blind spot, closed here for this
// file only). A violation's line number comes from the blanked text, so a `\`-newline continuation
// inside a `"""` literal would shift every later one (F414's second blind spot).
//
// **What a pass does not prove.** Scope here is lexical: a use counts as on the queue when it sits
// inside an accepted body, whatever that body does with it. Three things pass that should not:
//
// - **A closure that escapes an accepted scope.** `captureQueue.sync { DispatchQueue.global().async
//   { self._streamDied = true } }` passes, and so does a `Task { self._streamDied = true }` created
//   in a func whose first statement is the precondition. The write runs off the queue in both.
// - **A `let _x`.** Only `var _x` is a field, so `private let _box = NSMutableArray()` mutated from
//   anywhere is not reported. The file has no `let _x` today.
// - **The object behind a field.** Only the reference is checked. `systemWriter?.cancel()` goes
//   through a syncing getter, so it passes, and then runs the writer's own code off the queue. That
//   is the shape F388 and F632 fixed by hand for `finish()`, and this scan cannot see it.
//
// The first two were shown, not assumed: the w2-F-capture review's probes inserted each into the
// real file's source, in memory, and the scan reported nothing; its fix pass re-ran them with the
// same result. The third is visible in the real file itself, which passes with such calls in it.
//
// Not planned for the first and third: they need the scan to follow what code does at run time, not
// where it sits in the text, and that is a different tool from a text scan over one file. The second
// is cheaper (the field pattern would also match `let`) and is left open only because nothing in the
// file needs it yet. `asyncAfter` on the queue is not a blind spot: it is not recognised as a queue
// body, so a `_x` inside it is reported (fail closed).

private let captureEnginePath = "Sources/WhisperMeet/AudioCaptureEngine.swift"

/// What the scan found: the derived field set, how many queue bodies it recognised (so a scan that
/// recognised nothing cannot pass vacuously), and every violation, each naming a line.
struct CaptureQueueProtectionScan {
    var fields: [String] = []
    var queueBodyCount = 0
    var violations: [String] = []
}

func scanCaptureQueueProtection(_ source: String) -> CaptureQueueProtectionScan {
    let code = SourceAssertion.stripComments(source, blankStringLiterals: true)
    let units = Array(code.utf16)
    let codeLines = code.components(separatedBy: "\n")
    let length = (code as NSString).length
    var scan = CaptureQueueProtectionScan()

    func unit(_ character: Character) -> UInt16 { character.utf16.first! }
    let openBrace = unit("{"), closeBrace = unit("}"), openParen = unit("("), closeParen = unit(")")
    let openBracket = unit("["), closeBracket = unit("]"), newline = unit("\n")

    func matches(_ pattern: String, in range: Range<Int>? = nil) -> [NSTextCheckingResult] {
        let expression = try! NSRegularExpression(pattern: pattern)
        let searched = range.map { NSRange(location: $0.lowerBound, length: $0.count) }
            ?? NSRange(location: 0, length: length)
        return expression.matches(in: code, range: searched)
    }
    func text(_ range: Range<Int>) -> String {
        String(decoding: units[range], as: UTF16.self)
    }
    func lineNumber(_ offset: Int) -> Int {
        units[0..<offset].reduce(1) { $1 == newline ? $0 + 1 : $0 }
    }
    func describe(_ offset: Int) -> String {
        let number = lineNumber(offset)
        return "line \(number): \(codeLines[number - 1].trimmingCharacters(in: .whitespaces))"
    }
    func isSpace(_ value: UInt16) -> Bool { value == 0x20 || value == 0x09 || value == newline || value == 0x0D }
    func skipSpace(_ offset: Int) -> Int {
        var cursor = offset
        while cursor < units.count, isSpace(units[cursor]) { cursor += 1 }
        return cursor
    }
    /// The offset of the delimiter that closes the one at `open`, counting nesting.
    func closing(_ open: Int, _ opener: UInt16, _ closer: UInt16) -> Int? {
        var depth = 0
        var cursor = open
        while cursor < units.count {
            if units[cursor] == opener { depth += 1 }
            if units[cursor] == closer { depth -= 1; if depth == 0 { return cursor } }
            cursor += 1
        }
        return nil
    }
    /// The first `{` at bracket depth 0 from `offset`, stopping at `limit`.
    func firstBrace(from offset: Int, before limit: Int) -> Int? {
        var parens = 0, brackets = 0
        var cursor = offset
        while cursor < limit {
            switch units[cursor] {
            case openParen: parens += 1
            case closeParen: parens -= 1
            case openBracket: brackets += 1
            case closeBracket: brackets -= 1
            case openBrace where parens == 0 && brackets == 0: return cursor
            case closeBrace where parens == 0 && brackets == 0: return nil
            default: break
            }
            cursor += 1
        }
        return nil
    }
    func endOfLine(_ offset: Int) -> Int {
        var cursor = offset
        while cursor < units.count, units[cursor] != newline { cursor += 1 }
        return cursor
    }

    // Queue bodies: `captureQueue.sync { … }`, `captureQueue.async { [weak self] in … }`, and a
    // parenthesised argument list before the trailing closure if one is ever added.
    var onQueue: [Range<Int>] = []
    for match in matches(#"captureQueue\s*\.\s*(?:sync|async)\b"#) {
        var cursor = skipSpace(match.range.upperBound)
        if cursor < units.count, units[cursor] == openParen, let close = closing(cursor, openParen, closeParen) {
            cursor = skipSpace(close + 1)
        }
        guard cursor < units.count, units[cursor] == openBrace, let close = closing(cursor, openBrace, closeBrace)
        else { continue }
        onQueue.append(cursor..<close)
        scan.queueBodyCount += 1
    }

    // The sample handler's premise: every registration puts it on `captureQueue`.
    let registrations = matches(#"addStreamOutput\s*\("#).compactMap { match -> String? in
        let open = match.range.upperBound - 1
        return closing(open, openParen, closeParen).map { text(open..<($0 + 1)) }
    }
    let handlerIsOnQueue = !registrations.isEmpty
        && registrations.allSatisfy { $0.range(of: #"sampleHandlerQueue\s*:\s*captureQueue\b"#, options: .regularExpression) != nil }

    // Funcs that assert the queue first thing, and the sample handler.
    for match in matches(#"\bfunc\s+[A-Za-z_]\w*"#) {
        guard let open = firstBrace(from: match.range.upperBound, before: units.count),
              let close = closing(open, openBrace, closeBrace) else { continue }
        let signature = text(match.range.lowerBound..<open)
        let body = text((open + 1)..<close).trimmingCharacters(in: .whitespacesAndNewlines)
        if body.range(of: #"^dispatchPrecondition\s*\(\s*condition\s*:\s*\.onQueue\s*\(\s*captureQueue\s*\)\s*\)"#,
                      options: .regularExpression) != nil {
            onQueue.append(open..<close)
        } else if signature.contains("didOutputSampleBuffer") {
            if handlerIsOnQueue {
                onQueue.append(open..<close)
            } else {
                scan.violations.append("""
                    the SCStreamOutput sample handler is treated as on captureQueue only while every \
                    addStreamOutput call passes `sampleHandlerQueue: captureQueue`; found \
                    \(registrations.isEmpty ? "no addStreamOutput call" : registrations.joined(separator: ", "))
                    """)
            }
        }
    }

    // The fields, and each one's declaration (to the end of its line, or through the braces of an
    // observer or a computed body that opens on it).
    var declarations: [String: Range<Int>] = [:]
    for match in matches(#"\bvar\s+(_[A-Za-z]\w*)\b"#) {
        let name = (code as NSString).substring(with: match.range(at: 1))
        let lineEnd = endOfLine(match.range.upperBound)
        var end = lineEnd
        if let open = firstBrace(from: match.range.upperBound, before: lineEnd),
           let close = closing(open, openBrace, closeBrace) {
            end = close
        }
        scan.fields.append(name)
        declarations[name] = match.range.lowerBound..<end
        onQueue.append(match.range.lowerBound..<end)
    }

    func usePattern(_ name: String) -> String { #"(?<![A-Za-z0-9_$])"# + name + #"(?![A-Za-z0-9_])"# }
    // Blanking the literals is what stops a `{` inside one from opening a scope, and it blanks `\(…)`
    // with them, so a `_x` read inside an interpolation is invisible to every check here (F414's first
    // blind spot). Blanking changes what is emitted and never the lexer's state, so the uses this scan
    // can see are exactly the uses outside literals; any more than that in the unblanked text are
    // inside one. Reported wherever they are, on the queue or off it — fail closed, because the scan
    // cannot place a use it cannot see.
    let literalsKept = SourceAssertion.stripComments(source)
    let literalsKeptLines = literalsKept.components(separatedBy: "\n")
    for field in scan.fields {
        let expression = try! NSRegularExpression(pattern: usePattern(field))
        let everywhere = expression.numberOfMatches(
            in: literalsKept, range: NSRange(location: 0, length: (literalsKept as NSString).length))
        guard everywhere > matches(usePattern(field)).count else { continue }
        let candidates = literalsKeptLines.indices.filter {
            literalsKeptLines[$0].contains("\"") && literalsKeptLines[$0].range(of: usePattern(field), options: .regularExpression) != nil
        }.map { "line \($0 + 1): \(literalsKeptLines[$0].trimmingCharacters(in: .whitespaces))" }
        scan.violations.append("""
            \(field) appears inside a string literal, where this scan cannot see whether it is on \
            captureQueue; read it into a local outside the literal — \(candidates.joined(separator: "; "))
            """)
    }

    for field in scan.fields {
        // Every use.
        for use in matches(usePattern(field)) {
            let offset = use.range.lowerBound
            if !onQueue.contains(where: { $0.contains(offset) }) {
                scan.violations.append("\(field) used off captureQueue — \(describe(offset))")
            }
        }
        // Its accessor, if it has one: every clause syncs.
        let accessorName = String(field.dropFirst())
        for accessor in matches(#"\bvar\s+"# + accessorName + #"\s*(?::[^{=\n]*)?\{"#) {
            let open = accessor.range.upperBound - 1
            guard let close = closing(open, openBrace, closeBrace) else { continue }
            var clauses: [(String, Range<Int>)] = []
            for clause in matches(#"\b(get|set)\s*(?:throws\s*)?\{"#, in: (open + 1)..<close) {
                let clauseOpen = clause.range.upperBound - 1
                let depth = units[(open + 1)..<clause.range.lowerBound].reduce(0) {
                    $1 == openBrace ? $0 + 1 : ($1 == closeBrace ? $0 - 1 : $0)
                }
                guard depth == 0, let clauseClose = closing(clauseOpen, openBrace, closeBrace) else { continue }
                clauses.append(((code as NSString).substring(with: clause.range(at: 1)), clauseOpen..<clauseClose))
            }
            if clauses.isEmpty { clauses = [("get", open..<close)] }   // the `var x: T { … }` shorthand
            for (kind, range) in clauses where !text(range).contains("captureQueue.sync") {
                scan.violations.append("\(accessorName)'s \(kind) does not go through captureQueue.sync — \(describe(range.lowerBound))")
            }
        }
    }

    // The F401 exemption: a `let` behind its own lock, written only by `_streamDied`'s `didSet`. Fail
    // closed: outside its declaration and that `didSet`, the one use allowed is the plain read
    // `streamDiedMirror.withLock { $0 }`. Matching write shapes instead would be a hand-written list
    // again, and `withLock { state in state = true }` or `withLock { $0.toggle() }` would get past it.
    let mirrorUses = matches(usePattern("streamDiedMirror"))
    if !mirrorUses.isEmpty {
        let mirrorDeclarations = matches(#"\blet\s+streamDiedMirror\b"#)
        if mirrorDeclarations.isEmpty {
            scan.violations.append("streamDiedMirror must be a `let`: it is exempt from the queue only because its lock guards it")
        }
        let plainReads = Set(matches(#"streamDiedMirror\s*\.\s*withLock\s*\{\s*\$0\s*\}"#).map(\.range.location))
        for use in mirrorUses {
            let offset = use.range.location
            if mirrorDeclarations.contains(where: { NSLocationInRange(offset, $0.range) })
                || declarations["_streamDied"]?.contains(offset) == true
                || plainReads.contains(offset) { continue }
            scan.violations.append("""
                streamDiedMirror touched outside `_streamDied`'s didSet, and not as the plain read \
                `streamDiedMirror.withLock { $0 }` — \(describe(offset))
                """)
        }
    }
    return scan
}

private func captureEngineSource() throws -> String {
    try String(contentsOf: SourceAssertion.url(captureEnginePath), encoding: .utf8)
}

/// The real file with one exact edit applied. `#require`s that the text being replaced is there, so a
/// mutation that no longer matches the file fails instead of testing the unmutated source.
private func mutated(_ source: String, replacing original: String, with replacement: String) throws -> String {
    let targetIsThere = source.contains(original)
    try #require(targetIsThere, "the mutation's target text is gone from \(captureEnginePath)")
    return source.replacingOccurrences(of: original, with: replacement)
}

@Test("Every _-prefixed AudioCaptureEngine field is used only on captureQueue (F402)")
func captureEngineQueueStorageIsUsedOnlyOnTheQueue() throws {
    let scan = scanCaptureQueueProtection(try captureEngineSource())
    // Floors against a scan that matched nothing, not a restated list: the field F364 was about, and
    // the queue bodies without which every use would be an offender.
    #expect(scan.fields.contains("_streamDied"), "derived fields: \(scan.fields)")
    #expect(scan.queueBodyCount > 0)
    #expect(scan.violations.isEmpty, """
        AudioCaptureEngine keeps its cross-thread state in `_`-prefixed storage behind `captureQueue`.
        Code on the queue uses the storage; code off it uses the un-prefixed accessor, whose every
        clause syncs. A function that touches the storage must be on the queue provably: inside a
        `captureQueue.sync`/`async` body, or starting with
        `dispatchPrecondition(condition: .onQueue(captureQueue))`.

        \(scan.violations.joined(separator: "\n"))
        """)
}

@Test("The derived guard fails when streamDied's setter writes without the queue (F402, mutation 1)")
func derivedGuardCatchesABareSetter() throws {
    let source = try mutated(try captureEngineSource(),
                             replacing: "set { captureQueue.sync { _streamDied = newValue } }",
                             with: "set { _streamDied = newValue }")
    let violations = scanCaptureQueueProtection(source).violations
    #expect(violations.contains { $0.hasPrefix("_streamDied used off captureQueue") }, "\(violations)")
    #expect(violations.contains { $0.hasPrefix("streamDied's set does not go through captureQueue.sync") }, "\(violations)")
}

@Test("The derived guard fails when start() clears the death with bare writes (F402, mutation 2)")
func derivedGuardCatchesBareWritesInStart() throws {
    let source = try mutated(try captureEngineSource(),
                             replacing: """
                                         captureQueue.sync {
                                             _streamError = nil
                                             _streamDied = false
                                         }
                             """,
                             with: """
                                         _streamError = nil
                                         _streamDied = false
                             """)
    let violations = scanCaptureQueueProtection(source).violations
    #expect(violations.contains { $0.hasPrefix("_streamError used off captureQueue") && $0.contains("_streamError = nil") },
            "\(violations)")
    #expect(violations.contains { $0.hasPrefix("_streamDied used off captureQueue") && $0.contains("_streamDied = false") },
            "\(violations)")
}

@Test("The derived guard fails when systemWriter's setter writes without the queue (F402, mutation 3)")
func derivedGuardCatchesAWriterSetterWithoutTheQueue() throws {
    let source = try mutated(try captureEngineSource(),
                             replacing: "set { captureQueue.sync { _systemWriter = newValue } }",
                             with: "set { _systemWriter = newValue }")
    let violations = scanCaptureQueueProtection(source).violations
    #expect(violations.contains { $0.hasPrefix("systemWriter's set does not go through captureQueue.sync") }, "\(violations)")
}

@Test("The derived guard fails when the restart padding stops asserting the queue (F402)")
func derivedGuardCatchesAPaddingPathOffTheQueue() throws {
    let source = try mutated(try captureEngineSource(),
                             replacing: """
                                 func applyPendingRestartPaddingIfNeeded() throws {
                                     dispatchPrecondition(condition: .onQueue(captureQueue))

                             """,
                             with: """
                                 func applyPendingRestartPaddingIfNeeded() throws {

                             """)
    let violations = scanCaptureQueueProtection(source).violations
    #expect(violations.contains { $0.hasPrefix("_pendingRestartPadding used off captureQueue") }, "\(violations)")
    #expect(violations.contains { $0.hasPrefix("_paddedGaps used off captureQueue") }, "\(violations)")
}

@Test("The derived guard fails when owed padding is set without the queue (F402)")
func derivedGuardCatchesABarePaddingWrite() throws {
    let source = try mutated(try captureEngineSource(),
                             replacing: "captureQueue.sync { _pendingRestartPadding = max(0, frames) }",
                             with: "_pendingRestartPadding = max(0, frames)")
    let violations = scanCaptureQueueProtection(source).violations
    #expect(violations.contains { $0.hasPrefix("_pendingRestartPadding used off captureQueue") }, "\(violations)")
}

@Test("The sample handler counts as on the queue only while its registration says so (F402)")
func derivedGuardChecksTheSampleHandlerRegistration() throws {
    let original = "try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: captureQueue)"
    let source = try mutated(try captureEngineSource(),
                             replacing: original,
                             with: "try stream.addStreamOutput(self, type: .audio, sampleHandlerQueue: .global())")
    let violations = scanCaptureQueueProtection(source).violations
    #expect(violations.contains { $0.hasPrefix("the SCStreamOutput sample handler is treated as on captureQueue") }, "\(violations)")
    #expect(violations.contains { $0.hasPrefix("_systemWriter used off captureQueue") }, "\(violations)")
}

@Test("The F401 mirror is exempt only while _streamDied's didSet is its one writer (F402)")
func derivedGuardChecksTheMirrorsOnlyWriter() throws {
    let source = try mutated(try captureEngineSource(),
                             replacing: "var captureDidDie: Bool { streamDiedMirror.withLock { $0 } }",
                             with: """
                             var captureDidDie: Bool { streamDiedMirror.withLock { $0 } }
                                 func markDeadForTesting() { streamDiedMirror.withLock { $0 = true } }
                             """)
    let violations = scanCaptureQueueProtection(source).violations
    #expect(violations.contains { $0.hasPrefix("streamDiedMirror touched outside `_streamDied`'s didSet") }, "\(violations)")
}

@Test("The mirror's one-writer check does not depend on how the write is spelled (F402)")
func derivedGuardChecksTheMirrorWhateverTheWriteLooksLike() throws {
    // A named closure parameter instead of `$0`, and a mutating call instead of an assignment. A check
    // that matches `withLock { $0 = …` sees neither.
    for write in ["streamDiedMirror.withLock { state in state = true }", "streamDiedMirror.withLock { $0.toggle() }"] {
        let source = try mutated(try captureEngineSource(),
                                 replacing: "var captureDidDie: Bool { streamDiedMirror.withLock { $0 } }",
                                 with: """
                                 var captureDidDie: Bool { streamDiedMirror.withLock { $0 } }
                                     func markDeadForTesting() { \(write) }
                                 """)
        let violations = scanCaptureQueueProtection(source).violations
        #expect(violations.contains { $0.hasPrefix("streamDiedMirror touched outside `_streamDied`'s didSet") },
                "\(write) was not reported: \(violations)")
    }
}

@Test("A field read inside a string interpolation is reported, not blanked away with the literal (F402)")
func derivedGuardSeesAFieldInsideAnInterpolation() throws {
    // The scan blanks string literals so a `{` inside one is not a scope, and that blanks `\(…)` too.
    // An off-queue log line is the likeliest place for a casual read of the storage.
    let source = try mutated(try captureEngineSource(),
                             replacing: #"Self.logger.info("Stop's restart wait ran out, but no restart was in flight.")"#,
                             with: #"Self.logger.info("Stop's restart wait ran out, but no restart was in flight (died: \(_streamDied)).")"#)
    let violations = scanCaptureQueueProtection(source).violations
    #expect(violations.contains { $0.hasPrefix("_streamDied appears inside a string literal") && $0.contains("died: ") },
            "\(violations)")

    // Fail closed: the scan cannot tell where a literal sits, so one inside a queue body is reported too.
    let fixture = """
        final class Engine {
            private let captureQueue = DispatchQueue(label: "fixture")
            private var _count = 0
            func log() { captureQueue.sync { print("count \\(_count)") } }
        }
        """
    let inQueueBody = scanCaptureQueueProtection(fixture).violations
    #expect(inQueueBody.count == 1 && inQueueBody.first?.hasPrefix("_count appears inside a string literal") == true,
            "\(inQueueBody)")
}

@Test("A computed _-prefixed property is queue storage: fine on the queue, flagged off it (F402)")
func derivedGuardTreatsAComputedUnderscorePropertyAsStorage() {
    // The shape F484 (unmerged at the time of writing) adds: a computed `_liveStreamIdentity` read
    // from inside `captureQueue.async`, and a `_`-prefixed test stand-in with no accessor.
    let fixture = """
        final class Engine {
            private let captureQueue = DispatchQueue(label: "fixture")
            private var _stream: AnyObject?
            private var _standIn: AnyObject?
            private var _liveIdentity: AnyObject? {
                if let _standIn { return _standIn }
                return _stream
            }
            func onQueue(_ candidate: AnyObject) {
                captureQueue.async { [weak self] in
                    guard let self, self._liveIdentity === candidate else { return }
                }
            }
            func install(_ standIn: AnyObject?) { captureQueue.sync { _standIn = standIn } }
        }
        """
    let clean = scanCaptureQueueProtection(fixture)
    #expect(clean.fields == ["_stream", "_standIn", "_liveIdentity"])
    #expect(clean.violations.isEmpty, "\(clean.violations)")

    let offQueue = fixture.replacingOccurrences(
        of: "    func install(",
        with: "    func peek() -> AnyObject? { _liveIdentity }\n    func install("
    )
    let violations = scanCaptureQueueProtection(offQueue).violations
    #expect(violations.count == 1 && violations.first?.hasPrefix("_liveIdentity used off captureQueue") == true, "\(violations)")
}
