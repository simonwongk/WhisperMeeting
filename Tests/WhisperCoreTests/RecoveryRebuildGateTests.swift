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
