import Testing
@testable import WhisperCore

/// F75 — backup planning, retention, and verification.
@Test("Backup plan skips unchanged files, schedules changed and new ones")
func backupPlanComputes() {
    let source = [
        BackupFile(relativePath: "a", size: 10, contentHash: "h-a"),   // unchanged
        BackupFile(relativePath: "b", size: 20, contentHash: "h-b2"),  // changed
        BackupFile(relativePath: "c", size: 30, contentHash: "h-c"),   // new
    ]
    let destination = [
        BackupFile(relativePath: "a", size: 10, contentHash: "h-a"),
        BackupFile(relativePath: "b", size: 20, contentHash: "h-b1"), // different hash
    ]

    let plan = BackupPlan.compute(source: source, destination: destination)

    func action(_ path: String) -> BackupAction? { plan.first { $0.file.relativePath == path }?.action }
    #expect(action("a") == .skip)
    #expect(action("b") == .copy)
    #expect(action("c") == .copy)
}

@Test("keep-3 retention prunes exactly the 4th-oldest and older")
func backupRetentionKeepsLatest() {
    let generations = [
        BackupGeneration(id: "g1", createdAtEpoch: 100), // oldest
        BackupGeneration(id: "g2", createdAtEpoch: 200),
        BackupGeneration(id: "g3", createdAtEpoch: 300),
        BackupGeneration(id: "g4", createdAtEpoch: 400), // newest
    ]

    let toDrop = BackupRetention.prune(generations: generations, policy: .keepLatest(3))

    #expect(toDrop.map(\.id) == ["g1"]) // keep g4/g3/g2; drop the oldest
}

@Test("Backup verification fails on a post-copy hash mismatch")
func backupVerification() {
    #expect(BackupVerification.succeeded(expectedHash: "abc", actualHash: "abc"))
    #expect(!BackupVerification.succeeded(expectedHash: "abc", actualHash: "xyz"))
}
