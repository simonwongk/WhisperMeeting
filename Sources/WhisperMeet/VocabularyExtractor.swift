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

    // MARK: - F593: single-word technical jargon on the transcript path

    /// Calendar names are the one common, closed-vocabulary class of English word that is
    /// capitalized by rule regardless of sentence position ("we meet every Monday") rather than by
    /// being a genuine proper noun or technical term — measured directly as the dominant false
    /// positive of the mid-sentence-capitalization signal below on a plain-prose transcript (see
    /// F593's `docs/TICKET_LOG.md` entry for the count). A closed set of 19 names that will never
    /// need another entry, unlike an open-ended "common words" list this codebase deliberately
    /// avoids maintaining by hand.
    private static let calendarWords: Set<String> = [
        "monday", "tuesday", "wednesday", "thursday", "friday", "saturday", "sunday",
        "january", "february", "march", "april", "may", "june", "july",
        "august", "september", "october", "november", "december",
    ]

    /// Whether an NLTagger `.otherWord` occurrence, found only in a TRANSCRIPT (never a document —
    /// see the call site), still looks like a technical term rather than an ordinary word, using
    /// shape signals a common word does not share (F593):
    ///
    /// 1. Contains a digit ("GPT4", "K8s", "Web3") — no ordinary English word does.
    /// 2. Internal mixed case ("gRPC", "GitHub", "iPhone") — an uppercase letter after the first
    ///    character, alongside a lowercase one (so a plain ALL-CAPS acronym, already caught by the
    ///    regex above, does not also take this path).
    /// 3. Capitalized and **mid-sentence**: an ordinary word is capitalized only because it opens a
    ///    sentence; a word capitalized in the middle of one ("Our Kestrel service…") was capitalized
    ///    on purpose. Calendar names are excluded (see `calendarWords`) since English capitalizes
    ///    them by rule, not because they are notable.
    /// 4. Capitalized and **repeats across two or more distinct lines**, even sentence-initially —
    ///    for a term whose position in this transcript always happens to open a sentence. Gated on
    ///    `lexicalClass` being `.noun`, not merely capitalization: this is the one signal that could
    ///    otherwise resurrect a determiner/pronoun/conjunction that recurs at the start of many
    ///    sentences ("The", "We"), which is exactly the F518 regression this ticket must not reopen.
    ///
    /// The `lexicalClass` gate is deliberately scoped to signal 4 only, not signal 3 too. Signal 4
    /// is the one that can resurrect a determiner/pronoun/conjunction, because those words genuinely
    /// do recur at the start of many sentences ("The", "We") — signal 3 has no matching failure mode
    /// in practice, since a function word capitalized *mid*-sentence is not an English usage this
    /// codebase needs to defend against. Measured directly against the jargon-heavy fixture: two
    /// genuine terms ("Ansible", "Elasticsearch") are mis-tagged `.adjective`/`.adverb` by the
    /// installed model rather than `.noun`, so gating signal 3 on `.noun` too would have cost real
    /// recall for no corresponding precision gain.
    private static func looksLikeTranscriptJargon(
        _ word: String,
        at range: Range<String.Index>,
        in text: String,
        lineOccurrences: [String: Int],
        lexicalTagger: NLTagger?
    ) -> Bool {
        if word.contains(where: \.isNumber) { return true }
        if isMixedCaseWord(word) { return true }
        guard let first = word.first, first.isUppercase else { return false }
        guard !calendarWords.contains(word.lowercased()) else { return false }
        if isMidSentence(range, in: text) { return true }
        guard (lineOccurrences[word.lowercased()] ?? 0) >= 2, let lexicalTagger else { return false }
        return lexicalTagger.tag(at: range.lowerBound, unit: .word, scheme: .lexicalClass).0 == .noun
    }

    /// An uppercase letter after the word's first character, alongside a lowercase letter somewhere
    /// in the word — "gRPC", "GitHub", "iPhone". Requiring a lowercase letter too excludes a plain
    /// ALL-CAPS run ("CCPA"), which the dedicated all-caps regex above already handles.
    private static func isMixedCaseWord(_ word: String) -> Bool {
        guard word.contains(where: \.isLowercase) else { return false }
        return word.dropFirst().contains(where: \.isUppercase)
    }

    /// Whether `range` opens mid-sentence rather than at the very start of `text` or immediately
    /// after a sentence-ending mark (reusing `sentenceEndingPunctuation`, the same marks the
    /// document line heuristic treats as ending a clause). Walks backward over whitespace only, so
    /// it costs nothing beyond the immediately preceding run of spaces/newlines.
    private static func isMidSentence(_ range: Range<String.Index>, in text: String) -> Bool {
        var index = range.lowerBound
        while index > text.startIndex {
            let previousIndex = text.index(before: index)
            let character = text[previousIndex]
            if character.isWhitespace {
                index = previousIndex
                continue
            }
            return String(character).rangeOfCharacter(from: sentenceEndingPunctuation) == nil
        }
        return false
    }

    /// How many distinct lines of `text` contain `word` (case-insensitive, whole word), for signal 4
    /// above. Computed once per `candidates` call over the whole transcript, not once per candidate
    /// word, so a transcript with many candidates still costs one pass.
    private static func lineOccurrenceCounts(in text: String) -> [String: Int] {
        guard let wordPattern = try? NSRegularExpression(pattern: #"[A-Za-z][A-Za-z0-9]*"#) else {
            return [:]
        }
        var linesByWord: [String: Set<Int>] = [:]
        for (lineIndex, line) in text.components(separatedBy: .newlines).enumerated() {
            let nsLine = line as NSString
            let matches = wordPattern.matches(in: line, range: NSRange(location: 0, length: nsLine.length))
            for match in matches {
                let word = nsLine.substring(with: match.range).lowercased()
                linesByWord[word, default: []].insert(lineIndex)
            }
        }
        return linesByWord.mapValues(\.count)
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

        // F593: after F518 scoped the name finder to person/place/organisation tags, a single-word
        // technical term in running prose — "Kubernetes", "Grafana", "Kestrel" — is tagged
        // `.otherWord` just like a common word, so it stopped being suggested at all. F518's own
        // property (no ordinary word suggested) must hold on the DOCUMENT path, where the line
        // heuristic below already recovers short jargon lines a name-type tag misses. The transcript
        // path (`includeLineHeuristic: false`) has no such fallback, so `.otherWord` there gets one
        // more chance under shape signals a common word does not share (`looksLikeTranscriptJargon`).
        // Never applied to Chinese: the tagger's Chinese catch-all is a different tag, `.other`, and
        // none of these shape signals (Latin case, digits) mean anything for Chinese text anyway —
        // `ordinaryChineseWordsAreNotCandidates` below stays exactly as strict as F518 left it.
        let lexicalTagger: NLTagger?
        let lineOccurrences: [String: Int]
        if includeLineHeuristic {
            lexicalTagger = nil
            lineOccurrences = [:]
        } else {
            let posTagger = NLTagger(tagSchemes: [.lexicalClass])
            posTagger.string = text
            lexicalTagger = posTagger
            lineOccurrences = lineOccurrenceCounts(in: text)
        }

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
            } else if !includeLineHeuristic, tag == .otherWord,
                      looksLikeTranscriptJargon(
                          String(text[range]),
                          at: range,
                          in: text,
                          lineOccurrences: lineOccurrences,
                          lexicalTagger: lexicalTagger
                      ) {
                terms.insert(String(text[range]))
            }
            return true
        }

        addMatches(
            pattern: #"\b[A-Z][A-Z0-9][A-Z0-9._-]{1,15}\b"#,
            from: text,
            to: &terms
        )
        addCapitalizedPhraseMatches(from: text, to: &terms)

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

    /// Function words that open a sentence capitalized and so read, to the capitalized-phrase
    /// rule, as the first word of a name: "Our Kestrel service…" gave "Our Kestrel" (F623).
    /// Articles, demonstratives, possessive determiners, personal pronouns and conjunctions: closed
    /// grammatical classes, so this is a closed set in the `calendarWords` sense, not a
    /// "common words" list. Single letters ("A", "I") are absent because the phrase rule's first
    /// word needs two. Prepositions are deliberately left out, because they open real terms
    /// ("On Call", "To Do") about as often as they open a sentence.
    ///
    /// Chosen over the first token's `.lexicalClass` tag, which gave the same output on the F593
    /// fixtures and this ticket's examples (measured for F623), because a list does not inherit
    /// the tagger's local-versus-CI model risk that F593 recorded.
    private static let leadingFunctionWords: Set<String> = [
        "the", "an",
        "this", "that", "these", "those",
        "my", "our", "your", "his", "her", "its", "their",
        "we", "you", "he", "she", "it", "they", "me", "us", "him", "them",
        "and", "but", "or", "nor", "so", "yet",
        "if", "when", "while", "because", "although", "though", "since", "unless",
    ]

    /// Two to four capitalized words in a row ("Priya Raman", "New York"), on both paths. A leading
    /// function word is dropped first (F623), only in title case so an acronym that spells one
    /// ("IT Operations", "US Treasury") is kept whole, and what is left counts only if it is still
    /// two or more words. A single word is not this rule's to suggest: on the document path F518
    /// keeps single `.otherWord` terms out, and on the transcript path `looksLikeTranscriptJargon`
    /// already judges the word on its own ("Kestrel", capitalized after "Our", is mid-sentence).
    private static func addCapitalizedPhraseMatches(from text: String, to terms: inout Set<String>) {
        guard let expression = try? NSRegularExpression(
            pattern: #"\b[A-Z][\p{L}\p{M}'’-]+(?:\s+[A-Z][\p{L}\p{M}'’-]+){1,3}\b"#
        ) else { return }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        for match in expression.matches(in: text, range: range) {
            guard let range = Range(match.range, in: text) else { continue }
            var phrase = text[range]
            while let end = phrase.firstIndex(where: \.isWhitespace),
                  isTitleCaseFunctionWord(phrase[..<end]) {
                phrase = phrase[end...].drop(while: \.isWhitespace)
            }
            if phrase.split(whereSeparator: \.isWhitespace).count >= 2 {
                terms.insert(String(phrase))
            }
        }
    }

    private static func isTitleCaseFunctionWord(_ word: Substring) -> Bool {
        guard let first = word.first, first.isUppercase,
              !word.dropFirst().contains(where: \.isUppercase) else { return false }
        return leadingFunctionWords.contains(word.lowercased())
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
