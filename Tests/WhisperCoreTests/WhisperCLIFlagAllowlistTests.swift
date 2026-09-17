import Foundation
import Testing
@testable import WhisperCore

// F264 (part) — nothing constrained which flags we hand the Whisper CLI.
//
// What these tests are for, stated honestly: they catch **us** passing a flag openai-whisper has
// never had. They do NOT catch upstream removing one. The allowlist is a hardcoded literal and the
// subset check compares `commandArguments` against that same literal, so nothing here reads the
// installed CLI — if a future `pip install --upgrade openai-whisper` drops
// `--carry_initial_prompt`, these tests stay green and the meeting still dies with argparse exit 2.
// Catching that would mean shelling out to the runtime, which the rest of WhisperCore avoids
// because its tests must pass with no model installed.
//
// That still earns its place: the flag surface is 32 names, the tempting wrong ones look plausible,
// and the failure is total (`LocalWhisperError.processFailed`, no transcript) rather than degraded.
//
// The allowlist is not invented. It is the 32 flags parsed out of the installed runtime's own
// `whisper/transcribe.py` argparse setup (openai-whisper 20250625):
//
//   python -c "import whisper,inspect,re,os; \
//     print(re.findall(r'add_argument\\(\\s*\"(--[a-z0-9_]+)\"', \
//     open(os.path.join(os.path.dirname(inspect.getfile(whisper)),'transcribe.py')).read()))"
//
// NOTE the deliberate exclusions: `--repetition_penalty`, `--no_repeat_ngram_size`, `--vad_filter`,
// `--condition_on_prev_tokens`, `--chunk_length` and `--batch_size` are faster-whisper / HF names.
// They are NOT in this list because passing one is exactly the failure this test exists to catch.

private func makeClient() -> LocalWhisperClient {
    LocalWhisperClient(
        executableURL: URL(fileURLWithPath: "/tmp/whisper-does-not-need-to-exist"),
        modelDirectory: URL(fileURLWithPath: "/tmp/models")
    )
}

private func flags(in arguments: [String]) -> [String] {
    arguments.filter { $0.hasPrefix("--") }
}

@Test("Every flag the meeting path passes is one the installed CLI accepts (F264)")
func meetingArgumentsUseOnlyKnownFlags() {
    let arguments = makeClient().commandArguments(
        recordingAt: URL(fileURLWithPath: "/tmp/meeting.wav"),
        outputDirectory: URL(fileURLWithPath: "/tmp/out"),
        options: .accuracyFirst()
    )
    let used = flags(in: arguments)
    #expect(!used.isEmpty)
    for flag in used {
        #expect(LocalWhisperClient.supportedCLIFlags.contains(flag),
                "\(flag) is not a flag openai-whisper accepts — argparse would exit 2")
    }
}

@Test("The vocabulary branch's flags are also all known (F264)")
func vocabularyArgumentsUseOnlyKnownFlags() {
    // `--initial_prompt` and `--carry_initial_prompt` only appear when a vocabulary exists, so the
    // default-options case above never reaches them.
    let arguments = makeClient().commandArguments(
        recordingAt: URL(fileURLWithPath: "/tmp/meeting.wav"),
        outputDirectory: URL(fileURLWithPath: "/tmp/out"),
        options: .accuracyFirst(language: .english, keyterms: ["Acme", "Kubernetes"])
    )
    let used = flags(in: arguments)
    #expect(used.contains("--initial_prompt"))
    #expect(used.contains("--carry_initial_prompt"))
    #expect(used.contains("--language"))
    for flag in used {
        #expect(LocalWhisperClient.supportedCLIFlags.contains(flag), "\(flag) is unknown upstream")
    }
}

@Test("The allowlist is the installed CLI's real surface, not a guess (F264)")
func allowlistMatchesTheInstalledSurface() {
    #expect(LocalWhisperClient.supportedCLIFlags.count == 32)
    // Spot-check flags we rely on today…
    for flag in ["--model", "--model_dir", "--output_dir", "--output_format",
                 "--verbose", "--task", "--fp16", "--language",
                 "--initial_prompt", "--carry_initial_prompt"] {
        #expect(LocalWhisperClient.supportedCLIFlags.contains(flag))
    }
    // …and the threshold flags F264's remaining half would reach for, so a later change can trust
    // this list rather than re-deriving it.
    for flag in ["--condition_on_previous_text", "--compression_ratio_threshold",
                 "--logprob_threshold", "--no_speech_threshold", "--temperature"] {
        #expect(LocalWhisperClient.supportedCLIFlags.contains(flag))
    }
}

@Test("A faster-whisper flag name is rejected, so the guard actually bites (F264)")
func foreignFlagNamesAreNotAllowed() {
    // Without this the allowlist could be quietly over-broad and never fail anything. These are the
    // exact names a well-meaning change would reach for to fix a repetition loop — and each one
    // would mean no transcript, not a degraded one.
    for foreign in ["--repetition_penalty", "--no_repeat_ngram_size", "--vad_filter",
                    "--condition_on_prev_tokens", "--chunk_length", "--batch_size"] {
        #expect(!LocalWhisperClient.supportedCLIFlags.contains(foreign),
                "\(foreign) is a faster-whisper/HF name; openai-whisper would exit 2")
    }
}
