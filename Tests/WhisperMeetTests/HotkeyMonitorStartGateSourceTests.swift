import Foundation
import Testing

/// F690: the real `HotkeyMonitor.start` must consult `mayHoldTriggerBack` before it creates the
/// F-key trigger's active tap (F547).
///
/// No test runs the real `start`: it creates a `CGEventTap`, which needs Accessibility or Input
/// Monitoring on the machine running the suite. The controller tests' fake monitor
/// (`GrantAwareMonitor`) re-implements the gate instead, so deleting it from `start` left every
/// related test green (the round-2 review of lane M ran exactly that mutation). This reads the
/// source, with comments and string literals stripped (F285), and checks that the one
/// `startTriggerTap(` call inside `start` sits under a condition naming `mayHoldTriggerBack`: in
/// the call's own clause, followed back across the line breaks of a condition split over lines, or
/// in the header of a block that encloses it. `startGateGuardReadsTheWholeCondition` pins which
/// shapes count, on fixtures.
///
/// "The body mentions `mayHoldTriggerBack`" would not be enough, and neither would "the first
/// mention comes before the call". `start` names the property a second time, in the branch that
/// only picks a log line, so a mutant that drops the gate but keeps that branch still mentions it.
/// A logging `if !mayHoldTriggerBack { … }` moved above an unguarded call would still come first.
///
/// It checks shape, not meaning. An early `guard mayHoldTriggerBack else { … }` above the call
/// fails it, although it would gate the call, and an inverted `if !mayHoldTriggerBack, …` passes
/// it. Only a test that runs `start` could tell either apart.
@Test("HotkeyMonitor.start creates the active trigger tap only under mayHoldTriggerBack (F690)")
func hotkeyMonitorStartGatesTheActiveTapOnMayHoldTriggerBack() throws {
    let conditions = try startTriggerTapConditions(
        in: try String(
            contentsOf: SourceAssertion.url("Sources/WhisperMeet/Dictation/HotkeyMonitor.swift"),
            encoding: .utf8
        )
    )
    #expect(
        conditions.contains { $0.contains("mayHoldTriggerBack") },
        """
        HotkeyMonitor.start calls startTriggerTap( without a condition naming mayHoldTriggerBack, \
        so it can arm the active tap when it must stay listen-only (F547). Conditions seen: \
        \(conditions.map { $0.trimmingCharacters(in: .whitespaces) })
        """
    )
}

@Test("The start-gate guard reads a condition split across lines, and still rejects an ungated call (F690)")
func startGateGuardReadsTheWholeCondition() throws {
    // Each fixture is a `start` shaped like the real one, with its tap gate replaced by `gate`.
    // Accepted shapes mean the same as today's gate; rejected ones arm the tap without it.
    let accepted: [(name: String, gate: String)] = [
        ("today's one-line gate", "if mayHoldTriggerBack, startTriggerTap(keyCode: hotkey.keyCode) { return true }"),
        ("split after the comma", "if mayHoldTriggerBack,\n               startTriggerTap(keyCode: hotkey.keyCode) { return true }"),
        ("split before &&", "if mayHoldTriggerBack\n                && startTriggerTap(keyCode: hotkey.keyCode) { return true }"),
        ("split after &&", "if mayHoldTriggerBack &&\n                startTriggerTap(keyCode: hotkey.keyCode) { return true }"),
        ("a comment between the halves", "if mayHoldTriggerBack,\n               // the active tap\n               startTriggerTap(keyCode: hotkey.keyCode) { return true }"),
        ("nested in its own block", "if mayHoldTriggerBack {\n                if startTriggerTap(keyCode: hotkey.keyCode) { return true }\n            }"),
    ]
    let rejected: [(name: String, gate: String)] = [
        ("the gate deleted", "if startTriggerTap(keyCode: hotkey.keyCode) { return true }"),
        ("a logging branch above an ungated call", "if !mayHoldTriggerBack { log.notice(\"listen-only\") }\n            if startTriggerTap(keyCode: hotkey.keyCode) { return true }"),
        ("a mention in the statement before", "let wanted = mayHoldTriggerBack\n            if startTriggerTap(keyCode: hotkey.keyCode) { return true }"),
        ("a mention after the call", "if startTriggerTap(keyCode: hotkey.keyCode), mayHoldTriggerBack { return true }"),
    ]
    for (name, gate) in accepted {
        let conditions = try startTriggerTapConditions(in: startFixture(gate: gate))
        #expect(conditions.contains { $0.contains("mayHoldTriggerBack") },
                "\(name) should pass; conditions seen: \(conditions)")
    }
    for (name, gate) in rejected {
        let conditions = try startTriggerTapConditions(in: startFixture(gate: gate))
        #expect(!conditions.contains { $0.contains("mayHoldTriggerBack") },
                "\(name) should fail; conditions seen: \(conditions)")
    }
}

