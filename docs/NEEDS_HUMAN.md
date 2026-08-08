# Needs human

The queue of tickets blocked on a physical action or a decision only the user can make — each with a
**What I need from you:** line. How an entry arrives here, and the cap on this file, are governed by
the ticket rules in [`../AGENTS.md`](../AGENTS.md); open work stays in [`TICKETS.md`](TICKETS.md).

---

### F176 — Install and select full Xcode so the Swift Testing suite can run

- **Status:** needs-human
- **Owner:** /root
- **Severity:** medium
- **Area:** build
- **Filed:** 2026-08-08 by /root, while verifying F175

**Problem.** `swift build` passes, but `swift test` stops before any tests run because every test
target reports `no such module 'Testing'`. The active developer directory is
`/Library/Developer/CommandLineTools`; `xcodebuild -version` reports that Xcode is required, and no
`Xcode.app` is installed in `/Applications`. The project uses the Swift Testing framework by design.

**Impact.** No behavioral change can currently meet the required full-suite verification gate, even
though the application itself builds.

**What I need from you:** Install a full Xcode version compatible with this macOS release, select it
as the active developer directory, then let an agent rerun `swift test`.

**Verification.** `xcode-select -p` ends in `Xcode.app/Contents/Developer`, `swift test` compiles
`import Testing`, and the full suite completes.
