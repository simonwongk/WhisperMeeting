// Sources/WhisperMeet/TransientAcknowledgment.swift
import SwiftUI

/// A boolean acknowledgment that turns on and auto-resets after a hold — the "Copied" flash on
/// copy buttons. The pending reset is cancelled on re-trigger, so an older press can never clear
/// a newer confirmation early (F159). The wait is injectable (the F47 seam style) so tests drive
/// the window deterministically with no real sleeps.
@MainActor
final class TransientAcknowledgment: ObservableObject {
    @Published private(set) var isActive = false
    private let hold: Duration
    private var reset: Task<Void, Never>?

    /// Returns true when the full hold elapsed; false when the sleep was cancelled. Tests replace
    /// this with continuation-driven waits.
    var waitForHold: @MainActor (Duration) async -> Bool = { hold in
        (try? await Task.sleep(for: hold)) != nil
    }

    init(hold: Duration = .seconds(2)) {
        self.hold = hold
    }

    func trigger() {
        isActive = true
        reset?.cancel()
        let wait = waitForHold
        let hold = hold
        reset = Task { [weak self] in
            // Both guards matter: a cancelled real sleep reports false, and a test-injected wait
            // can report elapsed after cancellation — neither may clear a newer press.
            guard await wait(hold), !Task.isCancelled else { return }
            self?.isActive = false
        }
    }
}