/// A `HotkeyMonitor.start` laid out like the real one, with `gate` in place of its tap gate.
private func startFixture(gate: String) -> String {
    """
    protocol HotkeyMonitoring {
        func start(hotkey: DictationHotkey) -> Bool
    }

    final class HotkeyMonitor: HotkeyMonitoring {
        func start(hotkey: DictationHotkey) -> Bool {
            removeTap()
            if Self.tapKind(for: hotkey) == .holdsTriggerBack {
                \(gate)
                if mayHoldTriggerBack {
                    log.error("the active tap could not be created { listening only")
                } else {
                    log.notice("armed listen-only")
                }
            }
            return false
        }

        private func startTriggerTap(keyCode: UInt16) -> Bool { mayHoldTriggerBack }
    }
    """
}

/// The conditions in front of the one `startTriggerTap(` call in `HotkeyMonitor.start`: the call's
/// own clause, then the header of every block inside `start` that encloses the call, innermost
/// first. Comments and string literals are stripped first.
private func startTriggerTapConditions(in rawSource: String) throws -> [String] {
    let source = SourceAssertion.stripComments(rawSource, blankStringLiterals: true)
    // The protocol declares the same signature with no body, so anchor on the class, and include
    // the brace in the signature.
    let classMarker = try #require(source.range(of: "final class HotkeyMonitor"))
    let signature = try #require(
        source.range(of: "func start(hotkey: DictationHotkey) -> Bool {", range: classMarker.upperBound..<source.endIndex),
        "HotkeyMonitor.start was not found; this guard needs re-anchoring"
    )
    var depth = 1
    var cursor = signature.upperBound
    while cursor < source.endIndex, depth > 0 {
        if source[cursor] == "{" { depth += 1 } else if source[cursor] == "}" { depth -= 1 }
        cursor = source.index(after: cursor)
    }
    let body = source[signature.upperBound..<cursor]

    // A wrongly anchored extraction, or a call moved out of `start`, fails here, not vacuously below.
    let calls = body.ranges(of: "startTriggerTap(")
    try #require(calls.count == 1, "expected exactly one startTriggerTap( call in HotkeyMonitor.start, found \(calls.count)")
    let call = calls[0]

    // The call's own clause: `if mayHoldTriggerBack, startTriggerTap(…)`, on one line or several.
    var conditions = [clause(endingAt: call.lowerBound, in: body)]
    // Every block inside `start` that encloses the call: `if mayHoldTriggerBack { … }`.
    var nesting = 0
    var scan = call.lowerBound
    while scan > body.startIndex {
        scan = body.index(before: scan)
        if body[scan] == "}" {
            nesting += 1
        } else if body[scan] == "{" {
            if nesting == 0 { conditions.append(clause(endingAt: scan, in: body)) } else { nesting -= 1 }
        }
    }
    return conditions
}

/// The text from the start of the statement that `end` is in, up to `end`.
///
/// Walking back from `end`, the statement starts just after the first `{`, `}` or `;`. Reaching the
/// start of a line without one, it carries on to the line before only when this line starts with
/// `&&`, `||` or `,`, or the line before ends with `,`, `&&`, `||` or `(`, which is how a condition
/// list or a boolean expression is split. Blank lines, which is what a stripped comment leaves, are
/// stepped over. Otherwise the statement starts on this line, so a mention of the property in an
/// earlier statement does not count as this one's condition.
private func clause(endingAt end: Substring.Index, in body: Substring) -> String {
    let lines = body[..<end].split(separator: "\n", omittingEmptySubsequences: false)
    var parts: [Substring] = []
    var index = lines.count - 1
    while index >= 0 {
        let line = lines[index]
        if let bound = line.lastIndex(where: { "{};".contains($0) }) {
            parts.append(line[line.index(after: bound)...])
            break
        }
        parts.append(line)
        var previous = index - 1
        while previous >= 0, lines[previous].trimmingCharacters(in: .whitespaces).isEmpty { previous -= 1 }
        guard previous >= 0 else { break }
        let thisLine = line.trimmingCharacters(in: .whitespaces)
        let lineBefore = lines[previous].trimmingCharacters(in: .whitespaces)
        let continues = ["&&", "||", ","].contains { thisLine.hasPrefix($0) }
            || [",", "&&", "||", "("].contains { lineBefore.hasSuffix($0) }
        guard continues else { break }
        index = previous
    }
    return parts.reversed().map { $0.trimmingCharacters(in: .whitespaces) }.joined(separator: " ")
}
