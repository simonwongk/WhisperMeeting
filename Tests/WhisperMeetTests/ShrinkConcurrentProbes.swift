import Foundation

/// Runs `work` on each of `items`, at most `width` at a time, and returns the results in the items' order (review 2 of
/// Wave 8 lane A, finding 8: Shrink's probe corpora ran one file after another, each mostly waiting on its own detached
/// decode, encode and channel measure). Every probe still runs, through its own fixture and model, and every verdict is
/// asserted by the caller after all have finished — nothing a probe pins is dropped, only the waiting is overlapped.
@MainActor
func concurrentProbes<Item: Sendable, Output: Sendable>(
    _ items: [Item], width: Int = 4, _ work: @escaping @MainActor @Sendable (Item) async throws -> Output
) async throws -> [Output] {
    var results = [Output?](repeating: nil, count: items.count)
    try await withThrowingTaskGroup(of: (Int, Output).self) { group in
        var next = 0
        func start() {
            guard next < items.count else { return }
            let index = next, item = items[index]
            next += 1
            group.addTask { @MainActor in (index, try await work(item)) }
        }
        for _ in 0..<Swift.max(1, width) { start() }
        while let (index, output) = try await group.next() {
            results[index] = output
            start()
        }
    }
    return results.map { $0! }
}
