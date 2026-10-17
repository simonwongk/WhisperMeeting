import Foundation
import Testing
@testable import WhisperCore

// F1020 (F620's retention half, the user's decision of 2026-10-16: "Never; keep them"). A conflict
// branch is a losing save's work and exists nowhere else, so nothing deletes one automatically — only
// the user, through Forget History's "and Conflict Copies". `RetentionPolicy.maxConflictBranches`
// (20) was read by nothing, so the code implied a limit it never enforced. It is gone; the rule that
// replaces it is the one `prune` already keeps.

@Test("The retention policy carries no conflict-branch limit, because conflict branches are never pruned (F1020)")
func theRetentionPolicyHasNoConflictBranchLimit() {
    // Derived from the type, so a renamed or re-added limit is seen without this test knowing its name.
    let fields = Mirror(reflecting: RetentionPolicy()).children.compactMap(\.label)
    #expect(!fields.contains { $0.lowercased().contains("conflict") }, "\(fields)")
}

@Test("More conflict branches than the old limit all survive every prune (F1020)")
func conflictBranchesPastTheOldLimitSurvive() throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("F1020-\(UUID().uuidString)", isDirectory: true)
    let history = directory.appendingPathComponent("meetings.history", isDirectory: true)
    try FileManager.default.createDirectory(at: history, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }
    let branches = (1...25).map { String(format: "conflict-%09d-aaaa1020-%016llx.json", $0, UInt64($0)) }
    for name in branches { try Data("[]".utf8).write(to: history.appendingPathComponent(name)) }
    let store = BackupJSONStore<[String]>(
        primaryURL: directory.appendingPathComponent("meetings.json"),
        backupURL: directory.appendingPathComponent("meetings.backup.json"),
        retention: RetentionPolicy(recentCount: 1, ageAnchors: [], pinHighWaterRecordCount: false, byteBudget: 1, byteBudgetCeiling: 1)
    )
    var token = try store.save(["one"]).token
    for index in 0..<3 { token = try store.save(["save \(index)"], expecting: token).token }

    let left = Set(try FileManager.default.contentsOfDirectory(atPath: history.path))
    #expect(Set(branches).isSubset(of: left), "a conflict branch was removed: \(Set(branches).subtracting(left).sorted())")
}
