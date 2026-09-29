import AppKit
import Foundation
import Testing
@testable import WhisperMeet

/// F657 — F601 starts the clipboard read on `TextInjector`'s snapshot queue when the dictation
/// starts. If that read has not finished by paste time — a lazily provided 12-megapixel image took
/// 2.5 s (F601's measurement), and a short dictation is shorter — the main thread used the same
/// `NSPasteboard` at the same time: a second read at paste time, then `clearContents` and
/// `writeObjects` while the queue was still inside `data(forType:)`. F425 never let the two meet.
///
/// The early read here is a fake that blocks until released, on a private pasteboard. A helper
/// thread releases it as soon as the main thread is seen touching the pasteboard (a second read, or
/// a write) — which is what the overlap looks like — or, when nothing overlaps, after half a second.
/// The half second only bounds how long a correct run waits; what is asserted — at most one read in
/// flight, and no write while the early read is inside — does not depend on it.

private final class BlockingReads: @unchecked Sendable {
    private let lock = NSLock()
    private var calls = 0
    private var inFlight = 0
    private(set) var maxInFlight = 0
    private(set) var earlyEntered = false
    private(set) var laterEntered = false
    private(set) var writtenDuringEarlyRead = false
    private var countAtEarlyEntry = 0
    let release = DispatchSemaphore(value: 0)

    func snapshot() -> (maxInFlight: Int, earlyEntered: Bool, laterEntered: Bool, writtenDuringEarlyRead: Bool) {
        lock.withLock { (maxInFlight, earlyEntered, laterEntered, writtenDuringEarlyRead) }
    }

    var entryCount: Int { lock.withLock { countAtEarlyEntry } }

    func read(_ handle: TextInjector.PasteboardHandle, _ limit: Int) -> Result<PasteboardSnapshot, PasteboardSnapshot.Refusal> {
        let call: Int = lock.withLock {
            calls += 1
            inFlight += 1
            maxInFlight = max(maxInFlight, inFlight)
            if calls == 1 {
                earlyEntered = true
                countAtEarlyEntry = handle.pasteboard.changeCount
            } else {
                laterEntered = true
            }
            return calls
        }
        if call == 1 {
            release.wait()
            let moved = handle.pasteboard.changeCount != lock.withLock { countAtEarlyEntry }
            lock.withLock { if moved { writtenDuringEarlyRead = true } }
        }
        let result = PasteboardSnapshot.read(from: handle.pasteboard, maximumBytes: limit)
        lock.withLock { inFlight -= 1 }
        return result
    }
}

@MainActor
private final class OverlapHarness {
    let board = NSPasteboard.withUniqueName()
    let reads = BlockingReads()
    var textFieldFocused = true
    private(set) var pasteCount = 0

    init() throws {
        board.clearContents()
        board.setString("copied on my phone", forType: .string)
        try #require(board.string(forType: .string) == "copied on my phone", "the private pasteboard does not round-trip a string on this host")
    }

    func makeInjector() -> TextInjector {
        let reads = self.reads
        return TextInjector(
            pasteboard: board,
            readSnapshot: { reads.read($0, $1) },
            canSynthesizePaste: { true },
            focusedTextField: { [unowned self] in
                FocusedTextField.Probe(isTextField: self.textFieldFocused, summary: "test", processIdentifier: 100)
            },
            synthesizePaste: { [unowned self] in
                self.pasteCount += 1
                return true
            },
            schedule: { _, _ in }
        )
    }

    /// Starts the early read and waits — on the read's own flag, capped — until it is inside the
    /// fake and blocked; then arms the helper that releases it.
    func startBlockedEarlyRead(_ injector: TextInjector) async throws -> (FocusedTextField.Probe, Task<Void, Never>) {
        let pressedIn = injector.captureWillStart(autoPaste: true)
        let early = try #require(injector.clipboardPrefetch, "the press did not start the early read")
        let deadline = Date().addingTimeInterval(30)
        while !reads.snapshot().earlyEntered, Date() < deadline {
            try await Task.sleep(for: .milliseconds(5))
        }
        try #require(reads.snapshot().earlyEntered, "the early read never started")
        let reads = self.reads
        let handle = TextInjector.PasteboardHandle(pasteboard: board)
        let start = reads.entryCount
        Thread.detachNewThread {
            let bound = Date().addingTimeInterval(0.5)
            while !reads.snapshot().laterEntered, handle.pasteboard.changeCount == start, Date() < bound {
                usleep(1_000)
            }
            reads.release.signal()
        }
        return (pressedIn, early)
    }

    deinit { board.releaseGlobally() }
}

@MainActor
@Test("The paste-time read waits for an early read still in flight, and never overlaps it (F657)")
func thePasteTimeReadWaitsForTheEarlyRead() async throws {
    let harness = try OverlapHarness()
    let injector = harness.makeInjector()
    let (pressedIn, early) = try await harness.startBlockedEarlyRead(injector)

    #expect(injector.deliver("dictated words", autoPaste: true, pressedIn: pressedIn) == .pasted)
    await early.value

    let seen = harness.reads.snapshot()
    #expect(seen.laterEntered, "no paste-time read happened, so this test checked nothing")
    #expect(seen.maxInFlight == 1)
    #expect(!seen.writtenDuringEarlyRead)
    #expect(harness.pasteCount == 1)
}

@MainActor
@Test("A write at delivery waits for an early read still in flight (F657)")
func aWriteAtDeliveryWaitsForTheEarlyRead() async throws {
    let harness = try OverlapHarness()
    let injector = harness.makeInjector()
    let (pressedIn, early) = try await harness.startBlockedEarlyRead(injector)
    // Focus moved off the field while transcribing: no paste-time read, only the write.
    harness.textFieldFocused = false

    #expect(injector.deliver("dictated words", autoPaste: true, pressedIn: pressedIn) == .pastedUnconfirmed)
    await early.value

    let seen = harness.reads.snapshot()
    #expect(!seen.laterEntered)
    #expect(!seen.writtenDuringEarlyRead)
    #expect(harness.board.string(forType: .string) == "dictated words")
}
