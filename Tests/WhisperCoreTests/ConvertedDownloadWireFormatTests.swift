import Foundation
import Testing
@testable import WhisperCore

// F977 — `download-conversion.json` is a wire format between builds: recovery writes it beside a
// link import's download (F947) and Shrink reads it back, possibly from a later build. Its keys were
// pinned by nothing; a rename would decode to nil, fail closed, and quietly keep every recovered WebM
// download forever. These tests hold the keys in both directions, the way F188 asks of every
// persisted type.

/// What the shipped build writes: the three keys by name, as a literal, not through the encoder.
private let shippedRecordJSON = #"{"download":"recording.webm","downloadBytes":83000000,"seconds":3600.25}"#
private let shippedRecord = InterruptedLinkImportExtraction.ConvertedDownload(
    download: "recording.webm", downloadBytes: 83_000_000, seconds: 3_600.25
)

@Test("A record the shipped build wrote decodes under today's keys (F977)")
func shippedConversionRecordDecodes() throws {
    let decoded = try JSONDecoder().decode(
        InterruptedLinkImportExtraction.ConvertedDownload.self, from: Data(shippedRecordJSON.utf8)
    )
    #expect(decoded == shippedRecord)
}

@Test("A record this build writes carries exactly the shipped keys, so the previous build reads it (F977)")
func conversionRecordWritesTheShippedKeys() throws {
    let data = try JSONEncoder().encode(shippedRecord)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    #expect(Set(object.keys) == ["download", "downloadBytes", "seconds"], "\(object)")
    #expect(object["download"] as? String == "recording.webm")
    #expect((object["downloadBytes"] as? NSNumber)?.int64Value == 83_000_000)
    #expect((object["seconds"] as? NSNumber)?.doubleValue == 3_600.25)
}

@Test("Every stored property of the record reaches the wire (F977)")
func everyConversionRecordPropertyIsEncoded() throws {
    // Derived, not restated (AGENTS.md, "Derive the list"): a property added later without a key
    // is named here, where the literal set above would go on matching.
    let data = try JSONEncoder().encode(shippedRecord)
    let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
    let properties = Mirror(reflecting: shippedRecord).children.compactMap(\.label)
    #expect(!properties.isEmpty)
    for property in properties {
        #expect(object[property] != nil, "stored property \(property) is not on the wire")
    }
}

@Test("Shrink's reader measures a download from a record written with the shipped keys (F977)")
func convertedSecondsReadsAShippedRecord() throws {
    // The user-facing direction: the file on disk was written by whatever build ran recovery.
    let folder = FileManager.default.temporaryDirectory
        .appendingPathComponent("F977-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: folder) }
    let download = folder.appendingPathComponent("recording.webm")
    let bytes = Data(repeating: 0x57, count: 1_024)
    try bytes.write(to: download)
    let json = #"{"download":"recording.webm","downloadBytes":1024,"seconds":12.5}"#
    try Data(json.utf8).write(to: folder.appendingPathComponent(InterruptedLinkImportExtraction.convertedDownloadFilename))

    #expect(InterruptedLinkImportExtraction.convertedSeconds(of: download) == 12.5)
}
