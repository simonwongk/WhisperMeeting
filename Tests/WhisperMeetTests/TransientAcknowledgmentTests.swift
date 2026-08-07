import Testing
@testable import WhisperMeet

// F159 — the copy acknowledgment holder: a re-trigger must cancel the older pending reset so an
// earlier press can never clear a newer confirmation early. The wait is injected (F47 style) so
// the window is driven deterministically, with no real sleeps.

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
    for _ in 0..<20 { await Task.yield() }
    #expect(ack.isActive == true)

    // Press 2's own window elapses — now the acknowledgment resets.
    waits.continuations[1].resume(returning: true)
    for _ in 0..<20 { await Task.yield() }
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
    for _ in 0..<20 { await Task.yield() }
    #expect(ack.isActive == true)

    while waits.continuations.count < 2 { await Task.yield() }
    waits.continuations[1].resume(returning: true)
    for _ in 0..<20 { await Task.yield() }
    #expect(ack.isActive == false)
}
