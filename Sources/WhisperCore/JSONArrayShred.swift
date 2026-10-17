import Foundation

/// Removes elements from a JSON array by their `"id"`, without decoding them into any model
/// (F552, F457).
///
/// The shred's one operation, shared by the retained history (`BackupJSONStore.shredHistory`) and
/// the index's other copies — a quarantined index, a restore's snapshot — so all of them remove a
/// deleted meeting the same way. Working on the JSON rather than through a `Codable` model is the
/// point: a model this build has drops what a newer build wrote and cannot read what it cannot
/// decode, and these files are exactly the copies someone recovers from.
public enum JSONArrayShred {
    /// `data`'s top-level array without the elements whose `"id"` string is one of `ids` (compared
    /// case-insensitively), serialized again, with how many elements remain — or nil when `data` is
    /// not a JSON array or holds none of them, so a caller leaves that file byte-for-byte alone.
    ///
    /// Everything else keeps its meaning: an element that is not an object, or has no string `id`,
    /// is kept. A kept element keeps the bytes it had, so a file the stores wrote still reads as they
    /// wrote it; a file that takes the whole-parse path is written pretty-printed with sorted keys,
    /// the stores' own format.
    ///
    /// `removed` is the ids that were found, lowercased — so a caller can tell which deletions a
    /// copy it then fails to write still holds (F668).
    ///
    /// **By the bytes, where it can (F907).** Parsing every element of a 274 MB generation and
    /// pretty-printing all of it again took 4.6 s, four times per shred, on the main actor at launch.
    /// So the array is first walked as bytes by a strict JSON validator that records where each
    /// element starts and ends (`ElementScanner`). Only an element whose bytes mention a doomed id
    /// (compared without case) is parsed, and it is removed only when its own top-level `"id"` is one;
    /// every other element is copied byte for byte, so its formatting and anything a newer build wrote
    /// in it are untouched. An element with a backslash-u escape anywhere is parsed and judged too,
    /// since escapes can spell an id the byte search cannot see. A file the validator cannot vouch
    /// for — not well-formed, not UTF-8, a byte order mark, a surrogate escape, a number with too many
    /// digits, deep nesting — takes the whole-parse path this replaced, whose answer it then is.
    ///
    /// The validator is stricter than `JSONSerialization` in every case known but one: a number too
    /// large for a `Double`, such as `1e400`. `JSONSerialization` refuses a file holding one, and the
    /// validator accepts it, so such a file has its doomed record cut and every other byte kept as
    /// written. That loses nothing, and routing it to the whole parse instead would meet F1041 for
    /// `-1e400`, which that path parses and then raises on when writing it back
    /// (`hugeNumberElsewhereIsKeptAsWritten`, F907 review, finding 2).
    public static func removingElements(
        withIDs ids: Set<String>, from data: Data
    ) -> (data: Data, count: Int, removed: Set<String>)? {
        let doomed = Set(ids.map { $0.lowercased() })
        guard !doomed.isEmpty else { return nil }
        switch removingByBytes(doomed, from: data) {
        case .answered(let answer): return answer
        case .cannotVouch: return removingByParsingEverything(doomed, from: data)
        }
    }

    private enum ByteAnswer {
        case answered((data: Data, count: Int, removed: Set<String>)?)
        case cannotVouch
    }

