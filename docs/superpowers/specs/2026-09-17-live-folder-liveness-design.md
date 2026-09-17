# F279 — Closing F255's residual gap with a direct liveness test

**Status:** design, 2026-09-17, whisper-62. **Ticket:** F279, the unclosed remainder of F255.

## The sequence to close

1. A opens, takes `.held`, sits idle.
2. B launches → `.heldElsewhere`, cached in `MeetingStore.init` for B's whole life.
3. The user quits A. The lock is free; B never re-reads it.
4. B starts recording. Nothing gates `startRecording` on the lease.
5. C launches → acquires `.held` → **F255's gate opens** → C rebuilds B's live folder.

F255's premise — "a live second instance never holds the lease" — covers a recorder holding
`.held`. It does not cover a recorder holding *neither*, because its sample is stale.

## Two fixes I rejected, and why

**Re-take the lease when recording starts.** Closes step 4 only if A has already quit. A quitting
*during* B's recording leaves the same hole, because the lease frees up mid-capture and C then
takes it. It also invites the far worse variant — refusing to record without a lease — which would
cost the user a meeting to prevent a recovery bug.

**A freshness window on the `.f32` mtime** (the original F255 proposal). Needs a number, and every
number is wrong somewhere: long enough to survive a stream outage that F275 restarts, and short
enough that a *genuinely* crashed recording is recoverable at the next launch. Those pull opposite
ways, and the loser is the common case — a user relaunching within seconds of a crash would find
recovery deferred, with nothing re-running it in that session.

## The fix: ask whether the file is growing

A live capture appends frames continuously — the callback delivers buffers whether or not anyone is
speaking, so a silent room still grows the file. A crashed one does not grow at all, ever.

So sample the two `.f32` sizes, wait briefly, sample again. Growth means live. No window, no
constant to re-derive, and no penalty for relaunching quickly after a crash: a dead folder's bytes
are identical across the two samples however soon you look.

One sleep covers the whole sweep — sample every orphan, sleep once, sample again — so the cost is
a fixed fraction of a second, and only when something looks orphaned at all, which is normally
nothing.

## What this does NOT do

**The lease gate stays.** The probe is an additional refusal, not a replacement. Relaxing the gate
now that folders can be checked individually would also fix F255's accepted trade-off — a
genuinely orphaned folder is currently not rebuilt while another instance is open — and that is
tempting and out of scope. If the probe is wrong in some case nobody has thought of, keeping the
gate means the failure is a deferred recovery rather than a re-run of F255. One guard is being
added, not swapped.

**Nothing gates `startRecording`.** Recording must never be refused to protect a recovery
invariant.

## Residual, stated rather than discovered later

A capture whose stream has died but which F275 is about to restart is not growing during the
outage. A second instance sweeping in exactly that window sees a dead-looking folder. The window is
bounded by F275's retry, the lease gate still covers the ordinary two-instance case, and the
alternative — a freshness window — has a worse failure in a more common case. It goes in the log,
not in a comment nobody reads.

## Verification

- A folder whose tracks grow between samples is not rebuilt; its raw tracks are untouched.
- A folder whose tracks are identical across samples **is** rebuilt — the probe must not defer
  every recovery, which would be a silent way of breaking the feature.
- A folder with no tracks at all reads as not-growing rather than crashing.
- The skip is reported, not silent.
- The sampling is pure and tested without sleeping: `sample` and `isGrowing` are separate.
