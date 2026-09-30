import Foundation
import Testing
@testable import WhisperCore

// F255 — only the instance that owns the library may rebuild an interrupted recording.
//
// While a capture runs, its folder holds two growing `.f32` tracks and no finalized recording,
// which is structurally identical to an interrupted one: `meeting.wav` is written only by
// `AudioCaptureEngine.stop()`. A second instance that rebuilds it writes `meeting-recovered.wav`
// into the LIVE folder and indexes that, so when the first instance finishes and writes the
// complete `meeting.wav`, nothing points at it — the real recording is stranded on disk.
//
// The lease already distinguishes the only case that matters, which is why no heartbeat is needed:
// a live second instance never holds it, and a crashed first instance had its lease released by
// the kernel, so the relaunch after a crash does hold it and does rebuild.

@Test("An instance that holds the lease may rebuild")
func heldLeaseMayRebuild() {
    #expect(InterruptedRecordingRecovery.mayRebuildInterruptedRecordings(.held(realm: "shared")))
}

@Test("An instance that does NOT hold the lease must not rebuild")
func leaseHeldElsewhereMustNotRebuild() {
    #expect(
        !InterruptedRecordingRecovery.mayRebuildInterruptedRecordings(.heldElsewhere(realm: "shared"))
    )
}

@Test("A library where no lease could be taken still rebuilds — fail open, deliberately")
func unavailableLeaseFailsOpen() {
    // Refusing here would permanently disable recovery on a volume without `flock`, which is a
    // worse defect than the one this gate closes. It also keeps F190's Invariant L intact in
    // spirit: the lease stays advisory, and this gate only defers recovery, never bricks a library.
    #expect(
        InterruptedRecordingRecovery.mayRebuildInterruptedRecordings(.unavailable(reason: "no flock"))
    )
}

@Test("An unmanaged lease still rebuilds, so fixtures and tests are unaffected")
func unmanagedLeaseMayRebuild() {
    #expect(InterruptedRecordingRecovery.mayRebuildInterruptedRecordings(.unmanaged))
}

// MARK: - The premise the whole gate rests on

