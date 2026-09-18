import Foundation
import FluidAudio

// F232 probe: the app's current runtime (pyannote community-1 via OfflineDiarizerManager) and
// FluidAudio's offline Sortformer, on the same real meeting. Prints speaker counts, per-speaker
// speech time and pairwise overlap seconds. Never prints audio content.

let args = CommandLine.arguments
guard args.count >= 3 else { print("usage: probe <audio.wav> <pyannote models parent dir> [sortformer cache dir]"); exit(2) }
let audio = URL(fileURLWithPath: args[1])
let pyannoteModels = URL(fileURLWithPath: args[2])
let cache = args.count > 3 ? URL(fileURLWithPath: args[3]) : nil

var allTurns: [String: [Turn]] = [:]
struct Turn { let speaker: Int; let start: Double; let end: Double }

@MainActor func summarize(_ label: String, _ turns: [Turn]) {
    let speakers = Set(turns.map(\.speaker)).sorted()
    print("\(label): speakers=\(speakers.count) turns=\(turns.count)")
    for s in speakers {
        let total = turns.filter { $0.speaker == s }.reduce(0.0) { $0 + ($1.end - $1.start) }
        print(String(format: "  speaker %d: %.1f s of speech in %d turns", s, total, turns.filter { $0.speaker == s }.count))
    }
    var overlap = 0.0
    var pairs: [String: Double] = [:]
    let sorted = turns.sorted { $0.start < $1.start }
    for i in 0..<sorted.count {
        for j in (i+1)..<sorted.count {
            let a = sorted[i], b = sorted[j]
            if b.start >= a.end { break }
            if a.speaker == b.speaker { continue }
            let o = min(a.end, b.end) - max(a.start, b.start)
            if o > 0 { overlap += o; pairs["\(min(a.speaker,b.speaker))&\(max(a.speaker,b.speaker))", default: 0] += o }
        }
    }
    // Merge overlap into intervals, then bucket by length: a 0.3 s backchannel and an 8 s argument
    // are different problems for a label.
    var spans: [(Double, Double)] = []
    for i in 0..<sorted.count { for j in (i+1)..<sorted.count {
        let a = sorted[i], b = sorted[j]
        if b.start >= a.end { break }
        if a.speaker != b.speaker, min(a.end,b.end) > max(a.start,b.start) { spans.append((max(a.start,b.start), min(a.end,b.end))) }
    } }
    spans.sort { $0.0 < $1.0 }
    var merged: [(Double, Double)] = []
    for s in spans { if let l = merged.last, s.0 <= l.1 { merged[merged.count-1].1 = max(l.1, s.1) } else { merged.append(s) } }
    let lens = merged.map { $0.1 - $0.0 }
    print("  overlap intervals: \(merged.count); <0.5s: \(lens.filter{$0<0.5}.count), 0.5-2s: \(lens.filter{$0>=0.5 && $0<2}.count), >=2s: \(lens.filter{$0>=2}.count), longest \(String(format: "%.1f", lens.max() ?? 0)) s")
    allTurns[label.prefix(3).description] = turns
    print(String(format: "  simultaneous speech reported: %.1f s across %d speaker pairs", overlap, pairs.count))
}

let started = Date()
// 1. The current runtime.
do {
    let models = try await OfflineDiarizerModels.load(from: pyannoteModels, configuration: nil)
    let manager = OfflineDiarizerManager(config: OfflineDiarizerConfig())
    manager.initialize(models: models)
    let t0 = Date()
    let result = try await manager.process(audio) { _, _ in }
    let turns = result.segments.map { seg -> Turn in
        let id = seg.speakerId.replacingOccurrences(of: "S", with: "")
        return Turn(speaker: Int(id) ?? 0, start: Double(seg.startTimeSeconds), end: Double(seg.endTimeSeconds))
    }
    summarize(String(format: "PYANNOTE (current runtime, %.0f s)", Date().timeIntervalSince(t0)), turns)
} catch {
    print("PYANNOTE failed: \(error)")
}

// 2. Sortformer offline v2.1.
do {
    let t0 = Date()
    let models = try await OfflineSortformerModels.loadFromHuggingFace(cacheDirectory: cache)
    print(String(format: "SORTFORMER models ready in %.0f s", Date().timeIntervalSince(t0)))
    let diarizer = OfflineSortformerDiarizer()
    diarizer.initialize(models: models)
    let t1 = Date()
    let timeline = try diarizer.processComplete(audioFileURL: audio)
    let turns = timeline.speakers.values.flatMap { $0.finalizedSegments + $0.tentativeSegments }.map { Turn(speaker: $0.speakerIndex, start: Double($0.startTime), end: Double($0.endTime)) }
    summarize(String(format: "SORTFORMER (offline v2.1, %.0f s)", Date().timeIntervalSince(t1)), turns)
} catch {
    print("SORTFORMER failed: \(error)")
}
// Agreement: for each 0.1 s frame where both name exactly one speaker, does the best one-to-one
// mapping of Sortformer slots onto pyannote clusters agree?
if let p = allTurns["PYA"], let q = allTurns["SOR"] {
    let end = max(p.map(\.end).max() ?? 0, q.map(\.end).max() ?? 0)
    let n = Int(end * 10) + 1
    func frames(_ t: [Turn]) -> [[Int]] { var f = Array(repeating: [Int](), count: n); for x in t { for i in Int(x.start*10)..<min(n, Int(x.end*10)) { f[i].append(x.speaker) } }; return f }
    let fp = frames(p), fq = frames(q)
    var co: [Int: [Int: Int]] = [:]; var both = 0
    for i in 0..<n where Set(fp[i]).count == 1 && Set(fq[i]).count == 1 { co[fq[i][0], default: [:]][fp[i][0], default: 0] += 1; both += 1 }
    var used = Set<Int>(); var agree = 0
    for (qs, row) in co.sorted(by: { ($0.value.values.max() ?? 0) > ($1.value.values.max() ?? 0) }) {
        if let best = row.filter({ !used.contains($0.key) }).max(by: { $0.value < $1.value }) { used.insert(best.key); agree += best.value; print("  sortformer \(qs) -> pyannote \(best.key): \(best.value) frames") }
    }
    print(String(format: "AGREEMENT on single-speaker frames: %.1f%% of %d", both == 0 ? 0 : 100 * Double(agree) / Double(both), both))
    let onlyP = (0..<n).filter { !fp[$0].isEmpty && fq[$0].isEmpty }.count, onlyQ = (0..<n).filter { fp[$0].isEmpty && !fq[$0].isEmpty }.count
    print(String(format: "speech only pyannote hears: %.1f s; only sortformer: %.1f s", Double(onlyP)/10, Double(onlyQ)/10))
}
print(String(format: "total %.0f s", Date().timeIntervalSince(started)))
