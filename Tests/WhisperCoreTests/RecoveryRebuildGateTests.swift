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
    // Bounded, and both bounds matter. `Process.run()` on `/usr/bin/env` succeeds whenever `env`
    // exists — it says nothing about `python3`, which Apple has been steadily unbundling and which
    // a runner without Command Line Tools does not have. An unbounded loop over `availableData`
    // would then spin at 100% CPU forever on an already-EOF pipe, and this suite already has a
    // scar from a wedged child presenting as a silent hang (F169). Empty data is EOF; the deadline
    // catches a child that opens the pipe and then stalls.
    var banner = Data()
    let deadline = Date().addingTimeInterval(10)
    while !String(decoding: banner, as: UTF8.self).contains("locked") {
        let chunk = out.fileHandleForReading.availableData
        if chunk.isEmpty { break }          // the child exited without taking the lock
        if Date() >= deadline { break }
        banner.append(chunk)
    }
    try #require(
        String(decoding: banner, as: UTF8.self).contains("locked"),
        "the holder child never reported taking the lock — is python3 present?"
    )

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
