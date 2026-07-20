import Foundation
import Testing
@testable import WhisperCore

@Test("The first request starts immediately; further requests wait in order")
func runsOneAtATime() {
    var queue = TranscriptionQueue()
    let a = UUID(), b = UUID(), c = UUID()

    let addedA = queue.enqueue(a)
    #expect(addedA)
    let started = queue.startNext()
    #expect(started == a)
    #expect(queue.activeID == a)

    let addedB = queue.enqueue(b)
    let addedC = queue.enqueue(c)
    #expect(addedB)
    #expect(addedC)
    // Busy: nothing new starts.
    let blocked = queue.startNext()
    #expect(blocked == nil)
    #expect(queue.isPending(b))
    #expect(queue.isPending(c))

    queue.finishActive()
    let next1 = queue.startNext()
    #expect(next1 == b)
    queue.finishActive()
    let next2 = queue.startNext()
    #expect(next2 == c)
    queue.finishActive()
    let next3 = queue.startNext()
    #expect(next3 == nil)
    #expect(queue.isIdle)
}

@Test("Duplicate requests are ignored whether active or pending")
func deduplicates() {
    var queue = TranscriptionQueue()
    let a = UUID(), b = UUID()

    let first = queue.enqueue(a)
    #expect(first)
    _ = queue.startNext()
    let againActive = queue.enqueue(a)   // already active
    #expect(againActive == false)
    let addedB = queue.enqueue(b)
    #expect(addedB)
    let againPending = queue.enqueue(b)  // already pending
    #expect(againPending == false)
    #expect(queue.pendingCount == 1)
}

@Test("Removing a pending item drops it; removing the active item frees the slot")
func removes() {
    var queue = TranscriptionQueue()
    let a = UUID(), b = UUID()
    _ = queue.enqueue(a)
    _ = queue.enqueue(b)
    _ = queue.startNext()                // a active, b pending

    let removedB = queue.remove(b)
    #expect(removedB == .wasPending)
    #expect(queue.contains(b) == false)

    let removedA = queue.remove(a)
    #expect(removedA == .wasActive)
    #expect(queue.isIdle)
    let removedAgain = queue.remove(a)
    #expect(removedAgain == .notFound)
}
