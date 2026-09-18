import Foundation

/// Decides which files in a watched folder are new, finished recordings (F318).
///
/// Fed one directory listing per look. Pure, so the rule that matters — *when is a file finished?*
/// — is tested without a folder, a timer or a recorder writing into one. A file is ready when it
/// is a recording (`ExternalFileIntake`), appeared after watching began, is not empty, and has had
/// the same size and modification date for `settledLooks` consecutive looks. Each version of a
/// file is handed over once.
public struct WatchedFolderInbox: Sendable {
    public struct Entry: Sendable, Equatable {
        public let url: URL
        public let size: Int64
        public let modified: Date

        public init(url: URL, size: Int64, modified: Date) {
            self.url = url
            self.size = size
            self.modified = modified
        }
    }

    /// Looks a file must survive unchanged after it is first seen. With the monitor's 3-second
    /// interval that is six quiet seconds — longer than any writer pauses, short enough to feel
    /// prompt.
    public static let settledLooks = 2

    private struct Version: Equatable, Sendable { let size: Int64; let modified: Date }
    private var baseline: Set<String>?
    private var watching: [String: (version: Version, unchangedLooks: Int)] = [:]
    private var delivered: [String: Version] = [:]

    private let lastLook: Date?

    /// `lastLook` is when a previous run of the app last looked at this folder, if it ever did. A
    /// file modified after that arrived while the app was closed, and is new — without this, quitting
    /// the app would quietly turn every recording dropped meanwhile into "already there".
    public init(lastLook: Date? = nil) {
        self.lastLook = lastLook
    }

    /// The modification date of the oldest file seen but not yet handed over, if any.
    ///
    /// The caller persists "when I last looked" so files dropped while the app is closed count as
    /// new. That date must not move past a file still being watched: found on a real run, where the
    /// app quit one look after a file appeared, the saved date was later than the file, and the
    /// next launch filed it under "already there" — for good.
    public var oldestUnsettled: Date? {
        watching.values.map(\.version.modified).min()
    }

    public mutating func ready(in listing: [Entry]) -> [URL] {
        let candidates = listing.filter { entry in
            !entry.url.lastPathComponent.hasPrefix(".") && ExternalFileIntake.isImportable(entry.url)
        }
        guard let baseline else {
            // The first look defines what was already there. Importing a folder's existing contents
            // the moment the switch is turned on would be the opposite of opt-in.
            let old = candidates.filter { entry in lastLook.map { entry.modified <= $0 } ?? true }
            self.baseline = Set(old.map(\.url.path))
            for entry in old { delivered[entry.url.path] = Version(size: entry.size, modified: entry.modified) }
            for entry in candidates where !old.contains(entry) && entry.size > 0 {
                watching[entry.url.path] = (Version(size: entry.size, modified: entry.modified), 0)
            }
            return []
        }
        _ = baseline
        var ready: [URL] = []
        var stillThere: Set<String> = []
        for entry in candidates where entry.size > 0 {
            let path = entry.url.path
            let version = Version(size: entry.size, modified: entry.modified)
            stillThere.insert(path)
            if delivered[path] == version { continue }
            if let seen = watching[path], seen.version == version {
                let looks = seen.unchangedLooks + 1
                if looks >= Self.settledLooks {
                    delivered[path] = version
                    watching[path] = nil
                    ready.append(entry.url)
                } else {
                    watching[path] = (version, looks)
                }
            } else {
                watching[path] = (version, 0)
            }
        }
        watching = watching.filter { stillThere.contains($0.key) }
        return ready
    }
}