    private static func removingByBytes(_ doomed: Set<String>, from data: Data) -> ByteAnswer {
        data.withUnsafeBytes { (bytes: UnsafeRawBufferPointer) -> ByteAnswer in
            var scanner = ElementScanner(bytes: bytes)
            guard let elements = scanner.topLevelElements() else { return .cannotVouch }
            // Which elements mention a doomed id anywhere, found in a lowercased copy of the bytes. A
            // mention is not a record — a transcript can quote an id, a segment can carry one — so each
            // candidate is then parsed and judged by its own top-level `"id"`. An element with a
            // backslash-u escape anywhere is a candidate too: its id may be spelled by escapes the search
            // cannot see (F907 review, finding 1). The stores' encoders escape only control
            // characters, so a store-written file has few such elements and the speed is unchanged.
            var lowered = [UInt8](bytes)
            for index in lowered.indices where lowered[index] &- 0x41 < 26 { lowered[index] |= 0x20 }
            var candidates = scanner.escapedElements
            lowered.withUnsafeBytes { haystack in
                guard let base = haystack.baseAddress else { return }
                for id in doomed {
                    let needle = Array(id.utf8)
                    var offset = 0
                    while offset < haystack.count,
                          let found = memmem(base + offset, haystack.count - offset, needle, needle.count) {
                        let at = base.distance(to: UnsafeRawPointer(found))
                        if let element = elementIndex(containing: at, in: elements) { candidates.insert(element) }
                        offset = at + 1
                    }
                }
            }
            var removed: Set<String> = []
            var removedIndices = Set<Int>()
            for index in candidates {
                let range = elements[index]
                let slice = Data(bytes: bytes.baseAddress! + range.lowerBound, count: range.count)
                guard let value = try? JSONSerialization.jsonObject(with: slice, options: [.fragmentsAllowed]) else {
                    return .cannotVouch
                }
                guard let id = (value as? [String: Any])?["id"] as? String, doomed.contains(id.lowercased()) else {
                    continue
                }
                removed.insert(id.lowercased())
                removedIndices.insert(index)
            }
            guard !removed.isEmpty else { return .answered(nil) }
            // The array's own bytes around its elements, and the separator between its first two, so
            // a store-written file reads as the store wrote it.
            var output = Data(bytes: bytes.baseAddress!, count: elements[0].lowerBound)
            let separator = elements.count > 1
                ? Data(bytes: bytes.baseAddress! + elements[0].upperBound, count: elements[1].lowerBound - elements[0].upperBound)
                : Data()
            var kept = 0
            for (index, range) in elements.enumerated() where !removedIndices.contains(index) {
                if kept > 0 { output.append(separator) }
                output.append(bytes.baseAddress!.assumingMemoryBound(to: UInt8.self) + range.lowerBound, count: range.count)
                kept += 1
            }
            let end = elements[elements.count - 1].upperBound
            output.append(bytes.baseAddress!.assumingMemoryBound(to: UInt8.self) + end, count: bytes.count - end)
            return .answered((output, kept, removed))
        }
    }

    /// The element whose byte range holds `offset`, by binary search over ranges in order.
    private static func elementIndex(containing offset: Int, in elements: [Range<Int>]) -> Int? {
        var low = 0
        var high = elements.count - 1
        while low <= high {
            let middle = (low + high) / 2
            if elements[middle].upperBound <= offset {
                low = middle + 1
            } else if elements[middle].lowerBound > offset {
                high = middle - 1
            } else {
                return middle
            }
        }
        return nil
    }

    /// The path every file took before F907, and the one a file the scanner cannot vouch for takes.
    private static func removingByParsingEverything(
        _ doomed: Set<String>, from data: Data
    ) -> (data: Data, count: Int, removed: Set<String>)? {
        guard let elements = (try? JSONSerialization.jsonObject(with: data)) as? [Any] else { return nil }
        var removed: Set<String> = []
        let kept = elements.filter { element in
            guard let id = (element as? [String: Any])?["id"] as? String,
                  doomed.contains(id.lowercased())
            else { return true }
            removed.insert(id.lowercased())
            return false
        }
        guard !removed.isEmpty,
              let rewritten = try? JSONSerialization.data(
                  withJSONObject: kept, options: [.prettyPrinted, .sortedKeys]
              )
        else { return nil }
        return (rewritten, kept.count, removed)
    }

    /// Whether `data` parses as a JSON array at all. A file that does not is one the shred can never
    /// clean, which is different from one that simply holds none of the ids (F668).
    public static func isArray(_ data: Data) -> Bool {
        (try? JSONSerialization.jsonObject(with: data)) is [Any]
    }

    /// The ids among `ids` whose text appears anywhere in `data`, compared case-insensitively and
    /// lowercased — for a file that does not parse, where there are no elements to look at, only
    /// bytes (F668). A mention is not proof of a record, but for a copy that cannot be cleaned it is
    /// the honest reason to say the text may still be there.
    public static func mentionedIDs(_ ids: Set<String>, in data: Data) -> Set<String> {
        let text = String(decoding: data, as: UTF8.self).lowercased()
        return Set(ids.map { $0.lowercased() }.filter { text.contains($0) })
    }
}

