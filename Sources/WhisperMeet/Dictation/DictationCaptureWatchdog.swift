import Foundation

@MainActor
final class DictationCaptureWatchdog {
    typealias Sleep = @Sendable (Duration) async throws -> Void

    private let timeout: Duration
    private let sleep: Sleep
    private let onTimeout: @MainActor () -> Void
    private var task: Task<Void, Never>?

    init(
        timeout: Duration,
        sleep: @escaping Sleep = { try await Task.sleep(for: $0) },
        onTimeout: @escaping @MainActor () -> Void
    ) {
        self.timeout = timeout
        self.sleep = sleep
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
