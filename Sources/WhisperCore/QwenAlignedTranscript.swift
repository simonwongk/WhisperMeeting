import Foundation

public struct QwenAlignedItem: Codable, Sendable, Equatable {
    public let text: String
    public let start: Double
    public let end: Double

    public init(text: String, start: Double, end: Double) {
        self.text = text
        self.start = start
        self.end = end
    }
}

public enum QwenAlignedTranscript {
    /// Maps Qwen's word-level alignment back onto the model's punctuated transcript, one sentence at
    /// a time. A sentence that cannot be found among the aligner's words is returned untimed with its
    /// text intact; if no sentence can be found at all this returns no segments, so callers keep the
    /// complete original text instead of risking dropped words (F30, F263).
    public static func segments(
        fullText: String,
        alignedItems: [QwenAlignedItem]
    ) -> [TranscriptSegment] {
        let sentences = sentenceSlices(fullText)
        guard !sentences.isEmpty, !alignedItems.isEmpty else { return [] }

        let stream = KeyStream(alignedItems)
        let keys = sentences.map { Array(alignmentKey($0).unicodeScalars) }

        // For each sentence, the key of the next sentence that has one: what a re-sync must be
        // followed by (see `place`). `nil` after the last such sentence.
        var following = [[Unicode.Scalar]?](repeating: nil, count: keys.count)
        var nextKey: [Unicode.Scalar]?
        for index in keys.indices.reversed() {
            following[index] = nextKey
            if !keys[index].isEmpty { nextKey = keys[index] }
        }

        var cursor = 0
        var unplaced = 0
        var result: [TranscriptSegment] = []
        var timedCount = 0

        for (index, sentence) in sentences.enumerated() {
            let key = keys[index]
            if !key.isEmpty,
               let offset = place(
                   key, in: stream, cursor: cursor, unplaced: unplaced, followedBy: following[index]
               ) {
                // A sentence that begins or ends inside an aligner word ("I think." / ".maybe …"
                // against the one word "thinkmaybe") takes that word's timing. It is the same word,
                // not a neighbour's, so the rule below is not bent.
                let last = offset + key.count - 1
                result.append(TranscriptSegment(
                    speaker: nil,
                    start: alignedItems[stream.owner[offset]].start,
                    end: alignedItems[stream.owner[last]].end,
                    text: sentence
                ))
                cursor = last + 1
                unplaced = 0
                timedCount += 1
            } else {
                // Untimed, and never inherited from a neighbour: a wrong timestamp seeks the user
                // to the wrong place in the audio, which is worse than having none. The text is
                // still verbatim, so the original "complete text preserved" guarantee holds. The
                // cursor does not move: a sentence that was not found consumes nothing (F420).
                result.append(TranscriptSegment(speaker: nil, start: nil, end: nil, text: sentence))
                unplaced += key.count
            }
        }

        // Nothing reconciled at all — keep the pre-F263 contract exactly. `QwenASRClient`'s F30
        // warning and the caller's fallback to the raw transcript both key off an empty result, and
        // partial recovery must only ADD to that behaviour, never change it.
        guard timedCount > 0 else { return [] }
        return result
    }

    /// How far a re-sync may look ahead of the cursor, in key scalars, given `unplaced` — the key
    /// length of the sentences that have failed since the last one placed (F420).
    ///
    /// The aligner is given the same chunk texts that are joined into the transcript, on both of
    /// the helper's paths (`qwen_transcribe.py`: `segments_for` and `joined_text` over one list of
    /// texts; mlx-audio 0.3.1's own `generate` in `qwen3_asr.py` joins the texts it puts in
    /// `segments`), and `align_chunks` aligns each chunk's text. So the aligner's words spell the
    /// transcript's letters, minus any chunk it skipped: after a run of failed sentences the next
    /// one is normally no further ahead than the letters that failed, which is the `unplaced` term.
    ///
    /// It is counted twice so that the window outgrows a surplus — letters the aligner has and the
    /// transcript lacks — of any size. Not expected, but each miss moves the next sentence exactly
    /// one-for-one further from the cursor, so a window that also grew one-for-one would never
    /// reach it, and every later sentence would be lost exactly as before F420. Growing two-for-one,
    /// it overtakes a surplus after about that many letters of misses. The slack lets the first
    /// sentence after a surplus of a few letters be found at once.
    ///
    /// The window only bounds how far a match may jump. What stops a wrong one is the anchor in
    /// `place`.
    private static func resyncWindow(unplaced: Int) -> Int {
        2 * unplaced + 16
    }

