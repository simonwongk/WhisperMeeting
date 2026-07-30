import Foundation
import Testing
@testable import WhisperCore

@Test("A failed file-handle write throws instead of terminating the app")
func failedFileHandleWriteThrows() throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("WhisperMeetFileWriteTests-\(UUID().uuidString)")
    defer { try? FileManager.default.removeItem(at: url) }
    #expect(FileManager.default.createFile(atPath: url.path, contents: nil))
    let handle = try FileHandle(forWritingTo: url)
    try handle.close()

    #expect(throws: (any Error).self) {
        try ThrowingFileHandleIO.write(Data("recording bytes".utf8), to: handle)
    }
}
