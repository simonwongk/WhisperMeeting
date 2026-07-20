# Recording Health Monitoring

WhisperMeet checks recording conditions before capture and monitors the two saved source channels while a meeting is in progress. Health warnings never delete or replace audio; they help the user react before a problem affects the transcript.

## Before recording

The New Meeting screen shows:

- The current default microphone, whether an input device exists, and its permission state.
- Mac system-audio capture permission.
- Storage available on the volume containing the recording library.

macOS requests undecided microphone permission when recording starts. Recording is blocked when no microphone input is available. Screen/system-audio capture has only a granted/not-granted preflight signal; when it is not granted, the app directs the user to check System Settings because macOS may not show the prompt again after a denial. Recording is also blocked when less than 500 MB is available because beginning a meeting in that condition puts the audio at immediate risk.

## During recording

The app displays separate level meters for the microphone and Mac system audio. These levels are calculated from the same converted samples being written into `microphone-audio.f32` and `system-audio.f32`, rather than from an unrelated preview path.

The health panel checks once per second and reports:

| Condition | Behavior |
|---|---|
| A previously active channel delivers no samples for more than 3 seconds | Warn that capture stopped. |
| No microphone samples arrive during the initial 4-second grace period | Warn that microphone capture stopped. |
| No system-audio samples have ever arrived after 15 seconds | Ask the user to play meeting audio to verify the channel. Silence alone is not described as a capture failure. |
| A channel reaches 98% of full scale | Keep a clipping warning visible for 3 seconds. |
| Available storage falls below 2 GB | Warn the user to stop soon to protect the recording. |

Warnings do not stop the meeting automatically. Stopping safely is normally preferable to abruptly ending capture, and the existing interruption recovery remains available if capture subsequently fails.

WhisperMeet also asks macOS to prevent idle system sleep and sudden process termination for the duration of recording and final audio preparation. The activity ends after stopping, cancellation, or a capture error.

## Interpretation

- A moving microphone meter confirms that local speech is reaching the saved microphone track.
- A moving system-audio meter confirms that Mac playback is reaching the saved remote-participant track.
- A silent system meter can be normal before another participant speaks or while the meeting application is silent.
- Level monitoring detects capture continuity, clipping, and storage risk. It does not prove that the intended application or microphone was selected, so the user should still perform a short spoken/playback check before an important meeting.

## Verification

Core tests cover dropped-channel detection, clipping, low storage, and the distinction between system audio that has not yet been detected and a channel that was active and then stopped.
