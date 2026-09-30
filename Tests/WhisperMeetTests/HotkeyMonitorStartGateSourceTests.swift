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
/// `startTriggerTap(` call inside `start` sits under a condition naming `mayHoldTriggerBack`: on
/// the call's own line, or in the header of a block that encloses it.
///
/// "The body mentions `mayHoldTriggerBack`" would not be enough, and neither would "the first
/// mention comes before the call". `start` names the property a second time, in the branch that
/// only picks a log line, so a mutant that drops the gate but keeps that branch still mentions it.
/// A logging `if !mayHoldTriggerBack { … }` moved above an unguarded call would still come first.
@Test("HotkeyMonitor.start creates the active trigger tap only under mayHoldTriggerBack (F690)")
func hotkeyMonitorStartGatesTheActiveTapOnMayHoldTriggerBack() throws {
    let source = SourceAssertion.stripComments(
        try String(
            contentsOf: SourceAssertion.url("Sources/WhisperMeet/Dictation/HotkeyMonitor.swift"),
            encoding: .utf8
        ),
        blankStringLiterals: true
    )
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

    func lineText(containing index: Substring.Index) -> Substring {
        let start = body[..<index].lastIndex(of: "\n").map { body.index(after: $0) } ?? body.startIndex
        let end = body[index...].firstIndex(of: "\n") ?? body.endIndex
        return body[start..<end]
    }

    // The call's own line, up to the call: `if mayHoldTriggerBack, startTriggerTap(…)`.
    let callLineStart = body[..<call.lowerBound].lastIndex(of: "\n").map { body.index(after: $0) } ?? body.startIndex
    var conditions: [Substring] = [body[callLineStart..<call.lowerBound]]
    // Every block inside `start` that encloses the call: `if mayHoldTriggerBack { … }`.
    var nesting = 0
    var scan = call.lowerBound
    while scan > body.startIndex {
        scan = body.index(before: scan)
        if body[scan] == "}" {
            nesting += 1
        } else if body[scan] == "{" {
            if nesting == 0 { conditions.append(lineText(containing: scan)) } else { nesting -= 1 }
        }
    }

    #expect(
        conditions.contains { $0.contains("mayHoldTriggerBack") },
        """
        HotkeyMonitor.start calls startTriggerTap( without a condition naming mayHoldTriggerBack, \
        so it can arm the active tap when it must stay listen-only (F547). Conditions seen: \
        \(conditions.map { $0.trimmingCharacters(in: .whitespaces) })
        """
    )
}
