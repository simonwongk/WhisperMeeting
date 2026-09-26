import Foundation
import Testing
@testable import WhisperCore
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

/// F170 — a chosen reference document reads to its full (capped) raw text, not extracted candidates,
/// so the correction pass can be guided toward spellings that only appear in the reference.
@Test("Reference document reads to prepared raw text (F170)")
func referenceDocumentReadsRawText() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("spec.md")
    try "# Naming\nThe correct spelling is Sequoya, not Sequoia.\n".data(using: .utf8)!.write(to: url)

    let reference = try #require(VocabularyExtractor.referenceText(from: url))
    #expect(reference.contains("Sequoya"))              // raw text, not just proper-noun candidates
    #expect(reference.contains("The correct spelling")) // ordinary words survive (unlike `candidates`)
}

/// F170 — an empty or unreadable reference reads to nil so the UI can say so instead of passing "".
@Test("Empty or unsupported reference document reads to nil (F170)")
func emptyReferenceDocumentReadsToNil() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let empty = dir.appendingPathComponent("empty.txt")
    try "   \n".data(using: .utf8)!.write(to: empty)
    #expect(VocabularyExtractor.referenceText(from: empty) == nil)

    let unsupported = dir.appendingPathComponent("image.bin")
    try Data([0x00, 0x01]).write(to: unsupported)
    #expect(VocabularyExtractor.referenceText(from: unsupported) == nil)
}

// MARK: - F518 Part 2: GB18030/GBK and Big5, the standard Windows encodings for Simplified and
// Traditional Chinese plain text, must decode correctly instead of falling through to the
// Windows-1252 fallback and becoming Latin mojibake. Fixtures in three encodings, per the ticket:
// English (must keep working), GBK (Simplified), and Big5 (Traditional).

/// Apple's own built-in-encodings enum (`CFStringEncodingExt.h`), bridged to a Cocoa
/// `String.Encoding` exactly as `VocabularyExtractor.readText` does — duplicated here (rather than
/// exposed from the `private` production constant) so the fixture bytes are demonstrably built the
/// same way a real Chinese-locale Excel/Notepad export would produce them.
private let gb18030Encoding = String.Encoding(
    rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue))
)
private let big5Encoding = String.Encoding(
    rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(CFStringEncodings.big5.rawValue))
)

/// F518 Part 2 — an English glossary must keep reading correctly once GB18030/Big5 join the
/// fallback chain: they must not intercept plain ASCII/UTF-8 text ahead of the existing encodings.
@Test("An English document still reads correctly with GB18030/Big5 in the fallback chain (F518)")
func englishDocumentStillReadsCorrectly() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("glossary.txt")
    try "Kubernetes\nPrometheus\nGrafana\n".data(using: .utf8)!.write(to: url)

    let terms = try VocabularyExtractor.extract(from: url)
    #expect(terms.contains("Kubernetes"))
    #expect(terms.contains("Prometheus"))
    #expect(terms.contains("Grafana"))
}

/// F518 Part 2 — a GBK/GB18030 Simplified Chinese .csv (no BOM, exactly how Excel and Notepad
/// save a Chinese-locale export) must decode to its real characters, not Windows-1252 mojibake.
@Test("A GBK/GB18030 Simplified Chinese document decodes to its real characters, not mojibake (F518)")
func gbkDocumentDecodesCorrectly() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("glossary.csv")
    let text = "项目背景\n张经理，李总监\n"
    try text.data(using: gb18030Encoding)!.write(to: url)

    let raw = try #require(VocabularyExtractor.referenceText(from: url))
    #expect(raw.contains("项目背景"))
    #expect(raw.contains("张经理"))
    // The Windows-1252 fallback this used to fall through to would have produced Latin garbage —
    // pin that the mojibake byte sequence is gone, not only that the correct text is present.
    #expect(!raw.contains("Ïî"))
}

/// F518 Part 2 — a Big5 Traditional Chinese .txt (no BOM) must decode to its real characters too.
@Test("A Big5 Traditional Chinese document decodes to its real characters, not mojibake (F518)")
func big5DocumentDecodesCorrectly() throws {
    let dir = try makeTempDir()
    defer { try? FileManager.default.removeItem(at: dir) }
    let url = dir.appendingPathComponent("glossary.txt")
    let text = "項目背景\n張經理、李總監\n"
    try text.data(using: big5Encoding)!.write(to: url)

    let raw = try #require(VocabularyExtractor.referenceText(from: url))
    #expect(raw.contains("項目背景"))
    #expect(raw.contains("張經理"))
    #expect(!raw.contains("¶"))
}
