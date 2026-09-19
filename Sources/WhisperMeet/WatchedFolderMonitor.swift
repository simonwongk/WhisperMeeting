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

    /// Why a look found nothing — as distinct from a folder that really is empty (F325).
    ///
    /// `(try? contentsOfDirectory(…)) ?? []` used to turn a TCC denial, a deleted or renamed folder,
    /// an unmounted volume and a revoked network share all into "empty listing", and the watcher then
    /// span silently every three seconds for the life of the process with the feature visibly on in
    /// Settings. The app is not sandboxed, so `NSOpenPanel` confers no persistent access to a
    /// TCC-protected location: declining one prompt is enough to reach this.
    enum Problem: Error, Sendable, Equatable {
        case missing
        case unreadable
    }

    private var timer: Timer?
    private var inbox = WatchedFolderInbox()
    private var isLooking = false
    private var onLook: ((WatchedFolderInbox.Snapshot?, [URL], Problem?) -> Void)?
    private(set) var folder: URL?

    /// `known` is what the last run of the app saw in this folder; `onLook` receives the snapshot to
    /// persist (nil when there is nothing trustworthy to persist), the files ready to import, and
    /// the reason the folder could not be read, if it could not.
    func start(
        folder: URL,
        known: WatchedFolderInbox.Snapshot?,
        onLook: @escaping (WatchedFolderInbox.Snapshot?, [URL], Problem?) -> Void
    ) {
        stop()
        self.folder = folder
        self.onLook = onLook
        inbox = WatchedFolderInbox(known: known)
        look()
        let timer = Timer(timeInterval: Self.interval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.look() }
        }
        // `.common`, not the default mode (F344): a menu-bar app spends real time in menu tracking,
        // and in `.default` the looks stop for as long as a menu is open.
        RunLoop.main.add(timer, forMode: .common)
        self.timer = timer
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        folder = nil
        onLook = nil
    }

    /// One look: list off the main thread, decide on it back here.
    ///
    /// Off the main thread because `contentsOfDirectory` blocks on a TCC prompt for a folder under
    /// Desktop/Documents/Downloads and on I/O for a network or external volume, and the first look
    /// runs inside startup recovery — so a stalled listing was a stalled launch (F324). `isLooking`
    /// because a listing slower than the three-second timer would otherwise start a second one and
    /// feed the inbox two overlapping views of the folder.
    private func look() {
        guard !isLooking, let folder else { return }
        isLooking = true
        Task { [weak self] in
            let outcome = await Task.detached(priority: .utility) { Self.listing(at: folder) }.value
            guard let self else { return }
            self.isLooking = false
            // `stop()`, or a different folder, while the listing was in flight.
            guard self.folder == folder, let onLook = self.onLook else { return }
            switch outcome {
            case .success(let entries):
                let ready = self.inbox.ready(in: entries)
                onLook(self.inbox.snapshot, ready, nil)
            case .failure(let problem):
                // The inbox is NOT fed here: an empty listing would prune everything it knows, and
                // on a first look it would record an empty baseline — so granting access later would
                // import the whole folder as new (F325).
                onLook(nil, [], problem)
            }
        }
    }

    /// The folder's own files, not its subfolders': a watched folder is an inbox, not a tree.
    nonisolated static func listing(at folder: URL) -> Result<[WatchedFolderInbox.Entry], Problem> {
        var isDirectory: ObjCBool = false
        guard FileManager.default.fileExists(atPath: folder.path, isDirectory: &isDirectory) else {
            return .failure(.missing)
        }
        guard isDirectory.boolValue else { return .failure(.unreadable) }
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey, .isRegularFileKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]
        ) else {
            return .failure(.unreadable)
        }
        return .success(urls.compactMap { url in
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { return nil }
            return WatchedFolderInbox.Entry(
                url: url, size: Int64(values.fileSize ?? 0), modified: values.contentModificationDate ?? .distantPast
            )
        })
    }
}
