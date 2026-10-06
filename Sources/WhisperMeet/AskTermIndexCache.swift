import Foundation
import WhisperCore

/// What one meeting's keyword index is built from (F538). Everything Ask's results show from a
/// meeting is derived from these four values, so when any of them changes — a rename, a
/// re-transcription, or a hand edit, which changes only the text (F455) — the index is rebuilt.
struct AskCorpusSource: Sendable, Equatable {
    let id: UUID
    let title: String
    let transcriptText: String
    let segments: [TranscriptSegment]

    init(_ meeting: MeetingRecord) {
        id = meeting.id
        title = meeting.title
        transcriptText = meeting.transcriptText
        segments = meeting.segments
    }

    /// The meeting as Ask searches it (F455): its segments, or — once the user hand-edited the
    /// transcript — the lines they left, so a deleted or corrected sentence is not a passage, an
    /// answer's grounding, or a row in the meaning index. A line keeps its segment's precise time
    /// while the lines still align and its visible MM:SS otherwise; one with neither is still
    /// searched, just without a timestamp.
    ///
    /// Worked out where the index is built, off the main actor: deciding "edited" renders the whole
    /// transcript, which is the cost this cache exists to pay once.
    var searchable: SearchableMeeting {
        let effective = EditedTranscript.effectiveSegments(transcriptText: transcriptText, segments: segments)
        return SearchableMeeting(
            id: id,
            title: title,
            segments: effective.enumerated().map { index, segment in
                SearchableSegment(index: index, start: segment.start, text: segment.text)
            }
        )
    }
}

/// Each meeting's keyword index, kept between Ask queries until the meeting's text changes (F538).
///
/// Read and filled by the background task that builds an Ask's corpus — each index inserted as soon
/// as it is built, so a cancelled pass keeps what it finished — so it locks. The main actor only
/// prunes it. Sources are compared outside the lock: two versions of a long transcript can take a
/// moment to compare, and nothing should wait on that.
final class AskTermIndexCache: @unchecked Sendable {
    private let lock = NSLock()
    private var entries: [UUID: (source: AskCorpusSource, index: MeetingTermIndex)] = [:]
    private var heldTokens = 0
    private let tokenLimit: Int

    init(tokenLimit: Int) {
        self.tokenLimit = tokenLimit
    }

    /// The index built from exactly this source, or nil.
    func index(for source: AskCorpusSource) -> MeetingTermIndex? {
        guard let entry = lock.withLock({ entries[source.id] }) else { return nil }
        return entry.source == source ? entry.index : nil
    }

    /// Keeps `index` unless it would take the cache past its bound. An entry it replaces is dropped
    /// either way: it describes text that no longer exists.
    func insert(_ index: MeetingTermIndex, for source: AskCorpusSource) {
        lock.withLock {
            if let stale = entries.removeValue(forKey: source.id) {
                heldTokens -= stale.index.tokenCount
            }
            guard heldTokens + index.tokenCount <= tokenLimit else { return }
            entries[source.id] = (source, index)
            heldTokens += index.tokenCount
        }
    }

    /// Drops every meeting not in `ids` — a deleted meeting's text does not outlive it here.
    func retainOnly(_ ids: Set<UUID>) {
        lock.withLock {
            for id in entries.keys.filter({ !ids.contains($0) }) {
                if let gone = entries.removeValue(forKey: id) { heldTokens -= gone.index.tokenCount }
            }
        }
    }
}
