import Foundation

/// The number of top-level elements in a JSON array, read from its bytes without parsing them into
/// objects (F854).
///
/// Recover Library counts each retained generation the ledger no longer describes, on the main actor
/// while its sheet opens, and a save does the same once per launch for each such file (F677). Both
/// used `JSONSerialization`, which builds a Foundation object graph of the whole index — hundreds of
/// MB at 1,000 meetings (F526) — only to read `.count`. This walks the bytes once, tracking strings
/// (with their escapes) and nesting, and counts the commas at depth one.
///
/// It checks structure, not every token: brackets and braces must balance and nest correctly,
/// strings must close, nothing but whitespace may follow the array, and an element may not be empty
/// (`[1,]`, `[,1]`). Two scalars run together (`[1 2]`) are not caught — every caller has already
/// verified the bytes against the content fingerprint in their file name, so they are bytes a
/// `JSONEncoder` wrote, and the question is only how many elements they hold.
public enum JSONArrayCount {
    public static func topLevelElements(in data: Data) -> Int? {
        data.withUnsafeBytes { raw -> Int? in
            let bytes = raw.bindMemory(to: UInt8.self)
            return count(bytes)
        }
    }

    private static let openArray = UInt8(ascii: "["), closeArray = UInt8(ascii: "]")
    private static let openObject = UInt8(ascii: "{"), closeObject = UInt8(ascii: "}")
    private static let quote = UInt8(ascii: "\""), backslash = UInt8(ascii: "\\"), comma = UInt8(ascii: ",")

    private static func isWhitespace(_ byte: UInt8) -> Bool {
        byte == 0x20 || byte == 0x09 || byte == 0x0A || byte == 0x0D
    }

    private static func count(_ bytes: UnsafeBufferPointer<UInt8>) -> Int? {
        var index = 0
        let end = bytes.count
        while index < end, isWhitespace(bytes[index]) { index += 1 }
        guard index < end, bytes[index] == openArray else { return nil }
        index += 1

        // The open containers below the top-level array, innermost last.
        var stack: [UInt8] = []
        var elements = 0
        // Whether the current top-level element has any content yet.
        var elementHasContent = false
        var sawComma = false
        while index < end {
            let byte = bytes[index]
            index += 1
            if byte == quote {
                // Skip the string, honouring escapes.
                var closed = false
                while index < end {
                    let inner = bytes[index]
                    index += 1
                    if inner == backslash { index += 1; continue }
                    if inner == quote { closed = true; break }
                }
                guard closed else { return nil }
                if stack.isEmpty { elementHasContent = true }
                continue
            }
            if isWhitespace(byte) { continue }
            if stack.isEmpty {
                if byte == comma {
                    guard elementHasContent else { return nil }
                    elements += 1
                    elementHasContent = false
                    sawComma = true
                    continue
                }
                if byte == closeArray {
                    if elementHasContent {
                        elements += 1
                    } else if sawComma {
                        return nil   // `[1,]`
                    }
                    while index < end, isWhitespace(bytes[index]) { index += 1 }
                    return index == end ? elements : nil
                }
                if byte == closeObject { return nil }
                elementHasContent = true
            }
            switch byte {
            case openArray, openObject:
                stack.append(byte)
            case closeArray:
                guard stack.popLast() == openArray else { return nil }
            case closeObject:
                guard stack.popLast() == openObject else { return nil }
            default:
                break
            }
        }
        return nil   // the array never closed
    }
}
