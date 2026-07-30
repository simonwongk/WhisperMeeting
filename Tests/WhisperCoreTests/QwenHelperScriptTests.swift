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
