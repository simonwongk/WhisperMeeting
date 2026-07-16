import AppKit
import Foundation
import NaturalLanguage
import PDFKit

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
        let accessed = url.startAccessingSecurityScopedResource()
        defer { if accessed { url.stopAccessingSecurityScopedResource() } }

        let text: String
        switch url.pathExtension.lowercased() {
        case "pdf":
            guard let value = PDFDocument(url: url)?.string else {
                throw VocabularyImportError.unreadableFile
            }
            text = value
        case "txt", "md", "markdown", "csv":
            text = try String(contentsOf: url, encoding: .utf8)
        case "docx":
            var attributes: NSDictionary?
            let value = try NSAttributedString(
                url: url,
                options: [.documentType: NSAttributedString.DocumentType.officeOpenXML],
                documentAttributes: &attributes
            )
            text = value.string
        default:
            throw VocabularyImportError.unsupportedFile
        }
        return candidates(in: text)
    }

    static func candidates(in text: String) -> [String] {
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

        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "#•*-–—"))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if line.count >= 2, line.count <= 48,
               !line.contains("."), !line.contains(","), !line.contains("，") {
                terms.insert(line)
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