    /// Where `key` starts in the aligner's words, or `nil` if it cannot be placed (F420).
    ///
    /// The previous matcher assembled items one at a time and gave up on the first item that
    /// diverged, having already consumed it. When a sentence boundary fell inside an aligner word,
    /// the next sentence started one item late, failed, consumed one more, and so on: one mismatch
    /// untimed the rest of the meeting, because the item cursor never caught up. Matching against
    /// the concatenated key stream takes item boundaries out of the question, and a miss consumes
    /// nothing.
    ///
    /// - **In step** (`unplaced == 0`: no sentence with letters has failed since the last one
    ///   placed), a sentence
    ///   found exactly at `cursor` is taken there without further evidence. That is the ordinary
    ///   case, and what the previous matcher did.
    /// - **Otherwise**, a match is only a candidate. It may start at `cursor` or at the start of an
    ///   aligner word at most `resyncWindow(unplaced:)` scalars ahead, so how far a sentence can
    ///   skip is bounded by how much text has already failed. And it must be **anchored**: the next
    ///   sentence that has any letters must follow it immediately or, when there is none, the
    ///   aligner's words must end there. One short sentence ("Yeah.") recurs everywhere, and two
    ///   consecutive sentences agreeing is what being back in step means. Without the anchor a
    ///   dropped "Yeah." would take the next "yeah" ahead — or the "Yeah," that opens the very next
    ///   sentence — and time the wrong words. Without the window, a dropped sentence that recurs
    ///   later in the meeting would be placed there and untime everything in between.
    private static func place(
        _ key: [Unicode.Scalar],
        in stream: KeyStream,
        cursor: Int,
        unplaced: Int,
        followedBy next: [Unicode.Scalar]?
    ) -> Int? {
        if unplaced == 0, stream.matches(key, at: cursor) { return cursor }

        guard let first = key.first else { return nil }
        let furthest = min(cursor + resyncWindow(unplaced: unplaced), stream.scalars.count - key.count)
        func isAnchored(_ offset: Int) -> Bool {
            let end = offset + key.count
            return next.map { stream.matches($0, at: end) } ?? (end == stream.scalars.count)
        }

        if stream.matches(key, at: cursor), isAnchored(cursor) { return cursor }
        // Only word starts that begin with the key's first letter are worth comparing. Walking every
        // offset in the window instead took 57 s in a debug build for 2,400 synthetic sentences
        // against 21,600 aligner words that matched none of them; this takes 0.05 s on that input,
        // and 3.4 s on the worst one measured — the sentences' own ten words in an order that never
        // spells one, so that a tenth of the word starts in every window are candidates.
        for offset in stream.wordStarts(beginningWith: first, after: cursor, through: furthest)
        where stream.matches(key, at: offset) && isAnchored(offset) {
            return offset
        }
        return nil
    }

    /// Every aligned item's key laid end to end, with the item each scalar came from (F420).
    private struct KeyStream {
        let scalars: [Unicode.Scalar]
        /// `owner[i]` is the index in `alignedItems` of the item that `scalars[i]` came from.
        let owner: [Int]
        /// The offsets at which each aligner word begins, keyed by the word's first scalar, in
        /// ascending order.
        private let wordStartsByFirstScalar: [Unicode.Scalar: [Int]]

        init(_ items: [QwenAlignedItem]) {
            var scalars: [Unicode.Scalar] = []
            var owner: [Int] = []
            var wordStarts: [Unicode.Scalar: [Int]] = [:]
            for (index, item) in items.enumerated() {
                let key = QwenAlignedTranscript.alignmentKey(item.text).unicodeScalars
                if let first = key.first {
                    wordStarts[first, default: []].append(scalars.count)
                }
                for scalar in key {
                    scalars.append(scalar)
                    owner.append(index)
                }
            }
            self.scalars = scalars
            self.owner = owner
            self.wordStartsByFirstScalar = wordStarts
        }

        func matches(_ key: [Unicode.Scalar], at offset: Int) -> Bool {
            guard offset >= 0, offset <= scalars.count, key.count <= scalars.count - offset else {
                return false
            }
            return scalars[offset..<(offset + key.count)].elementsEqual(key)
        }

        /// The offsets in `lower + 1 ... upper` at which an aligner word beginning with `first`
        /// starts, in ascending order.
        func wordStarts(
            beginningWith first: Unicode.Scalar,
            after lower: Int,
            through upper: Int
        ) -> ArraySlice<Int> {
            guard lower < upper, let starts = wordStartsByFirstScalar[first] else { return [] }
            let from = firstIndex(in: starts, above: lower)
            let to = firstIndex(in: starts, above: upper)
            return starts[from..<to]
        }

