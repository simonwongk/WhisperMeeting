import Foundation
import Testing
@testable import WhisperCore

// F854, round 2 (the lane review's finding 5). Recover Library counts each generation the ledger no
// longer describes, on the main actor, while the sheet is being opened. That count used to be a full
// `JSONSerialization` parse: a Foundation object graph of the whole index — hundreds of MB at 1,000
// meetings (F526) — built only to read `.count`. `JSONArrayCount` reads the bytes once and counts the
// top-level elements without building anything. Asked to agree with the parser it replaces.

private let cases: [String] = [
    "[]",
    "  [ ]  ",
    "[1]",
    "[1,2,3]",
    "[ 1 , 2 ]\n",
    #"["a","b"]"#,
    #"["a,b","[c]","{d}"]"#,
    #"["quote \" and backslash \\", "\\\""]"#,
    #"[{"id":"A","title":"x, y"},{"id":"B","nested":[1,[2,3],{"k":"]"}]}]"#,
    #"[[],[[]],{}]"#,
    #"["中文, 🎙️", "é"]"#,
    "[true,false,null,-1.5e3]",
    // Not arrays, or not JSON: both must say nil.
    "{}",
    #"{"a":[1,2]}"#,
    "1",
    "",
    "[",
    "[1,2",
    #"["unterminated]"#,
    "[,1]",
    "[1] trailing",
    "[1]]",
    "[{]}",
]

@Test("The top-level element count agrees with JSONSerialization on every shape (F854)")
func theCountAgreesWithTheParser() {
    for text in cases {
        let data = Data(text.utf8)
        let parsed = ((try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed])) as? [Any])?.count
        #expect(JSONArrayCount.topLevelElements(in: data) == parsed, "\(text)")
    }
}

@Test("A trailing comma is not an element (F854)")
func aTrailingCommaIsRefused() {
    // Not in the comparison above: JSONSerialization on this Mac's macOS 27 reads `[1,]` as one
    // element, and what an older Foundation says is not something to assert on another host. No
    // encoder writes it; the counter refuses it rather than guess.
    #expect(JSONArrayCount.topLevelElements(in: Data("[1,]".utf8)) == nil)
}

@Test("The count of an index the app writes is its number of records (F854)")
func theCountOfAnEncodedIndexIsItsRecordCount() throws {
    struct Record: Codable { let id: String; let title: String; let tags: [String]; let notes: String? }
    let records = (0..<250).map {
        Record(id: "\($0)", title: "Meeting, \($0) [draft]", tags: ["a", "{b}"], notes: $0 % 3 == 0 ? nil : "\"quoted\" \\ text")
    }
    let data = try BackupJSONStore<[Record]>.makeEncoder().encode(records)
    #expect(JSONArrayCount.topLevelElements(in: data) == 250)
}
