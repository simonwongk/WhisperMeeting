import Foundation
import Testing

@Test("Qwen helper alignment failure returns no items and a diagnostic")
func qwenHelperAlignmentFallback() throws {
    let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let helper = repository.appendingPathComponent("Scripts/qwen_transcribe.py")
    let program = """
    import importlib.util, json
    spec = importlib.util.spec_from_file_location("qwen_transcribe", \(String(reflecting: helper.path)))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    def fail(_):
        raise RuntimeError("forced alignment failure")
    items, warning = module.align_chunks(fail, "missing", [], [], "auto")
    print(json.dumps({"items": items, "warning": warning}))
    """
    let pipe = Pipe()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = ["-c", program]
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let output = String(decoding: data, as: UTF8.self)
    #expect(process.terminationStatus == 0, Comment(rawValue: output))
    #expect(output.contains("\"items\": []"))
    #expect(output.contains("RuntimeError: forced alignment failure"))
    #expect(output.contains("preserving complete ASR text"))
}

@Test("Qwen dictation helper reuses the captured WAV and maps automatic language")
func qwenDictationHelperMapsSharedRequest() throws {
    let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let helper = repository.appendingPathComponent("Scripts/qwen_dictate_server.py")
    // F431: the helper decodes through mlx-audio's `stream_generate`, one chunk at a time, instead
    // of the library's unguarded `generate`; these fakes stand in for the three runtime calls.
    let program = """
    import importlib.util, json
    spec = importlib.util.spec_from_file_location("qwen_dictate_server", \(String(reflecting: helper.path)))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    arguments = {}
    module.load_clip = lambda path: arguments.update(path=path) or "clip audio"
    module.split_clip = lambda audio, sample_rate: [(audio, 0.0)]
    module.release_chunk_memory = lambda: None
    class Tokenizer:
        def decode(self, tokens, skip_special_tokens=True):
            return " shared audio worked " if tokens == [7] else repr(tokens)
    class Model:
        sample_rate = 16000
        _tokenizer = Tokenizer()
        def stream_generate(self, audio, **options):
            arguments.update(audio=audio, **options)
            yield 7, None
    response = module.transcribe_request(Model(), {
        "wavPath": "/tmp/existing-capture.wav",
        "language": None,
        "initialPrompt": "Whisper-only vocabulary",
    })
    print(json.dumps({"arguments": arguments, "response": response}))
    """
    let pipe = Pipe()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = ["-c", program]
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let output = String(decoding: data, as: UTF8.self)

    #expect(process.terminationStatus == 0, Comment(rawValue: output))
    #expect(output.contains("\"path\": \"/tmp/existing-capture.wav\""))
    #expect(output.contains("\"language\": \"auto\""))
    #expect(output.contains("\"text\": \"shared audio worked\""))
    #expect(!output.contains("Whisper-only vocabulary"))
}

@Test("Qwen dictation helper compiles one inference before reporting ready")
func qwenDictationHelperPrewarmsModel() throws {
    let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let helper = repository.appendingPathComponent("Scripts/qwen_dictate_server.py")
    // F431: the prewarm runs the request path itself, so the clip it writes is observed where
    // every request's clip is loaded, and the language where every request's chunk is decoded.
    let program = """
    import importlib.util, json, os, wave
    spec = importlib.util.spec_from_file_location("qwen_dictate_server", \(String(reflecting: helper.path)))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    observed = {}
    def load_clip(path):
        with wave.open(path, "rb") as audio:
            observed.update(
                exists=os.path.exists(path),
                rate=audio.getframerate(),
                channels=audio.getnchannels(),
                frames=audio.getnframes(),
            )
        return "clip audio"
    module.load_clip = load_clip
    module.split_clip = lambda audio, sample_rate: [(audio, 0.0)]
    module.release_chunk_memory = lambda: None
    class Tokenizer:
        def decode(self, tokens, skip_special_tokens=True):
            return ""
    class Model:
        sample_rate = 16000
        _tokenizer = Tokenizer()
        def stream_generate(self, audio, **options):
            observed.update(language=options["language"])
            yield from ()  # a generator, as the library's is
    module.prewarm(Model())
    print(json.dumps(observed))
    """
    let pipe = Pipe()
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = ["-c", program]
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    let output = String(decoding: data, as: UTF8.self)

    #expect(process.terminationStatus == 0, Comment(rawValue: output))
    #expect(output.contains("\"exists\": true"))
    #expect(output.contains("\"rate\": 16000"))
    #expect(output.contains("\"channels\": 1"))
    #expect(output.contains("\"frames\": 16000"))
    #expect(output.contains("\"language\": \"auto\""))
}
