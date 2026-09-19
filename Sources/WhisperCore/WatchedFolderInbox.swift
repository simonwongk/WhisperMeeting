import Foundation

/// Decides which files in a watched folder are new, finished recordings (F318).
///
/// Fed one directory listing per look. Pure, so the rule that matters — *when is a file finished?*
/// — is tested without a folder, a timer or a recorder writing into one. A file is ready when it
/// is a recording (`ExternalFileIntake`), was not already known, is not empty, and has had the same
/// size and modification date for `settledLooks` consecutive looks. Each version of a file is
/// handed over once.
///
/// **Arrival is a listing, not a clock (F320).** The first version asked "is this file newer than
/// the last time I looked?", using `contentModificationDate` as a proxy for when the file landed
/// here. That proxy is false for every ordinary way a user adds a recording they already have — a
/// Finder drag within a volume (`rename(2)`), a Finder copy across volumes, `cp -p`, `rsync -t`,
/// `ditto`, unzip, AirDrop, a hard link, a Time Machine restore — because all of them preserve
/// mtime. Such a file read as "already there" and, being recorded as delivered, was never retried
/// on any later look or launch: the headline use of the feature lost the file for good. So the
/// record carried across launches is the **set of files this folder was known to hold**
/// (`snapshot`), and anything absent from it is new whatever its dates say. That also removes every
/// dependence on clock movement and on filesystem timestamp granularity.
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

    /// What a file looked like — enough to tell "the same file" from "a different recording under
    /// the same name". `Codable` because the caller persists a folder's snapshot between launches.
    public struct Version: Sendable, Equatable, Codable {
        public let size: Int64
        public let modified: Date

        public init(size: Int64, modified: Date) {
            self.size = size
            self.modified = modified
        }
    }

    /// The files a folder is known to hold, by path. Persisted by the caller; handed back to
    /// `init(known:)` on the next launch.
    public typealias Snapshot = [String: Version]

    /// Looks a file must survive unchanged after it is first seen. With the monitor's 3-second
    /// interval that is six quiet seconds — longer than any writer pauses, short enough to feel
    /// prompt.
    public static let settledLooks = 2

    private var known: Snapshot?
    private var didBaseline = false
    private var handled: Snapshot = [:]
    private var watching: [String: (version: Version, unchangedLooks: Int)] = [:]

    /// `known` is what a previous run of the app last saw in this folder, or nil if it never
    /// watched it. Anything in the folder that is not in `known` arrived while the app was closed
    /// and is new — without this, quitting the app would quietly turn every recording dropped
    /// meanwhile into "already there".
    public init(known: Snapshot? = nil) {
        self.known = known
    }

    /// What this folder is known to hold, for the caller to persist, or nil before the first look.
    ///
    /// A file that has been *seen* but not yet handed over is deliberately absent: found on a real
    /// run, where the app quit one look after a file appeared and the next launch filed it under
    /// "already there" — for good. Nil before the first look for the same reason in the other
    /// direction: persisting an empty snapshot would make every file in the folder new on the next
    /// launch, which is how a folder gets imported twice.
    public var snapshot: Snapshot? { didBaseline ? handled : nil }

    public mutating func ready(in listing: [Entry]) -> [URL] {
        let candidates = listing.filter { entry in
            !entry.url.lastPathComponent.hasPrefix(".") && ExternalFileIntake.isImportable(entry.url)
        }
        guard didBaseline else {
            didBaseline = true
            // The first look defines what was already there. Importing a folder's existing contents
            // the moment the switch is turned on would be the opposite of opt-in — except for what
            // a previous run of the app was watching and had not seen, which is genuinely new.
            for entry in candidates {
                let path = entry.url.path
                let version = Version(size: entry.size, modified: entry.modified)
                guard let known else {
                    handled[path] = version
                    continue
                }
                if known[path] == version {
                    handled[path] = version
                } else if entry.size > 0 {
                    watching[path] = (version, 0)
                }
            }
            return []
        }
        var ready: [URL] = []
        var stillThere: Set<String> = []
        for entry in candidates where entry.size > 0 {
            let path = entry.url.path
            let version = Version(size: entry.size, modified: entry.modified)
            stillThere.insert(path)
            if handled[path] == version { continue }
            if let seen = watching[path], seen.version == version {
                let looks = seen.unchangedLooks + 1
                if looks >= Self.settledLooks {
                    handled[path] = version
                    watching[path] = nil
                    ready.append(entry.url)
                } else {
                    watching[path] = (version, looks)
                }
            } else {
                watching[path] = (version, 0)
            }
        }
        // A file that has left the folder leaves the record with it: it is new again if the user
        // puts it back, and the snapshot cannot grow without bound.
        watching = watching.filter { stillThere.contains($0.key) }
        handled = handled.filter { stillThere.contains($0.key) }
        return ready
    }
}
