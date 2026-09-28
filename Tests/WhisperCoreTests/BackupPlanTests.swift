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

// F532 — a `.skip` item costs 0 bytes only when hard links actually work at the destination.
// exFAT/FAT/most SMB mounts refuse them, so every `.skip` there falls back to a full copy, and the
// free-space check must budget for that BEFORE the run starts, not discover it mid-copy.
@Test("bytesNeeded counts skip items as free only when hard links are supported (F532)")
func bytesNeededAccountsForHardLinkFallback() {
    let plan = [
        BackupItem(file: BackupFile(relativePath: "a", size: 100, contentHash: "h-a"), action: .copy),
        BackupItem(file: BackupFile(relativePath: "b", size: 200, contentHash: "h-b"), action: .skip),
        BackupItem(file: BackupFile(relativePath: "c", size: 300, contentHash: "h-c"), action: .skip),
    ]

    // Hard links work (the ordinary case, e.g. APFS): skips are free.
    #expect(BackupPlan.bytesNeeded(for: plan, hardLinksSupported: true) == 100)
    // Hard links do not work (exFAT/FAT/most SMB): skips fall back to a real copy and cost their
    // full size too.
    #expect(BackupPlan.bytesNeeded(for: plan, hardLinksSupported: false) == 600)
}
