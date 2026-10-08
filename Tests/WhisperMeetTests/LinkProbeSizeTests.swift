import Foundation
import Testing
@testable import WhisperCore
@testable import WhisperMeet

// F462 part 3 — Import from a link checks free space against the size the probe reports plus a
// 500 MB margin, and that size is whatever yt-dlp read off the page (`filesize_approx`/`filesize`,
// which can come straight from a page's JSON-LD `contentSize`). A size within 500 MB of Int64.max
// decodes cleanly and the `+` trapped, from one pasted link. The sum is now F494's saturating one
// (`importStorageNeeded`), so a need past Int64.max is refused as too big, which it is.
//
// Parts 1, 2 and 4 are in `WhisperCoreTests/DecodableCorruptValueTests.swift`.

/// Near the Int64 edge, as the ticket's page claimed: 2^63 - 1024.
private let sizeNearTheEdge: Int64 = 9_223_372_036_854_774_784

@MainActor
private func makeModel() throws -> (AppModel, URL) {
    let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("F462-link-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    let defaults = try #require(UserDefaults(suiteName: testSuiteName()))
    let model = AppModel(
        store: MeetingStore(rootDirectory: root), recorder: AudioCaptureEngine(), defaults: defaults,
        whisperExecutable: { URL(fileURLWithPath: "/usr/bin/true") }, qwenInstalled: { true }
    )
    model.linkImportEnabled = true
    // Nothing may download: the refusal has to come first. A download, if reached, throws, so no
    // meeting could be adopted either way and `store.meetings` stays empty only for the right reason
    // when the outcome is also the space refusal.
    model.downloadMedia = { _, _, _ in throw CocoaError(.fileWriteUnknown) }
    model.downloadCaptions = { _, _, _ in [] }
    return (model, root)
}

@MainActor
@Test("A probe size near Int64.max is refused for space, naming the need, not a crash (F462)")
func probeSizeNearInt64MaxIsRefusedNotTrapped() async throws {
    let (model, root) = try makeModel()
    defer { try? FileManager.default.removeItem(at: root) }
    // The check is skipped when the volume reports no free-space figure; require one, or this would
    // fail as a claim about arithmetic when it is a fact about the host.
    model.refreshRecordingPreflight()
    try #require(model.recordingPreflight.availableStorageBytes != nil, "this volume reports no free-space figure")
    model.probeMediaURL = { _ in
        MediaProbe(title: "Huge", durationSeconds: 60, approximateBytes: sizeNearTheEdge, language: "en")
    }

    let outcome = await model.importFromURL("https://www.youtube.com/watch?v=abc123")

    guard case let .refused(message) = outcome else {
        Issue.record("expected a refusal for space, got \(outcome)")
        return
    }
    // The need saturated at Int64.max, formatted the way the message formats it, so the assertion is
    // about the number and not this machine's locale. A wrapped sum would name a negative size.
    let saturated = ByteCountFormatter.string(fromByteCount: .max, countStyle: .file)
    #expect(message.contains(saturated), "the refusal names the need: \(message)")
    #expect(model.store.meetings.isEmpty)
}

@Test("The link import's free-space need is the probe's size plus the margin, saturating, with no negative size (F462)")
func linkImportStorageNeedReadsCorrectly() {
    // Without a size the margin alone is needed, as before.
    #expect(AppModel.linkImportStorageNeeded(approximateBytes: nil) == 500_000_000)
    #expect(AppModel.linkImportStorageNeeded(approximateBytes: 1_000_000_000) == 1_500_000_000)
    // A negative size is no size: it must not eat into the margin, or turn the need negative so
    // that every volume passes.
    #expect(AppModel.linkImportStorageNeeded(approximateBytes: -1_000_000_000) == 500_000_000)
    #expect(AppModel.linkImportStorageNeeded(approximateBytes: .min) == 500_000_000)
    // Past Int64.max the need is Int64.max: no volume has it free, so it is refused as too big.
    #expect(AppModel.linkImportStorageNeeded(approximateBytes: sizeNearTheEdge) == .max)
    #expect(AppModel.linkImportStorageNeeded(approximateBytes: .max) == .max)
}