/// A strict RFC 8259 validator for a top-level JSON array that records each element's byte range
/// (F907). It allocates nothing per value, which is what makes it fast.
///
/// It answers nil — "cannot vouch", and the caller parses the whole file instead — for anything that
/// is not plainly valid, and for the few valid shapes `JSONSerialization` may treat differently: a
/// byte order mark or another encoding (the first byte is not `[` after whitespace), a `\u` escape in
/// the surrogate range, a number with more than 40 digits or an exponent of more than three, and
/// nesting deeper than 128. Being stricter than `JSONSerialization` only costs speed; being looser
/// would let a file it rejects be rewritten, so every doubt is a nil. The one known exception is a
/// number beyond a `Double`'s range (`1e400`), which this accepts and `JSONSerialization` refuses;
/// `JSONArrayShred.removingElements` says why that is kept.
struct ElementScanner {
    let bytes: UnsafeRawBufferPointer
    private var index = 0
    private var depth = 0
    /// Whether the element being walked has a backslash-u escape anywhere in it.
    private var sawUnicodeEscape = false
    /// The top-level elements with a backslash-u escape anywhere in them (F907 review, finding 1).
    /// Such an element's text can spell an id without the id's own characters — an escaped letter or
    /// hyphen — so no byte search can rule it out, and it is parsed and judged like a candidate.
    private(set) var escapedElements = Set<Int>()
    private static let maximumDepth = 128

    init(bytes: UnsafeRawBufferPointer) {
        self.bytes = bytes
    }

    /// The byte range of each element of the top-level array, in order, or nil.
    mutating func topLevelElements() -> [Range<Int>]? {
        skipWhitespace()
        guard peek == UInt8(ascii: "[") else { return nil }
        index += 1
        var elements: [Range<Int>] = []
        skipWhitespace()
        if peek == UInt8(ascii: "]") {
            index += 1
        } else {
            while true {
                skipWhitespace()
                let start = index
                sawUnicodeEscape = false
                guard value() else { return nil }
                if sawUnicodeEscape { escapedElements.insert(elements.count) }
                elements.append(start..<index)
                skipWhitespace()
                if peek == UInt8(ascii: ",") {
                    index += 1
                } else if peek == UInt8(ascii: "]") {
                    index += 1
                    break
                } else {
                    return nil
                }
            }
        }
        skipWhitespace()
        guard index == bytes.count, !elements.isEmpty else { return nil }
        return elements
    }

    private var peek: UInt8? { index < bytes.count ? bytes[index] : nil }

    private mutating func skipWhitespace() {
        while index < bytes.count {
            switch bytes[index] {
            case 0x20, 0x0A, 0x0D, 0x09: index += 1
            default: return
            }
        }
    }

    private mutating func value() -> Bool {
        guard let first = peek else { return false }
        switch first {
        case UInt8(ascii: "{"): return object()
        case UInt8(ascii: "["): return array()
        case UInt8(ascii: "\""): return string()
        case UInt8(ascii: "t"): return literal("true")
        case UInt8(ascii: "f"): return literal("false")
        case UInt8(ascii: "n"): return literal("null")
        case UInt8(ascii: "-"), UInt8(ascii: "0")...UInt8(ascii: "9"): return number()
        default: return false
        }
    }

    private mutating func enter() -> Bool {
        depth += 1
        index += 1
        return depth <= Self.maximumDepth
    }

    private mutating func object() -> Bool {
        guard enter() else { return false }
        skipWhitespace()
        if peek == UInt8(ascii: "}") {
            index += 1
            depth -= 1
            return true
        }
        while true {
            skipWhitespace()
            guard peek == UInt8(ascii: "\""), string() else { return false }
            skipWhitespace()
            guard peek == UInt8(ascii: ":") else { return false }
            index += 1
            skipWhitespace()
            guard value() else { return false }
            skipWhitespace()
            if peek == UInt8(ascii: ",") {
                index += 1
            } else if peek == UInt8(ascii: "}") {
                index += 1
                depth -= 1
                return true
            } else {
                return false
            }
        }
    }

    private mutating func array() -> Bool {
        guard enter() else { return false }
        skipWhitespace()
        if peek == UInt8(ascii: "]") {
            index += 1
            depth -= 1
            return true
        }
        while true {
            skipWhitespace()
            guard value() else { return false }
            skipWhitespace()
            if peek == UInt8(ascii: ",") {
                index += 1
            } else if peek == UInt8(ascii: "]") {
                index += 1
                depth -= 1
                return true
            } else {
                return false
            }
        }
    }

