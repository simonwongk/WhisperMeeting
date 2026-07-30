import Foundation
import Testing
@testable import WhisperCore

@Test("Meeting engine selection preserves existing Whisper preference values")
func meetingEnginePreferenceCompatibility() {
    #expect(MeetingTranscriptionEngine(rawValue: "large") == .whisperLarge)
    #expect(MeetingTranscriptionEngine(rawValue: "turbo") == .whisperTurbo)
    #expect(MeetingTranscriptionEngine.whisperLarge.whisperModel == .large)
    #expect(MeetingTranscriptionEngine.whisperTurbo.whisperModel == .turbo)
    #expect(MeetingTranscriptionEngine.qwenBalanced.whisperModel == nil)
    #expect(MeetingTranscriptionEngine.availableCases.contains(.whisperLarge))
    #expect(MeetingTranscriptionEngine.availableCases.contains(.whisperTurbo))
    #if arch(arm64)
    #expect(MeetingTranscriptionEngine.availableCases.contains(.qwenBalanced))
    #else
    #expect(!MeetingTranscriptionEngine.availableCases.contains(.qwenBalanced))
    #endif
}

@Test("Queued transcription keeps the engine and language selected when it was requested")
func queuedTranscriptionSelectionSnapshot() {
    let meetingID = UUID()
    var store = TranscriptionSelectionStore()
    var currentEngine = MeetingTranscriptionEngine.qwenBalanced
    var currentLanguage = WhisperLanguage.chinese
    store.snapshot(
        MeetingTranscriptionSelection(engine: currentEngine, language: currentLanguage),
        for: meetingID
    )

    currentEngine = .whisperTurbo
    currentLanguage = .english

    #expect(store.selection(for: meetingID) == MeetingTranscriptionSelection(
        engine: .qwenBalanced,
        language: .chinese
    ))
    store.remove(meetingID)
    #expect(store.selection(for: meetingID) == nil)
}

@Test("Qwen word alignment becomes readable timestamped sentences without losing punctuation")
func qwenEnglishAlignmentAssembly() {
    let items = [
        QwenAlignedItem(text: "Send", start: 0.0, end: 0.3),
        QwenAlignedItem(text: "the", start: 0.3, end: 0.5),
        QwenAlignedItem(text: "report", start: 0.5, end: 0.9),
        QwenAlignedItem(text: "It", start: 1.1, end: 1.3),
        QwenAlignedItem(text: "is", start: 1.3, end: 1.5),
        QwenAlignedItem(text: "ready", start: 1.5, end: 1.9),
    ]

    #expect(QwenAlignedTranscript.segments(
        fullText: "Send the report. It is ready!",
        alignedItems: items
    ) == [
        TranscriptSegment(speaker: nil, start: 0.0, end: 0.9, text: "Send the report."),
        TranscriptSegment(speaker: nil, start: 1.1, end: 1.9, text: "It is ready!"),
    ])
}

@Test("Qwen alignment preserves Mandarin punctuation and English code-switch terms")
func qwenCodeSwitchAlignmentAssembly() {
    let items = [
        QwenAlignedItem(text: "这个", start: 0.0, end: 0.3),
        QwenAlignedItem(text: "bug", start: 0.3, end: 0.6),
        QwenAlignedItem(text: "已经", start: 0.6, end: 0.9),
        QwenAlignedItem(text: "fix", start: 0.9, end: 1.2),
        QwenAlignedItem(text: "了", start: 1.2, end: 1.4),
    ]

    #expect(QwenAlignedTranscript.segments(
        fullText: "这个 bug 已经 fix 了。",
        alignedItems: items
    ) == [
        TranscriptSegment(
            speaker: nil,
            start: 0.0,
            end: 1.4,
            text: "这个 bug 已经 fix 了。"
        ),
    ])
}

@Test("Qwen alignment mismatch returns no segments so the full transcript remains authoritative")
func qwenAlignmentMismatchIsLossless() {
    let items = [
        QwenAlignedItem(text: "a", start: 0.0, end: 0.1),
        QwenAlignedItem(text: "different", start: 0.1, end: 0.4),
        QwenAlignedItem(text: "result", start: 0.4, end: 0.8),
    ]

    #expect(QwenAlignedTranscript.segments(
        fullText: "Keep this complete transcript.",
        alignedItems: items
    ).isEmpty)
}