        /// The index of the first element of the ascending `starts` that is greater than `value`.
        private func firstIndex(in starts: [Int], above value: Int) -> Int {
            var low = 0
            var high = starts.count
            while low < high {
                let middle = low + (high - low) / 2
                if starts[middle] <= value { low = middle + 1 } else { high = middle }
            }
            return low
        }
    }

    /// The transcript cut into sentences at `.`, `?`, `!`, `。`, `？`, `！` and newlines.
    ///
    /// A `.`, `?` or `!` followed directly by a letter, a digit, or a comma, semicolon or colon
    /// (ASCII or fullwidth) does not end a sentence (F420). The aligner splits English on whitespace, so "A.D.,",
    /// "Sources.com" and "3.5" each reach it as one word, and cutting them put a sentence boundary
    /// in the middle of an aligner word — "… A." / "D." / ", …" — besides leaving lines
    /// like "D." that are not sentences. The comma, semicolon and colon are there because no
    /// sentence ends in ".,": without them "A.D.," would still be cut before its comma. Any other
    /// character, such as a closing quote or another terminator, still ends the sentence as before;
    /// `place` copes with a boundary that lands inside an aligner word either way.
    ///
    /// A CJK ideograph is the exception and still ends the sentence. The aligner makes every
    /// ideograph its own word (`is_cjk_char` in `qwen3_forced_aligner.py`, applied by
    /// `split_segment_with_chinese` and `tokenize_chinese_mixed`), so a cut in front of one is always
    /// on a word boundary, and Chinese puts no space after a sentence, so declining the cut would run
    /// sentences together. `。`, `？`, `！` and the newline are unchanged.
    private static func sentenceSlices(_ text: String) -> [String] {
        let terminators: Set<Character> = [".", "?", "!", "。", "？", "！", "\n"]
        let characters = Array(text)
        var current = ""
        var result: [String] = []

        for (index, character) in characters.enumerated() {
            current.append(character)
            guard terminators.contains(character) else { continue }
            if wordInternalTerminators.contains(character),
               index + 1 < characters.count,
               continuesSentence(characters[index + 1]) {
                continue
            }
            let sentence = current.trimmingCharacters(in: .whitespacesAndNewlines)
            if !sentence.isEmpty {
                result.append(sentence)
            }
            current = ""
        }
        let remainder = current.trimmingCharacters(in: .whitespacesAndNewlines)
        if !remainder.isEmpty {
            result.append(remainder)
        }
        return result
    }

    /// The terminators that can sit inside a word ("A.D.", ".com", "3.5", "Yahoo!Mail") (F420).
    private static let wordInternalTerminators: Set<Character> = [".", "?", "!"]

    /// Punctuation that continues the clause a terminator is part of, as in "A.D.," (F420).
    private static let clauseContinuations: Set<Character> = [",", ";", ":", "，", "；", "："]

    /// Whether `next`, directly after a `.`, `?` or `!`, means the sentence has not ended (F420).
    private static func continuesSentence(_ next: Character) -> Bool {
        if clauseContinuations.contains(next) { return true }
        guard next.isLetter || next.isNumber else { return false }
        return !isCJKIdeograph(next)
    }

    /// The aligner's own ideograph ranges (`is_cjk_char` in `qwen3_forced_aligner.py`, mlx-audio
    /// 0.3.1), tested on the character's first scalar.
    private static func isCJKIdeograph(_ character: Character) -> Bool {
        guard let scalar = character.unicodeScalars.first else { return false }
        switch scalar.value {
        case 0x4E00...0x9FFF, 0x3400...0x4DBF, 0x20000...0x2A6DF, 0x2A700...0x2B73F,
             0x2B740...0x2B81F, 0x2B820...0x2CEAF, 0xF900...0xFAFF:
            return true
        default:
            return false
        }
    }

    /// Exactly the characters the aligner itself keeps, so the two sides can ever agree (F263).
    ///
    /// `qwen3_forced_aligner.py:23-30` (`is_kept_char`) keeps Unicode categories `L*` and `N*` plus
    /// an apostrophe, and `clean_token` strips everything else from the token text it reports. Swift's
    /// `CharacterSet.alphanumerics` is `L* + M* + N*`, so the old key retained combining marks the
    /// aligner had already removed — and no amount of assembling could then match. The apostrophe is
    /// dropped on both sides here, which is harmless because both sides go through this function.
    private static let keptScalars = CharacterSet.alphanumerics.subtracting(.nonBaseCharacters)

    private static func alignmentKey(_ text: String) -> String {
        // Compose first, so a decomposed "é" becomes one letter instead of a letter plus a mark that
        // the filter below would then discard — which would reintroduce the mismatch it prevents.
        String(
            text.precomposedStringWithCanonicalMapping
                .lowercased()
                .unicodeScalars
                .filter { keptScalars.contains($0) }
        )
    }
}
