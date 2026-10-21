import Foundation
@testable import WhisperMeet

/// A stand-in for the Mac's Trash, for `AppModel.trashForShrink` (F1040): each item Shrink hands it is moved
/// into a folder inside the test's own library and its name recorded, so no test touches the user's real Trash
/// (the real seam refuses in a test process anyway, F442). `failing` refuses every item, as a volume with no
/// Trash does, and records nothing.
final class ShrinkTestTrash: @unchecked Sendable {
    let folder: URL
    private let failing: Bool
    private let lock = NSLock()
    private var names: [String] = []

    init(in root: URL, failing: Bool = false) throws {
        folder = root.appendingPathComponent(".TestTrash", isDirectory: true)
        self.failing = failing
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    }

    /// The names items arrived under, in order.
    var received: [String] { lock.withLock { names } }

    func holds(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: folder.appendingPathComponent(name).path)
    }

    var seam: @Sendable (URL) throws -> URL? {
        { [self] url in
            if failing { throw CocoaError(.fileWriteVolumeReadOnly) }
            let landed = folder.appendingPathComponent(url.lastPathComponent)
            try FileManager.default.moveItem(at: url, to: landed)
            lock.withLock { names.append(url.lastPathComponent) }
            return landed
        }
    }
}
