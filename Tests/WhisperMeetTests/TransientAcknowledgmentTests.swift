import Testing
@testable import WhisperMeet

// F159 — the copy acknowledgment holder: a re-trigger must cancel the older pending reset so an
// earlier press can never clear a newer confirmation early. The wait is injected (F47 style) so
// the window is driven deterministically, with no real sleeps.

/// Polls `condition` every 5 ms under a 30 s cap and requires it, so a timeout fails as a timeout
/// (F639). Used where the test needs the acknowledgment to CHANGE: a budget of `Task.yield()`s
/// expires under a starved scheduler before the reset task has run.
@MainActor
private func waitUntil(_ what: String, _ condition: () -> Bool) async throws {
    var ticks = 0
    while !condition(), ticks < 6_000 {
        try await Task.sleep(nanoseconds: 5_000_000)
        ticks += 1
    }
    try #require(condition(), "timed out waiting for \(what)")
}

/// Gives a resumed wait a real chance to run its reset, for the assertions that the acknowledgment
/// did NOT change. There is nothing to poll for a claim that nothing happened, so this is a window
/// of real time (20 x 1 ms) rather than 20 scheduler turns (F639); it can only err toward a false
/// pass if a reset needed longer than the window, never toward a false failure.
@MainActor
private func settle() async throws {
    for _ in 0..<20 { try await Task.sleep(nanoseconds: 1_000_000) }
}

@MainActor
@Test("A second trigger keeps the acknowledgment visible for its own full window")
func retriggerKeepsAcknowledgmentVisible() async throws {
    let ack = TransientAcknowledgment()
    final class Waits: @unchecked Sendable {
        var continuations: [CheckedContinuation<Bool, Never>] = []
    }
    let waits = Waits()
    ack.waitForHold = { _ in
        await withCheckedContinuation { waits.continuations.append($0) }
    }

    ack.trigger() // press 1 — reset 1 pending
    ack.trigger() // press 2 before the window elapsed — reset 1 must be cancelled
    while waits.continuations.count < 2 { await Task.yield() }

    // Press 1's window elapses. Its (cancelled) reset must not clear press 2's confirmation.
    waits.continuations[0].resume(returning: true)
    try await settle()
    #expect(ack.isActive == true)

    // Press 2's own window elapses — now the acknowledgment resets.
    waits.continuations[1].resume(returning: true)
    try await waitUntil("the acknowledgment to reset") { !ack.isActive }
    #expect(ack.isActive == false)
}

@MainActor
@Test("A cancelled hold never resets a newer acknowledgment even if its wait reports elapsed late")
func cancelledHoldChecksCancellation() async throws {
    let ack = TransientAcknowledgment()
    final class Waits: @unchecked Sendable {
        var continuations: [CheckedContinuation<Bool, Never>] = []
    }
    let waits = Waits()
    ack.waitForHold = { _ in
        await withCheckedContinuation { waits.continuations.append($0) }
    }

    ack.trigger()
    while waits.continuations.isEmpty { await Task.yield() }
    ack.trigger() // cancels reset 1 while it is mid-wait
    waits.continuations[0].resume(returning: true) // late "elapsed" from the cancelled task
    try await settle()
    #expect(ack.isActive == true)

    while waits.continuations.count < 2 { await Task.yield() }
    waits.continuations[1].resume(returning: true)
    try await waitUntil("the acknowledgment to reset") { !ack.isActive }
    #expect(ack.isActive == false)
}
