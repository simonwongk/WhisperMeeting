import Foundation
import WhisperCore

/// Looks at the watched folder every few seconds and reports finished new recordings (F318).
///
/// A timer and a directory listing rather than FSEvents: the question being asked is "has this file
/// stopped changing", which needs repeated looks whatever woke them, and listing one folder every
/// three seconds costs nothing measurable. The decision itself is `WatchedFolderInbox`, which is
/// pure and tested; this only feeds it.
@MainActor
final class WatchedFolderMonitor {
    static let interval: TimeInterval = 3

    private var timer: Timer?
    private var inbox = WatchedFolderInbox()
    private(set) var folder: URL?

    func start(folder: URL, lastLook: Date?, onLook: @escaping (_ safeLastLook: Date, _ ready: [URL]) -> Void) {
        stop()
        self.folder = folder
        inbox = WatchedFolderInbox(lastLook: lastLook)
        let look = { [weak self] in
            guard let self, let folder = self.folder else { return }
            let ready = self.inbox.ready(in: Self.listing(of: folder))
            // Never later than a file still being watched — see `oldestUnsettled`.
            let now = Date()
            let safe = self.inbox.oldestUnsettled.map { min(now, $0.addingTimeInterval(-1)) } ?? now
            onLook(safe, ready)
        }
        look()
        timer = Timer.scheduledTimer(withTimeInterval: Self.interval, repeats: true) { _ in
            MainActor.assumeIsolated(look)
        }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        folder = nil
    }

    /// The folder's own files, not its subfolders': a watched folder is an inbox, not a tree.
    static func listing(of folder: URL) -> [WatchedFolderInbox.Entry] {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        let urls = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        )) ?? []
        return urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { return nil }
            return WatchedFolderInbox.Entry(
                url: url, size: Int64(values.fileSize ?? 0), modified: values.contentModificationDate ?? .distantPast
            )
        }
    }
}
