import Foundation
import WhisperCore

/// The install-time proof that the staged speaker-analysis models actually work on this Mac (F216).
///
/// `Scripts/setup-speaker-diarization.sh` can hash every downloaded byte and still be staging a
/// tree that cannot run: `.mlmodelc` bundles are compiled *for a Core ML runtime*, and whether they
/// load is a property of this machine's OS and Neural Engine, not of the bytes. The sherpa-onnx
/// installer answered that by running the pinned CLI before it activated anything. There is no CLI
/// any more — the diarizer is a library inside this app — so the installer calls the app back
/// instead, with the flag below, and refuses to activate if this returns non-zero.
///
/// It runs before `SwiftUI`'s `App.main()` and therefore before any window, `NSApplication`,
/// permission prompt or user state exists. Nothing here reads the user's library: the only file it
/// writes is a second of silence in a temporary directory, which it deletes.
enum DiarizationInstallSmokeTest {
    static let flag = "--diarization-smoke-test"

    /// The models *parent* directory the installer staged, or nil for an ordinary app launch.
    ///
    /// Matched only in its complete `--diarization-smoke-test <path>` form. A bare flag with no
    /// path is not a request — treating it as one would mean launching headless and exiting when
    /// the user expected a window.
    static func modelsParentDirectory(in arguments: [String]) -> URL? {
        guard let index = arguments.firstIndex(of: flag), index + 1 < arguments.count else {
            return nil
        }
        return URL(fileURLWithPath: arguments[index + 1])
    }

    /// Loads the staged models and runs the real pipeline over one second of generated silence.
    ///
    /// Silence rather than speech because a speech fixture would need a licence we can state, and
    /// every `.wav` in the model releases this project has surveyed carries no licence statement at
    /// all. What silence covers is the expensive half: `OfflineDiarizerModels.load` compiles and
    /// loads all four Core ML bundles and reads the PLDA parameters, so a bundle that will not
    /// compile here fails this call. What it does not cover is clustering — there is nothing to
    /// cluster — and the installer's comment says so rather than implying a stronger guarantee.
    static func run(modelsParentDirectory: URL) async -> (status: Int32, message: String) {
        guard FluidAudioDiarizationRuntime.isInstalled(inParent: modelsParentDirectory) else {
            let expected = modelsParentDirectory
                .appendingPathComponent("speaker-diarization", isDirectory: true)
            return (1, "incomplete staged models at \(expected.path)")
        }

        let scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperMeetDiarizationSmoke-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: scratch) }
        let audio = scratch.appendingPathComponent("silence.wav")
        do {
            try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
            try writeSilence(seconds: 1, to: audio)
        } catch {
            return (1, "could not write the smoke-test audio: \(error)")
        }

        let started = Date()
        let client = FluidAudioDiarizationClient(modelsParentDirectory: modelsParentDirectory)
        do {
            let result = try await client.diarize(audioURL: audio, durationSeconds: 1)
            // Silence that produces speaker turns means the pipeline ran and produced nonsense,
            // which is worse than a pipeline that did not run: it would ship a runtime that invents
            // speakers. The old installer refused on exactly this signal.
            guard result.turns.isEmpty else {
                return (1, "reported \(result.turns.count) speaker turns in one second of silence")
            }
            let elapsed = String(format: "%.2f", Date().timeIntervalSince(started))
            return (0, "models loaded and ran on 1 s of silence in \(elapsed)s, no turns reported")
        } catch {
            return (1, "the pipeline failed: \(error)")
        }
    }

    /// Runs the smoke test and exits the process with its status — the whole of this program's job
    /// when the flag is present.
    static func runAndExit(modelsParentDirectory: URL) -> Never {
        // A semaphore rather than an async main: this is called from `main()` before any SwiftUI
        // scene exists, and the process must not return to the launcher either way.
        let outcome = Outcome()
        let done = DispatchSemaphore(value: 0)
        Task {
            outcome.value = await run(modelsParentDirectory: modelsParentDirectory)
            done.signal()
        }
        done.wait()
        let (status, message) = outcome.value ?? (1, "the smoke test produced no result")
        if status == 0 {
            print("speaker-analysis smoke test passed: \(message)")
        } else {
            FileHandle.standardError.write(Data("speaker-analysis smoke test failed: \(message)\n".utf8))
        }
        exit(status)
    }

    private final class Outcome: @unchecked Sendable {
        var value: (status: Int32, message: String)?
    }

    /// A 16 kHz mono 16-bit PCM WAV of digital silence — the exact format speaker analysis prepares
    /// for every meeting, so the smoke test exercises the same decode path a real run does.
    static func writeSilence(seconds: Double, to url: URL) throws {
        let sampleRate = 16_000
        let byteCount = Int(saturating: Double(sampleRate) * 2 * max(0, seconds))
        var wav = WAVWriter.header(sampleRate: UInt32(sampleRate), dataByteCount: UInt32(byteCount))
        wav.append(Data(count: byteCount))
        try wav.write(to: url)
    }
}
