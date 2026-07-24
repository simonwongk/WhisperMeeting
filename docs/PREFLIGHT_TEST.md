# Preflight test recording

The single biggest anxiety with any recorder is silent: *will it actually capture when the meeting
that matters happens?* WhisperMeet captures two independent tracks — your microphone and the Mac's
system audio — and either can fail quietly (wrong input device, muted mic, no Screen-Recording
permission, nothing actually playing). You only find out afterwards, when it's too late.

Preflight test recording removes that risk. Before a critical meeting you run a short, **disposable**
test: it records a few seconds of both channels, analyzes each for real signal, and tells you plainly
whether mic and system audio are being captured — with specific guidance when one isn't. The test is
kept entirely **separate from the permanent meeting library**: it writes to a temp folder, is never
indexed as a meeting, and is deleted when you dismiss it.

## What it measures (`PreflightSignalAnalyzer`, pure `WhisperCore`, tested)

Each channel's `.f32` track is a stream of 48 kHz Float32 samples in `-1...1`. For each channel we
compute:

- **peak** — the largest absolute sample.
- **rms** — root-mean-square level (overall loudness).

and classify by peak into a `ChannelSignalLevel`:

| level | peak range | meaning |
|---|---|---|
| `silent` | `< 0.01` | essentially nothing — the channel captured no audio |
| `faint` | `0.01 – 0.05` | signal present but very quiet |
| `ok` | `0.05 – 0.98` | healthy |
| `hot` | `≥ 0.98` | very loud; may clip/distort |

Peak alone isn't enough to declare a channel healthy: a single notification blip, tap, or cable
click spikes the peak without any sustained audio. So readiness uses **`isSustained`**, which
requires a modest peak-to-RMS *crest factor* (≤ 20). Real speech — even quiet speech — stays well
under that; a lone transient (huge peak over a near-silent RMS) is far above it and is reported as
"only a brief sound … not sustained speech", not as ready.

## The verdict (`PreflightAssessment`, pure `WhisperCore`, tested)

`evaluate(microphone:system:)` combines the two channel signals into a `PreflightReport`: per-channel
`isCapturing` (the channel carried *sustained* audio — see `isSustained`, not merely a peak above
`silent`), a headline, and specific, actionable notes. The two channels are treated differently on
purpose:

- **A silent microphone is a real problem** — you almost always want your own voice. It's flagged
  firmly ("check your input device / that you're not muted").
- **Silent system audio is usually benign** — it's only captured while another app is *playing*
  sound, so during a quiet test it's expected. It's surfaced as an informational check, not a failure
  ("system audio is only captured while something is playing").

## Capture (UI, `WhisperMeet`)

A "Test recording" control in the Record view opens a sheet that records a fixed ~8-second sample via
a **dedicated** `AudioCaptureEngine` into a temp directory, then shows the report and lets you play the
sample back and re-run. It is blocked while a real meeting recording (or Quick Dictation) is active,
and the temp files are removed on dismiss.

## Invariants respected

Local-only (all analysis on-device), the permanent recording library is never touched, no diarization,
original language only. The disposable test never becomes a meeting and never deletes any real recording.