@Test("A lease held by a process that was SIGKILLed reads as available, not heldElsewhere")
func aDeadHoldersLeaseIsAvailable() throws {
    // F255's gate refuses to rebuild on `.heldElsewhere`, and the ONLY reason that is safe is that
    // a crashed instance stops holding its lease — otherwise a crash would block recovery of its
    // own interrupted recording forever, which is the exact opposite of what this is for.
    //
    // `LibraryWriterLeaseHandle`'s doc comment asserts this ("the kernel also releases it on the
    // last close — including after SIGKILL"), but nothing tested it, and the entire design rests on
    // it being true of this platform rather than of POSIX in principle. Asserted here with a real
    // process holding a real `flock`, then killed.
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("DeadHolderLease-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: root) }

    // `.writer.lock` is the shared lock `LibraryWriterLock.acquire` takes (rung 1).
    let lockPath = root.appendingPathComponent(".writer.lock").path
    let holder = Process()
    holder.executableURL = URL(fileURLWithPath: "/usr/bin/env")
    holder.arguments = [
        "python3", "-c",
        """
        import fcntl, sys
        handle = open(sys.argv[1], 'a')
        fcntl.flock(handle.fileno(), fcntl.LOCK_EX)
        sys.stdout.write('locked\\n')
        sys.stdout.flush()
        sys.stdin.read()
        """,
        lockPath,
    ]
    let out = Pipe()
    holder.standardOutput = out
    holder.standardInput = Pipe()
    try holder.run()
    defer { if holder.isRunning { kill(holder.processIdentifier, SIGKILL) } }

    // Handshake, so the assertion below cannot race the child taking the lock.
    //
    // Bounded both ways the child can fail to answer, and both bounds matter. `Process.run()` on
    // `/usr/bin/env` succeeds whenever `env` exists — it says nothing about `python3`, which Apple
    // has been steadily unbundling and which a runner without Command Line Tools does not have —
    // and this suite already has a scar from a wedged child presenting as a silent hang (F169). A
    // child that exits closes the pipe, which reads as end of file. A child that stays alive and
    // silent — an interpreter that hangs before its first write, or a `flock` that never returns —
    // is caught by `readHandshake`'s deadline, which is checked while nothing is arriving (F485);
    // the `defer` above then SIGKILLs it.
    let handshake = readHandshake(
        from: out.fileHandleForReading, until: "locked", timeoutMilliseconds: 10_000
    )
    switch handshake {
    case .found:
        break
    case .endOfFile:
        Issue.record("the holder child exited without reporting the lock — is python3 present?")
        return
    case .timedOut:
        Issue.record("the holder child was silent for 10 s — a hung python3, or a flock that never returned")
        return
    case .failed(let code):
        Issue.record("reading the holder child's output failed with errno \(code)")
        return
    }

    let blocked = LibraryWriterLock.acquire(root: root)
    #expect(blocked.lease == .heldElsewhere(realm: "shared"), "a live holder must block")
    blocked.release()

    kill(holder.processIdentifier, SIGKILL)

    // Poll rather than `waitUntilExit()`, which wedges this suite on a cooperative thread (F169).
    var acquired: StoreWriterLease = .unmanaged
    for _ in 0..<200 {
        let attempt = LibraryWriterLock.acquire(root: root)
        acquired = attempt.lease
        attempt.release()
        if acquired == .held(realm: "shared") { break }
        usleep(10_000)
    }
    #expect(acquired == .held(realm: "shared"), "a SIGKILLed holder must not keep the lease")
    // And therefore the gate lets the relaunch after a crash rebuild, which is the whole point.
    #expect(InterruptedRecordingRecovery.mayRebuildInterruptedRecordings(acquired))
}

// MARK: - A handshake read that a silent child cannot wedge (F485)

/// How `readHandshake` ended.
private enum HandshakeOutcome: Equatable {
    /// The needle arrived.
    case found
    /// The writer closed its end without sending the needle.
    case endOfFile
    /// The deadline passed first: the writer still has its end open and has not sent the needle.
    case timedOut
    /// `poll(2)` or `read(2)` failed with this `errno`.
    case failed(Int32)
}

/// Reads `handle` until its bytes contain `needle`, the writer closes, or `timeoutMilliseconds`
/// pass — whichever comes first.
///
/// The deadline has to be able to fire while nothing is arriving, which is exactly when a loop over
/// `FileHandle.availableData` cannot check it: `availableData` blocks until bytes or end of file, so
/// the loop this replaced checked its deadline only after a chunk arrived, and a writer that stayed
/// silent was not bounded at all (F485). Here every read is preceded by a `poll(2)` for the time
/// that is left, so a silent writer costs the timeout and no more. `read(2)` rather than
/// `availableData` for a second reason: `availableData` raises an Objective-C exception on a read
/// error, which no Swift `catch` sees.
private func readHandshake(
    from handle: FileHandle, until needle: String, timeoutMilliseconds: Int
) -> HandshakeOutcome {
    let descriptor = handle.fileDescriptor
    // Monotonic milliseconds, so a change to the wall clock cannot stretch or cut the wait. The sum
    // cannot overflow: uptime in milliseconds is nowhere near `UInt64.max - UInt64(Int.max)`.
    func uptimeMilliseconds() -> UInt64 { DispatchTime.now().uptimeNanoseconds / 1_000_000 }
    let deadline = uptimeMilliseconds() + UInt64(max(0, timeoutMilliseconds))
    var banner = Data()
    var buffer = [UInt8](repeating: 0, count: 4_096)
    while !String(decoding: banner, as: UTF8.self).contains(needle) {
        let now = uptimeMilliseconds()
        guard now < deadline else { return .timedOut }
        var request = pollfd(fd: descriptor, events: Int16(POLLIN), revents: 0)
        // `clamping:`, because a plain `Int32(_:)` traps on a remainder past `Int32.max`.
        let ready = poll(&request, 1, Int32(clamping: deadline - now))
        if ready < 0 {
            let code = errno
            if code == EINTR { continue }
            return .failed(code)
        }
        if ready == 0 { continue }                      // nothing yet; the deadline is checked above
        if request.revents & Int16(POLLNVAL) != 0 { return .failed(EBADF) }
        let count = buffer.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
        if count < 0 {
            let code = errno
            if code == EINTR || code == EAGAIN { continue }
            return .failed(code)
        }
        if count == 0 { return .endOfFile }             // the writer closed without the needle
        banner.append(contentsOf: buffer[..<count])
    }
    return .found
}

/// Runs `readHandshake` on a global-queue thread and waits a bounded time for it to return, so a
/// read that blocks fails the test that made it instead of hanging the suite. `nil` means it did
/// not return. The ten seconds asks only whether it returned at all — the tests below pass either
/// a timeout over thirty times shorter, or one so long that only returning on the end of file or on
/// the banner can beat it — so it is not a speed assertion.
private func handshakeWithWatchdog(
    reading handle: FileHandle, until needle: String, timeoutMilliseconds: Int
) -> HandshakeOutcome? {
    let result = HandshakeResult()
    let returned = DispatchSemaphore(value: 0)
    DispatchQueue.global().async {
        result.store(readHandshake(from: handle, until: needle, timeoutMilliseconds: timeoutMilliseconds))
        returned.signal()
    }
    guard returned.wait(timeout: .now() + 10) == .success else { return nil }
    return result.load()
}

private final class HandshakeResult: @unchecked Sendable {
    private let lock = NSLock()
    private var outcome: HandshakeOutcome?

    func store(_ value: HandshakeOutcome) { lock.withLock { outcome = value } }
    func load() -> HandshakeOutcome? { lock.withLock { outcome } }
}

@Test("The handshake gives up on a peer that keeps its pipe open and says nothing (F485)")
func theHandshakeGivesUpOnASilentPeer() throws {
    // The shape of a child that hangs before its first write, or waits in `flock`: the write end
    // stays open, so there is no end of file to return on, and nothing arrives either.
    let pipe = Pipe()
    // On every path, so a read that is still blocked gets end of file and its thread finishes.
    defer { try? pipe.fileHandleForWriting.close() }

    let outcome = handshakeWithWatchdog(
        reading: pipe.fileHandleForReading, until: "locked", timeoutMilliseconds: 300
    )
    let returned = try #require(outcome, "the handshake read never returned from a silent peer")
    #expect(returned == .timedOut)
}

@Test("The handshake reports a peer that closes without the banner as end of file (F485)")
func theHandshakeReportsAPeerThatClosesWithoutTheBanner() throws {
    // A child that exits before taking the lock — a missing `python3`, say — closes its stdout
    // having written nothing on it; any complaint goes to stderr, which this pipe does not carry.
    let pipe = Pipe()
    try pipe.fileHandleForWriting.close()

    // A timeout far longer than the watchdog's ten seconds, so only the end of file can make this
    // return in time.
    let outcome = handshakeWithWatchdog(
        reading: pipe.fileHandleForReading, until: "locked", timeoutMilliseconds: 600_000
    )
    let returned = try #require(outcome, "the handshake read did not return at end of file")
    #expect(returned == .endOfFile)
}

@Test("The handshake returns on the banner without waiting for the peer to close (F485)")
func theHandshakeReturnsOnTheBannerAlone() throws {
    // The holder child keeps its end open after the banner — it is blocked in `sys.stdin.read()`
    // holding the lock — so the read must return on the needle, not on end of file.
    let pipe = Pipe()
    defer { try? pipe.fileHandleForWriting.close() }
    try pipe.fileHandleForWriting.write(contentsOf: Data("locked\n".utf8))

    let outcome = handshakeWithWatchdog(
        reading: pipe.fileHandleForReading, until: "locked", timeoutMilliseconds: 600_000
    )
    let returned = try #require(outcome, "the handshake read did not return on the banner")
    #expect(returned == .found)
}
