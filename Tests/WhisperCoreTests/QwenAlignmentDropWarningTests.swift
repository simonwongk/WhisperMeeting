import Foundation
import Testing
@testable import WhisperCore

// F30 — a completed Qwen transcript must never silently lose every timestamp. Whenever the result
// carries text but no timestamped segments, `makeResult` surfaces a plain-language warning so the
// UI can explain the missing timestamps. This covers the case F28's plumbing could not: the helper
// itself reports success (no `alignmentWarning`) but its word timings cannot be reconciled with the
// punctuated transcript, so `QwenAlignedTranscript.segments` drops them all.

/// Aligner produced word timings, but they do not reconcile with the transcript text (a
/// `QwenAlignedTranscript` guard trips and returns no segments). The helper reported no warning, so
/// before F30 the result carried empty segments AND a nil warning — a silent drop.
@Test("Unreconcilable Qwen alignment surfaces a warning even when the helper reported none (F30)")
func unreconcilableAlignmentSurfacesWarning() throws {
    let payload = try JSONDecoder().decode(
        QwenOutput.self,
        from: Data(#"""
        {"text":"Kubernetes powers the cluster.","language":"en",
         "alignedItems":[{"text":"totally","start":0.0,"end":0.5},
                         {"text":"different","start":0.5,"end":1.0}],
         "alignmentWarning":null}
        """#.utf8)
    )
    let result = QwenASRClient.makeResult(id: "m1", text: "Kubernetes powers the cluster.", payload: payload)

    #expect(result.segments.isEmpty) // the mismatch drops every timestamp …
    #expect(result.text == "Kubernetes powers the cluster.") // … but the complete text is preserved
    #expect(result.alignmentWarning != nil) // and the user is now told why (F30)
}

/// The helper produced text but no alignment items at all and reported no warning. This is still a
/// transcript with no timestamps, so it too must be explained rather than shown blank.
@Test("A timestamp-less Qwen transcript with no helper warning still surfaces a warning (F30)")
func emptyAlignmentSurfacesWarning() throws {
    let payload = try JSONDecoder().decode(
        QwenOutput.self,
        from: Data(#"{"text":"hello world","language":"en","alignedItems":[],"alignmentWarning":null}"#.utf8)
    )
    let result = QwenASRClient.makeResult(id: "m2", text: "hello world", payload: payload)

    #expect(result.segments.isEmpty)
    #expect(result.alignmentWarning != nil)
}

/// Defensive: even if the helper reports a warning, when its word timings still reconcile into
/// segments the transcript IS seekable — so the "timestamps unavailable" notice must NOT appear
/// (it would contradict the seekable transcript shown right below it).
@Test("A helper warning is suppressed when segments still reconcile (F30)")
func helperWarningSuppressedWhenSegmentsReconcile() throws {
    let payload = try JSONDecoder().decode(
        QwenOutput.self,
        from: Data(#"""
        {"text":"hello world.","language":"en",
         "alignedItems":[{"text":"hello","start":0.0,"end":0.4},
                         {"text":"world","start":0.4,"end":0.9}],
         "alignmentWarning":"RuntimeWarning: soft glitch"}
        """#.utf8)
    )
    let result = QwenASRClient.makeResult(id: "m4", text: "hello world.", payload: payload)

    #expect(!result.segments.isEmpty)
    #expect(result.alignmentWarning == nil)
}

/// A well-aligned transcript reconciles cleanly, so there is nothing to warn about.
@Test("A cleanly aligned Qwen transcript carries timestamps and no warning (F30)")
func cleanAlignmentHasNoWarning() throws {
    let payload = try JSONDecoder().decode(
        QwenOutput.self,
        from: Data(#"""
        {"text":"hello world.","language":"en",
         "alignedItems":[{"text":"hello","start":0.0,"end":0.4},
                         {"text":"world","start":0.4,"end":0.9}],
         "alignmentWarning":null}
        """#.utf8)
    )
    let result = QwenASRClient.makeResult(id: "m3", text: "hello world.", payload: payload)

    #expect(!result.segments.isEmpty)
    #expect(result.alignmentWarning == nil)
}
