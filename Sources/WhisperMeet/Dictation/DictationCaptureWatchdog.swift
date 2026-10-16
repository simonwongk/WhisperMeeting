import Foundation

@MainActor
final class DictationCaptureWatchdog {
    typealias Sleep = @Sendable (Duration) async throws -> Void

    private let timeout: Duration
    private let sleep: Sleep
    private let onTimeout: @MainActor () -> Void
    private var task: Task<Void, Never>?

    /// `sleep` is the timer; `nil` means `Task.sleep(for:)`. The real sleep is written here rather
    /// than as a default argument (F771), the shape F718 removed from WhisperCore: a closure in a
    /// default is compiled into each module that uses the default, and two copies of an async
    /// closure were once mispaired by a debug link. Written in the body, it is compiled once.
    init(
        timeout: Duration,
        sleep: Sleep? = nil,
        onTimeout: @escaping @MainActor () -> Void
    ) {
        self.timeout = timeout
        self.sleep = sleep ?? { try await Task.sleep(for: $0) }
        self.onTimeout = onTimeout
    }

    func arm() {
        cancel()
        let timeout = self.timeout
        let sleep = self.sleep
        let onTimeout = self.onTimeout
        task = Task {
            do {
                try await sleep(timeout)
            } catch {
                return
            }
            guard !Task.isCancelled else { return }
            onTimeout()
        }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    deinit {
        task?.cancel()
    }
}
