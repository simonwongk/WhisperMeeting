import Foundation

/// Pure push-to-talk state machine. Given user/engine events it returns the next side-effecting
/// action for the controller to perform. No timers, no I/O — fully unit-testable.
public struct DictationSession: Sendable {
    public enum FailureReason: Equatable, Sendable {
        case emptyTranscript
        case engine(String)
    }

    public enum State: Equatable, Sendable {
        case idle, listening, transcribing, delivering, done
        case failed(FailureReason)
    }

    public enum Event: Sendable {
        case startPressed
        case endPressed(clipDuration: TimeInterval)
        case transcriptReady(String)
        case delivered
        case engineFailed(String)
        case dismiss
    }

    public enum Action: Equatable, Sendable {
        case none, startCapture, discard, transcribe, deliver(String), busy, reset
    }

    public private(set) var state: State = .idle
    public var minClipDuration: TimeInterval

    public init(minClipDuration: TimeInterval = 0.35) {
        self.minClipDuration = minClipDuration
    }

    public mutating func handle(_ event: Event) -> Action {
        switch (state, event) {
        case (.idle, .startPressed):
            state = .listening
            return .startCapture
        case (_, .startPressed):
            return .busy
        case let (.listening, .endPressed(duration)):
            if duration < minClipDuration {
                state = .idle
                return .discard
            }
            state = .transcribing
            return .transcribe
        case let (.transcribing, .transcriptReady(text)):
            if text.isEmpty {
                state = .failed(.emptyTranscript)
                return .none
            }
            state = .delivering
            return .deliver(text)
        case (.delivering, .delivered):
            state = .done
            return .none
        case let (_, .engineFailed(message)):
            state = .failed(.engine(message))
            return .none
        case (_, .dismiss):
            state = .idle
            return .reset
        default:
            return .none
        }
    }
}
