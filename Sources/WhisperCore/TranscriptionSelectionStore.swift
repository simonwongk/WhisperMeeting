import Foundation

public struct MeetingTranscriptionSelection: Sendable, Equatable {
    public let engine: MeetingTranscriptionEngine
    public let language: WhisperLanguage

    public init(engine: MeetingTranscriptionEngine, language: WhisperLanguage) {
        self.engine = engine
        self.language = language
    }
}

/// Snapshots mutable Settings values when a meeting enters the transcription queue. Waiting jobs
/// must not silently switch model or language if the user changes Settings for future meetings.
public struct TranscriptionSelectionStore: Sendable, Equatable {
    private var selections: [UUID: MeetingTranscriptionSelection] = [:]

    public init() {}

    public mutating func snapshot(
        _ selection: MeetingTranscriptionSelection,
        for meetingID: UUID
    ) {
        selections[meetingID] = selection
    }

    public func selection(for meetingID: UUID) -> MeetingTranscriptionSelection? {
        selections[meetingID]
    }

    public mutating func remove(_ meetingID: UUID) {
        selections[meetingID] = nil
    }
}
