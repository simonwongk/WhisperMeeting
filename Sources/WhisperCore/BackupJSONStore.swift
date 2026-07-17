import Foundation

public enum BackupJSONStoreError: LocalizedError, Sendable, Equatable {
    case noReadableCopy(primary: String, backup: String)

    public var errorDescription: String? {
        switch self {
        case let .noReadableCopy(primary, backup):
            return "Neither \(primary) nor its backup \(backup) could be read. Both files were preserved for manual recovery."
        }
    }
}

public struct BackupJSONStore<Value: Codable> {
    public enum LoadSource: Sendable, Equatable {
        case primary
        case backup
    }

    public struct LoadResult {
        public let value: Value
        public let source: LoadSource
    }

    private let primaryURL: URL
    private let backupURL: URL
    private let fileManager: FileManager

    public init(
        primaryURL: URL,
        backupURL: URL,
        fileManager: FileManager = .default
    ) {
        self.primaryURL = primaryURL
        self.backupURL = backupURL
        self.fileManager = fileManager
    }

    public func load() throws -> LoadResult? {
        let primaryExists = fileManager.fileExists(atPath: primaryURL.path)
        let backupExists = fileManager.fileExists(atPath: backupURL.path)

        if primaryExists,
           let data = try? Data(contentsOf: primaryURL),
           let value = try? decoder.decode(Value.self, from: data) {
            return LoadResult(value: value, source: .primary)
        }
        if backupExists,
           let data = try? Data(contentsOf: backupURL),
           let value = try? decoder.decode(Value.self, from: data) {
            return LoadResult(value: value, source: .backup)
        }
        guard primaryExists || backupExists else { return nil }
        throw BackupJSONStoreError.noReadableCopy(
            primary: primaryURL.lastPathComponent,
            backup: backupURL.lastPathComponent
        )
    }

    public func save(_ value: Value) throws {
        try fileManager.createDirectory(
            at: primaryURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        let newData = try encoder.encode(value)
        let existingPrimary = readableData(at: primaryURL)
        let existingBackup = readableData(at: backupURL)
        let backupData = existingPrimary ?? existingBackup ?? newData
        try backupData.write(to: backupURL, options: .atomic)
        try newData.write(to: primaryURL, options: .atomic)
    }

    private func readableData(at url: URL) -> Data? {
        guard let data = try? Data(contentsOf: url),
              (try? decoder.decode(Value.self, from: data)) != nil else {
            return nil
        }
        return data
    }

    private var encoder: JSONEncoder {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }

    private var decoder: JSONDecoder {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }
}
