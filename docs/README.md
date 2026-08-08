# WhisperMeet documentation map

Use this page to choose the right document instead of scanning the whole repository. The first table
is for people using or evaluating the app; the second is for people and agents changing it.

## Product and operation

| If you need to… | Start here | Then consult |
|---|---|---|
| Understand the app and install it | [`../README.md`](../README.md) | [`PRODUCT_SPEC.md`](PRODUCT_SPEC.md) for the non-negotiable requirements. |
| Record safely or recover a meeting | [`RECOVERY.md`](RECOVERY.md) | [`RECORDING_HEALTH.md`](RECORDING_HEALTH.md), [`PREFLIGHT_TEST.md`](PREFLIGHT_TEST.md). |
| Use a focused feature | [`QUICK_DICTATION_DESIGN.md`](QUICK_DICTATION_DESIGN.md) | [`RECORDING_MARKERS.md`](RECORDING_MARKERS.md), [`TRANSCRIPT_QUALITY.md`](TRANSCRIPT_QUALITY.md). |
| Understand the only cloud exception | [`CLAUDE_SUMMARIES.md`](CLAUDE_SUMMARIES.md) | The privacy boundary in [`PRODUCT_SPEC.md`](PRODUCT_SPEC.md). |

## Project work

| Need | Authoritative source | Best view |
|---|---|---|
| Start or claim work | [`TICKETS.md`](TICKETS.md) | [`tickets-dashboard.html`](tickets-dashboard.html) for a scan-first static view. |
| Complete a human-only check or decision | [`NEEDS_HUMAN.md`](NEEDS_HUMAN.md) | The dashboard's **Needs your action** section. |
| Verify a finished ticket | [`TICKET_LOG.md`](TICKET_LOG.md) | The ticket's recorded command output and reachability evidence. |
| Understand the process | [`../AGENTS.md`](../AGENTS.md) | The **Start every task** and ticket templates. |

The Markdown files are always authoritative. The dashboard is generated from them and is
deliberately static—after editing a board file, run the two commands documented in
[`../AGENTS.md`](../AGENTS.md) to regenerate and verify it.

## Decisions and evidence

| Document | Purpose |
|---|---|
| [`ROADMAP.md`](ROADMAP.md) | Aspirational, prioritized work that is not yet a ticket. |
| [`CHANGELOG.md`](CHANGELOG.md) | Human-facing account of shipped cycles. |
| [`ASR_EVALUATION_LOG_2026-07-29.md`](ASR_EVALUATION_LOG_2026-07-29.md) | Synthetic ASR comparison evidence. |
| [`ASR_MODEL_ALTERNATIVES.md`](ASR_MODEL_ALTERNATIVES.md) | Decision criteria for local ASR choices. |
| [`DICTATION_MODEL_SELECTION_LOG_2026-07-30.md`](DICTATION_MODEL_SELECTION_LOG_2026-07-30.md) | Dictation model evaluation record. |
| [`UI_REDESIGN_LOG.md`](UI_REDESIGN_LOG.md) | UI redesign decisions and rejected alternatives. |
| [`URL_IMPORT_PLAN.md`](URL_IMPORT_PLAN.md) | Proposed plan (`F175`) for importing audio from a pasted link. Not started; decisions and verified traps recorded before any code. |

## Historical planning records

[`../plans/README.md`](../plans/README.md) indexes completed animation plans. It is a historical
record, not an alternate work queue: re-verify and file a ticket before acting on any observation in
it.
