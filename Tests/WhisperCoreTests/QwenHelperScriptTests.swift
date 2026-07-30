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
    let program = """
    import importlib.util, json
    spec = importlib.util.spec_from_file_location("qwen_dictate_server", \(String(reflecting: helper.path)))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    class Result:
        text = " shared audio worked "
        segments = []
    class Model:
        def __init__(self):
            self.arguments = None
        def generate(self, path, **options):
            self.arguments = {"path": path, **options}
            return Result()
    model = Model()
    response = module.transcribe_request(model, {
        "wavPath": "/tmp/existing-capture.wav",
        "language": None,
        "initialPrompt": "Whisper-only vocabulary",
    })
    print(json.dumps({"arguments": model.arguments, "response": response}))
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
    let program = """
    import importlib.util, json, os, wave
    spec = importlib.util.spec_from_file_location("qwen_dictate_server", \(String(reflecting: helper.path)))
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    class Model:
        def __init__(self):
            self.observed = None
        def generate(self, path, **options):
            with wave.open(path, "rb") as audio:
                self.observed = {
                    "exists": os.path.exists(path),
                    "rate": audio.getframerate(),
                    "channels": audio.getnchannels(),
                    "frames": audio.getnframes(),
                    "language": options["language"],
                }
    model = Model()
    module.prewarm(model)
    print(json.dumps(model.observed))
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
