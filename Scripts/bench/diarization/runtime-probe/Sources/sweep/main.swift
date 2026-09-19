import AVFoundation
import FluidAudio
import Foundation

// F225 — sweep FluidAudio's clustering threshold over annotated audio. Segmentation and embeddings
// are computed once per file (`prepare`); only the clustering is repeated (`cluster`). Writes
// `<out>/<threshold>/<name>.json` as [{start,end,speaker}], which `sweep_score.py` scores.

let args = CommandLine.arguments
guard args.count >= 5 else { print("usage: sweep <models parent> <out dir> <t1,t2,…> <wav>…"); exit(2) }
let modelsParent = URL(fileURLWithPath: args[1])
let outRoot = URL(fileURLWithPath: args[2])
let thresholds = args[3].split(separator: ",").compactMap { Double($0) }
// `thresholds[0]` is indexed below, and `args.count >= 5` does not make the list non-empty: a typo
// in the threshold argument was an index-out-of-range crash before the first file was read (F343).
guard !thresholds.isEmpty else { print("no parsable thresholds in \"\(args[3])\""); exit(2) }
let files = args[4...].map { URL(fileURLWithPath: $0) }

func config(_ threshold: Double) -> OfflineDiarizerConfig {
    // The app's own configuration (`FluidAudioDiarizationClient.analysisConfiguration`), with only
    // the threshold varied.
    var clustering = OfflineDiarizerConfig.Clustering.community
    clustering.threshold = threshold
    return OfflineDiarizerConfig(
        segmentation: .community, embedding: .community, clustering: clustering,
        vbx: .community, postProcessing: .community
    )
}

func samples16k(_ url: URL) throws -> [Float] {
    let file = try AVAudioFile(forReading: url)
    guard file.processingFormat.sampleRate == 16_000, file.processingFormat.channelCount == 1 else {
        throw NSError(domain: "sweep", code: 1, userInfo: [NSLocalizedDescriptionKey: "\(url.lastPathComponent) is not 16 kHz mono"])
    }
    let buffer = AVAudioPCMBuffer(pcmFormat: file.processingFormat, frameCapacity: AVAudioFrameCount(file.length))!
    try file.read(into: buffer)
    return Array(UnsafeBufferPointer(start: buffer.floatChannelData![0], count: Int(buffer.frameLength)))
}

let models = try await OfflineDiarizerModels.load(from: modelsParent, configuration: nil)
for file in files {
    let name = file.deletingPathExtension().lastPathComponent
    let started = Date()
    let preparer = OfflineDiarizerManager(config: config(thresholds[0]))
    preparer.initialize(models: models)
    let prepared = try await preparer.prepare(audio: try samples16k(file))
    // Saturating rather than `Int(Double)`, the house standard: a trap here loses a 9-hour sweep
    // for a progress string (F343).
    let prepareSeconds = Date().timeIntervalSince(started)
    var line = "\(name) prepare \(prepareSeconds.isFinite ? Int(prepareSeconds.rounded(.down)) : -1)s |"
    for threshold in thresholds {
        let manager = OfflineDiarizerManager(config: config(threshold))
        manager.initialize(models: models)
        let result = try manager.cluster(prepared)
        let turns = result.segments.map {
            ["start": Double($0.startTimeSeconds), "end": Double($0.endTimeSeconds), "speaker": $0.speakerId] as [String: Any]
        }
        let dir = outRoot.appendingPathComponent(String(format: "%.2f", threshold), isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        try JSONSerialization.data(withJSONObject: turns).write(to: dir.appendingPathComponent("\(name).json"))
        line += String(format: " %.2f:%d", threshold, Set(result.segments.map(\.speakerId)).count)
    }
    print(line)
}
