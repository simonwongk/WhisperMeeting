import Foundation

/// Temporary folders named for the process that made them — `<prefix><process ID>-<UUID>` — so a later
/// run can tell a folder whose process has exited from one still in use, and remove what a crash or a
/// force-quit left behind (F533 review R7, for Whisper's run folders; F965, for the mix an engine run
/// makes of a several-track recording and for speaker analysis's workspace; F996, for Qwen's decode, the
/// local helpers' working folders, a segment re-run's clip and the test recording, which each launch
/// sweeps — `AppModel.removeAbandonedTemporaryFolders`).
///
/// A `defer` removes a folder however a run ends, but it cannot run when the process dies, and these
/// folders are large: a decode or a mix is about 115 MB per hour of audio, and nothing else removed
/// one before macOS cleared its temporary folder. So Whisper's, the mix's and speaker analysis's runs
/// sweep their own prefix first, each launch sweeps every prefix the app names this way, and a later
/// run or launch removes what an earlier one could not.
///
/// Only a real directory is removed (never a link, nor what one points at), only when its name is
/// exactly one `name(prefix:processID:id:)` makes, and only when its process is not this one and no
/// longer exists. A folder still in use always has a live process: this one, a second copy of the app,
/// or one that cannot be checked. So no run in progress loses its folder. A folder whose process ID
/// has since been reused is kept until macOS clears it, which costs only space.
public enum OwnedTemporaryFolders {
    /// A new folder's name under `prefix`, for this process unless a test names another.
    public static func name(prefix: String, processID: pid_t = getpid(), id: UUID = UUID()) -> String {
        "\(prefix)\(processID)-\(id.uuidString)"
    }

    /// The process that made the folder called `name`, or nil when `name` is not exactly a name
    /// `name(prefix:processID:id:)` makes: the prefix, a positive decimal ID with no sign or leading
    /// zero, and an upper-case UUID. So the sweep cannot mistake anything else for a run's folder.
    public static func owner(of name: String, prefix: String) -> pid_t? {
        guard name.hasPrefix(prefix) else { return nil }
        let rest = name.dropFirst(prefix.count)
        guard let dash = rest.firstIndex(of: "-") else { return nil }
        let digits = rest[..<dash]
        let uuidText = String(rest[rest.index(after: dash)...])
        guard let owner = pid_t(digits), owner > 0, String(owner) == digits,
              UUID(uuidString: uuidText)?.uuidString == uuidText else { return nil }
        return owner
    }

    /// Whether a process with this ID exists. Only "no such process" counts as gone: `EPERM` is a
    /// live process that is not ours to signal, and any other answer keeps the folder too.
    public static func processExists(_ pid: pid_t) -> Bool {
        kill(pid, 0) == 0 || errno != ESRCH
    }

    /// Removes the folders under `prefix` in `directory` that a process which has since exited left
    /// behind, and returns their names.
    @discardableResult
    public static func removeAbandoned(in directory: URL, prefix: String) -> [String] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path) else { return [] }
        let current = getpid()
        var removed: [String] = []
        for name in names {
            guard let owner = owner(of: name, prefix: prefix), owner != current, !processExists(owner) else { continue }
            // No trailing slash, and `attributesOfItem` does not follow a link, so a link named like
            // a run's folder is seen as the link it is.
            let path = directory.appendingPathComponent(name, isDirectory: false).path
            guard (try? FileManager.default.attributesOfItem(atPath: path)[.type]) as? FileAttributeType == .typeDirectory,
                  (try? FileManager.default.removeItem(atPath: path)) != nil else { continue }
            removed.append(name)
        }
        return removed
    }
}
