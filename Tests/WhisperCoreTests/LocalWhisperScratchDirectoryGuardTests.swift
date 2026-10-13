import Foundation
import Testing
@testable import WhisperCore

// F937 — a `LocalWhisperClient` built without `scratchDirectory` puts its run folder in the real
// `$TMPDIR`, and since F533 (review R7) every run first sweeps that folder of
// `WhisperMeet-Whisper-<dead pid>-<UUID>` folders. A test doing that deletes from a folder it does not
// own — the developer's and the CI runner's — which is the host coupling AGENTS.md warns about.
// Nothing in use can be lost (only dead-pid folders), so no test can observe the harm; this scan
// holds the rule instead: every client a test builds names a scratch directory of its own.

private let testDirectories = ["WhisperCoreTests", "WhisperMeetTests"]

private func testsRoot() -> URL {
    // …/Tests/WhisperCoreTests/<this file> → …/Tests
    URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
}

/// Comment-stripped source (`//` to end of line, `/* … */` blocks), so a comment that quotes the
/// construction cannot satisfy or trip the scan (F285's lesson).
private func strippingComments(_ source: String) -> String {
    var output = ""
    var characters = Array(source)
    characters.append(" ")
    var index = 0
    while index < characters.count - 1 {
        if characters[index] == "/", characters[index + 1] == "/" {
            while index < characters.count, !characters[index].isNewline { index += 1 }
        } else if characters[index] == "/", characters[index + 1] == "*" {
            index += 2
            while index < characters.count - 1, !(characters[index] == "*" && characters[index + 1] == "/") { index += 1 }
            index += 2
        } else {
            output.append(characters[index])
            index += 1
        }
    }
    return output
}

/// Every `LocalWhisperClient(` construction in `source` with the text of its balanced argument list.
private func clientConstructions(in source: String) -> [String] {
    let characters = Array(source)
    let marker = Array("LocalWhisperClient(")
    var found: [String] = []
    var index = 0
    while index + marker.count <= characters.count {
        guard Array(characters[index..<index + marker.count]) == marker,
              // Not `.LocalWhisperClient(` or a longer identifier ending in the name.
              index == 0 || !(characters[index - 1].isLetter || characters[index - 1].isNumber || characters[index - 1] == "_" || characters[index - 1] == ".")
        else { index += 1; continue }
        var depth = 1
        var end = index + marker.count
        while end < characters.count, depth > 0 {
            if characters[end] == "(" { depth += 1 } else if characters[end] == ")" { depth -= 1 }
            end += 1
        }
        found.append(String(characters[index..<end]))
        index = end
    }
    return found
}

@Test("Every LocalWhisperClient a test builds names its own scratch directory, so no test sweeps the real temporary folder (F937)")
func everyTestWhisperClientNamesAScratchDirectory() throws {
    let files = FileManager.default
    var offenders: [String] = []
    var constructions = 0
    for directory in testDirectories {
        let root = testsRoot().appendingPathComponent(directory, isDirectory: true)
        // This file holds the marker as a string literal, which is the one match that is not a client.
        let thisFile = URL(fileURLWithPath: #filePath).lastPathComponent
        let names = try files.contentsOfDirectory(atPath: root.path)
            .filter { $0.hasSuffix(".swift") && $0 != thisFile }.sorted()
        for name in names {
            let source = try String(contentsOf: root.appendingPathComponent(name), encoding: .utf8)
            for construction in clientConstructions(in: strippingComments(source)) {
                constructions += 1
                if !construction.contains("scratchDirectory:") {
                    offenders.append("\(directory)/\(name): \(construction.prefix(60))…")
                }
            }
        }
    }
    // Fail closed: a scan that finds nothing is a broken scan, not a clean tree.
    #expect(constructions > 0)
    #expect(offenders.isEmpty, "clients built without scratchDirectory:\n\(offenders.joined(separator: "\n"))")
}