    private mutating func literal(_ word: StaticString) -> Bool {
        let count = word.utf8CodeUnitCount
        guard bytes.count - index >= count else { return false }
        for offset in 0..<count where bytes[index + offset] != word.utf8Start[offset] { return false }
        index += count
        return true
    }

    private mutating func digits() -> Int {
        let start = index
        while let byte = peek, byte >= UInt8(ascii: "0"), byte <= UInt8(ascii: "9") { index += 1 }
        return index - start
    }

    private mutating func number() -> Bool {
        if peek == UInt8(ascii: "-") { index += 1 }
        var mantissa = 0
        if peek == UInt8(ascii: "0") {
            index += 1
            mantissa = 1
        } else {
            mantissa = digits()
            guard mantissa > 0 else { return false }
        }
        if peek == UInt8(ascii: ".") {
            index += 1
            let fraction = digits()
            guard fraction > 0 else { return false }
            mantissa += fraction
        }
        guard mantissa <= 40 else { return false }
        if peek == UInt8(ascii: "e") || peek == UInt8(ascii: "E") {
            index += 1
            if peek == UInt8(ascii: "+") || peek == UInt8(ascii: "-") { index += 1 }
            let exponent = digits()
            guard exponent > 0, exponent <= 3 else { return false }
        }
        return true
    }

    private mutating func string() -> Bool {
        index += 1   // the opening quote
        while index < bytes.count {
            let byte = bytes[index]
            switch byte {
            case UInt8(ascii: "\""):
                index += 1
                return true
            case UInt8(ascii: "\\"):
                index += 1
                guard let escaped = peek else { return false }
                switch escaped {
                case UInt8(ascii: "\""), UInt8(ascii: "\\"), UInt8(ascii: "/"), UInt8(ascii: "b"),
                     UInt8(ascii: "f"), UInt8(ascii: "n"), UInt8(ascii: "r"), UInt8(ascii: "t"):
                    index += 1
                case UInt8(ascii: "u"):
                    sawUnicodeEscape = true
                    index += 1
                    guard bytes.count - index >= 4 else { return false }
                    var scalar: UInt32 = 0
                    for _ in 0..<4 {
                        guard let digit = Self.hexValue(bytes[index]) else { return false }
                        scalar = scalar << 4 | digit
                        index += 1
                    }
                    // A surrogate escape, paired or not: valid JSON, but not vouched for.
                    guard !(0xD800...0xDFFF).contains(scalar) else { return false }
                default:
                    return false
                }
            case 0x00..<0x20:
                return false
            case 0x20..<0x80:
                index += 1
            default:
                guard utf8Sequence() else { return false }
            }
        }
        return false
    }

    /// One multi-byte UTF-8 sequence starting at `index`, by RFC 3629's table: no overlong form, no
    /// surrogate, nothing past U+10FFFF.
    private mutating func utf8Sequence() -> Bool {
        let lead = bytes[index]
        let length: Int
        var secondRange: ClosedRange<UInt8> = 0x80...0xBF
        switch lead {
        case 0xC2...0xDF: length = 2
        case 0xE0: length = 3; secondRange = 0xA0...0xBF
        case 0xE1...0xEC, 0xEE...0xEF: length = 3
        case 0xED: length = 3; secondRange = 0x80...0x9F
        case 0xF0: length = 4; secondRange = 0x90...0xBF
        case 0xF1...0xF3: length = 4
        case 0xF4: length = 4; secondRange = 0x80...0x8F
        default: return false
        }
        guard bytes.count - index >= length, secondRange.contains(bytes[index + 1]) else { return false }
        for offset in 2..<length where !(0x80...0xBF).contains(bytes[index + offset]) { return false }
        index += length
        return true
    }

    private static func hexValue(_ byte: UInt8) -> UInt32? {
        switch byte {
        case UInt8(ascii: "0")...UInt8(ascii: "9"): return UInt32(byte - UInt8(ascii: "0"))
        case UInt8(ascii: "a")...UInt8(ascii: "f"): return UInt32(byte - UInt8(ascii: "a") + 10)
        case UInt8(ascii: "A")...UInt8(ascii: "F"): return UInt32(byte - UInt8(ascii: "A") + 10)
        default: return nil
        }
    }
}
