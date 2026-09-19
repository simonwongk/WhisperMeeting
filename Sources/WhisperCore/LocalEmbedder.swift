import Foundation

/// Where the search-by-meaning model lives, and whether it is there (F316). It shares the
/// summarizer's Python runtime and adds no packages to it.
public enum AskEmbeddingRuntime {
    /// Recorded in every index, so vectors from another model are never compared with these.
    public static let modelID = "intfloat/multilingual-e5-small@614241f622f5"

    public static func modelDirectory(applicationSupport: URL? = nil) -> URL {
        SummarizerRuntime.managedDirectory(applicationSupport: applicationSupport)
            .appendingPathComponent("embedding-model", isDirectory: true)
    }

    public static func isInstalled(applicationSupport: URL? = nil) -> Bool {
        let files = FileManager.default
        let model = modelDirectory(applicationSupport: applicationSupport)
        return files.isExecutableFile(atPath: SummarizerRuntime.pythonExecutable(applicationSupport: applicationSupport).path)
            && ["config.json", "tokenizer.json", "model.safetensors"].allSatisfy {
                files.fileExists(atPath: model.appendingPathComponent($0).path)
            }
    }
}

public enum LocalEmbedderError: LocalizedError, Equatable {
    case notInstalled
    case helperFailed(String)
    case unreadableOutput

    public var errorDescription: String? {
        switch self {
        case .notInstalled: "The search model is not installed."
        case let .helperFailed(log): "The search model could not run. \(log)"
        case .unreadableOutput: "The search model returned something unreadable."
        }
    }
}

/// Runs `embed_local.py` (F316): texts in, L2-normalised vectors out. One process per call; a whole
/// library indexes in seconds, so there is no server to keep warm.
public struct LocalEmbedder: Sendable {
    public enum Kind: String, Sendable { case query, passage }

    private let pythonExecutableURL: URL
    private let helperScriptURL: URL
    private let modelDirectory: URL

    public init(
        helperScriptURL: URL,
        pythonExecutableURL: URL = SummarizerRuntime.pythonExecutable(),
        modelDirectory: URL = AskEmbeddingRuntime.modelDirectory()
    ) {
        self.helperScriptURL = helperScriptURL
        self.pythonExecutableURL = pythonExecutableURL
        self.modelDirectory = modelDirectory
    }

    /// `texts.count × dimension` floats, row-major, in input order.
    public func embed(_ texts: [String], kind: Kind) async throws -> (dimension: Int, vectors: [Float]) {
        guard !texts.isEmpty else { return (0, []) }
        let files = FileManager.default
        guard files.isExecutableFile(atPath: pythonExecutableURL.path),
              files.fileExists(atPath: helperScriptURL.path),
              files.fileExists(atPath: modelDirectory.appendingPathComponent("model.safetensors").path)
        else { throw LocalEmbedderError.notInstalled }

        let working = files.temporaryDirectory.appendingPathComponent("WhisperMeet-Embed-\(UUID().uuidString)", isDirectory: true)
        try files.createDirectory(at: working, withIntermediateDirectories: true)
        defer { try? files.removeItem(at: working) }
        let input = working.appendingPathComponent("in.json")
        let output = working.appendingPathComponent("out.f32")
        try JSONSerialization.data(withJSONObject: ["kind": kind.rawValue, "texts": texts]).write(to: input)

        let outcome = try await ProcessGroupRunner().run(
            executableURL: pythonExecutableURL,
            arguments: [helperScriptURL.path, "--model", modelDirectory.path, "--input", input.path, "--output", output.path],
            environment: LocalSummarizer.makeEnvironment(),
            stallTimeout: 300
        )
        guard outcome.exitStatus == 0 else {
            throw LocalEmbedderError.helperFailed(String(outcome.output.suffix(400)))
        }
        struct Metadata: Decodable { let count: Int; let dimension: Int }
        guard let raw = try? Data(contentsOf: URL(fileURLWithPath: output.path + ".json")),
              let metadata = try? JSONDecoder().decode(Metadata.self, from: raw),
              metadata.count == texts.count, metadata.dimension > 0,
              let data = try? Data(contentsOf: output),
              data.count == metadata.count * metadata.dimension * MemoryLayout<Float>.size
        else { throw LocalEmbedderError.unreadableOutput }
        // Alignment-safe, for the reason `SegmentEmbeddings.floats(from:count:)` documents (F333).
        return (metadata.dimension,
                SegmentEmbeddings.floats(from: data, count: metadata.count * metadata.dimension))
    }
}
