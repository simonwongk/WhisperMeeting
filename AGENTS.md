## Tickets — read this first

`docs/TICKETS.md` is the single source of truth for outstanding work, for every coding agent.

Read it before starting any task. File anything you discover there as a ticket, including findings
you are not going to fix — a finding that lives only in a chat reply dies with the session. Claim a
ticket by setting `Status: in-progress` and `Owner` before you work on it.

When you close a ticket, move it to `docs/TICKET_LOG.md` and record **real command output** as
evidence: the test failing before your fix, the test passing after, the build, and any real-model
run. Never delete a ticket — `wontfix` and `invalid` get logged like any other outcome. Reference
the ticket ID in commit messages, e.g. `fix(dictation): keep helper stdout pure JSON (F24)`.

The full rules, ID allocation, and the definition of done are in `docs/TICKETS.md`.

## Upstream documentation

Always fetch https://whisperai.com/docs before writing WhisperAI code. Verify endpoint paths and
parameters against the live docs — do not guess.

Before writing local OpenAI Whisper code, fetch the current official repository documentation at
https://github.com/openai/whisper and verify model names and command-line options against the live
source.
