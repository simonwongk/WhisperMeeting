import Foundation

public enum BackupJSONStoreError: LocalizedError, Sendable, Equatable {
    case noReadableCopy(primary: String, backup: String, quarantined: [String])

    public var errorDescription: String? {
        switch self {
        case let .noReadableCopy(primary, backup, quarantined):
            // Claim only the preservation that actually happened (F187). The prior wording promised
            // preservation unconditionally while nothing preserved anything.
            guard !quarantined.isEmpty else {
                return "Neither \(primary) nor its backup \(backup) could be read, and neither could be copied aside. Nothing was changed on disk."
            }
            return "Neither \(primary) nor its backup \(backup) could be read. The exact bytes were copied aside as \(quarantined.joined(separator: " and ")) and nothing was overwritten."
        }
    }
}

/// A value rebuilt from a partly-unreadable file, plus the records that had to be left behind.
public struct SalvagedValue<Value>: Sendable where Value: Sendable {
    public let value: Value
    public let parkedIdentifiers: [String]

    public init(value: Value, parkedIdentifiers: [String]) {
        self.value = value
        self.parkedIdentifiers = parkedIdentifiers
    }
}

public struct BackupJSONStore<Value: Codable & Sendable> {
    public struct LoadResult {
        public let value: Value
        public let health: PersistedStoreHealth
    }

    private let primaryURL: URL
    private let backupURL: URL
    private let fileManager: FileManager
    /// Optional element-wise recovery so one bad record costs one record, not the whole library (F187).
    private let salvage: (@Sendable (Data) -> SalvagedValue<Value>?)?

    public init(
        primaryURL: URL,
        backupURL: URL,
        fileManager: FileManager = .default,
        salvage: (@Sendable (Data) -> SalvagedValue<Value>?)? = nil
    ) {
        self.primaryURL = primaryURL
        self.backupURL = backupURL
        self.fileManager = fileManager
        self.salvage = salvage
    }

    public func load() throws -> LoadResult? {
        let primaryExists = fileManager.fileExists(atPath: primaryURL.path)
        let backupExists = fileManager.fileExists(atPath: backupURL.path)

        if primaryExists,
           let data = try? Data(contentsOf: primaryURL),
           let value = try? decoder.decode(Value.self, from: data) {
            return LoadResult(value: value, health: .complete)
        }
        if backupExists,
           let data = try? Data(contentsOf: backupURL),
           let value = try? decoder.decode(Value.self, from: data) {
            return LoadResult(value: value, health: .recoveredFromBackup)
        }
        guard primaryExists || backupExists else { return nil }

        // Preserve first, then try to rescue individual records from the preserved bytes.
        var quarantined: [String] = []
        if let name = try StoreQuarantine.preserve(fileAt: primaryURL, using: fileManager) {
            quarantined.append(name)
        }
        if let name = try StoreQuarantine.preserve(fileAt: backupURL, using: fileManager) {
            quarantined.append(name)
        }

        if let salvage {
            for url in [primaryURL, backupURL] {
                guard let data = try? Data(contentsOf: url), let rescued = salvage(data) else { continue }
                return LoadResult(
                    value: rescued.value,
                    health: .partiallySalvaged(parkedIdentifiers: rescued.parkedIdentifiers)
                )
            }
        }

        throw BackupJSONStoreError.noReadableCopy(
            primary: primaryURL.lastPathComponent,
            backup: backupURL.lastPathComponent,
            quarantined: quarantined
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

        // Preserve anything that exists but does not decode BEFORE either write can replace it (F187).
        // "Undecodable" is not "worthless": conflating them is what destroyed the library on 2026-08-14.
        // If the bytes cannot be preserved, refuse to write at all — surfacing an error beats losing data.
        if existingPrimary == nil {
            _ = try StoreQuarantine.preserve(fileAt: primaryURL, using: fileManager)
        }
        if existingBackup == nil {
            _ = try StoreQuarantine.preserve(fileAt: backupURL, using: fileManager)
        }

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
