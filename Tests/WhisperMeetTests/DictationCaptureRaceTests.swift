import AVFoundation
import Foundation
import Testing
@testable import WhisperMeet

// F720 — F404 put MicDictationRecorder's state, interruption, node and callback under one lock, but
// every test of it was deterministic: an observer registered with `queue: nil` runs inside `post`,
// so the handler always ran on the test's own thread and two threads never touched the recorder at
// once. This one posts the configuration change from another thread while this thread stops the
// capture, which is the interleaving the lock exists for (AVFAudio posts from its own queue while
// the key release reaches `stop()` on main). Its point is the ThreadSanitizer run recorded in F720's
// closure; without the sanitizer it checks only that every outcome is one a key release can see.

@Test("A device change handled on another thread while stop() runs leaves one of the outcomes a key release can see (F720)")
func aChangeOnAnotherThreadRacesStop() {
    let center = NotificationCenter()
    let recorder = MicDictationRecorder(
        hardwareFormatProbe: { (sampleRate: 48_000, channels: 1) },
        notificationCenter: center
    )
    let engine = recorder.engineForTesting
    let poster = DispatchQueue(label: "F720.poster")
    var unexpected: [String] = []
    for _ in 0..<200 {
        recorder.setRecordingForTesting()
        let posted = DispatchGroup()
        poster.async(group: posted) {
            center.post(name: .AVAudioEngineConfigurationChange, object: engine)
        }
        do {
            _ = try recorder.stop()
            unexpected.append("stop() returned a clip from a capture that heard nothing")
        } catch let error as MicDictationRecorder.RecorderError {
            switch error {
            case .noAudioCaptured, .notRecording, .captureInterrupted(.deviceConfigurationChanged): break
            default: unexpected.append(String(describing: error))
            }
        } catch {
            unexpected.append(String(describing: error))
        }
        posted.wait()
        // Whatever the order, the handler's reason is not left for the next capture.
        _ = try? recorder.stop()
        recorder.cancel()
    }
    #expect(unexpected.isEmpty, "\(unexpected.prefix(5))")
    #expect(!recorder.isRecording)
}
