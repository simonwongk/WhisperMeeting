// Sources/WhisperMeet/Dictation/DictationSpeechDetector.swift
@preconcurrency import CoreML
import CryptoKit
import FluidAudio
import Foundation
import WhisperCore

/// What Quick Dictation asks before sending a clip to Whisper Turbo (F846): the clip's highest
/// voice-activity probability, or nil when it cannot tell — no model, a model that does not verify
/// or load, a clip it cannot read. nil means "transcribe as before": refusing a clip deletes the
/// user's words, so every doubt goes the way the app went before there was a detector.
protocol DictationSpeechDetecting: Sendable {
    func peakSpeechProbability(ofClipAt url: URL) async -> Float?
}

/// FluidAudio 0.15.7's Silero VAD (`VadManager`, `Sources/FluidAudio/VAD/VadManager.swift`), run on
/// the Core ML model shipped inside the app (F846, the user's decision of 2026-10-07: bundled, not
/// downloaded). FluidAudio would otherwise fetch the model from Hugging Face on first use
/// (`ModelHub.loadModels(.vad, …)`); here it is handed a model loaded from the app bundle through
/// `VadManager(config:vadModel:)`, the manual API `ModelHub.swift:28` names, so FluidAudio never
/// reaches the network for it.
///
/// The model is pinned: `pinnedFiles` are the SHA-256s of the five files of
/// `silero-vad-unified-256ms-v6.2.1.mlmodelc` (`ModelNames.VAD.sileroVad` in FluidAudio 0.15.7) at
/// revision `b419383c55c110e2c9271fa6ee0ea83d03c70d96` of huggingface.co/FluidInference/silero-vad-coreml
/// (MIT; a Core ML conversion of github.com/snakers4/silero-vad, MIT; both notices in
/// `Resources/THIRD-PARTY-NOTICES.txt`). They are checked before the model is loaded, and a
/// mismatch is treated as no model at all. Loaded once, with the configuration `ModelHub` itself
/// uses (`ModelHub.swift:355-357`), which is what the F846 measurement ran.
actor SileroDictationSpeechDetector: DictationSpeechDetecting {
    static let resourceDirectory = "DictationVAD"
    static let modelName = "silero-vad-unified-256ms-v6.2.1.mlmodelc"
    static let pinnedFiles: [(path: String, sha256: String)] = [
        ("analytics/coremldata.bin", "8067594eb3126ab8318af507f0c00cabfed40d5fedb8a0ee5075dd02e903d909"),
        ("coremldata.bin", "7db35a4fd995222a7fb0129713473b15d1462572ab4a2e5e4d56bcaad9e40f41"),
        ("metadata.json", "2740be542c611e1ba358e1849b4e265c65cdf0b17192767e1e5de86a31ac94d6"),
        ("model.mil", "c6a9d1bf22d413265da0a07a1d14151c3ea2fad296b3aa5859275b33ef1c3270"),
        ("weights/weight.bin", "53ecc8b5081146140ab654c89109cf001f2183abddd7a2411c5081feeffff063"),
    ]

    /// Where `Scripts/build-app.sh` puts the model: `Contents/Resources/DictationVAD/…` of the app.
    /// nil for a process with no resource directory; a development build has no model there, and
    /// fails open.
    static func bundledModelURL(resourceURL: URL? = Bundle.main.resourceURL) -> URL? {
        resourceURL?
            .appendingPathComponent(resourceDirectory, isDirectory: true)
            .appendingPathComponent(modelName, isDirectory: true)
    }

    /// Whether every pinned file is present with its pinned hash.
    static func modelVerifies(at modelURL: URL) -> Bool {
        pinnedFiles.allSatisfy { file in
            guard let data = try? Data(contentsOf: modelURL.appendingPathComponent(file.path)) else { return false }
            return SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() == file.sha256
        }
    }

    private let modelURL: URL?
    private var manager: VadManager?
    /// A model that failed to verify or load is not tried again in this process.
    private var unavailable = false

    init(modelURL: URL? = SileroDictationSpeechDetector.bundledModelURL()) {
        self.modelURL = modelURL
    }

    func peakSpeechProbability(ofClipAt url: URL) async -> Float? {
        guard let manager = loadedManager() else { return nil }
        guard let results = try? await manager.process(url) else { return nil }
        return DictationVoiceActivity.peak(of: results.map(\.probability))
    }

    private func loadedManager() -> VadManager? {
        if let manager { return manager }
        guard !unavailable else { return nil }
        guard let modelURL, Self.modelVerifies(at: modelURL) else {
            unavailable = true
            return nil
        }
        let configuration = MLModelConfiguration()
        configuration.computeUnits = VadConfig.default.computeUnits
        configuration.allowLowPrecisionAccumulationOnGPU = true
        guard let model = try? MLModel(contentsOf: modelURL, configuration: configuration) else {
            unavailable = true
            return nil
        }
        let loaded = VadManager(config: .default, vadModel: model)
        manager = loaded
        return loaded
    }
}
