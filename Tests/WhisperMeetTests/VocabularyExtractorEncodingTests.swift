import Foundation
import Testing
@testable import WhisperMeet

private func makeTempDir() throws -> URL {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("VocabularyExtractorEncodingTests-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    return dir
}

/// F49 — a non-UTF-8 glossary file must yield candidate terms instead of throwing.
@Test("Vocabulary import reads a non-UTF-8 (UTF-16) document")
func importsNonUTF8Document() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let utf16URL = dir.appendingPathComponent("glossary.csv")
    try "Kubernetes\nPrometheus\n".data(using: .utf16)!.write(to: utf16URL)

    let terms = try VocabularyExtractor.extract(from: utf16URL)
    #expect(terms.contains("Kubernetes"))
    #expect(terms.contains("Prometheus"))
}

/// F49 — one unreadable file in a batch must not throw away the good files' terms.
@Test("Vocabulary batch import skips a bad file and keeps the good files' terms")
func batchImportSkipsBadFiles() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let utf16URL = dir.appendingPathComponent("a.csv")
    try "Kubernetes\nPrometheus\n".data(using: .utf16)!.write(to: utf16URL)
    let utf8URL = dir.appendingPathComponent("b.txt")
    try "Grafana\n".data(using: .utf8)!.write(to: utf8URL)
    let badURL = dir.appendingPathComponent("image.bin") // unsupported extension → throws
    try Data([0x00, 0x01, 0x02]).write(to: badURL)

    let result = VocabularyExtractor.extractBatch(from: [utf16URL, badURL, utf8URL])

    #expect(result.terms.contains("Kubernetes")) // survives the non-UTF-8 read
    #expect(result.terms.contains("Grafana"))    // survives the sibling bad file
    #expect(result.failed.map(\.lastPathComponent) == ["image.bin"])
}
