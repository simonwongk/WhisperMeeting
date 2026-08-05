import Foundation
import Testing

/// F164 — exercises the real Scripts/summarize_local.py pure `parse_summary` through the system
/// Python (no mlx_lm needed: the heavy import is deferred inside main()), mirroring the house
/// QwenHelperScriptTests pattern. This proves the degrade-never-raise parsing contract that the
/// Swift `LocalSummarizer` depends on when it decodes the helper's --output payload.
struct SummarizeLocalHelperScriptTests {

    private func runParseSummary(on modelText: String) throws -> String {
        let repository = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // WhisperCoreTests/
            .deletingLastPathComponent()   // Tests/
            .deletingLastPathComponent()   // repo root
        let helper = repository.appendingPathComponent("Scripts/summarize_local.py")
        let program = """
        import importlib.util, json
        spec = importlib.util.spec_from_file_location("summarize_local", \(String(reflecting: helper.path)))
        module = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(module)
        payload, warning = module.parse_summary(\(String(reflecting: modelText)))
        print(json.dumps({"payload": payload, "warning": warning}, ensure_ascii=False))
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
        return output
    }

    @Test("summarize_local extracts a fenced JSON object with prose and a thinking block (F164)")
    func extractsJSONFromMessyOutput() throws {
        let messy = """
        <think>The user wants a summary as JSON.</think>
        Sure, here is the summary:
        ```json
        {"summary":"We shipped v1.","keyPoints":["Ship v1"],"actionItems":["Email vendor"]}
        ```
        """
        let output = try runParseSummary(on: messy)
        #expect(output.contains("\"warning\": null"))
        #expect(output.contains("We shipped v1."))
        #expect(output.contains("Email vendor"))
        // The reasoning trace must never leak into the summary.
        #expect(!output.contains("The user wants a summary"))
    }

    @Test("summarize_local degrades non-JSON output to a raw-text summary, never raising (F164)")
    func degradesNonJSONWithoutRaising() throws {
        let output = try runParseSummary(on: "I couldn't follow the format, but here is a recap.")
        #expect(output.contains("used its text as the summary"))
        #expect(output.contains("here is a recap."))
    }
}
