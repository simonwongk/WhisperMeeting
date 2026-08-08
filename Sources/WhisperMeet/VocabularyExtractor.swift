import AppKit
import Foundation
import NaturalLanguage
import PDFKit
import WhisperCore

enum VocabularyImportError: LocalizedError {
    case unsupportedFile
    case unreadableFile

    var errorDescription: String? {
        switch self {
        case .unsupportedFile:
            return "Choose a PDF, DOCX, TXT, or Markdown document."
        case .unreadableFile:
            return "The selected document could not be read."
        }
    }
}

enum VocabularyExtractor {
    static func extract(from url: URL) throws -> [String] {
        candidates(in: try rawText(from: url))
    }

    /// Reads a document's full plain text — the same per-type reading as `extract`, but returning the
    /// raw text instead of extracted candidate terms. Used for F170 reference documents, where the
    /// user wants the model guided by the document's actual spellings (including ordinary words), not
    /// only its proper-noun candidates.
    static func rawText(from url: URL) throws -> String {
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        switch url.pathExtension.lowercased() {
        case "pdf":
            guard let value = PDFDocument(url: url)?.string else {
                throw VocabularyImportError.unreadableFile
            }
            return value
        case "txt", "md", "markdown", "csv":
            return try readText(from: url)
        case "docx":
            var attributes: NSDictionary?
            let value = try NSAttributedString(
                url: url,
                options: [.documentType: NSAttributedString.DocumentType.officeOpenXML],
                documentAttributes: &attributes
            )
            return value.string
        default:
            throw VocabularyImportError.unsupportedFile
        }
    }

    /// The prepared (trimmed, context-window-capped, line-safe) text of a chosen reference document for
    /// the F170 correction pass, or `nil` if the document could not be read or has no usable text — in
    /// which case the caller passes `reference: nil` and the corrector simply skips the reference.
    static func referenceText(from url: URL) -> String? {
        guard let text = try? rawText(from: url) else { return nil }
        return ReferenceDocument.prepared(text)
    }

    /// Reads a plain-text document, tolerating non-UTF-8 encodings. Excel CSVs (Windows-1252),
    /// UTF-16, and Latin-1 `.txt` files are common and must not throw. Tries the file's declared
    /// encoding first, then a small list of fallbacks (F49).
    private static func readText(from url: URL) throws -> String {
        var detected = String.Encoding.utf8
        if let text = try? String(contentsOf: url, usedEncoding: &detected) {
            return text
        }
        for encoding in [String.Encoding.utf8, .utf16, .windowsCP1252, .isoLatin1] {
            if let text = try? String(contentsOf: url, encoding: encoding) {
                return text
            }
        }
        throw VocabularyImportError.unreadableFile
    }

    /// Extracts candidate terms from several files, skipping (never aborting on) any file that cannot
    /// be read, so one bad file in a batch does not throw away the good files' terms (F49). Returns
    /// the merged, first-seen-deduplicated terms and the URLs that failed.
    static func extractBatch(from urls: [URL]) -> (terms: [String], failed: [URL]) {
        var terms: [String] = []
        var failed: [URL] = []
        for url in urls {
            if let extracted = try? extract(from: url) {
                terms.append(contentsOf: extracted)
            } else {
                failed.append(url)
            }
        }
        var seen = Set<String>()
        return (terms.filter { seen.insert($0).inserted }, failed)
    }

    /// Extracts candidate proper nouns / key terms from free text.
    /// - Parameter includeLineHeuristic: when true (documents), whole short lines are treated as
    ///   candidate terms — useful for glossaries and bullet lists, but wrong for transcripts, where
    ///   each spoken line would become a bogus term. Transcript suggestions pass `false`.
    static func candidates(in text: String, includeLineHeuristic: Bool = true) -> [String] {
        guard !text.isEmpty else { return [] }
        var terms = Set<String>()

        let tagger = NLTagger(tagSchemes: [.nameType])
        tagger.string = text
        tagger.enumerateTags(
            in: text.startIndex..<text.endIndex,
            unit: .word,
            scheme: .nameType,
            options: [.omitWhitespace, .omitPunctuation, .joinNames]
        ) { tag, range in
            if tag != nil {
                terms.insert(String(text[range]))
            }
            return true
        }

        addMatches(
            pattern: #"\b[A-Z][A-Z0-9][A-Z0-9._-]{1,15}\b"#,
            from: text,
            to: &terms
        )
        addMatches(
            pattern: #"\b[A-Z][\p{L}\p{M}'’-]+(?:\s+[A-Z][\p{L}\p{M}'’-]+){1,3}\b"#,
            from: text,
            to: &terms
        )

        if includeLineHeuristic {
            for rawLine in text.split(whereSeparator: \.isNewline) {
                let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                    .trimmingCharacters(in: CharacterSet(charactersIn: "#•*-–—"))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if line.count >= 2, line.count <= 48,
                   !line.contains("."), !line.contains(","), !line.contains("，") {
                    terms.insert(line)
                }
            }
        }

        return terms
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { $0.count >= 2 && $0.count <= 80 }
            .sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
            .prefix(200)
            .map { $0 }
    }

    private static func addMatches(
        pattern: String,
        from text: String,
        to terms: inout Set<String>
    ) {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for match in expression.matches(in: text, range: range) {
            guard let range = Range(match.range, in: text) else { continue }
            terms.insert(String(text[range]))
        }
    }
}
