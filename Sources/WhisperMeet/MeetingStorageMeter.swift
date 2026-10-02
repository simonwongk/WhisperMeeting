import Foundation
import WhisperCore

/// Reads a meeting folder's files and their sizes on disk (F795). Fresh URLs every call: Foundation
/// caches resource values per URL instance, which is what defeated F326's re-check (F698).
enum MeetingStorageMeter {
    static func entries(in folder: URL) -> [MeetingStoragePlan.FolderEntry] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .totalFileAllocatedSizeKey, .fileAllocatedSizeKey, .fileSizeKey]
        let root = URL(fileURLWithPath: folder.path, isDirectory: true).standardizedFileURL
        guard let enumerator = FileManager.default.enumerator(at: root, includingPropertiesForKeys: keys) else {
            return []
        }
        var entries: [MeetingStoragePlan.FolderEntry] = []
        for case let found as URL in enumerator {
            let url = URL(fileURLWithPath: found.path)
            guard let values = try? url.resourceValues(forKeys: Set(keys)), values.isRegularFile == true else { continue }
            let bytes = values.totalFileAllocatedSize ?? values.fileAllocatedSize ?? values.fileSize ?? 0
            let name = String(url.standardizedFileURL.path.dropFirst(root.path.count + 1))
            entries.append(.init(name: name, bytes: Int64(bytes)))
        }
        return entries
    }
}
