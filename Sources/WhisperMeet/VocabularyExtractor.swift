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

    /// GB18030 (a superset of GBK), the standard encoding for Simplified Chinese plain text on
    /// Windows (F518). `CFStringEncodings` is Apple's own built-in-encodings enum — see
    /// `CFStringEncodingExt.h`, `kCFStringEncodingGB_18030_2000 = 0x0632` — bridged to a
    /// Cocoa `String.Encoding` through `CFStringConvertEncodingToNSStringEncoding`.
    private static let gb18030Encoding = String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.GB_18030_2000.rawValue)
        )
    )

    /// Big5, the standard encoding for Traditional Chinese plain text on Windows (F518).
    /// `kCFStringEncodingBig5 = 0x0A03` in `CFStringEncodingExt.h`.
    private static let big5Encoding = String.Encoding(
        rawValue: CFStringConvertEncodingToNSStringEncoding(
            CFStringEncoding(CFStringEncodings.big5.rawValue)
        )
    )

    /// Marks that end a sentence or clause, ASCII and full-width, checked by the document line
    /// heuristic below (F518 Part 3). The ASCII comma was already rejected before this fix and
    /// stays rejected — unchanged, English-side behaviour. Deliberately excludes '、' and '，'
    /// (the full-width comma): those join short list items ("张经理、李总监") at least as often
    /// as they end a clause, so they are handled separately, by splitting rather than rejecting.
    ///
    /// Presence alone is not the test any more (F518 follow-up, review round 2): a line merely
    /// *containing* one of these used to reject unconditionally, which also rejected a term that
    /// is itself punctuated — "Yahoo!" — where the old (pre-F518) code kept it. See
    /// `lineReadsAsSentence` below for the narrower rule that replaced the bare presence check.
    private static let sentenceEndingPunctuation = CharacterSet(charactersIn: ".,!?;:。！？；")

    /// Enumeration marks that join short list items on one line (F518 Part 3): the Chinese
    /// enumeration comma '、' and the full-width comma '，'. A line whose only punctuation is one
    /// of these is split into its parts instead of being kept as one joined, unusable term.
    private static let enumerationSeparators = CharacterSet(charactersIn: "、，")

    /// Whether `line` reads as a sentence or clause rather than as a punctuated term (F518 Part 3
    /// follow-up). Only called when `line` contains at least one `sentenceEndingPunctuation` mark.
    ///
    /// A Chinese sentence-ending mark is unambiguous: no legitimate business term itself ends in
    /// '。', '！', or '；' — a term or name written in Chinese has no reason to carry one — so any
    /// occurrence of one in a line that contains Han characters rejects the whole line, exactly as
    /// before this follow-up ("这是一句话。", "请提醒我下午三点跟客户开会！").
    ///
    /// A Latin mark is far more overloaded — brand and product names routinely end in '!' or '?'
    /// ("Yahoo!") — so for a line with no Han characters, presence alone no longer rejects. It
    /// rejects only when the line goes on to show actual sentence structure: longer than a term
    /// could be (the same 48-character cap the caller enforces, checked here so a long sentence is
    /// recognized as a sentence rather than silently falling out of the length filter instead),
    /// carrying whitespace-separated words the way a clause does ("Kubernetes, Prometheus" already
    /// had this shape before this follow-up and must keep rejecting), or having more text after the
    /// last sentence-ending mark rather than ending on one ("Wait, really?! No.").
    private static func lineReadsAsSentence(_ line: String) -> Bool {
        guard line.rangeOfCharacter(from: sentenceEndingPunctuation) != nil else { return false }
        if containsHanCharacters(line) { return true }
        if line.count > 48 { return true }
        if line.rangeOfCharacter(from: .whitespaces) != nil { return true }
        guard let lastScalar = line.unicodeScalars.last else { return false }
        return !sentenceEndingPunctuation.contains(lastScalar)
    }

    /// Whether `text` contains a Han (Chinese) ideograph — the same two Unicode blocks
    /// `ProtectedTerms.hasCJK` checks in `WhisperCore`. Duplicated rather than shared: that function
    /// is `private` to `WhisperCore`, and this file lives in `WhisperMeet`.
    private static func containsHanCharacters(_ text: String) -> Bool {
        text.unicodeScalars.contains { scalar in
            (0x4E00...0x9FFF).contains(scalar.value) || (0x3400...0x4DBF).contains(scalar.value)
        }
    }

    /// Reads a plain-text document, tolerating non-UTF-8 encodings. Excel CSVs (Windows-1252),
    /// UTF-16, and Latin-1 `.txt` files are common and must not throw (F49); GB18030/GBK and Big5
    /// `.txt`/`.csv` files, with no BOM, are just as common on a Chinese-locale workflow and must
    /// not be silently misread either (F518).
    ///
    /// `usedEncoding` only recognizes a BOM or a filesystem xattr, so a bare GBK/GB18030 or Big5
    /// export (no BOM — exactly how Excel and Notepad save one) always falls through it. A plain
    /// ordered list of encodings to try in turn cannot safely stand in for it here the way it does
    /// for the Western fallbacks below: GB18030's and Big5's multi-byte ranges overlap enough that
    /// either one "succeeds" — decodes without throwing, into different but equally plausible-looking
    /// Han characters — on the other's common text. Verified directly: a Simplified business
    /// glossary's GB18030 bytes decode without error as garbled (wrong) Big5 text, and a Traditional
    /// glossary's Big5 bytes decode without error as garbled (wrong) GB18030 text, so whichever
    /// encoding a fixed ordered list tried first would silently win over the other every time,
    /// solving the CP1252-mojibake failure this ticket reports only by replacing it with a same-shaped
    /// one level down (wrong Han characters instead of wrong Latin ones).
    ///
    /// `NSString.stringEncoding(for:convertedString:usedLossyConversion:)` runs Apple's own
    /// statistical detector instead of a bare "did this throw" check, and correctly told a GB18030
    /// sample from a Big5 one in every case measured for this fix. Hint it toward exactly the two
    /// encodings this ticket is about (it still tries its full default list alongside them) and
    /// require a non-lossy result — a lossy one means it had to guess at unmappable bytes, and this
    /// codebase would rather fall through than keep a guess. The plain ordered list remains below as
    /// the last-resort fallback for whatever the detector could not decide at all (a return of 0).
    /// What "measured for this fix" means is enforced, not just remembered: GB18030 and Big5 each
    /// have a committed fixture test (`VocabularyExtractorEncodingTests.gbkDocumentDecodesCorrectly`
    /// / `.big5DocumentDecodesCorrectly`), and hinting the detector toward those two must not cost
    /// the pre-existing Windows-1252 fallback — pinned by
    /// `.westernCP1252DocumentStillDecodesCorrectly`, a sample with smart quotes, an em dash, and
    /// accented Latin letters that GB18030/Big5 cannot represent.
    ///
    /// Residual risk, stated rather than hidden: detection is still probabilistic. A very short
    /// document (a handful of terms, as a vocabulary glossary often is) gives the statistical
    /// detector little to work with, and a short GB18030/Big5 sample that the detector cannot
    /// confidently place falls to the ordered list below, where GB18030 is tried before Big5 — a
    /// short Traditional-only glossary could still be misread as (wrong) Simplified text in that
    /// last-resort path. There is no encoding-agnostic way to eliminate this with ordering alone;
    /// only a longer sample or a user-supplied hint would.
    private static func readText(from url: URL) throws -> String {
        var detected = String.Encoding.utf8
        if let text = try? String(contentsOf: url, usedEncoding: &detected) {
            return text
        }
        if let data = try? Data(contentsOf: url) {
            var convertedString: NSString?
            var usedLossy: ObjCBool = false
            let suggested = [gb18030Encoding.rawValue, big5Encoding.rawValue] as NSArray
            let detectedEncoding = NSString.stringEncoding(
                for: data,
                encodingOptions: [.suggestedEncodingsKey: suggested],
                convertedString: &convertedString,
                usedLossyConversion: &usedLossy
            )
            if detectedEncoding != 0, !usedLossy.boolValue, let text = convertedString as String? {
                return text
            }
        }
        for encoding in [String.Encoding.utf8, .utf16, gb18030Encoding, big5Encoding, .windowsCP1252, .isoLatin1] {
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
            // F518: `tag != nil` also accepted `.otherWord` (and Chinese `.other`) — the scheme's
            // catch-all for "some word, not a name" — so every word of 2+ characters in the
            // document became a candidate: the, and, of, we, will, 我们, 明天. Only a name the
            // tagger actually classified as a person, place, or organisation belongs in Vocabulary.
            if tag == .personalName || tag == .placeName || tag == .organizationName {
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
                guard !line.isEmpty else { continue }
                // F518 Part 3: the check was clearly meant to exclude sentences — it already
                // rejected the ASCII and full-width comma — but it omitted every other
                // sentence-ending mark, ASCII or full-width, so "本次会议讨论了预算问题。" and
                // "请大家准时参加！" passed straight through as whole-sentence "terms". A bare
                // enumeration mark ('、' or '，') does not by itself mean a sentence, though: it
                // commonly *joins* short list items ("张经理、李总监"), so a line whose only
                // punctuation is an enumeration mark is split into its parts instead of being
                // rejected outright or kept as one unusable joined term. `lineReadsAsSentence`
                // (review-round-2 follow-up) narrows the sentence-mark check further: rejecting on
                // bare presence also rejected a term that is itself punctuated ("Yahoo!"), which the
                // pre-F518 code had kept.
                guard !lineReadsAsSentence(line) else { continue }
                if line.rangeOfCharacter(from: enumerationSeparators) != nil {
                    for rawPart in line.components(separatedBy: enumerationSeparators) {
                        let part = rawPart.trimmingCharacters(in: .whitespacesAndNewlines)
                        if part.count >= 2, part.count <= 48 {
                            terms.insert(part)
                        }
                    }
                } else if line.count >= 2, line.count <= 48 {
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
