import Foundation

/// An array a store can encode one element at a time (F526). Conformance is conditional on the
/// elements, so `BackupJSONStore` — generic over any `Value` — can ask at runtime whether its value
/// is such an array.
protocol ConcurrentlyEncodableArray {
    func encodedConcurrently(makeEncoder: () -> JSONEncoder) throws -> Data
}

extension Array: ConcurrentlyEncodableArray where Element: Encodable {
    func encodedConcurrently(makeEncoder: () -> JSONEncoder) throws -> Data {
        try ConcurrentArrayEncoding.encode(self, makeEncoder: makeEncoder)
    }
}

/// Encodes an array's elements on every core and splices them into the bytes the whole-array
/// encoder would have written (F526).
///
/// **Why.** At 1,000 transcribed meetings the index is ~274 MB, and one `JSONEncoder` pass over it
/// took ~1.95 s of a ~2.0 s save, on the main actor, after every edit and every 0.5 s pause in
/// typing. Encoding the records separately, spread over every core, took the same index 0.33–0.39 s
/// on an 11-core Mac, and the output was byte-identical (`IndexSaveCostMeasurementTests`).
///
/// **Why the bytes cannot mean anything else.** Each element is encoded by an encoder with the
/// caller's configuration, exactly as the array's encoder encodes it, except at the top of its own
/// document. Pretty-printed, that only changes its indentation: the splice puts two spaces before
/// every line that has content and leaves blank lines blank, as the encoder itself writes the blank
/// line inside an empty container. JSON allows any whitespace between tokens, and a raw line feed
/// never occurs inside a string — `JSONEncoder` escapes U+000A, and no UTF-8 continuation byte is
/// 0x0A — so adding spaces after one cannot touch a value. The parts are joined with the array's own
/// `[\n`, `,\n` and `\n]` (`[`, `,`, `]` compact). So the result always decodes to the same value;
/// that it is also byte-identical is pinned by `elementwiseEncodingIsByteIdentical` and
/// `theMeetingIndexOnDiskIsTheWholeArrayEncoding`, so a Foundation that formats differently fails a
/// test rather than changing a file's format.
///
/// **What an element must not do:** read `encoder.codingPath` to decide what to write, because at the
/// top of its own document the path is empty where the array's encoder would have given its index.
/// Nothing in the meeting index does (`optedInStoresEncodeElementwise` shows the difference).
enum ConcurrentArrayEncoding {
    static func encode<Element: Encodable>(
        _ elements: [Element], makeEncoder: () -> JSONEncoder
    ) throws -> Data {
        let probe = makeEncoder()
        // Nothing to splice, and an empty array's own form (`[\n\n]`) is not the join of no parts.
        guard elements.count > 1 else { return try probe.encode(elements) }
        let pretty = probe.outputFormatting.contains(.prettyPrinted)

        let count = elements.count
        let lanes = min(count, max(1, ProcessInfo.processInfo.activeProcessorCount) * 4)
        let encoders = (0..<lanes).map { _ in makeEncoder() }
        var parts = [Data](repeating: Data(), count: count)
        let failure = FirstFailure()
        parts.withUnsafeMutableBufferPointer { output in
            DispatchQueue.concurrentPerform(iterations: lanes) { lane in
                let encoder = encoders[lane]
                for index in (lane * count / lanes)..<((lane + 1) * count / lanes) {
                    guard !failure.happened else { return }
                    do {
                        let document = try encoder.encode(elements[index])
                        output[index] = pretty ? indentedOneLevel(document) : document
                    } catch {
                        failure.record(error)
                        return
                    }
                }
            }
        }
        if let error = failure.error { throw error }

        let open = Data((pretty ? "[\n" : "[").utf8)
        let separator = Data((pretty ? ",\n" : ",").utf8)
        let close = Data((pretty ? "\n]" : "]").utf8)
        let total = parts.reduce(open.count + close.count + separator.count * (count - 1)) { $0 + $1.count }
        var data = Data(capacity: total)
        data.append(open)
        for (index, part) in parts.enumerated() {
            if index > 0 { data.append(separator) }
            data.append(part)
        }
        data.append(close)
        return data
    }

    /// `document`, a pretty-printed value, as it reads one level deeper: two spaces before every line
    /// that has content, blank lines left blank.
    static func indentedOneLevel(_ document: Data) -> Data {
        let indent: [UInt8] = [0x20, 0x20]
        var out = Data(capacity: document.count + document.count / 8 + indent.count)
        document.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            let bytes = base.assumingMemoryBound(to: UInt8.self)
            let count = raw.count
            var lineStart = 0
            while lineStart < count {
                // The line runs to its line feed, inclusive, or to the end.
                let lineEnd = memchr(base + lineStart, 0x0A, count - lineStart)
                    .map { base.distance(to: UnsafeRawPointer($0)) + 1 } ?? count
                if bytes[lineStart] != 0x0A { out.append(contentsOf: indent) }
                out.append(bytes + lineStart, count: lineEnd - lineStart)
                lineStart = lineEnd
            }
        }
        return out
    }
}

/// The first error any lane hit, so the others can stop early and the caller throws one of them.
/// Which one is not decided — an encode that fails anywhere fails the save before anything is written.
private final class FirstFailure: @unchecked Sendable {
    private let lock = NSLock()
    private var first: Error?
    var happened: Bool { lock.withLock { first != nil } }
    var error: Error? { lock.withLock { first } }
    func record(_ error: Error) { lock.withLock { if first == nil { first = error } } }
}
