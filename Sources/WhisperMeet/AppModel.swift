import AVFoundation
import AppKit
import CoreGraphics
import Combine
import Foundation
import UserNotifications
import WhisperCore

struct RecordingPreflightStatus: Equatable {
    enum Access: Equatable {
        case granted
        case permissionNeeded
        case notGranted
        case denied
        case unavailable
    }

    let microphoneAccess: Access
    let systemAudioAccess: Access
    let microphoneName: String
    let availableStorageBytes: Int64?

    static let checking = RecordingPreflightStatus(
        microphoneAccess: .permissionNeeded,
        systemAudioAccess: .permissionNeeded,
        microphoneName: "Default microphone",
        availableStorageBytes: nil
    )

    static func inspect(storageDirectory: URL) -> RecordingPreflightStatus {
        let microphone = AVCaptureDevice.default(for: .audio)
        let microphoneAccess: Access
        if microphone == nil {
            microphoneAccess = .unavailable
        } else {
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized:
                microphoneAccess = .granted
            case .notDetermined:
                microphoneAccess = .permissionNeeded
            case .denied, .restricted:
                microphoneAccess = .denied
            @unknown default:
                microphoneAccess = .denied
            }
        }
        let values = try? storageDirectory.resourceValues(forKeys: [
            .volumeAvailableCapacityForImportantUsageKey
        ])
        return RecordingPreflightStatus(
            microphoneAccess: microphoneAccess,
            systemAudioAccess: CGPreflightScreenCaptureAccess() ? .granted : .notGranted,
            microphoneName: microphone?.localizedName ?? "No microphone available",
            availableStorageBytes: values?.volumeAvailableCapacityForImportantUsage
        )
    }
}

@MainActor
final class RecordingMeterViewModel: ObservableObject {
    @Published private(set) var snapshot = RecordingMeterSnapshot.silent

    func update(_ snapshot: RecordingMeterSnapshot) {
        guard self.snapshot != snapshot else { return }
        self.snapshot = snapshot
    }

    func reset() {
        update(.silent)
    }
}

/// Why a per-segment re-run could not slice a clip (F92 audit fixes).
enum SegmentReRunError: LocalizedError {
    case unsupportedRecordingFormat
    case unreadableRecording

    var errorDescription: String? {
        switch self {
        case .unsupportedRecordingFormat:
            return "This recording isn't a native WAV, so a single segment can't be re-transcribed in place. Re-transcribe the whole meeting instead."
        case .unreadableRecording:
            return "The recording could not be read for re-transcription."
        }
    }
}

/// What the speaker-analysis seam needs (F219). Deliberately NOT the `MeetingRecord`: the runtime is
/// handed a path and a duration, never the transcript, the title, the notes, or anything else about
/// the meeting — there is nothing about a person for it to learn from.
struct SpeakerDiarizationRequest: Sendable {
    let meetingID: UUID
    let audioURL: URL
    let durationSeconds: TimeInterval
}

/// Everything a view needs to render anonymous speaker labels for one meeting, recomputed from the
/// CURRENT segments (F219). Display only: nothing here is ever written into `TranscriptSegment`,
/// `transcriptText`, or `meetings.json`.
struct SpeakerOverlayPresentation: Sendable, Equatable {
    /// One row per segment, in segment order.
    let rows: [SpeakerOverlayRow]
    /// The distinct clusters actually shown, in first-appearance order — the legend's row order.
    let clusterIDs: [Int]
    /// Cluster id -> the label a person typed for it, for this one meeting.
    let aliases: [Int: String]
    /// The stored analysis was computed against different transcript timings, so no label may be
    /// shown. The result itself is KEPT: the user is told why, and can analyze again.
    let isStale: Bool
    /// Exactly one voice could be told apart. Labelling every row "Speaker 1" is worthless for a real
    /// monologue and actively misleading for a failed separation, and renaming that single cluster
    /// would attribute the other person's words to the name typed — so nothing is labelled and rename
    /// is refused (the F216/F217 single-cluster rule).
    let isSingleCluster: Bool
    /// How many intervals the stored result contains. Zero means the analysis found no speech at all,
    /// which the review surface has to say differently from "one voice" — "a single speaker" would be
    /// a claim about a recording in which nothing was found (F220).
    let turnCount: Int
    /// How many distinct clusters the stored TURNS carry, before the overlay's conservative rule runs.
    /// Two or more of these with an empty `clusterIDs` means voices WERE told apart and no line could
    /// be attributed — which must not be reported as "only one voice", because that is false (F220).
    let distinguishedVoiceCount: Int
    /// A saved result exists but could not be read. Kept distinct from "no result at all" so someone
    /// who already ran an analysis is told their file is unreachable rather than being quietly invited
    /// to run one for the first time (F220).
    let isUnreadable: Bool
}

@MainActor
final class AppModel: ObservableObject {
    private enum EngineAdmissionError: LocalizedError {
        case dictationActive

        var errorDescription: String? {
            switch self {
            case .dictationActive:
                return "Finish the current Quick Dictation before starting a meeting transcription."
            }
        }
    }

    enum RecordingState: Equatable {
        case idle
        case starting
        case recording(startedAt: Date)
        case stopping

        /// Whether a capture is running right now — the phase a restart may act on (F275).
        var isLive: Bool {
            if case .recording = self { return true }
            return false
        }

        /// This phase as `WhisperCore` sees it, for the pure policies that cannot import `AppModel`.
        var policyState: RecordingSleepPolicy.State {
            switch self {
            case .idle: .idle
            case .starting: .starting
            case .recording: .recording
            case .stopping: .stopping
            }
        }
    }

    /// The lifecycle of a disposable "test recording" that verifies both channels before a real
    /// meeting. Kept entirely separate from the recording state machine and the meeting library.
    enum PreflightTestPhase: Equatable {
        case idle
        case recording(secondsRemaining: Int)
        case analyzing
        case result(PreflightReport, playbackURL: URL?)
        case failed(String)
    }

    @Published private(set) var recordingState: RecordingState = .idle
    @Published private(set) var preflightTest: PreflightTestPhase = .idle
    /// Markers dropped during the current recording (offsets from its start). Persisted into the
    /// `MeetingRecord` on stop; discarded on cancel. See `docs/RECORDING_MARKERS.md`.
    @Published private(set) var pendingMarkers: [RecordingMarker] = []
    /// The title being typed for the current recording (F298).
    ///
    /// On the model rather than in `ContentView`'s `@State` because a view-local value exists
    /// nowhere but the view: F258 built a sidecar to survive a crash, ⌘Q or a shutdown, and every
    /// caller wrote its `title` empty because the title had not reached the model yet. Often the
    /// only thing distinguishing two meetings recorded the same afternoon.
    ///
    /// Not `private(set)`: the recording sheet's text field binds to it directly, which is the
    /// point — there is no second copy to keep in step.
    ///
    /// Mirrored to the sidecar from `didSet`, not from a `$recordingTitle` sink. `@Published`
    /// publishes in *willSet*, so a sink that asked `updateRecordingSession` to mirror the property
    /// would write the value the user just replaced — and its first draft did, silently, because the
    /// file it wrote was still well-formed. `didSet` runs after the assignment, needs no observer to
    /// be wired up, and keeps the mirror in the one place that knows the file reflects the model.
    @Published var recordingTitle: String = "" {
        didSet {
            // Per keystroke, but `updateRecordingSession` returns immediately when nothing is
            // recording, so idle typing costs a guard.
            //
            // While recording it is a sidecar read plus a whole-file write, which is exactly the
            // shape the F160 rule exists to keep off a tick — so it is **measured**, not assumed:
            // **269 µs** per read+write with twelve markers, so ~0.27% of main-thread time at ten
            // keystrokes a second. A marker drop already pays the same call; the difference is only
            // that markers are dropped by hand. If that ever stops being true — a much larger
            // sidecar, a pressured filesystem — coalescing the writes is the fix, not dropping them.
            guard oldValue != recordingTitle else { return }
            updateRecordingSession { _ in }
        }
    }
    @Published private(set) var activeMeetingID: UUID?
    @Published private(set) var transcription = TranscriptionQueue()
    @Published private(set) var transcriptionProgress: [UUID: LocalTranscriptionProgress] = [:]
    @Published private(set) var activeSummarizationID: UUID?
    @Published private(set) var hasClaudeAPIKey: Bool = false
    @Published private(set) var runtimeExecutableURL: URL?
    @Published private(set) var isInstallingRuntime = false
    @Published private(set) var installationMessage: String?
    @Published private(set) var isQwenInstalled = false
    @Published private(set) var isInstallingQwenRuntime = false
    @Published private(set) var qwenInstallationMessage: String?
    @Published private(set) var isSummarizerInstalled = false
    @Published private(set) var isInstallingSummarizer = false
    @Published private(set) var summarizerInstallationMessage: String?
    /// The meeting currently being corrected by the local model, or nil. Scoped to an ID (not a
    /// global Bool) so another meeting's view never shows this run as its own (F173, mirroring
    /// F156's `secondOpinionRunningID`).
    @Published private(set) var proposingCorrectionsID: UUID?

    /// Whether any correction run is active — the "don't start a second run" convenience.
    var isProposingCorrections: Bool { proposingCorrectionsID != nil }
    @Published private(set) var recordingPreflight = RecordingPreflightStatus.checking
    @Published private(set) var recordingHealth: RecordingHealthSnapshot?
    /// Which at-risk problems this recording has already announced (F294). Reset per recording.
    private var riskAnnouncer = RecordingRiskAnnouncer()
    @Published private(set) var isImporting = false
    @Published var selectedEngine: MeetingTranscriptionEngine {
        didSet { defaults.set(selectedEngine.rawValue, forKey: Self.modelKey) }
    }
    @Published var selectedLanguage: WhisperLanguage {
        didSet { defaults.set(selectedLanguage.rawValue, forKey: Self.languageKey) }
    }
    /// The summarization engine. `.local` (on-device, keyless) is the default; `.claude` is opt-in
    /// cloud (F164). Persisted like `selectedEngine`.
    @Published var summarizationEngine: SummarizationEngine {
        didSet { defaults.set(summarizationEngine.rawValue, forKey: Self.summarizationEngineKey) }
    }
    /// The single in-window alert surface. **Set through `report(_:)`, not directly** (F257).
    ///
    /// The `.alert` host lives in `ContentView` inside the `WindowGroup`, so with the window closed
    /// — a normal state while recording from the menu bar — assigning this shows nobody anything.
    /// Every existing assignment stays valid for the windowed case; `report` adds the other one.
    @Published var alertMessage: String?

    /// Holds the `storageErrorMessage` subscription for the app's lifetime (F257).
    private var storageErrorObserver: AnyCancellable?

    /// Tells the user something, wherever they can be reached (F257).
    ///
    /// With a window, this is the alert it always was. Without one, it also posts a notification —
    /// because the messages that arrive in this channel are the recovery and storage failures
    /// `PRODUCT_SPEC.md` promises to "surface in plain language", and a promise kept only while a
    /// window happens to be open is not kept.
    ///
    /// `alertMessage` is set either way, so a user who opens the window afterwards still sees it.
    /// The notification is an addition, never a replacement — dropping the alert when windowless
    /// would trade one silent path for another.
    func report(_ message: String) {
        alertMessage = message
        postWindowlessAlert(message)
    }

    /// Mirrors the store's write failures into the windowless channel (F257).
    ///
    /// `storageErrorMessage` lives on `MeetingStore` and is rendered by the same `.alert` host, so
    /// it was invisible in exactly the same state — and it is the "changes could not be saved"
    /// message, which is the one a user most needs while recording from the menu bar.
    ///
    /// Observed here rather than posted by the store: the store is a data layer and has no business
    /// knowing about `NSApp` or Notification Centre. It reports; this decides how to reach someone.
    /// Combine rather than a callback because `storageErrorMessage` is `private(set)` and set from a
    /// dozen places, so a callback would need threading through every one of them.
    func observeStorageErrors() {
        guard storageErrorObserver == nil else { return }
        storageErrorObserver = store.$storageErrorMessage
            .compactMap { $0 }
            .removeDuplicates()
            .sink { [weak self] message in
                MainActor.assumeIsolated { self?.postWindowlessAlert(message) }
            }
    }

    /// Posts `message` as a notification when there is no window to show it in (F257).
    private func postWindowlessAlert(_ message: String) {
        // `NSApp` is nil in a headless test process, the same reason
        // `postTranscriptionNotification` binds rather than force-unwraps. A test asserting `report`
        // cannot and should not post to the user's Notification Centre.
        guard let app = NSApp else { return }
        let hasVisibleWindow = app.windows.contains {
            WindowlessAlert.isReadable(
                isVisible: $0.isVisible, canBecomeMain: $0.canBecomeMain,
                isMiniaturized: $0.isMiniaturized, isOnActiveSpace: $0.isOnActiveSpace
            )
        }
        guard WindowlessAlert.shouldPost(hasVisibleWindow: hasVisibleWindow, message: message) else {
            return
        }
        let content = WindowlessAlert.content(for: message)
        Self.deliverNotification(title: content.title, body: content.body)
    }

    /// Posts one user-facing notification, sequencing the post **after** the authorization result.
    ///
    /// F294. Both callers used to do this:
    ///
    /// ```swift
    /// center.requestAuthorization(options: [.alert, .sound]) { _, _ in }
    /// center.add(UNNotificationRequest(...))          // immediately, not in the completion
    /// ```
    ///
    /// `requestAuthorization` is asynchronous. On a first run the `add` is therefore evaluated while
    /// the user is still looking at the system prompt, against settings that are not yet
    /// authorized — so the post is not sequenced after their decision, and the notification most
    /// likely to be lost is the **first** one. For `postWindowlessAlert` that is precisely the
    /// notice F257 exists to deliver: the one telling a user with no window open that something
    /// went wrong.
    ///
    /// Adding inside the completion is correct for every case: an already-authorized user's
    /// callback returns immediately, a first-time grant now delivers, and a denial skips an `add`
    /// that would have been dropped anyway.
    ///
    /// **There is no unit test for this, and there cannot be one here.** It is two
    /// `UNUserNotificationCenter` calls behind a `guard let app = NSApp`, which is nil in a
    /// headless test process — the same boundary F257 closed `partial` over, where "the delegate
    /// fires without a window is AppKit's contract, taken on trust". What *is* tested is the
    /// decision: `WindowlessAlert.shouldPost` and `.content`. The physical confirmation is the run
    /// already waiting in `NEEDS_HUMAN.md`, and this fix is what makes that run meaningful — it
    /// could otherwise have failed for a reason unrelated to what it was testing.
    private static func deliverNotification(title: String, body: String) {
        UNUserNotificationCenter.current()
            .requestAuthorization(options: [.alert, .sound]) { granted, _ in
                guard granted else { return }
                let notification = UNMutableNotificationContent()
                notification.title = title
                notification.body = body
                // `current()` again rather than a captured `center`: the completion handler is
                // `@Sendable` and `UNUserNotificationCenter` is not `Sendable`, so capturing it is
                // an error under `-warnings-as-errors`. Only the release build says so — the debug
                // build and the whole test suite passed with the capture in place, which is why the
                // gate's step 4 exists and `swift test` is not a substitute for it.
                UNUserNotificationCenter.current().add(
                    UNNotificationRequest(
                        identifier: UUID().uuidString, content: notification, trigger: nil
                    )
                )
            }
    }

    /// Presents the Keyboard Shortcuts reference sheet, toggled by the ⌘/ command (F85).
    @Published var showsShortcutsSheet = false

    /// A request to open a meeting (and optionally seek it) from another view — the "Ask Meetings"
    /// cited results (F180). It lives on the model, not on a view, because the detail view is recreated
    /// per selection (`.id(meetingID)`), so a view-local seek would be wiped by the navigation itself.
    /// `ContentView` drives the sidebar selection from it; `TranscriptDetailView` consumes the seek on
    /// appear and clears it.
    struct MeetingNavigationRequest: Equatable {
        let meetingID: UUID
        let seek: Double?
    }
    @Published var pendingNavigation: MeetingNavigationRequest?

    // MARK: - Link import (F183)

    /// Live download progress for the link-import sheet. Nil when no download is running.
    @Published var mediaDownloadProgress: MediaDownloadProgress?
    /// A probed link whose duration is above `longMediaDurationThreshold`, awaiting explicit
    /// confirmation. Never a hard cap — a legitimate 4-hour conference recording stays possible.
    @Published var pendingLongMediaConfirmation: MediaProbe?
    /// Retained index generations offered for review while a recovery decision is pending (F193),
    /// newest first. Non-nil only between `requestLibraryRecovery()` and the user acting on it,
    /// which is what makes recovery explicit: the ticket requires it "never run automatically", so
    /// the offer and the act are two separate calls. Deliberately the same shape as
    /// `pendingLongMediaConfirmation` above, so this model has one confirmation idiom, not two.
    @Published var pendingLibraryRecovery: [RetainedGeneration]?
    /// A folder rebuild awaiting the user's review (F289). Offered by `requestLibraryRecovery` when
    /// a read-only library has no retained generation to restore — F252's dead end — and applied
    /// only by `rebuildLibraryFromFolders(confirmed: true)`.
    @Published var pendingFolderRebuild: FolderRebuild.Proposal?
    /// The reviewed rebuild offer awaiting the user's answer (F267). Nil when none is pending.
    @Published var pendingSourceRebuild: SourceRebuildRequest?
    /// Whether the user has opted into the link-import feature. Off by default: every other
    /// boundary-crossing capability in this app is opt-in (Qwen, Claude summaries), so the network
    /// path is explicit rather than ambient.
    @Published var linkImportEnabled: Bool {
        didSet { defaults.set(linkImportEnabled, forKey: Self.linkImportEnabledKey) }
    }
    static let linkImportEnabledKey = "linkImportEnabled"

    /// Above this, a link download asks for explicit confirmation before starting.
    static let longMediaDurationThreshold: TimeInterval = 2 * 3_600

    /// Whether the yt-dlp downloader is present (it ships inside the Whisper runtime venv).
    var isDownloaderInstalled: Bool { MediaDownloadRuntime.findExecutable() != nil }
    @Published private(set) var isUpdatingDownloader = false
    @Published private(set) var downloaderUpdateMessage: String?

    /// Refreshes just the downloader, backing the "the downloader is out of date" failure guidance —
    /// sites change how they serve media, so this goes stale on a scale of weeks (F183).
    func updateDownloader() {
        guard !isUpdatingDownloader else { return }
        guard let script = Bundle.main.url(forResource: "update-yt-dlp", withExtension: "sh")
            ?? Self.developmentScriptURL("update-yt-dlp.sh") else {
            alertMessage = "The downloader updater is missing from this build."
            return
        }
        isUpdatingDownloader = true
        downloaderUpdateMessage = nil
        Task {
            let runner = ProcessGroupRunner()
            let outcome = try? await runner.run(
                executableURL: URL(fileURLWithPath: "/bin/zsh"),
                arguments: [script.path],
                environment: MediaDownloadClient.makeEnvironment(),
                stallTimeout: 600
            )
            isUpdatingDownloader = false
            if let outcome, outcome.exitStatus == 0 {
                downloaderUpdateMessage = "The downloader is up to date."
            } else {
                downloaderUpdateMessage = "The downloader could not be updated. \(String((outcome?.output ?? "").suffix(200)))"
            }
        }
    }

    /// Locates a bundled script when running from a built `.app`, falling back to the checkout while
    /// developing (the packaged path is the one that matters; see build-app.sh).
    ///
    /// `nonisolated` because it reads nothing but the filesystem, and the speaker-analysis reclaim
    /// resolves its script off the main actor (F219). Main-actor callers are unaffected.
    nonisolated static func developmentScriptURL(_ name: String) -> URL? {
        let candidate = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // WhisperMeet/
            .deletingLastPathComponent()   // Sources/
            .deletingLastPathComponent()   // repo root
            .appendingPathComponent("Scripts/\(name)")
        return FileManager.default.fileExists(atPath: candidate.path) ? candidate : nil
    }

    /// Probes a link for its metadata. Injected so the flow is testable without the real downloader.
    var probeMediaURL: @Sendable (String) async throws -> MediaProbe = { url in
        try await MediaDownloadClient.installed().probe(url: url)
    }

    /// Downloads a link's audio into a directory, returning the written file. Injected for tests.
    var downloadMedia: @Sendable (String, URL, @Sendable @escaping (MediaDownloadProgress) -> Void) async throws -> URL = {
        url, directory, progress in
        try await MediaDownloadClient.installed().download(url: url, into: directory, progress: progress)
    }

    /// Best-effort captions for a link, as reference segments. Never throws — a caption failure must
    /// never fail the import. Injected for tests.
    var downloadCaptions: @Sendable (String, URL, String) async -> [TranscriptSegment] = {
        url, directory, subLangs in
        guard let client = try? MediaDownloadClient.installed() else { return [] }
        return await client.captions(url: url, into: directory, subLangs: subLangs)
    }

    let store: MeetingStore
    let recordingMeter = RecordingMeterViewModel()
    /// Internal rather than private so `CaptureRestartWiringTests` can kill the stream the way a
    /// lost display does, without a display to lose (F275).
    let recorder: AudioCaptureEngine
    private var preflightRecorder: AudioCaptureEngine?
    private var preflightDirectory: URL?
    private var preflightTask: Task<Void, Never>?
    private static let preflightDurationSeconds = 8
    private let defaults: UserDefaults
    private var transcriptionTasks: [UUID: Task<Void, Never>] = [:]
    private var transcriptionSettings = TranscriptionSelectionStore()
    private var summarizationTasks: [UUID: Task<Void, Never>] = [:]
    private var didPerformStartupRecovery = false
    /// The live capture's claim on its own folder (F297): an exclusive `flock` on `capture.lock`,
    /// held from the moment the folder exists until the recording is indexed or discarded. A
    /// second instance's startup sweep asks the kernel whether this is held, and that — not the
    /// library-wide lease — is how it tells a recording in progress from one that crashed.
    /// Advisory: nil when the lock could not be taken, and recording proceeds regardless.
    private var captureLock: RecordingCaptureLock.Handle?
    private var isDictationActive: () -> Bool = { false }
    /// AppEntry wires this to `DictationController.releaseIdleModelsForMeetingTranscription`.
    /// Kept as a headless seam so tests can prove the release completes before an engine starts.
    var releaseIdleDictationModels: @Sendable () async -> Void = {}
    /// Once all meeting ASR work has ended, AppEntry uses this to rewarm only the dictation
    /// recognizer. The optional refiner stays evicted so the next hotkey stays responsive.
    var warmIdleDictationRecognition: () -> Void = {}

    private static let modelKey = "localWhisperModel"
    private static let languageKey = "localWhisperLanguage"
    private static let claudeAPIKeyAccount = "claudeAPIKey"
    private static let summarizationEngineKey = "summarizationEngine"

    convenience init() {
        self.init(
            store: MeetingStore(),
            recorder: AudioCaptureEngine(),
            defaults: .standard
        )
    }

    /// `whisperExecutable` and `qwenInstalled` are injected so the engine/runtime reconciliation
    /// below is testable (F262). They cannot come from the `findWhisperExecutable` stored property:
    /// reading it touches `self`, which is illegal until `selectedEngine` has a value — and the
    /// value of `selectedEngine` is exactly what depends on them.
    init(
        store: MeetingStore,
        recorder: AudioCaptureEngine,
        defaults: UserDefaults,
        whisperExecutable: @escaping @Sendable () -> URL? = { LocalWhisperRuntime.findExecutable() },
        qwenInstalled: @escaping @Sendable () -> Bool = { QwenASRRuntime.isInstalled() }
    ) {
        self.store = store
        self.recorder = recorder
        self.defaults = defaults
        // Adopt the injected probes as the seams, so `refreshRuntime()` keeps using them instead of
        // re-reading the real filesystem and discarding whatever was pinned here (F262).
        self.findWhisperExecutable = whisperExecutable
        self.checkQwenInstalled = qwenInstalled
        let storedEngine = MeetingTranscriptionEngine(
            rawValue: defaults.string(forKey: Self.modelKey) ?? ""
        )
        // F262: a missing preference is not a choice, so default to an engine that is actually
        // installed rather than to Whisper Large unconditionally — which left a Qwen-only Mac with a
        // selection it could never satisfy, and no way to notice but the Settings picker. A stored
        // choice is preserved even when uninstalled; `transcriptionUnavailableMessage` handles that,
        // because this initial assignment does not fire `selectedEngine`'s persisting `didSet`,
        // while a silent switch later would overwrite the user's choice on disk.
        let whisperURL = whisperExecutable()
        let qwenIsInstalled = qwenInstalled()
        selectedEngine = TranscriptionEngineAvailability.initialSelection(
            stored: storedEngine,
            isWhisperInstalled: whisperURL != nil,
            isQwenInstalled: qwenIsInstalled,
            isQwenSupported: MeetingTranscriptionEngine.qwenBalanced.isSupportedOnCurrentMac
        )
        selectedLanguage = WhisperLanguage(
            rawValue: defaults.string(forKey: Self.languageKey) ?? ""
        ) ?? .automatic
        summarizationEngine = SummarizationEngine(
            rawValue: defaults.string(forKey: Self.summarizationEngineKey) ?? ""
        ) ?? .local
        // Off unless the user has explicitly turned it on (F183).
        linkImportEnabled = defaults.bool(forKey: Self.linkImportEnabledKey)
        // Reuse the probes already run above rather than hitting the filesystem twice.
        runtimeExecutableURL = whisperURL
        isQwenInstalled = qwenIsInstalled
        isSummarizerInstalled = isSummarizerModelInstalled()
        isDiarizationInstalled = isDiarizationModelInstalled()
        hasClaudeAPIKey = KeychainStore.string(for: Self.claudeAPIKeyAccount) != nil
        refreshRecordingPreflight()
    }

    var isRuntimeInstalled: Bool {
        runtimeExecutableURL != nil
    }

    var isSelectedEngineInstalled: Bool {
        selectedEngine == .qwenBalanced ? isQwenInstalled : isRuntimeInstalled
    }

    /// Why transcription cannot start, or nil when it can (F262).
    ///
    /// Replaces "Install the selected transcription model in Settings", which reads as false to a
    /// user who has just installed a model — it simply was not the selected one. This names both
    /// sides of the mismatch and points at the picker that fixes it.
    var transcriptionUnavailableMessage: String? {
        TranscriptionEngineAvailability.unavailableMessage(
            selected: selectedEngine,
            isWhisperInstalled: isRuntimeInstalled,
            isQwenInstalled: isQwenInstalled
        )
    }

    var isInstallingRecognitionRuntime: Bool {
        isInstallingRuntime || isInstallingQwenRuntime
    }

    /// Whether ANY model install is in flight. Every installer's own admission guard asks this one
    /// question (F228).
    ///
    /// The narrower `isInstallingRecognitionRuntime` above still exists because the transcription
    /// and recording paths genuinely only care about Whisper and Qwen — a summarizer download must
    /// not block a recording. Installers are different: two of them at once compete for network and
    /// disk, and both call `refreshRuntime()` when they finish, so the slower one reports its result
    /// against state the faster one has already replaced.
    ///
    /// One property rather than a clause added to each guard, because the asymmetry this replaced
    /// was built exactly that way: `installSpeakerDiarization` listed all four flags while
    /// `installLocalWhisper` and `installQwenASR` listed only the recognition pair, so neither of
    /// them refused during a speaker-analysis install — or, unnoticed when this was filed, during a
    /// summarizer install either. A flag added here in future is wrong in one place, not four.
    var isInstallingAnyRuntime: Bool {
        isInstallingRecognitionRuntime || isInstallingSummarizer || isInstallingDiarizationRuntime
    }

    /// Wires the reverse of dictation's own meeting-active guard: lets `startRecording()` refuse to
    /// start while dictation currently owns the microphone. See `AppEntry`'s `.task` for the call site.
    func configureDictationGuard(_ isActive: @escaping () -> Bool) {
        isDictationActive = isActive
    }

    /// Lets a meeting ASR pass release inactive Quick Dictation helpers before it claims unified
    /// memory. This is intentionally separate from `configureDictationGuard`: the latter answers
    /// whether dictation owns the microphone; this one handles idle resident models.
    func configureIdleDictationModelRelease(_ release: @escaping @Sendable () async -> Void) {
        releaseIdleDictationModels = release
    }

    func configureIdleDictationRecognitionWarmUp(_ warm: @escaping () -> Void) {
        warmIdleDictationRecognition = warm
    }

    var isRecordingActive: Bool {
        switch recordingState {
        case .idle: return false
        default: return true
        }
    }

    var isPreflightTestActive: Bool {
        switch preflightTest {
        case .idle: return false
        default: return true
        }
    }

    /// True while any capture path owns the microphone — a meeting recording, an active preflight
    /// phase, OR a preflight engine still tearing down after Cancel. That last case matters because
    /// `teardownPreflight()` publishes `.idle` immediately, but the `SCStream` isn't released until
    /// the cancelled task's `engine.cancel()` finishes; guarding only on the published phase would
    /// let a new capture (meeting, another test, or dictation) start on top of a still-closing
    /// stream. All capture-start guards and the dictation hotkey consult this.
    var isMicrophoneBusy: Bool {
        isRecordingActive || isPreflightTestActive || preflightRecorder != nil
    }

    var isSummarizing: Bool {
        activeSummarizationID != nil
    }

    func setClaudeAPIKey(_ key: String?) {
        KeychainStore.set(key, for: Self.claudeAPIKeyAccount)
        hasClaudeAPIKey = KeychainStore.string(for: Self.claudeAPIKeyAccount) != nil
    }


    var hasActiveTranscription: Bool {
        transcription.activeID != nil
    }

    func isQueuedForTranscription(_ id: UUID) -> Bool {
        transcription.isPending(id)
    }

    func refreshRuntime() {
        runtimeExecutableURL = findWhisperExecutable()
        isQwenInstalled = checkQwenInstalled()
        isSummarizerInstalled = isSummarizerModelInstalled()
        isDiarizationInstalled = isDiarizationModelInstalled()
    }

    func refreshRecordingPreflight() {
        recordingPreflight = .inspect(storageDirectory: store.rootDirectory)
    }

    /// Whether a library-changing action may proceed, explaining the refusal through `alertMessage`
    /// — the channel these entry points already use. Mirrors `MeetingStore.mutationIsAllowed()`, which
    /// covers the write itself; this covers the work that leads up to one (F187).
    ///
    /// Callers MUST invoke this BEFORE doing that work. Import copies the media file into the library
    /// and transcription runs a speech model for minutes, and each only then reaches a `store.upsert`
    /// or `store.update` that a degraded store silently refuses — so without this the user waits out
    /// the whole job, is told nothing, and in the import case is left with audio sitting in the
    /// library that nothing will ever index.
    private func libraryAcceptsChanges(_ action: String) -> Bool {
        guard store.isDegraded else { return true }
        alertMessage = ReadOnlyLibraryNotice.actionRefused(action)
        return false
    }

    /// Rebuilds one interrupted recording folder from its raw tracks. Injectable so both callers
    /// are testable — startup recovery's per-orphan resilience (F47) and the failed-stop path that
    /// rebuilds this instance's own folder (F256) — and defaults to the real rebuild.
    var recoverInterruptedRecording: @Sendable (URL) throws -> RecoveredRecording? = {
        try InterruptedRecordingRecovery.recover(in: $0)
    }

    /// Runs the read-only integrity check for one meeting's on-disk audio. Injectable so the library
    /// sweep is testable with a fake finding, mirroring F47's recover seam; defaults to the real
    /// checker. Never opens, deletes, or rewrites audio (F83 wires the F66 core).
    var checkMeetingIntegrity: @Sendable (MeetingIntegrityDescriptor) -> [IntegrityFinding] = {
        MeetingIntegrityChecker.check($0)
    }

    /// Runs the Qwen installer's recovery-only reclaim over a runtime directory (restores an orphaned
    /// complete backup, removes abandoned artifacts). Injectable so the startup wiring is testable
    /// without spawning a real process; defaults to invoking the bundled `setup-qwen-asr.sh` with
    /// `QWEN_INSTALL_RECOVERY_ONLY=1` — the tested F33 core. Returns the reclaim's exit status.
    var runQwenInstallRecovery: @Sendable (URL) async -> Int32 = { runtimeDirectory in
        await AppModel.spawnQwenInstallRecovery(runtimeDirectory: runtimeDirectory)
    }

    /// The same for the local-summarizer runtime (F167). `setup-local-summarizer.sh` already
    /// reclaims orphaned `.Summarizer-backup-*` / `.Summarizer-install-*` artifacts, but only when
    /// the user next opens the installer — so after a crash mid-install the previous model could sit
    /// in a hidden backup with `Summarizer/` gone, reporting "not installed", indefinitely. Qwen
    /// (F33) and speaker analysis (F219) both got a launch reclaim; this completes the set.
    var runSummarizerInstallRecovery: @Sendable (URL) async -> Int32 = { runtimeDirectory in
        await AppModel.spawnSummarizerInstallRecovery(runtimeDirectory: runtimeDirectory)
    }

    /// Builds the summarizer for the selected engine. Injectable so the engine-selection + style
    /// wiring is testable without a network call or a local model; defaults to the real engines —
    /// the keyless on-device `LocalSummarizer` for `.local`, `ClaudeSummarizer` for `.claude`
    /// (F164 extends the F81 seam).
    var makeSummarizer: @Sendable (SummarizationEngine, String) -> MeetingSummarizer = { engine, apiKey in
        switch engine {
        case .local: return LocalSummarizer()
        case .claude: return ClaudeSummarizer(apiKey: apiKey)
        }
    }

    /// Whether the on-device summarization model is installed. Injectable so the install-required
    /// guard and the Settings state are testable without a real runtime; defaults to the real check
    /// (F164). Mirrors the `isQwenInstalled` predicate but behind a seam for headless wiring tests.
    var isSummarizerModelInstalled: @Sendable () -> Bool = { SummarizerRuntime.isInstalled() }

    /// Proposes transcript corrections with the on-device model (F165). Injectable so the correction
    /// wiring is testable without a real model; defaults to the real `LocalTranscriptCorrector`.
    var proposeTranscriptCorrections: @Sendable (
        _ transcript: String, _ vocabulary: [String], _ reference: String?
    ) async throws -> [TranscriptCorrection] = { transcript, vocabulary, reference in
        try await LocalTranscriptCorrector().correct(
            transcript: transcript, vocabulary: vocabulary, reference: reference
        )
    }

    /// Whether the on-device correction helper (`correct_local.py`) is installed alongside the model
    /// (F165). Injectable for headless tests; defaults to the real check.
    var isCorrectionModelInstalled: @Sendable () -> Bool = { SummarizerRuntime.isCorrectionHelperInstalled() }

    /// Whether the pinned speaker-analysis runtime is installed (F219). Injectable so the admission
    /// guard is testable without the real runtime, mirroring `isSummarizerModelInstalled`.
    ///
    /// It probes the FluidAudio Core ML bundles the runtime now loads, not the sherpa-onnx tree
    /// (F216): a machine carrying the old ONNX payload cannot run this analyzer, so reporting it as
    /// installed would enable a menu entry whose first run fails on missing models.
    var isDiarizationModelInstalled: @Sendable () -> Bool = { FluidAudioDiarizationRuntime.isInstalled() }

    /// Where the pinned speaker-analysis runtime lives. Held as a property rather than called at each
    /// use site so a test can point the install and the launch reclaim at a temp directory; without
    /// it both would work over the user's real `Runtime/Diarization` (F219).
    var diarizationRuntimeDirectory: URL = DiarizationRuntime.managedDirectory()

    /// Runs the bundled `setup-speaker-diarization.sh` over a runtime directory. Injectable so the
    /// install wiring is testable without a 60 MB download or a spawned process; defaults to the real
    /// runner, which mirrors `runQwenInstaller` (F219).
    var runDiarizationInstaller: @Sendable (
        _ scriptURL: URL, _ runtimeDirectory: URL
    ) async throws -> Void = { scriptURL, runtimeDirectory in
        try await AppModel.spawnDiarizationInstaller(
            scriptURL: scriptURL, runtimeDirectory: runtimeDirectory
        )
    }

    /// Runs the speaker-analysis installer's recovery-only reclaim over a runtime directory (restores
    /// an orphaned complete backup, removes abandoned artifacts). Injectable so the startup wiring is
    /// testable without spawning a real process; defaults to invoking the bundled script with
    /// `DIARIZATION_INSTALL_RECOVERY_ONLY=1` — the same arrangement F33 established for Qwen. Returns
    /// the reclaim's exit status.
    var runDiarizationInstallRecovery: @Sendable (URL) async -> Int32 = { runtimeDirectory in
        await AppModel.spawnDiarizationInstallRecovery(runtimeDirectory: runtimeDirectory)
    }

    /// Locates the installed local-Whisper executable. Injectable so a headless test can put the app
    /// into the "a transcription is running" state: `beginTranscription` refuses without an installed
    /// engine and re-probes the filesystem itself, which left every "refuse while transcribing" guard
    /// unreachable from a test (F219). Defaults to the real probe, so behaviour is unchanged.
    var findWhisperExecutable: @Sendable () -> URL? = { LocalWhisperRuntime.findExecutable() }
    /// The Qwen install probe, as a seam for the same reason `findWhisperExecutable` is one (F262).
    ///
    /// `refreshRuntime()` must go through both seams, not just this one's Whisper sibling. Until it
    /// did, an install state injected at construction was silently discarded by the first
    /// `refreshRuntime()` — which `stopRecording` and `importRecording` each call immediately before
    /// their install gate. That made a pinned test state useless and was invisible on a machine with
    /// the runtimes present; CI caught it.
    var checkQwenInstalled: @Sendable () -> Bool = { QwenASRRuntime.isInstalled() }

    /// Runs a transcription engine on a WAV and returns the result WITHOUT persisting. Injectable so the
    /// second-opinion (F88) and per-segment re-run (F92) flows are testable with a stub engine; when nil,
    /// `executeEngine` performs the real Qwen/Whisper dispatch.
    var runTranscriptionEngineOverride: ((MeetingTranscriptionSelection, URL) async throws -> TranscriptionResult)?

    /// Spans of the most recent cross-engine "second opinion", for the review sheet (F88).
    @Published var secondOpinionSpans: [TranscriptComparisonSpan]?
    /// True when the most recent second-opinion run failed to produce a comparison — so the sheet can
    /// show an error instead of rendering nil spans as "no differences" (F142).
    @Published var secondOpinionFailed = false
    /// The meeting whose second opinion is currently running, so ONLY that meeting's button shows a
    /// spinner (not every meeting's, which the global flag caused). nil when idle (F88 UX).
    @Published private(set) var secondOpinionRunningID: UUID?
    /// Live progress of the in-flight second-opinion engine run, so the sheet can show a determinate bar
    /// instead of a featureless spinner (F88 UX).
    @Published private(set) var secondOpinionProgress: LocalTranscriptionProgress?
    /// The engine being run for the second opinion, for the progress label (F88 UX).
    @Published private(set) var secondOpinionEngine: MeetingTranscriptionEngine?
    /// True while a second-opinion or segment re-run engine pass is in flight (F88/F92).
    @Published private(set) var isRunningAuxiliaryEngine = false

    /// The meeting whose speaker analysis is running, or nil. Scoped to an id — never a global Bool —
    /// so another meeting's view never shows this run as its own (F156/F173's lesson, F219).
    @Published private(set) var diarizationRunningID: UUID?
    /// Fraction complete (0...1) of the in-flight analysis, so the sheet shows a determinate bar
    /// instead of a featureless spinner. nil when idle.
    @Published private(set) var diarizationProgress: Double?
    /// True while the speaker-analysis installer owns the machine. Set by the installer wiring; read
    /// here so analysis never starts on top of a half-installed runtime (F219).
    @Published private(set) var isInstallingDiarizationRuntime = false
    /// Whether the pinned speaker-analysis runtime is on disk, refreshed alongside the other runtimes
    /// so Settings can offer Install / Repair (F219).
    @Published private(set) var isDiarizationInstalled = false
    /// The install row's plain-language status line — what is happening, or what happened. Mirrors
    /// `qwenInstallationMessage`; nil until an install is attempted (F219).
    @Published private(set) var diarizationInstallationMessage: String?
    /// Bumped whenever a meeting's stored speaker analysis changes. `PlayableTranscriptView` watches
    /// it to rebuild its precomputed label map; nothing else reads it (F220).
    @Published private(set) var speakerOverlayRevision = 0
    /// The in-flight analysis, held so `cancelSpeakerDiarization()` can stop it.
    private var diarizationTask: Task<Void, Never>?
    /// One meeting's computed overlay, keyed by the timings it was computed from. Single-entry on
    /// purpose: exactly one transcript is on screen at a time, so this bounds memory while still
    /// keeping the 4 Hz playback tick off the sidecar read and the turn/segment walk (the F160 rule).
    private var speakerOverlayCache: (meetingID: UUID, fingerprint: String, presentation: SpeakerOverlayPresentation?)?

    /// Runs the given engine selection on a recording (or clip) and returns the result without touching
    /// the store. Extracted from `performTranscription` so second-opinion/segment-rerun share one code
    /// path; the override seam lets tests substitute a stub.
    func executeEngine(
        _ selection: MeetingTranscriptionSelection,
        on url: URL,
        onProgress: @escaping @Sendable (LocalTranscriptionProgress) async -> Void = { _ in }
    ) async throws -> TranscriptionResult {
        // The systematic backstop (F187). Every heavy engine pass — full transcription, per-segment
        // re-run, second opinion — is admitted here, and nowhere else. The per-entry-point
        // `libraryAcceptsChanges` guards are what the user should normally hit, because they name the
        // action they attempted; this one exists for the entry point NOBODY REMEMBERED TO GUARD.
        // Three consecutive passes over this branch enumerated "every mutating entry point" by
        // grepping `store.upsert`/`store.update` call sites, and each missed one, because the
        // expensive work and the refused write live in different functions. So the guarantee is
        // placed where it cannot be missed by inspection: minutes of model time are never spent on a
        // library that will refuse to save the result. It sits ABOVE the override branch on purpose —
        // not even a stubbed engine runs while degraded.
        guard !store.isDegraded else { throw MeetingStoreError.engineRunIsReadOnly }
        // Entry points normally reject this sooner with a specific alert, but this central boundary
        // closes the queue/race hole for every heavy engine pass, including a direct auxiliary call.
        guard !isDictationActive() else { throw EngineAdmissionError.dictationActive }
        // A Qwen dictation helper and optional 4B/8B refiner can otherwise remain resident for five
        // minutes, materially slowing this ASR + alignment process through unified-memory pressure.
        // The configured closure waits for their children to exit before the selected engine begins.
        await releaseIdleDictationModels()
        if let override = runTranscriptionEngineOverride {
            return try await override(selection, url)
        }
        if selection.engine == .qwenBalanced {
            guard isQwenInstalled else { throw QwenASRError.runtimeNotInstalled }
            let client = QwenASRClient(
                pythonExecutableURL: QwenASRRuntime.pythonExecutable(),
                helperScriptURL: QwenASRRuntime.helperScript(),
                modelDirectory: QwenASRRuntime.modelDirectory(),
                alignerDirectory: QwenASRRuntime.alignerDirectory()
            )
            return try await client.transcribe(recordingAt: url, language: selection.language, onProgress: onProgress)
        } else {
            guard let executableURL = runtimeExecutableURL,
                  let whisperModel = selection.engine.whisperModel else {
                throw LocalWhisperError.runtimeNotInstalled
            }
            let client = LocalWhisperClient(
                executableURL: executableURL,
                modelDirectory: LocalWhisperRuntime.modelDirectory()
            )
            return try await client.transcribe(
                recordingAt: url,
                // The engine's `initial_prompt` is budgeted, so it takes the capped view — the stored
                // list is no longer trimmed to fit it (F187).
                options: .accuracyFirst(model: whisperModel, language: selection.language, keyterms: store.promptVocabulary),
                onProgress: onProgress
            )
        }
    }

    /// Kick off a second opinion (F88); guarded so it never runs alongside a transcription or another
    /// auxiliary pass. The heavy work is in `computeSecondOpinion`, which tests await directly.
    func requestSecondOpinion(id: UUID) {
        guard !hasActiveTranscription, !isRunningAuxiliaryEngine else {
            alertMessage = "Finish the current transcription before requesting a second opinion."
            return
        }
        guard !isDictationActive() else {
            alertMessage = "Finish the current Quick Dictation before requesting a second opinion."
            return
        }
        // Guarded here as well as in the worker, so the refusal is one immediate message rather than
        // one raised from inside a detached task after the engine flag was already claimed (F187).
        guard libraryAcceptsChanges("Requesting a second opinion") else { return }
        secondOpinionFailed = false
        secondOpinionSpans = nil
        secondOpinionProgress = nil
        secondOpinionRunningID = id
        isRunningAuxiliaryEngine = true
        Task {
            await computeSecondOpinion(id: id)
            secondOpinionRunningID = nil
            secondOpinionProgress = nil
            secondOpinionEngine = nil
            isRunningAuxiliaryEngine = false
            if !hasActiveTranscription { warmIdleDictationRecognition() }
        }
    }

    /// Runs the non-selected engine on the meeting's recording and stores the comparison spans. Never
    /// overwrites the stored transcript — only `applySecondOpinionSpan` does, on explicit user action.
    func computeSecondOpinion(id: UUID) async {
        // A second opinion is the single most expensive thing the app does — a whole second ASR pass
        // over the entire recording — and its ONLY product, `secondOpinionSpans`, can be consumed
        // solely through `applySecondOpinionSpan`, whose `store.update` a degraded store refuses. So
        // without this the user waits out a full re-transcription, reviews the divergences, and every
        // Replace click silently does nothing (F187).
        guard libraryAcceptsChanges("Requesting a second opinion") else { return }
        guard let meeting = store.meeting(id: id), meeting.status == .completed, !meeting.segments.isEmpty else { return }
        secondOpinionFailed = false
        // Run the genuine OTHER engine relative to the engine that produced this transcript (recorded on
        // the meeting), not current Settings — otherwise a Settings change could re-run the same engine (F142).
        let producedBy = meeting.transcriptionEngine ?? selectedEngine
        let other: MeetingTranscriptionEngine = producedBy == .qwenBalanced ? .whisperLarge : .qwenBalanced
        secondOpinionEngine = other
        let selection = MeetingTranscriptionSelection(engine: other, language: selectedLanguage)
        do {
            // Surface the other engine's live progress so the sheet shows real feedback, not a bare
            // spinner, while it re-transcribes (F88 UX).
            let result = try await executeEngine(selection, on: store.recordingURL(for: meeting)) { progress in
                await self.apply(secondOpinionProgress: progress)
            }
            secondOpinionSpans = TranscriptComparison.compare(meeting.segments, result.segments)
        } catch {
            secondOpinionFailed = true
            alertMessage = error.localizedDescription
        }
    }

    /// Publishes the second-opinion engine's live progress for the sheet (F88 UX).
    func apply(secondOpinionProgress progress: LocalTranscriptionProgress) {
        secondOpinionProgress = progress
    }

    /// Replace one diverging segment's text with the other engine's reading (F88), on explicit apply.
    func applySecondOpinionSpan(_ span: TranscriptComparisonSpan, to id: UUID) {
        guard let secondary = span.secondaryText else { return }
        store.update(id: id) { meeting in
            guard let index = meeting.segments.firstIndex(where: { $0.start == span.start && $0.text == span.primaryText }) else { return }
            meeting.segments[index].text = secondary
            meeting.transcriptText = TranscriptFormatter.timestamped(meeting.segments)
        }
    }

    // MARK: - Speaker analysis (F219)

    /// Runs anonymous speaker analysis over one prepared copy of a recording, reporting progress as a
    /// fraction. Injectable so the whole wiring — guards, cancellation, the sidecar, the overlay — is
    /// testable without the pinned runtime or real audio, in the F47 seam style.
    ///
    /// The default prepares 16 kHz mono audio into a per-run temp DIRECTORY that is removed on the way
    /// out, then runs `FluidAudioDiarizationClient`. `request.audioURL` is only ever READ: the
    /// canonical recording is never transcoded in place, moved, or rewritten.
    var runSpeakerDiarization: @Sendable (
        SpeakerDiarizationRequest, @Sendable @escaping (Double) async -> Void
    ) async throws -> SpeakerDiarizationResult = { request, progress in
        // A directory rather than a bare temp file, matching QwenASRClient's decode-first working
        // directory (F118): cleanup is then one `removeItem` that cannot strand a sibling afconvert
        // may have left behind, and it runs on every exit path including a throw.
        let workspace = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperMeet-Diarization-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: workspace, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: workspace) }

        // A meeting is captured at 48 kHz mono, so this normally converts; a recording already at
        // 16 kHz mono is analyzed where it lies, read-only.
        var analysisURL = request.audioURL
        if AudioTranscoder.needsTranscoding(request.audioURL) {
            let prepared = workspace.appendingPathComponent("analysis.wav")
            try AudioTranscoder.transcodeToWAV(input: request.audioURL, output: prepared)
            analysisURL = prepared
        }
        try Task.checkCancellation()

        // FluidAudio's in-process Core ML runtime, which replaced the sherpa-onnx subprocess
        // (F216). The subprocess client and its stdout-grammar parser were deleted with the runtime
        // they spoke to; only `SpeakerTurns.densify` survived, because the first-appearance remap is
        // not a property of any one runtime (F216/F219).
        let client = FluidAudioDiarizationClient()
        return try await client.diarize(
            audioURL: analysisURL,
            durationSeconds: AppModel.analysisSeconds(of: analysisURL, fallback: request.durationSeconds),
            progress: progress
        )
    }

    /// The pinned stack this build analyzes with, recorded on every artifact so a result produced by a
    /// different runtime or model is recognizable later — which is exactly what the move from
    /// sherpa-onnx to FluidAudio makes necessary (F216). Re-hashing the models on every run to
    /// re-derive a value the install gates on would buy nothing.
    ///
    /// The two hashes are the `weights/weight.bin` of `Segmentation.mlmodelc` and
    /// `Embedding.mlmodelc` — the model parameters themselves, the only part of a compiled Core ML
    /// bundle whose bytes are the model rather than its packaging — as published by
    /// `FluidInference/speaker-diarization-coreml` and staged during the F216 evaluation. The
    /// installer gates on the same two files when the Core ML payload replaces the ONNX tree (F219).
    private static let diarizationProducer = DiarizationProducer(
        runtimeID: FluidAudioDiarizationRuntime.runtimeID,
        runtimeVersion: FluidAudioDiarizationRuntime.runtimeVersion,
        segmentationModelSHA256: "c3189a64946c75bc24fcb98afe89ad78c52bdbadfdf65e857fb1b81e2cc9fbb2",
        embeddingModelSHA256: "99356b2985b8d43880a657024d941d450b38820451ccff903f76ed4e52d1868b",
        clusterThreshold: FluidAudioDiarizationRuntime.clusterThreshold
    )

    /// The canonical recording file names capture and interrupted-recording recovery write. An
    /// imported or downloaded file keeps its own name, which is what makes this a reliable test for
    /// "recorded natively in WhisperMeet".
    private static let nativeRecordingFileNames: Set<String> = ["meeting.wav", "meeting-recovered.wav"]

    /// Why the "Analyze Speaker Turns…" entry cannot run for this meeting right now, or nil when it
    /// can. The menu disables itself on this and prints `SpeakerAnalysisCopy.footnote(for:)` beneath
    /// the divider, so a greyed-out row always says why (F220).
    ///
    /// The order is what a person can act on, NOT the order `requestSpeakerDiarization` checks in.
    /// Facts about this meeting never change, so they are said first; an install is a one-time
    /// action; the busy states clear on their own and are said last. Those guards remain the
    /// authority — this decides only what the menu shows, and every refusal is re-made there with an
    /// alert naming the action attempted.
    func speakerAnalysisUnavailability(for meeting: MeetingRecord) -> SpeakerAnalysisUnavailability? {
        if meeting.status != .completed || !isNativeRecording(meeting) { return .unsupportedRecording }
        if !hasUsableTimings(meeting) { return .noTimestamps }
        // Said before the model check: installing 21.6 MB to reach a library that cannot save the
        // result is a download spent for nothing (the F187 rule, applied to the entry point).
        if store.isDegraded { return .libraryReadOnly }
        if isInstallingDiarizationRuntime { return .installing }
        // The PUBLISHED flag, not the `isDiarizationModelInstalled` probe: this is read on every
        // render of the transcript detail view, and that probe stats 21 model files. `refreshRuntime`
        // maintains the flag at launch and after an install; `requestSpeakerDiarization` re-probes the
        // disk for real, so a model deleted behind the app's back still fails honestly there rather
        // than being missed here (the F160 rule — no filesystem work inside a view body).
        if !isDiarizationInstalled { return .modelNotInstalled }
        if diarizationRunningID != nil { return .analyzing }
        if hasActiveTranscription || isRunningAuxiliaryEngine || isDictationActive()
            || isInstallingRecognitionRuntime || isMicrophoneBusy || isImporting {
            return .busy
        }
        return nil
    }

    /// The payload for the Export menu's labeled action, or nil when there is nothing to label —
    /// no analysis, a stale one, or a single distinguished voice. The menu shows the action only
    /// when this is non-nil, so "export with speaker labels" is never offered over a file that would
    /// come out identical to the ordinary transcript (F220).
    ///
    /// Built here rather than in the view because this is the ONE place labels are allowed to meet an
    /// export request: `speakerLabels`/`speakerRows` are read by the two labeled formats and by
    /// nothing else, and the nine standard formats render the very same request label-free
    /// (`labeledExportIsOfferedOnlyOnceAnOverlayExists` pins both halves).
    func speakerLabeledExportRequest(for id: UUID) -> TranscriptExportRequest? {
        guard let meeting = store.meeting(id: id) else { return nil }
        // `speakerOverlay` already withholds a stale result; `clusterIDs` is empty for the
        // single-cluster case, whose rows are all `.unlabeled`.
        guard let presentation = speakerOverlay(for: id), !presentation.clusterIDs.isEmpty else {
            return nil
        }
        return TranscriptExportRequest(
            title: meeting.title,
            languageCode: meeting.languageCode,
            durationSeconds: meeting.duration,
            transcriptText: meeting.transcriptText,
            segments: meeting.segments,
            markers: meeting.orderedMarkers,
            speakerLabels: presentation.aliases,
            speakerRows: presentation.rows
        )
    }

    private func isNativeRecording(_ meeting: MeetingRecord) -> Bool {
        meeting.source == nil
            && Self.nativeRecordingFileNames.contains(
                URL(fileURLWithPath: meeting.recordingPath).lastPathComponent
            )
    }

    private func hasUsableTimings(_ meeting: MeetingRecord) -> Bool {
        meeting.segments.contains { $0.start?.isFinite == true }
    }

    /// The recording length handed to the seam. `duration` is what the index recorded; a transcript
    /// that runs past it (a duration never written, or written short) would otherwise make every turn
    /// beyond it fail interval validation and throw away a whole valid result, so the last timed
    /// segment raises the floor.
    private static func analysisDurationSeconds(for meeting: MeetingRecord) -> TimeInterval {
        let transcriptEnd = meeting.segments
            .compactMap { $0.end ?? $0.start }
            .filter(\.isFinite)
            .max() ?? 0
        return max(meeting.duration, transcriptEnd)
    }

    /// The duration of the audio actually handed to the runtime, read from the prepared WAV's header.
    /// This is the bound every turn is validated against, so it has to describe the file the runtime
    /// saw rather than the index's recollection of the original.
    nonisolated static func analysisSeconds(of url: URL, fallback: TimeInterval) -> TimeInterval {
        guard let header = WAVInspection.header(at: url),
              header.sampleRate > 0, header.channels > 0, header.bitsPerSample >= 8 else {
            return fallback
        }
        let bytesPerFrame = Double(header.channels) * Double(header.bitsPerSample / 8)
        guard bytesPerFrame > 0 else { return fallback }
        let seconds = Double(header.declaredDataBytes) / (bytesPerFrame * Double(header.sampleRate))
        return seconds.isFinite && seconds > 0 ? seconds : fallback
    }

    /// Starts anonymous speaker analysis for one meeting (F219).
    ///
    /// Every refusal is stated through `alertMessage` — the channel these entry points already use —
    /// and every one of them happens BEFORE the seam is touched. Analysis is minutes of subprocess
    /// time whose only product is a sidecar a read-only library would refuse, so a refusal discovered
    /// afterwards is a refusal the user paid for (the F187 rule, applied to a new heavy path).
    func requestSpeakerDiarization(for id: UUID) {
        guard diarizationRunningID == nil else {
            alertMessage = "Speaker analysis is already running. Wait for it to finish, or cancel it."
            return
        }
        guard !hasActiveTranscription else {
            alertMessage = "Finish the current transcription before analyzing speaker turns."
            return
        }
        guard !isRunningAuxiliaryEngine else {
            alertMessage = "Finish the second opinion or segment re-run before analyzing speaker turns."
            return
        }
        guard !isDictationActive() else {
            alertMessage = "Finish the current Quick Dictation before analyzing speaker turns."
            return
        }
        guard !isInstallingRecognitionRuntime, !isInstallingDiarizationRuntime else {
            alertMessage = "Wait for the model installation to finish before analyzing speaker turns."
            return
        }
        // Before the runtime check, so a read-only library is reported as the real blocker rather than
        // as a missing model the user would then install for nothing.
        guard libraryAcceptsChanges("Speaker analysis") else { return }
        guard isDiarizationModelInstalled() else {
            alertMessage = LocalDiarizationError.runtimeNotInstalled.localizedDescription
            return
        }
        guard let meeting = store.meeting(id: id) else { return }
        guard meeting.status == .completed, isNativeRecording(meeting) else {
            alertMessage = "Speaker analysis needs a completed recording made in WhisperMeet. Imported and downloaded audio is not supported yet."
            return
        }
        guard hasUsableTimings(meeting) else {
            alertMessage = "This transcript has no timestamps to analyze against, so speaker turns cannot be labelled. The transcript itself is unchanged."
            return
        }

        let request = SpeakerDiarizationRequest(
            meetingID: id,
            audioURL: store.recordingURL(for: meeting),
            durationSeconds: Self.analysisDurationSeconds(for: meeting)
        )
        diarizationRunningID = id
        diarizationProgress = nil
        // Claimed alongside the scoped id so a transcription or a second opinion refuses to start on
        // top of this run, exactly as `requestSecondOpinion` does (F140). Cleared in the epilogue.
        isRunningAuxiliaryEngine = true
        diarizationTask = Task {
            await performSpeakerDiarization(request)
            diarizationRunningID = nil
            diarizationProgress = nil
            isRunningAuxiliaryEngine = false
            diarizationTask = nil
            // Analysis never evicts the dictation helpers itself, but it does hold the auxiliary flag
            // a finishing transcription checks before rewarming, so without this a rewarm could fall
            // between the two and leave the next hotkey cold.
            if !hasActiveTranscription { warmIdleDictationRecognition() }
        }
    }

    /// The analysis itself, separated from the guards so a test can drive a whole run and so the
    /// persistence decision lives in one place: ONLY a complete, validated result becomes a sidecar.
    func performSpeakerDiarization(_ request: SpeakerDiarizationRequest) async {
        // Re-checked here as well as at the entry point, so the refusal cannot be skipped by a caller
        // that reaches the worker directly. `DiarizationArtifactStore` deliberately holds no
        // `MeetingStore` reference, so nothing below this line would refuse to write a sidecar into a
        // read-only library — the F187 backstop, placed where inspection cannot miss it.
        guard libraryAcceptsChanges("Speaker analysis") else { return }
        do {
            let result = try await runSpeakerDiarization(request) { fraction in
                await self.apply(diarizationProgress: fraction)
            }
            try Task.checkCancellation()
            // Re-read rather than reuse: the meeting may have been edited or deleted while the runtime
            // worked, and the fingerprint has to describe the transcript this result will be shown
            // against, not the one it started from.
            guard let meeting = store.meeting(id: request.meetingID) else { return }
            let recordingURL = store.recordingURL(for: meeting)
            // A meeting recording is routinely hundreds of megabytes and can be gigabytes; hashing it
            // on the main actor would freeze the window for as long as the read takes.
            let sha256 = try await Task.detached(priority: .utility) {
                try RecordingFingerprint.sha256(of: recordingURL)
            }.value
            try Task.checkCancellation()
            let artifact = DiarizationArtifactV1(
                meetingID: request.meetingID,
                recording: DiarizationRecordingReference(
                    relativePath: meeting.recordingPath,
                    sha256: sha256,
                    durationSeconds: max(result.audioSeconds, request.durationSeconds)
                ),
                transcriptTimingFingerprint: TranscriptTimingFingerprint.compute(meeting.segments),
                producer: Self.diarizationProducer,
                createdAt: Date(),
                turns: result.turns,
                // A rerun deliberately starts with no aliases: cluster ids permute between runs, so
                // carrying a typed label across would quietly attribute it to a different voice.
                aliases: [:]
            )
            let quarantined = try DiarizationArtifactStore.save(
                artifact, for: request.meetingID, in: store.rootDirectory
            )
            invalidateSpeakerOverlayCache()
            if let quarantined {
                // A rerun landed on a damaged previous result. The new analysis was saved, but a
                // file the user never made is now beside their recording, so it is named.
                alertMessage = "Speaker analysis finished. The previous result was damaged, so a copy of it was kept beside the recording as \(quarantined)."
            }
        } catch is CancellationError {
            // Nothing written and nothing said: the user asked for this.
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    /// Publishes the runtime's live progress for the review sheet.
    func apply(diarizationProgress fraction: Double) {
        diarizationProgress = min(max(fraction, 0), 1)
    }

    /// Stops the in-flight analysis. The task's own epilogue clears the published state; nothing is
    /// written, because the sidecar is saved only after a complete result.
    func cancelSpeakerDiarization() {
        diarizationTask?.cancel()
    }

    /// Discards a meeting's speaker analysis. The recording and the transcript are never touched —
    /// throwing away labels is not throwing away the meeting.
    func clearSpeakerDiarization(for id: UUID) {
        guard libraryAcceptsChanges("Clearing speaker labels") else { return }
        do {
            try DiarizationArtifactStore.clear(meetingID: id, in: store.rootDirectory)
        } catch {
            alertMessage = "Those speaker labels could not be removed. Your recording and transcript are unchanged. \(error.localizedDescription)"
        }
        invalidateSpeakerOverlayCache()
    }

    /// Stores the label a person typed for one anonymous cluster, in this meeting only. It is an alias
    /// on a cluster, never an identity claim, and it never reaches the transcript or any default
    /// export. Renaming is refused unless that cluster is actually being shown — with one voice
    /// distinguished there is nothing safe to name, because the name would also cover whoever else the
    /// runtime failed to separate.
    func renameSpeaker(clusterID: Int, to alias: String, in id: UUID) {
        guard libraryAcceptsChanges("Renaming a speaker label") else { return }
        guard let presentation = speakerOverlay(for: id),
              !presentation.isSingleCluster,
              presentation.clusterIDs.contains(clusterID) else {
            alertMessage = "There is no speaker label to rename for this meeting."
            return
        }
        let artifact: DiarizationArtifactV1
        switch DiarizationArtifactStore.load(meetingID: id, in: store.rootDirectory) {
        case let .ready(loaded):
            artifact = loaded
        case let .unavailable(reason):
            alertMessage = Self.speakerLabelNotSavedMessage(reason)
            return
        case .absent, .stale:
            // The overlay above was drawn from a sidecar that has since gone or stopped matching.
            alertMessage = "That meeting's speaker analysis is no longer available, so the label was not saved. Your transcript is unchanged."
            return
        }
        var updated = artifact
        // Clamped by the codec's own rule, in bytes as well as characters. A `.prefix` on graphemes
        // alone satisfies half the bound and hands `encode` a value it refuses — 64 flag emoji is 512
        // UTF-8 bytes, 64 Devanagari clusters 768 — so an ordinary name in a non-Latin script used to
        // die on the way to disk (F227).
        guard let trimmed = DiarizationArtifactV1.clampedAlias(alias) else {
            // No prefix of this name fits, and an empty alias means "clear the label" — so saving it
            // would delete the name already on this speaker rather than store the new one.
            alertMessage = "That name is too long to save as a speaker label. Your transcript is unchanged, and so is the label already on this speaker."
            return
        }
        if trimmed.isEmpty {
            updated.aliases.removeValue(forKey: String(clusterID))
        } else {
            updated.aliases[String(clusterID)] = trimmed
        }
        do {
            if let quarantined = try DiarizationArtifactStore.save(
                updated, for: id, in: store.rootDirectory
            ) {
                // The label was saved, and a file the user did not create now sits beside their
                // recording. Saying nothing would leave them to discover it and guess.
                alertMessage = "The label was saved. The previous speaker-analysis file was damaged, so a copy of it was kept beside the recording as \(quarantined)."
            }
        } catch {
            alertMessage = error.localizedDescription
            return
        }
        invalidateSpeakerOverlayCache()
    }

    /// Why a speaker label could not be saved, in the user's terms. Three situations hide behind
    /// "could not be read" and their advice is opposite: a damaged file left a copy the user can go
    /// and find by name, a newer build's file needs an update rather than a repair, and a file the
    /// OS will not open is a permissions problem somewhere else entirely. One generic sentence for
    /// all three sends people looking in the wrong place. Every one still ends by saying the
    /// transcript is untouched — labels are an optional extra and losing one is not losing a meeting.
    static func speakerLabelNotSavedMessage(_ reason: DiarizationUnavailableReason) -> String {
        switch reason {
        case let .corrupt(quarantinedAs: name):
            let kept = name.map { " A copy of the damaged file was kept beside the recording as \($0)." }
                ?? " The damaged file was left exactly as it is."
            return "That meeting's speaker-analysis file is damaged, so the label was not saved.\(kept) Your transcript is unchanged."
        case let .newerSchema(version):
            return "That meeting's speaker analysis was written by a newer version of WhisperMeet (format \(version)), so the label was not saved. Update WhisperMeet to edit it. Your transcript is unchanged."
        case .unreadable:
            return "That meeting's speaker-analysis file could not be opened, so the label was not saved. Check the permissions on the recording's folder. Your transcript is unchanged."
        }
    }

    /// The labels to render for one meeting, or nil when none may be shown. A stale result is withheld
    /// here rather than re-mapped onto timings it was never computed against.
    func speakerOverlay(for id: UUID) -> SpeakerOverlayPresentation? {
        guard let presentation = diarizationPresentation(for: id),
              !presentation.isStale, !presentation.isUnreadable else { return nil }
        return presentation
    }

    /// What the transcript's review banner shows for one meeting (F220).
    ///
    /// Five of these end with no labels on screen, and they are deliberately NOT collapsed: a person
    /// who ran an analysis and then sees an ordinary transcript has no way to tell "one voice",
    /// "nothing found", "your file is damaged" and "these labels no longer line up" apart, and the
    /// right next action differs in each. `SpeakerAnalysisCopy.reviewHeadline/reviewDetail` supply the
    /// words; this decides only which of them applies.
    ///
    /// Computed from the cached presentation, so a call is a dictionary hit plus a timing fingerprint —
    /// but the view still stores the result rather than calling this from a body, because the body
    /// runs on the 4 Hz playback tick (the F160 rule).
    func speakerReviewState(for id: UUID) -> SpeakerReviewState {
        if diarizationRunningID == id { return .analyzing }
        guard let presentation = diarizationPresentation(for: id) else { return .notAnalyzed }
        if presentation.isUnreadable { return .unreadable }
        if presentation.isStale { return .stale }
        if presentation.turnCount == 0 { return .noTurnsFound }
        // Asked of the stored TURNS, not of the rows: if two voices were told apart and the overlay
        // still could not attribute a line, saying "only one voice" would be false.
        if presentation.distinguishedVoiceCount <= 1 { return .singleVoice }
        if presentation.clusterIDs.count < 2 { return .noConfidentLabels }
        return .labeled
    }

    /// The visible label for each transcript row, keyed by segment index — built ONCE per change and
    /// read by the row body as a single dictionary lookup (F220).
    ///
    /// This is the whole point of the layer: `PlayableTranscriptView` redraws every visible row on the
    /// 4 Hz playback tick, so resolving a label per row would put an overlay search and an alias
    /// lookup on the render path — the regression F160 documents for the search highlighter, repeated.
    /// Empty whenever no labels may be shown, which is also every state but `.labeled`.
    func speakerRowLabels(for id: UUID) -> [Int: String] {
        guard let presentation = speakerOverlay(for: id), !presentation.clusterIDs.isEmpty else {
            return [:]
        }
        return SpeakerOverlay.labelsByIndex(rows: presentation.rows, aliases: presentation.aliases)
    }

    /// The full state, INCLUDING a stale result — which the review surface has to explain plainly
    /// rather than silently show nothing.
    func diarizationPresentation(for id: UUID) -> SpeakerOverlayPresentation? {
        guard let meeting = store.meeting(id: id) else { return nil }
        let fingerprint = TranscriptTimingFingerprint.compute(meeting.segments)
        if let cached = speakerOverlayCache, cached.meetingID == id, cached.fingerprint == fingerprint {
            return cached.presentation
        }
        let presentation = computeSpeakerOverlay(for: meeting, fingerprint: fingerprint)
        speakerOverlayCache = (id, fingerprint, presentation)
        return presentation
    }

    private func computeSpeakerOverlay(
        for meeting: MeetingRecord,
        fingerprint: String
    ) -> SpeakerOverlayPresentation? {
        // Deliberately loaded WITHOUT the recording hash: hashing a multi-gigabyte recording belongs on
        // the analysis path, not on a render. The app never mutates a recording, so that hash is a
        // corruption check; the timing fingerprint is the one that moves during normal use.
        let artifact: DiarizationArtifactV1
        switch DiarizationArtifactStore.load(meetingID: meeting.id, in: store.rootDirectory) {
        case let .ready(loaded):
            artifact = loaded
        case .absent:
            return nil
        case .stale:
            // The recording's own bytes changed. Loaded here without the audio hash, so this is the
            // shape a future caller could produce; reported as stale rather than silently as nothing.
            return SpeakerOverlayPresentation(
                rows: [], clusterIDs: [], aliases: [:], isStale: true, isSingleCluster: false,
                turnCount: 0, distinguishedVoiceCount: 0, isUnreadable: false
            )
        case .unavailable:
            return SpeakerOverlayPresentation(
                rows: [], clusterIDs: [], aliases: [:], isStale: false, isSingleCluster: false,
                turnCount: 0, distinguishedVoiceCount: 0, isUnreadable: true
            )
        }
        let turnCount = artifact.turns.count
        let distinguishedVoiceCount = Set(artifact.turns.map(\.clusterID)).count
        guard artifact.transcriptTimingFingerprint == fingerprint else {
            return SpeakerOverlayPresentation(
                rows: [], clusterIDs: [], aliases: [:], isStale: true, isSingleCluster: false,
                turnCount: turnCount, distinguishedVoiceCount: distinguishedVoiceCount,
                isUnreadable: false
            )
        }
        let rows = SpeakerOverlay.rows(
            segments: meeting.segments,
            turns: artifact.turns,
            recordingDuration: meeting.duration > 0 ? meeting.duration : nil
        )
        let clusterIDs = SpeakerOverlay.clusterIDs(in: rows)
        guard clusterIDs.count >= 2 else {
            return SpeakerOverlayPresentation(
                rows: rows.map { SpeakerOverlayRow(segmentIndex: $0.segmentIndex, label: .unlabeled) },
                clusterIDs: [], aliases: [:], isStale: false, isSingleCluster: true,
                turnCount: turnCount, distinguishedVoiceCount: distinguishedVoiceCount,
                isUnreadable: false
            )
        }
        var aliases: [Int: String] = [:]
        for (key, value) in artifact.aliases {
            guard let clusterID = Int(key), clusterIDs.contains(clusterID) else { continue }
            aliases[clusterID] = value
        }
        return SpeakerOverlayPresentation(
            rows: rows, clusterIDs: clusterIDs, aliases: aliases, isStale: false,
            isSingleCluster: false, turnCount: turnCount,
            distinguishedVoiceCount: distinguishedVoiceCount, isUnreadable: false
        )
    }

    /// Dropped whenever the sidecar changes. The cache key carries the transcript's timings, so an
    /// edited transcript misses by construction; only a change to the artifact itself needs this.
    private func invalidateSpeakerOverlayCache() {
        speakerOverlayCache = nil
        // The transcript view precomputes its row labels off the render path, so it needs an explicit
        // signal that the stored analysis moved — a finished run, a rename, a clear. Publishing a
        // counter rather than the labels themselves keeps the 4 Hz playback tick out of this entirely.
        speakerOverlayRevision &+= 1
    }

    /// Re-transcribe a single segment (F92): slice that segment's audio from `meeting.wav`, run the
    /// selected engine on the clip, and splice the result back — the recording is never modified. The
    /// heavy work is here so tests can await it directly; `requestSegmentReTranscription` guards + wraps.
    func reTranscribeSegment(id: UUID, index: Int) async {
        guard libraryAcceptsChanges("Re-transcribing a segment") else { return }
        guard let meeting = store.meeting(id: id),
              meeting.segments.indices.contains(index),
              let start = meeting.segments[index].start,
              let end = meeting.segments[index].end else { return }
        let selection = MeetingTranscriptionSelection(engine: selectedEngine, language: selectedLanguage)
        do {
            let clipURL = try Self.makeSegmentClip(
                from: store.recordingURL(for: meeting), startSeconds: start, endSeconds: end
            )
            defer { try? FileManager.default.removeItem(at: clipURL) }
            let result = try await executeEngine(selection, on: clipURL)
            // A re-run can validly return text with no timestamped segments (alignment failure). Splicing
            // an empty array would DELETE the segment's text — keep the original instead (F92 audit fix).
            guard !result.segments.isEmpty else {
                alertMessage = "Re-transcribing that segment produced no timestamped text, so the original was kept."
                return
            }
            store.update(id: id) { meeting in
                guard meeting.segments.indices.contains(index) else { return }
                let merged = TranscriptSegmentSplice.splice(meeting.segments, replacingIndex: index, with: result.segments)
                meeting.segments = merged
                meeting.transcriptText = TranscriptFormatter.timestamped(merged)
            }
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    func requestSegmentReTranscription(id: UUID, index: Int) {
        guard !hasActiveTranscription, !isRunningAuxiliaryEngine else {
            alertMessage = "Finish the current transcription before re-transcribing a segment."
            return
        }
        guard !isDictationActive() else {
            alertMessage = "Finish the current Quick Dictation before re-transcribing a segment."
            return
        }
        // Guarded here as well as in the delegate, so the refusal is one immediate message rather
        // than one raised from inside a detached task after the engine flag was already claimed (F187).
        guard libraryAcceptsChanges("Re-transcribing a segment") else { return }
        isRunningAuxiliaryEngine = true
        Task {
            await reTranscribeSegment(id: id, index: index)
            isRunningAuxiliaryEngine = false
            if !hasActiveTranscription { warmIdleDictationRecognition() }
        }
    }

    /// Writes a temp WAV holding just one segment's audio, sliced from `meeting.wav`. Reads the real
    /// sample rate from the WAV header (the recording is 48 kHz, not 16 kHz) so the byte range is
    /// correct, then re-wraps the PCM slice with a fresh header. Never modifies the source (F92).
    static func makeSegmentClip(from wavURL: URL, startSeconds: Double, endSeconds: Double) throws -> URL {
        let handle = try FileHandle(forReadingFrom: wavURL)
        defer { try? handle.close() }
        guard let header = try handle.read(upToCount: SegmentAudioRange.headerBytes),
              header.count >= SegmentAudioRange.headerBytes else {
            throw SegmentReRunError.unreadableRecording
        }
        // Only a canonical PCM WAV can be byte-sliced. Imported recordings keep their original container
        // (.m4a/.mp3/.mp4/.mov/.aiff/.caf); slicing those as raw WAV bytes would produce garbage, so
        // refuse and let the caller guide the user (F92 audit fix).
        guard header.prefix(4).elementsEqual(Array("RIFF".utf8)),
              header.subdata(in: 8..<12).elementsEqual(Array("WAVE".utf8)) else {
            throw SegmentReRunError.unsupportedRecordingFormat
        }
        let sampleRate = header.withUnsafeBytes { raw -> UInt32 in
            raw.loadUnaligned(fromByteOffset: 24, as: UInt32.self).littleEndian
        }
        let fileSize = (try? wavURL.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? SegmentAudioRange.headerBytes
        let range = SegmentAudioRange.byteRange(
            startSeconds: startSeconds, endSeconds: endSeconds, sampleRate: Int(sampleRate)
        )
        let clamped = range.clamped(to: SegmentAudioRange.headerBytes..<max(SegmentAudioRange.headerBytes, fileSize))
        // Partial read: seek to the clip's byte range and read only those bytes — never the whole file,
        // so a multi-hundred-MB recording doesn't load into memory on the main actor (F92 audit fix).
        try handle.seek(toOffset: UInt64(clamped.lowerBound))
        let pcm = (try handle.read(upToCount: clamped.count)) ?? Data()
        var clip = WAVWriter.header(sampleRate: sampleRate, dataByteCount: UInt32(pcm.count))
        clip.append(pcm)
        let url = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperMeet-segment-\(UUID().uuidString).wav")
        try clip.write(to: url)
        return url
    }

    /// Backs the library up to a destination as a verified generation snapshot. Injectable so the
    /// Settings wiring is testable without touching a real disk destination; defaults to the real
    /// `BackupCoordinator` (F90). `now` is the generation stamp (epoch seconds).
    var runLibraryBackup: @Sendable (_ source: URL, _ destination: URL, _ now: Int, _ retain: Int) throws -> BackupSummary = {
        try BackupCoordinator.backUp(source: $0, destination: $1, now: $2, retain: $3)
    }
    /// Newest N backup generations to keep at the destination (Settings-controlled, F90).
    @Published var backupRetention = 5

    /// One reviewed restore awaiting the user's answer (F191 slice E3). Nil when none is pending.
    @Published var pendingLibraryRestore: PendingLibraryRestore?

    /// A restore offer: the plan, and the generation it came from.
    struct PendingLibraryRestore: Equatable {
        let generation: URL
        let plan: BackupRestorePlan
    }

    /// Offers a restore for review. Restores nothing itself (F191 slice E3, in F193's shape).
    ///
    /// The guards are stricter than `backUpLibrary`'s and for a concrete reason: a backup only
    /// READS the library, while this overwrites it — so running during a capture would replace the
    /// index of a meeting being recorded right now.
    ///
    /// The plan is built with the deep check. It costs minutes on a library of recordings, and this
    /// is the one place that is the right trade: the user is about to overwrite everything they
    /// have, and the cheap check cannot see same-size corruption. A fast answer that might be wrong
    /// is worth less here than a slow one that is not.
    func requestLibraryRestore(from generation: URL) async {
        guard libraryAcceptsChanges("Restoring the library") else { return }
        guard !isRecordingActive, !isImporting else {
            alertMessage = "Finish recording or importing before restoring the library."
            return
        }
        let library = store.rootDirectory
        do {
            let plan = try await Task.detached(priority: .userInitiated) {
                try BackupRestorePlan.make(from: generation, into: library, deep: true)
            }.value
            pendingLibraryRestore = PendingLibraryRestore(generation: generation, plan: plan)
        } catch {
            alertMessage = "That backup could not be read, so nothing was changed. \(error.localizedDescription)"
        }
    }

    /// Applies the reviewed restore. Does nothing at all unless `confirmed` is true.
    ///
    /// The unconfirmed call is the seam the confirmation hangs on, as in
    /// `recoverLibrary(from:confirmed:)` and `performSourceRebuild(confirmed:)`, and it leaves the
    /// offer standing because the user has not answered yet.
    ///
    /// Only a plan this model produced can be applied — F193's structural guarantee, so a caller
    /// cannot restore something the user never saw described.
    func performLibraryRestore(confirmed: Bool, acceptingUnverifiedBackup: Bool = false) async {
        guard confirmed, let pending = pendingLibraryRestore else { return }
        let library = store.rootDirectory
        do {
            let outcome = try await Task.detached(priority: .userInitiated) {
                try BackupRestore.apply(
                    pending.plan,
                    from: pending.generation,
                    into: library,
                    acceptingUnverifiedBackup: acceptingUnverifiedBackup
                )
            }.value
            pendingLibraryRestore = nil
            // The files on disk changed underneath this object, with no write algorithm to notice.
            store.reloadAfterLibraryRestore()
            var message = "Your library was restored from the backup."
            if let snapshot = outcome.preRestoreSnapshot {
                // Named, because the user may want it back and because a restore that silently
                // disposed of their previous library would not be reversible.
                message += " Your previous library was kept at \(snapshot.lastPathComponent) inside the library folder."
            }
            if !pending.plan.notInBackup.isEmpty {
                message += " \(pending.plan.notInBackup.count) file(s) recorded since that backup were left in place but are not listed in the restored index."
            }
            alertMessage = message
        } catch {
            // The offer stays, as F193 leaves `pendingLibraryRecovery` populated: the failure may be
            // specific to this attempt, and `BackupRestore` has already rolled the library back.
            alertMessage = "The library could not be restored, and nothing was changed. \(error.localizedDescription)"
        }
    }

    /// One retained index generation, described for the user to choose between (F193).
    ///
    /// On the model and static for the same reason the two restore messages are: the view that
    /// shows it is `private` and unreachable from tests, and a user picking which copy of their
    /// library to go back to is choosing from these strings alone.
    ///
    /// Record count and date are what distinguish them — a fingerprint is not a decision aid. An
    /// entry whose bytes no longer match its own name is labelled rather than hidden, because
    /// `restoreIndexGeneration` will refuse it and a silently-absent option looks like a bug.
    /// `nonisolated` because it is pure text over a `Sendable` value and touches no model state —
    /// so a test can assert the strings without driving the main actor.
    nonisolated static func generationLabel(_ generation: RetainedGeneration) -> String {
        var parts: [String] = []
        if let count = generation.recordCount {
            parts.append(count == 1 ? "1 meeting" : "\(count) meetings")
        }
        if let epoch = generation.wroteAtEpochSeconds {
            parts.append(Date(timeIntervalSince1970: TimeInterval(epoch))
                .formatted(date: .abbreviated, time: .shortened))
        }
        if !generation.bytesMatchName { parts.append("damaged — cannot be used") }
        return parts.isEmpty ? generation.name : parts.joined(separator: " · ")
    }

    /// The restore confirmation's body (F191 slice E3).
    ///
    /// On the model rather than in the view, and static, for the reason
    /// `rebuildConfirmationMessage` is: the view is `private` and unreachable from tests, and this
    /// text makes four promises the user is deciding on. A promise nothing asserts is a promise
    /// that drifts.
    ///
    /// It leads with what is NOT in the backup when there is anything, because that is the only
    /// item on the list the user cannot undo by restoring again — E1 computes that set precisely so
    /// this sentence can exist.
    static func restoreConfirmationMessage(_ pending: PendingLibraryRestore) -> String {
        let plan = pending.plan
        var lines: [String] = []
        if !plan.notInBackup.isEmpty {
            lines.append("\(plan.notInBackup.count) file(s) in your library are not in this backup. They will be left on disk, but the restored index will not list them.")
        }
        lines.append("\(plan.wouldOverwrite.count) file(s) will be replaced and \(plan.wouldAdd.count) restored.")
        lines.append("Your current library will be copied aside first and kept, so this can be undone.")
        if plan.verification.isUnverifiable {
            lines.append("This backup was made by an earlier version and carries no checksums, so WhisperMeet could not confirm it is intact.")
        } else if !plan.verification.isIntact {
            lines.append("This backup did not pass its own checks and cannot be restored: " + plan.verification.problems.prefix(3).joined(separator: " "))
        }
        return lines.joined(separator: "\n\n")
    }

    /// Dismisses a pending restore offer without restoring anything.
    func cancelLibraryRestore() {
        pendingLibraryRestore = nil
    }

    /// Copy the meeting library to a chosen backup folder as a new verified snapshot. Read-only on the
    /// source; surfaces success or the failure reason through `alertMessage` (F90). Refuses while a
    /// recording or import is active so it never snapshots changing files, and runs the copy/hash work
    /// off the main actor so the UI doesn't stall (F137).
    func backUpLibrary(to destination: URL, now: Int = Int(Date().timeIntervalSince1970)) async {
        // Refused while the library is read-only, ahead of the busyness guard below and of any
        // filesystem work — this is not about a transient conflict but about the library being
        // untrustworthy (F187). A backup taken from a library the app could not fully read is worse
        // than no backup: the snapshot captures the DAMAGED `meetings.json`, and the same run prunes
        // complete generations beyond `backupRetention`, so the user's last good off-library copies of
        // a readable index are replaced by copies of the truncated one. "Back this up before I touch
        // anything" is the most intuitive move here and would be the destructive one. While degraded
        // the only safe action is to change nothing at all; recovery is the manual path in
        // `docs/RECOVERY.md`, and a backup taken after that is a backup worth having.
        guard libraryAcceptsChanges("Backing up the library") else { return }
        guard !isRecordingActive, !isImporting else {
            alertMessage = "Finish recording or importing before backing up the library."
            return
        }
        let source = store.rootDirectory
        let retain = backupRetention
        let run = runLibraryBackup
        do {
            let summary = try await Task.detached(priority: .userInitiated) {
                try run(source, destination, now, retain)
            }.value
            alertMessage = "Library backed up: \(summary.copied) file(s) copied, \(summary.skipped) unchanged."
                + (summary.prunedGenerations.isEmpty ? "" : " Removed \(summary.prunedGenerations.count) old backup(s).")
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    /// The one place that turns a rebuild's truncation into words (F256).
    ///
    /// Both `InterruptedRecordingRecovery.recover` call sites need it, and they disagreed: the
    /// startup sweep reported the truncation and `stopRecording`'s error path did not, so the same
    /// bad block produced a "Partly Recovered Meeting" on one route and an ordinary four-second
    /// meeting under the user's own title on the other. The throwing-read half of F256 was global;
    /// this half was not.
    static func recoveryWarning(for recovered: RecoveredRecording) -> String? {
        recovered.truncatedAtSeconds.map {
            "The rebuilt audio stops at \(TranscriptFormatter.clock($0)) because a source track could not be read past that point. Anything recorded after that is missing from this file."
        }
    }

    /// Shown instead of the ordinary recovery notice when almost nothing survived (F256). Names the
    /// raw tracks because they are the only remaining route to the missing audio — nothing re-runs
    /// recovery on a folder once it is indexed (F267).
    static let severelyTruncatedRecoveryMessage = "Most of this recording could not be rebuilt because a source track became unreadable. The original microphone and system tracks are still in this meeting's folder and have not been changed."

    func performStartupRecovery() async {
        guard !didPerformStartupRecovery else { return }
        didPerformStartupRecovery = true
        // F257: idempotent, and started here because this is the one method that runs once per
        // launch regardless of window state now that `AppLifecycle` owns the call.
        observeStorageErrors()
        // Self-heal an interrupted Qwen install *before* refreshing runtime state, so a runtime that a
        // force-quit mid-install stranded in a backup dir is restored and shows as installed rather
        // than "not installed" (F33 wires the tested `setup-qwen-asr.sh` recovery branch to launch).
        await reclaimInterruptedQwenInstall()
        // The same self-heal for the speaker-analysis runtime, and for the same reason (F219): an
        // install interrupted mid-swap can leave the previous runtime in a `.Diarization-backup-*`
        // dir with `Diarization/` gone, which reports as "not installed" until it is reclaimed. It
        // must therefore also run BEFORE the probe below, or this launch shows the wrong state.
        await reclaimInterruptedDiarizationInstall()
        // And the summarizer (F167), for the same reason and before the same probe: an install
        // interrupted mid-swap reports as "not installed" until it is reclaimed.
        await reclaimInterruptedSummarizerInstall()
        refreshRuntime()
        refreshRecordingPreflight()
        var messages = store.startupRecoveryMessages
        // A library that did not fully load must never be "recovered" into a lesser one (F187). Every
        // recording folder looks orphaned when the in-memory index is empty, which is how ten meetings
        // became blank stubs on 2026-08-14. Show the state and stop; the user decides what happens next.
        if store.isDegraded {
            messages.append(
                "WhisperMeet is open in read-only mode because it could not fully read your meeting library. Your recordings are untouched and the unreadable index was copied aside. Nothing will be changed until you choose how to recover."
            )
            // `report`, not a bare assignment (F257): this is the startup-recovery summary, and a
            // launch with no window — a login item, or a window closed before this ran — showed it
            // to nobody. It is the notice that tells a user their recording came back.
            report(messages.joined(separator: "\n\n"))
            return
        }

        // Every meeting's transcript and summary is mirrored as notes.md beside its audio, so the
        // text survives even an index loss (F198). Idempotent: an up-to-date library writes nothing.
        // Awaited, but the sweep itself runs detached off the main actor — see the store.
        await store.backfillNotesSidecars()
        // F295: deletions older than the grace window lose their text from the saved history.
        store.processPendingShreds()

        do {
            let recover = recoverInterruptedRecording
            // F255: refuse to rebuild while another live instance owns the library. A running
            // capture's folder holds only growing `.f32` tracks and no finalized WAV — `meeting.wav`
            // is written by `AudioCaptureEngine.stop()` — so it is structurally identical to an
            // interrupted one. Without this, a second instance rebuilds the LIVE folder, indexes the
            // partial result, and the complete `meeting.wav` that arrives afterwards has nothing
            // pointing at it: the user's real recording is stranded on disk.
            //
            // Evaluated ONCE. The lease is loop-invariant, and testing it per folder would append
            // the same paragraph N times to `messages`, which are joined with a blank line.
            //
            // Only this loop is gated. `recover` is also reached from `stopRecording`'s error path,
            // where this instance is recovering its OWN folder after its own finalization failed —
            // and since nothing gates `startRecording` on the lease, that instance may well not hold
            // it. Gating the function instead of the loop would break exactly that case.
            let lease = store.writerLease
            // Asked even when the gate is shut, so the notice below is about folders that actually
            // exist. `orphanedRecordings()` is a pure read-and-report — that is the stated reason
            // the gate is not inside it — so calling it while refusing to act on it is safe.
            // Without this, opening a second copy over a perfectly clean library told the user to
            // quit and relaunch to finish recovering nothing, on every launch.
            let orphans = try store.orphanedRecordings()
            // F297: the lease answers "is another copy open"; the folder's own capture lock answers
            // "is THIS folder's writer alive", and the kernel answers it — a crashed writer's lock
            // is free, a live one's is held. So a recording that crashed in one instance is
            // rebuilt even while another copy is open, which F255 had recorded as its accepted
            // trade-off; a folder whose writer is alive is refused even when the lease says go,
            // which F255 could not do; and a folder with no lock file (a build before this one)
            // is decided by the lease exactly as before. `mayRebuild(folder:lease:)` is that rule.
            //
            // A free lock is TAKEN here and held through the rebuild below, so a third instance
            // probing the same folder meanwhile sees a live holder rather than joining in.
            var live: Set<URL> = []
            var probeLocks: [URL: RecordingCaptureLock.Handle] = [:]
            var candidates: [OrphanedRecording] = []
            var deferredForLease = 0
            for orphan in orphans {
                let probe = RecordingCaptureLock.probe(in: orphan.directory)
                if case .released(let handle) = probe { probeLocks[orphan.directory] = handle }
                if case .heldByLiveWriter = probe {
                    // Kept among the candidates so the "still in progress" notice below covers it,
                    // and in `live` so the loop never touches it.
                    live.insert(orphan.directory)
                    candidates.append(orphan)
                } else if InterruptedRecordingRecovery.mayRebuild(folder: probe, lease: lease) {
                    candidates.append(orphan)
                } else {
                    deferredForLease += 1
                }
            }
            if deferredForLease > 0 {
                // Only about folders the lease actually deferred. Before F297 this named the other
                // copy for every orphan, including the user's own crashed recording.
                messages.append(
                    "Another copy of WhisperMeet is open, so interrupted recordings were left untouched. Your audio is safe where it is. Quit the other copy and reopen WhisperMeet to finish recovering them."
                )
            }
            // F279: refuse any folder that is being written to right now, whatever the lease says.
            //
            // The lease answers "is another instance open", which is not the same question and
            // misses the case F255 left open: an instance whose rival has since quit still
            // believes `.heldElsewhere` for the rest of its life, nothing gates `startRecording`
            // on the lease, and a third instance then holds `.held` and rebuilds its live folder.
            // Growth between two samples answers the actual question directly.
            //
            // One sleep for the whole sweep rather than one per folder, and skipped entirely when
            // nothing looks orphaned — which is the normal case, so this costs launches nothing.
            // An ADDITIONAL refusal, never a replacement for the lease gate: if the probe is wrong
            // in some case nobody has thought of, the failure is a deferred recovery rather than a
            // re-run of F255. (F297's capture lock is the same kind of thing — it adds a refusal,
            // and vouches only for a folder it has positive evidence about — so the two stack.)
            if !candidates.isEmpty {
                // F283: a capture inside an outage it intends to resume is NOT growing, because
                // nothing is capturing — that is what the gap is. Growth alone therefore reads a
                // sleeping recording as dead, and F255's lease gate does not cover it either: the
                // instance sweeping here is a first launch after wake and holds the lease
                // legitimately, while the recorder holds a valid one and is about to resume. Both
                // guards miss it, which is why this one is not optional.
                //
                // Asked BEFORE the growth probe and short-circuiting it: a folder the writer has
                // declared mid-outage needs no sampling, and skipping the sleep is the common
                // case's reward.
                let now = Date()
                for candidate in candidates {
                    if RecordingSessionSidecar.read(in: candidate.directory)?
                        .isMidOutage(now: now) == true {
                        live.insert(candidate.directory)
                    }
                }
                let sampled = candidates.filter { !live.contains($0.directory) }
                let before = sampled.map {
                    ($0.directory, RecordingFolderLiveness.sample(in: $0.directory))
                }
                if !before.isEmpty {
                    try? await Task.sleep(for: .milliseconds(400))
                    for (directory, first) in before {
                        let second = RecordingFolderLiveness.sample(in: directory)
                        if RecordingFolderLiveness.isGrowing(from: first, to: second) {
                            live.insert(directory)
                        }
                    }
                }
                if !live.isEmpty {
                    messages.append(
                        // "in progress" rather than "being written": after F283 this covers a
                        // capture that is paused inside an outage as well as one actively
                        // appending, and a sleeping capture is not being written to.
                        "A recording on this Mac is still in progress, so it was left alone rather than rebuilt. Nothing was changed, and it will be added to your history when that recording stops."
                    )
                }
            }
            for orphan in candidates where !live.contains(orphan.directory) {
                let recovered: RecoveredRecording?
                do {
                    recovered = try await Task.detached(priority: .utility) {
                        try recover(orphan.directory)
                    }.value
                } catch {
                    // One unreadable/broken orphan folder must not abort recovery of the rest (F47).
                    // The folder is left untouched (raw tracks preserved) and reported.
                    messages.append(
                        "An interrupted recording folder at \(orphan.directory.path) could not be rebuilt and was left untouched. \(error.localizedDescription)"
                    )
                    continue
                }
                // F308: read back what `importFromURL` wrote. The sidecar goes into the folder
                // before the download starts, "so a crash mid-download still leaves a recoverable
                // link import" — and until now nothing read it, so that crash recovered the audio
                // and lost the link. The same shape as F274's `session.json`.
                //
                // Read ONCE, above every branch, and passed to all four upserts — including the
                // two capture-only ones, where a capture folder has no `source.json` and this is
                // nil. F303 exists because a field was set on one branch and not its sibling; a
                // value every branch receives cannot be forgotten by one of them.
                //
                // Nil for absent, unreadable or corrupt: it can add provenance to a recovery and
                // can never fail one.
                let mediaSource = MediaSource.read(in: orphan.directory)
                let provenanceTags = Self.provenanceTags(for: mediaSource)
                guard let recovered else {
                    if let imported = InterruptedRecordingRecovery.importedRecordingCandidate(
                        in: orphan.directory
                    ) {
                        let failedTitle = "Unverified Import \(orphan.createdAt.formatted(date: .abbreviated, time: .shortened))"
                        let message = "WhisperMeet preserved this interrupted import, but it was empty or macOS could not verify it as playable audio or video. The original file remains on this Mac; replace it with a valid recording or delete this entry."
                        store.upsert(MeetingRecord(
                            id: orphan.id,
                            title: failedTitle,
                            createdAt: orphan.createdAt,
                            recordingPath: store.relativeRecordingPath(for: imported),
                            status: .failed,
                            errorMessage: message,
                            tags: provenanceTags,
                            // F303: stated literally because there is no `RecoveredRecording` here
                            // — this branch is the `guard let recovered else`, reached precisely
                            // via `importedRecordingCandidate`, so the source is known from how we
                            // got here. That asymmetry with the branch below is why F273 missed
                            // both: the sibling had `recovered.source` to hand and this one did
                            // not, so the omission reads as a scope limit rather than a decision.
                            recoverySource: RecoveredRecording.Source.importedRecording.rawValue,
                            source: mediaSource
                        ))
                        messages.append("\(failedTitle) needs attention. \(message)")
                        continue
                    }
                    // F311: a link import that died before any audio arrived. `importFromURL`
                    // writes `source.json` BEFORE the download starts, deliberately, "so a crash
                    // mid-download still leaves a recoverable link import" — but yt-dlp writes
                    // `recording.<ext>.part` until it finishes and the candidate scan does not
                    // match a `.part`. So the folder holds the sidecar and maybe a partial file:
                    // no audio to recover, no candidate to index, and `removeIfEmpty` refuses
                    // because it is not empty. It fell through to the message below, and since
                    // nothing about the folder changed it said so again on every launch, forever.
                    // Reproduced by `InterruptedLinkImportTests`, not only traced.
                    //
                    // Indexed once rather than deleted, which is a decision and mine — no user
                    // input settled it. The sidecar exists so the URL outlives a crash and its
                    // comment promises the folder is "recoverable as a link import rather than an
                    // anonymous orphan folder"; the user has that URL nowhere else, so deleting it
                    // after one message would break the promise to save a directory. An indexed
                    // entry also ends the repetition on its own, because `orphanedRecordings()`
                    // skips folders whose UUID is already in the index.
                    //
                    // Only for a link import. A capture folder that produced no audio has no
                    // sidecar, nothing to retry and no URL worth keeping, so it keeps the message.
                    if let mediaSource {
                        let failedTitle = "Interrupted import from \(mediaSource.host)"
                        let message = "This import stopped before any audio finished downloading, so there is nothing to play. Its link was kept — open the source to try again, or delete this entry."
                        store.upsert(MeetingRecord(
                            id: orphan.id,
                            title: failedTitle,
                            createdAt: orphan.createdAt,
                            status: .failed,
                            errorMessage: message,
                            tags: provenanceTags,
                            source: mediaSource
                        ))
                        messages.append("\(failedTitle) needs attention. \(message)")
                        continue
                    }
                    if (try? InterruptedRecordingRecovery.removeIfEmpty(
                        in: orphan.directory
                    )) == true {
                        continue
                    }
                    messages.append(
                        "An interrupted recording folder was kept at \(orphan.directory.path), but it did not contain enough audio to rebuild a WAV."
                    )
                    continue
                }
                // F274: read back what F258 wrote. Hoisted above the title because F298 needs it
                // here — the user's own title is the one field distinguishing two meetings recorded
                // the same afternoon, and it was being overwritten by a synthesized name.
                let session = RecordingSessionSidecar.read(in: orphan.directory)
                let synthesizedTitle = "Recovered Meeting \(orphan.createdAt.formatted(date: .abbreviated, time: .shortened))"
                // Trimmed, because a whitespace-only title is not a title: it would render as a
                // blank row, indistinguishable from a bug in the sidebar.
                let userTitle = session?.title.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                let title = userTitle.isEmpty ? synthesizedTitle : userTitle
                let duration = recovered.duration > 0
                    ? recovered.duration
                    : await Self.loadDuration(of: recovered.recordingURL)
                if recovered.source == .importedRecording, duration <= 0 {
                    let failedTitle = "Unverified Import \(orphan.createdAt.formatted(date: .abbreviated, time: .shortened))"
                    let message = "WhisperMeet preserved this interrupted import, but macOS could not verify it as playable audio or video. The original file remains on this Mac; replace it with a valid recording or delete this entry."
                    store.upsert(MeetingRecord(
                        id: orphan.id,
                        title: failedTitle,
                        createdAt: orphan.createdAt,
                        recordingPath: store.relativeRecordingPath(for: recovered.recordingURL),
                        status: .failed,
                        errorMessage: message,
                        tags: provenanceTags,
                        // F303: without this the meeting renders no recording caveat at all —
                        // `recoveryCaveats(for:)` is built from `recoveryWarning`,
                        // `staleTranscriptWarning` and `recoverySource`, and this upsert set none
                        // of the three. So the only record that it came from an interrupted import
                        // was `errorMessage`, which `performTranscription` clears on start and on
                        // success. That is F273's defect exactly, in the branch F273 skipped, and
                        // transcription is deliberately still offered here (see the comment below
                        // on the severely-truncated sibling).
                        recoverySource: recovered.source.rawValue,
                        source: mediaSource
                    ))
                    messages.append("\(failedTitle) needs attention. \(message)")
                    continue
                }
                // The sidecar is the only place a marker offset survives a crash, ⌘Q or a
                // shutdown, and until F274 nothing read it — so a recovered meeting came back with
                // zero markers while its offsets sat on disk beside it. `interruptedBySleepAt` was
                // write-only for the same reason: F253 records WHY the capture stopped and nothing
                // ever said so.
                //
                // No health report is read, because there is none: `RecordingSession` has no such
                // field, so F258 never wrote one. The ticket lists it; the code does not have it.
                //
                // Absent or unreadable is a normal state, not a failure. `session.json` is written
                // best-effort — a metadata write must never be able to fail a capture that is
                // working — so recovery cannot depend on it and must not invent what it says.
                // (`session` itself is read above, where the title needs it.)
                let recoveredMarkers = session?.markers.isEmpty == false ? session?.markers : nil
                // F256. The rebuild reports where it stopped; say so on the meeting itself, not
                // only in the startup alert the user dismisses once.
                let recoveryWarning = Self.recoveryWarning(for: recovered)
                // Below a tenth of what the tracks promised, "technically recovered" would
                // masquerade as recovered — a two-second stub titled like an ordinary meeting. It
                // lands as `.failed` naming the raw tracks instead. What `.failed` buys is the
                // title, the red icon and the error text; transcription is still offered, as it is
                // for `.recorded`, because the surviving audio may still be worth transcribing.
                if recovered.isSeverelyTruncated {
                    // F298: keep the user's own title and the caveat, not one or the other. The
                    // caveat is what they scan the list for; the title is how they find this
                    // meeting among three from the same day.
                    let failedTitle = userTitle.isEmpty
                        ? "Partly Recovered Meeting \(orphan.createdAt.formatted(date: .abbreviated, time: .shortened))"
                        : "\(userTitle) (partly recovered)"
                    store.upsert(MeetingRecord(
                        id: orphan.id,
                        title: failedTitle,
                        createdAt: orphan.createdAt,
                        duration: duration,
                        recordingPath: store.relativeRecordingPath(for: recovered.recordingURL),
                        status: .failed,
                        errorMessage: Self.severelyTruncatedRecoveryMessage,
                        // Markers travel even here — arguably especially here. They are the user's
                        // own notes about where something happened, and a meeting whose audio is
                        // mostly gone is the one where they matter most.
                        markers: recoveredMarkers,
                        tags: provenanceTags,
                        recoveryWarning: recoveryWarning,
                        recoverySource: recovered.source.rawValue,
                        source: mediaSource
                    ))
                    messages.append("\(failedTitle) needs attention. \(Self.severelyTruncatedRecoveryMessage)")
                    // The clock time belongs in the worse case too. Without this the startup alert
                    // named where the audio stops only for the MILD truncation.
                    if let recoveryWarning { messages.append(recoveryWarning) }
                    continue
                }
                store.upsert(MeetingRecord(
                    id: orphan.id,
                    title: title,
                    createdAt: orphan.createdAt,
                    duration: duration,
                    recordingPath: store.relativeRecordingPath(for: recovered.recordingURL),
                    // F274 named the interruption here and said why: "Recovered after an
                    // interruption" is true and unhelpful — the user knows they closed the lid and
                    // wants the app to know it too. Its conclusion was "no new field for it", and
                    // F305 reverses that: `performTranscription` clears `errorMessage` on start and
                    // on success, so the reason died while the fact of the recovery survived. F273
                    // had ruled that out one commit earlier, for provenance, and the rule was not
                    // carried to the next fact that came along.
                    //
                    // The sleep sentence is therefore NOT appended here any more — it is generated
                    // from `recoveryInterruption` below, which also ends the duplication where the
                    // same thing was said twice on one screen until a transcription cleared one copy.
                    errorMessage: recovered.wasRebuiltFromRawTracks
                        ? "Recovered from source audio after an interruption. The raw microphone and system tracks were preserved; their exact start alignment was unavailable."
                        : "Recovered after an interruption. The original recording and source tracks were preserved.",
                    markers: recoveredMarkers,
                    tags: provenanceTags,
                    recoveryWarning: recoveryWarning,
                    // F273: the same fact structurally, because `performTranscription` clears
                    // `errorMessage` and used to take the provenance with it.
                    recoverySource: recovered.source.rawValue,
                    // F305: and the reason, for exactly the same reason.
                    recoveryInterruption: session?.interruptedBySleepAt == nil
                        ? nil
                        : RecoveryInterruption.systemSleep.rawValue,
                    source: mediaSource
                ))
                // `title` already begins with "Recovered Meeting", so do not prefix it again (F187).
                messages.append("\(title) was added back to meeting history.")
                if let recoveryWarning {
                    messages.append(recoveryWarning)
                }
            }
            // F297: let go of every lock the probe took. The file goes too for a folder that is
            // now indexed — it no longer looks crashed, because it no longer is. A folder still
            // orphaned after the sweep keeps its file: it is the evidence that lets the NEXT
            // launch rebuild it under a rival lease, and a 0-byte file costs nothing to keep.
            for (directory, handle) in probeLocks {
                let indexed = orphans.contains { orphan in
                    orphan.directory == directory && store.meeting(id: orphan.id) != nil
                }
                handle.release(removingFile: indexed)
            }
        } catch {
            messages.append(
                "WhisperMeet could not finish scanning interrupted recordings. Existing recording folders were not changed. \(error.localizedDescription)"
            )
        }
        recoverInterruptedTranscriptions()
        // Read-only integrity sweep over the whole library (including anything just recovered above):
        // flags missing/truncated/inconsistent audio without ever touching it (F83 wires the F66 core).
        messages.append(contentsOf: Self.integrityMessages(verifyLibraryIntegrity()))
        if !messages.isEmpty {
            // `report`, not a bare assignment (F257): this is the startup-recovery summary, and a
            // launch with no window — a login item, or a window closed before this ran — showed it
            // to nobody. It is the notice that tells a user their recording came back.
            report(messages.joined(separator: "\n\n"))
        }
    }

    func installLocalWhisper() {
        guard !isInstallingAnyRuntime,
              !isMicrophoneBusy,
              !isImporting,
              !hasActiveTranscription,
              !isDictationActive() else {
            return
        }
        guard let scriptURL = Bundle.main.url(
            forResource: "setup-local-whisper",
            withExtension: "sh"
        ) else {
            alertMessage = "The local Whisper installer is missing. Rebuild the app and try again."
            return
        }
        isInstallingRuntime = true
        installationMessage = "Installing FFmpeg and local Whisper…"
        let runtimeDirectory = LocalWhisperRuntime.managedDirectory()
        Task {
            do {
                try await runInstaller(
                    scriptURL: scriptURL,
                    runtimeDirectory: runtimeDirectory
                )
                refreshRuntime()
                if isRuntimeInstalled {
                    installationMessage = "Local Whisper is ready. The selected model downloads once, when first used."
                } else {
                    throw LocalWhisperError.runtimeNotInstalled
                }
            } catch {
                installationMessage = "Installation failed."
                alertMessage = error.localizedDescription
            }
            isInstallingRuntime = false
        }
    }

    func installQwenASR() {
        guard !isInstallingAnyRuntime,
              !isMicrophoneBusy,
              !isImporting,
              !hasActiveTranscription,
              !isRunningAuxiliaryEngine, // don't install atop a second-opinion / segment re-run (F140)
              !isDictationActive() else {
            return
        }
        guard MeetingTranscriptionEngine.qwenBalanced.isSupportedOnCurrentMac else {
            alertMessage = "Qwen3-ASR requires an Apple-silicon Mac. Whisper remains available on Intel Macs."
            return
        }
        guard let scriptURL = Bundle.main.url(
            forResource: "setup-qwen-asr",
            withExtension: "sh"
        ) else {
            alertMessage = "The Qwen3-ASR installer is missing. Rebuild the app and try again."
            return
        }
        isInstallingQwenRuntime = true
        qwenInstallationMessage = "Installing Qwen3-ASR and its timestamp model…"
        Task {
            do {
                try await runQwenInstaller(
                    scriptURL: scriptURL,
                    runtimeDirectory: QwenASRRuntime.managedDirectory()
                )
                refreshRuntime()
                if isQwenInstalled {
                    qwenInstallationMessage = "Qwen3-ASR is ready for local transcription."
                } else {
                    throw QwenASRError.runtimeNotInstalled
                }
            } catch {
                qwenInstallationMessage = "Installation failed. The previous runtime was preserved."
                alertMessage = error.localizedDescription
            }
            isInstallingQwenRuntime = false
        }
    }

    /// Installs the on-device summarization model, choosing 8B vs 4B by physical RAM (F164). Mirrors
    /// `installQwenASR`: resolve the bundled installer, run it off-actor exporting the chosen model
    /// repository, then refresh and report. The previous model is preserved on failure.
    func installSummarizer() {
        guard !isInstallingAnyRuntime,
              !isMicrophoneBusy,
              !isImporting,
              !hasActiveTranscription,
              !isRunningAuxiliaryEngine,
              !isDictationActive() else {
            return
        }
        guard SummarizerRuntime.isSupportedOnCurrentMac else {
            alertMessage = "Local summaries require an Apple-silicon Mac. Use Claude summaries on Intel Macs."
            return
        }
        guard let scriptURL = Bundle.main.url(
            forResource: "setup-local-summarizer",
            withExtension: "sh"
        ) else {
            alertMessage = "The local-summarizer installer is missing. Rebuild the app and try again."
            return
        }
        let repository = SummarizerRuntime.recommendedRepository()
        isInstallingSummarizer = true
        summarizerInstallationMessage = "Installing the local summarization model…"
        Task {
            do {
                try await runSummarizerInstaller(
                    scriptURL: scriptURL,
                    runtimeDirectory: SummarizerRuntime.managedDirectory(),
                    repository: repository
                )
                refreshRuntime()
                if isSummarizerInstalled {
                    summarizerInstallationMessage = "Local summaries are ready — private and offline."
                } else {
                    throw SummarizerError.modelNotInstalled
                }
            } catch {
                summarizerInstallationMessage = "Installation failed. The previous model was preserved."
                alertMessage = error.localizedDescription
            }
            isInstallingSummarizer = false
        }
    }

    /// Installs the pinned speaker-analysis runtime (F219). Mirrors `installQwenASR`: the same
    /// compound busy guard, the same architecture gate, the same bundled-script resolution, and the
    /// installer run off the main actor.
    ///
    /// The part that is not cosmetic is the verification. Success is decided by **re-probing the
    /// filesystem** afterwards (`refreshRuntime()` → `isDiarizationInstalled`), never by the
    /// installer's exit status: this script downloads, hash-verifies and atomically swaps, and any of
    /// those steps can leave the previous runtime in place while the shell still exits 0. Believing
    /// the exit code would leave the app announcing a model that is not there, and the first thing a
    /// user would see is analysis failing on a meeting instead of an honest install failure here.
    ///
    /// The guard also refuses while an analysis is running: the installer swaps the very binary that
    /// run is executing.
    func installSpeakerDiarization() {
        guard !isInstallingAnyRuntime,
              diarizationRunningID == nil, // never swap the runtime under a running analysis
              !isMicrophoneBusy,
              !isImporting,
              !hasActiveTranscription,
              !isRunningAuxiliaryEngine,
              !isDictationActive() else {
            return
        }
        guard Self.diarizationIsSupportedOnCurrentMac else {
            alertMessage = "Speaker analysis requires an Apple-silicon Mac. Everything else in WhisperMeet is unchanged on Intel Macs."
            return
        }
        guard let scriptURL = Bundle.main.url(
            forResource: "setup-speaker-diarization",
            withExtension: "sh"
        ) ?? Self.developmentScriptURL("setup-speaker-diarization.sh") else {
            alertMessage = "The speaker-analysis installer is missing. Rebuild the app and try again."
            return
        }
        let runtimeDirectory = diarizationRuntimeDirectory
        let install = runDiarizationInstaller
        isInstallingDiarizationRuntime = true
        diarizationInstallationMessage = "Installing the speaker-analysis model…"
        Task {
            do {
                try await install(scriptURL, runtimeDirectory)
                // Exit status is not evidence. Ask the filesystem.
                refreshRuntime()
                if isDiarizationInstalled {
                    diarizationInstallationMessage = "Speaker analysis is ready — it runs entirely on this Mac."
                } else {
                    throw LocalDiarizationError.runtimeNotInstalled
                }
            } catch {
                diarizationInstallationMessage = "Installation failed. The previous model was preserved."
                alertMessage = error.localizedDescription
            }
            isInstallingDiarizationRuntime = false
        }
    }

    /// The pinned runtime asset is `osx-arm64`, so speaker analysis is Apple-silicon only — the same
    /// constraint Qwen3-ASR and on-device summaries already carry (F219). Kept here rather than on
    /// `DiarizationRuntime` so this task touches only the files it owns.
    static var diarizationIsSupportedOnCurrentMac: Bool {
        #if arch(arm64)
        return true
        #else
        return false
        #endif
    }

    func startRecording() async {
        guard recordingState == .idle, !isImporting, !isMicrophoneBusy else { return }
        guard !isInstallingRecognitionRuntime else {
            alertMessage = "Wait for the local recognition model installation to finish before recording."
            return
        }
        guard !isDictationActive() else {
            alertMessage = "Finish Quick Dictation before recording a meeting — they can't share the microphone at the same time."
            return
        }
        // Must precede every side effect below, including the recording folder: while the library is
        // read-only the `store.upsert` in `stopRecording` is refused, so the meeting would be captured
        // to disk and then never indexed — and `orphanedRecordings()` reports nothing while degraded,
        // so the user would lose a whole meeting with no error shown (F187).
        guard !store.isDegraded else {
            alertMessage = ReadOnlyLibraryNotice.recordingRefused
            return
        }
        refreshRecordingPreflight()
        if recordingPreflight.microphoneAccess == .unavailable {
            alertMessage = "Recording cannot start because no microphone is connected or available. Connect an input device and choose Check Again."
            return
        }
        if let available = recordingPreflight.availableStorageBytes,
           available < 500_000_000 {
            alertMessage = "Recording cannot start because this Mac has less than 500 MB available. Free some storage so the meeting audio is not put at risk."
            return
        }
        recordingState = .starting
        recordingHealth = nil
        riskAnnouncer = RecordingRiskAnnouncer()
        recordingMeter.reset()
        pendingMarkers = []
        let id = UUID()
        activeMeetingID = id
        captureRestartNotice = nil
        let directory = store.recordingDirectoryURL(for: id)
        do {
            _ = try store.recordingDirectory(for: id)
            // F297: claim the folder before a single sample is written to it, so there is no
            // window in which it exists, looks interrupted, and nobody vouches for it.
            captureLock = RecordingCaptureLock.acquire(in: directory)
            try await recorder.start(in: directory) { [weak self] snapshot in
                Task { @MainActor [weak self] in
                    guard let self,
                          self.activeMeetingID == id,
                          case .recording = self.recordingState else {
                        return
                    }
                    self.recordingHealth = snapshot
                    // F294: the banner is in the window; with no window, say it once where they are.
                    if let announcement = self.riskAnnouncer.announcement(for: snapshot) {
                        self.postWindowlessAlert(announcement)
                    }
                    // F275: this 1 Hz tick is the only trigger that catches the case with no power
                    // event — a docked lid close, where the display-bound stream dies and the Mac
                    // never sleeps. Before this the banner appeared here and nothing else happened.
                    if self.recorder.hasStreamError {
                        await self.handleCaptureInterruption(trigger: .streamFailed)
                    } else {
                        self.noteCaptureAlive()
                    }
                }
            } onLevels: { [weak self] snapshot in
                Task { @MainActor [weak self] in
                    guard let self,
                          self.activeMeetingID == id,
                          case .recording = self.recordingState else {
                        return
                    }
                    self.recordingMeter.update(snapshot)
                }
            }
            let startedAt = Date()
            recordingState = .recording(startedAt: startedAt)
            // F258: put the session's metadata on disk alongside the audio, from the first moment of
            // capture. Everything the user enters during a recording used to exist only in RAM, so
            // any end the app did not control returned the audio and lost the meeting.
            persistRecordingSession(id: id, startedAt: startedAt)
            // F253: watch for sleep only while a capture is actually live.
            observeSystemSleep()
            refreshRecordingPreflight()
        } catch {
            recordingState = .idle
            activeMeetingID = nil
            recordingHealth = nil
            recordingMeter.reset()
            refreshRecordingPreflight()
            // The lock file first, or `removeIfEmpty` would find the folder non-empty (F297).
            releaseCaptureLock(removingFile: true)
            _ = try? InterruptedRecordingRecovery.removeIfEmpty(in: directory)
            alertMessage = error.localizedDescription
        }
    }

    func stopRecording(title: String) async -> UUID? {
        guard let id = activeMeetingID else { return nil }
        // F253: the capture is ending, so stop watching for sleep. Dropped here rather than in each
        // exit branch, because every path out of this function ends the recording.
        stopObservingSystemSleep()
        recordingState = .stopping
        let directory = store.recordingDirectoryURL(for: id)
        do {
            let artifact = try await recorder.stop()
            let fallbackTitle = "Meeting \(Date.now.formatted(date: .abbreviated, time: .shortened))"
            let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
            let meeting = MeetingRecord(
                id: id,
                title: cleanTitle.isEmpty ? fallbackTitle : cleanTitle,
                duration: artifact.duration,
                recordingPath: store.relativeRecordingPath(for: artifact.mixedRecordingURL),
                markers: pendingMarkers.isEmpty ? nil : pendingMarkers,
                healthReport: artifact.healthReport
            )
            store.upsert(meeting)
            pendingMarkers = []
            recordingState = .idle
            activeMeetingID = nil
            recordingHealth = nil
            recordingMeter.reset()
            refreshRecordingPreflight()
            // Indexed, so the folder no longer needs vouching for (F297).
            releaseCaptureLock(removingFile: true)

            refreshRuntime()
            if isSelectedEngineInstalled {
                beginTranscription(id: id)
            } else {
                // F262: name the engine that is installed instead of telling a user who just
                // installed one to install one.
                alertMessage = transcriptionUnavailableMessage
            }
            return id
        } catch let recordingError {
            recordingState = .idle
            activeMeetingID = nil
            recordingHealth = nil
            recordingMeter.reset()
            refreshRecordingPreflight()
            // F297: the lock is released on every exit below. The FILE is kept unless this
            // instance indexes the folder itself: a folder left for a later launch keeps the
            // evidence that its writer is gone, which is what lets that launch rebuild it even
            // while another copy of the app is open.
            defer { releaseCaptureLock(removingFile: store.meeting(id: id) != nil) }
            do {
                // Through the same seam the orphan sweep uses. It was calling the type directly,
                // which is why this branch — the one that runs when the user's own stop fails —
                // had no way to be tested at all.
                let recover = recoverInterruptedRecording
                let recovered = try await Task.detached(priority: .userInitiated) {
                    try recover(directory)
                }.value
                if let recovered {
                    // F256 applies here too. This is the second, deliberately ungated `recover`
                    // call site — this instance rebuilding its OWN folder after its own
                    // finalization failed — and a bad block truncates it exactly the same way. The
                    // user's typed title is kept either way: they chose it and will recognise the
                    // meeting by it; only an untitled severe truncation gets the synthesized name.
                    let severe = recovered.isSeverelyTruncated
                    let fallbackTitle = severe
                        ? "Partly Recovered Meeting \(Date.now.formatted(date: .abbreviated, time: .shortened))"
                        : "Recovered Meeting \(Date.now.formatted(date: .abbreviated, time: .shortened))"
                    let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
                    let recoveredMarkers = pendingMarkers.isEmpty ? nil : pendingMarkers
                    pendingMarkers = []
                    let recoveryWarning = Self.recoveryWarning(for: recovered)
                    store.upsert(MeetingRecord(
                        id: id,
                        title: cleanTitle.isEmpty ? fallbackTitle : cleanTitle,
                        duration: recovered.duration,
                        recordingPath: store.relativeRecordingPath(for: recovered.recordingURL),
                        status: severe ? .failed : .recorded,
                        errorMessage: severe
                            ? Self.severelyTruncatedRecoveryMessage
                            : "The recording was recovered after a finishing error. The source files remain on this Mac, and transcription can be tried again.",
                        markers: recoveredMarkers,
                        recoveryWarning: recoveryWarning,
                        recoverySource: recovered.source.rawValue
                    ))
                    var alert = severe
                        ? "The meeting could not finish normally, and most of its audio could not be rebuilt. \(Self.severelyTruncatedRecoveryMessage)"
                        : "The meeting could not finish normally, but its recording was recovered and added to history."
                    if let recoveryWarning { alert += " \(recoveryWarning)" }
                    // F294: through `report` — a recording that could not finish normally is the
                    // app's most serious message, and it reaches a user whose window is closed
                    // only through this channel. The stop that produced it is often itself
                    // triggered by sleep or a dead display, so "the user is right there" does not
                    // hold for any of these three.
                    report(alert + " \(recordingError.localizedDescription)")
                    return id
                }
            } catch {
                report("The recording could not be finalized automatically. Its folder was preserved at \(directory.path). Finishing error: \(recordingError.localizedDescription) Recovery error: \(error.localizedDescription)")
                return nil
            }
            report("No usable audio could be rebuilt, but the recording folder was left untouched at \(directory.path). \(recordingError.localizedDescription)")
            return nil
        }
    }

    /// Lets go of the live capture's folder lock (F297). Idempotent; a nil lock is a no-op.
    private func releaseCaptureLock(removingFile: Bool) {
        captureLock?.release(removingFile: removingFile)
        captureLock = nil
    }

    /// Presents the discard-recording confirmation. Owned by the model so both the in-window button and
    /// the ⌘ Cancel command route through the SAME confirmation, and never prompt when nothing is being
    /// recorded (F139).
    @Published var isConfirmingCancellation = false
    /// Cancel is only valid while capturing or starting — NOT during finalization (`.stopping`), where a
    /// cancel would race the Stop, nor when idle (F139).
    var canCancelRecording: Bool {
        switch recordingState {
        case .recording, .starting: return true
        case .stopping, .idle: return false
        }
    }
    func requestCancelConfirmation() {
        guard canCancelRecording else { return }
        isConfirmingCancellation = true
    }

    func cancelRecording() async {
        // A cancel that arrives during finalization (`.stopping`) or when idle must be a no-op so it
        // can't race/corrupt a simultaneous Stop (F139).
        guard canCancelRecording else { return }
        stopObservingSystemSleep()   // F253
        // Before the engine removes the folder, so nothing is held on a directory being deleted
        // (F297).
        releaseCaptureLock(removingFile: true)
        await recorder.cancel()
        recordingState = .idle
        activeMeetingID = nil
        recordingHealth = nil
        recordingMeter.reset()
        pendingMarkers = []
        refreshRecordingPreflight()
    }

    // MARK: - Recording markers

    /// Drops a marker at the current point in the live recording. No-op unless recording. The audio
    /// is never touched — this only records an offset. See `docs/RECORDING_MARKERS.md`.
    func addLiveMarker(label: String? = nil) {
        guard case let .recording(startedAt) = recordingState else { return }
        let offset = max(0, Date().timeIntervalSince(startedAt))
        pendingMarkers = RecordingMarkers.inserting(
            RecordingMarker(offset: offset, label: label),
            into: pendingMarkers
        )
        // F258: persist on every drop rather than at stop. A marker's offset is the one piece of
        // recording metadata that cannot be reconstructed afterwards — a title can be retyped in
        // seconds, a flagged moment in ninety minutes of audio cannot be found again.
        if let id = activeMeetingID {
            persistRecordingSession(id: id, startedAt: startedAt)
        }
    }

    /// The `willSleep` subscription, held only for the lifetime of a capture (F253).
    private var sleepObserver: NSObjectProtocol?
    private var wakeObserver: NSObjectProtocol?
    private var displayObserver: NSObjectProtocol?
    /// When the Mac began sleeping, so a wake can measure the gap it has to pad (F275).
    private var sleepBeganAt: Date?

    /// Subscribes to `NSWorkspace.willSleepNotification` for the duration of a recording (F253).
    ///
    /// On `AppModel` rather than a view, deliberately: every other lifecycle hook in this app hangs
    /// off `ContentView` inside the `WindowGroup` (F257), which means a menu-bar-only session gets
    /// none of them. `AppModel` is the app's own `@StateObject`, so a recording started from the
    /// menu bar with no window open is still covered. That also makes F253 independent of F257
    /// rather than blocked behind it.
    ///
    /// `queue: .main` with `assumeIsolated` rather than a `Task`: the handler has to run *inside*
    /// the notification, because the few seconds macOS grants are the entire budget. Hopping to a
    /// Task would return immediately and let the machine suspend before the note was written.
    private func observeSystemSleep() {
        guard sleepObserver == nil else { return }
        sleepObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.willSleepNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                self?.sleepBeganAt = Date()
                self?.handleSystemWillSleep()
            }
        }
        // F275's other two triggers. Both can fire without the stream being dead, and the policy
        // says so — a display change that left the capture alive, or a wake after a sleep the
        // recording was already finalized through, is a no-op.
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                // The gap is the sleep itself, which only this handler knows: no audio existed for
                // anyone during it, so it is exactly the span to pad.
                let slept = self.sleepBeganAt.map { Date().timeIntervalSince($0) }
                self.sleepBeganAt = nil
                Task { await self.handleCaptureInterruption(trigger: .didWake, gap: slept) }
            }
        }
        displayObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self else { return }
                Task { await self.handleCaptureInterruption(trigger: .displayReconfigured) }
            }
        }
    }

    /// Drops the subscriptions once the recording is over, so an idle app is not woken by them.
    private func stopObservingSystemSleep() {
        let center = NSWorkspace.shared.notificationCenter
        if let sleepObserver { center.removeObserver(sleepObserver) }
        if let wakeObserver { center.removeObserver(wakeObserver) }
        if let displayObserver { NotificationCenter.default.removeObserver(displayObserver) }
        sleepObserver = nil
        wakeObserver = nil
        displayObserver = nil
        sleepBeganAt = nil
        captureLastAliveAt = nil
        // `captureRestartNotice` deliberately survives this. Its entire job is to explain a stop the
        // user did not ask for, and this teardown runs *as part of* that stop — clearing it here
        // meant the explanation was written and erased in the same breath, so the recording just
        // ended for no stated reason. Caught by a red test. It is cleared when the next recording
        // starts instead.
    }

    /// Reacts to the Mac being about to sleep during a capture (F253).
    ///
    /// Internal so `SleepInterruptionWiringTests` can drive it without a real power event.
    ///
    /// Two steps, in this order, because only the first is guaranteed. macOS posts `willSleep` and
    /// waits a few seconds; finalizing a 63-minute recording means mixing ~1.4 GB, which will not
    /// fit in that window. So the sidecar note — a few hundred atomic bytes — lands first and always,
    /// and the stop is attempted after it as best-effort.
    ///
    /// If the stop is cut off mid-mix it degrades safely rather than corrupting: `FloatTrackMixer`
    /// writes the WAV header **last**, so a truncated `meeting.wav` fails `wavDuration`'s magic and
    /// size checks, `finalizedRecording(in:)` returns nil, and startup recovery rebuilds from the
    /// raw tracks as it would have anyway — now with the note explaining why.
    func handleSystemWillSleep(now: Date = Date()) {
        guard RecordingSleepPolicy.action(for: recordingState.policyState, on: .willSleep)
                == .finalize,
              let id = activeMeetingID,
              case let .recording(startedAt) = recordingState else {
            return
        }
        noteSleepInterruption(id: id, startedAt: startedAt, at: now)
        // Move the state machine SYNCHRONOUSLY before handing off to the async stop. Without this
        // the policy's `.stopping` no-op never fires: macOS can post `willSleep` more than once
        // around a failed sleep attempt, and `stopRecording` is async, so a second notification
        // arrived while the phase was still `.recording` and re-noted a later moment over the one
        // the Mac actually slept at. Caught by a red test rather than in the field.
        //
        // `.stopping` is also the correct phase to be in: it is what makes Cancel refuse
        // (`canCancelRecording`), so a cancel cannot race this finalize — the same guard F139 added.
        recordingState = .stopping
        // F298: the user's title survives a sleep-triggered stop for the same reason.
        Task { [recordingTitle] in _ = await stopRecording(title: recordingTitle) }
    }

    /// The last thing a restart did, for the banner. Nil when nothing has happened (F275).
    @Published var captureRestartNotice: String?

    /// When the capture was last seen alive, so a gap can be measured without a power event (F275).
    private var captureLastAliveAt: Date?

    /// Whether a restart is already in flight (F275).
    ///
    /// The 1 Hz health tick fires `.streamFailed` every second while the stream is dead, and the
    /// display and wake notifications can land in the same window. `handleCaptureInterruption` is
    /// async, so without this two calls both observe `hasStreamError == true` before either has
    /// restarted, and the recording is padded twice for one gap — shifting the timeline by the gap
    /// all over again, which is precisely the defect padding exists to prevent. Found by a red test.
    private var isHandlingCaptureInterruption = false

    /// Marks the capture as alive now, so a later failure can measure how long it was dead (F275).
    func noteCaptureAlive(at now: Date = Date()) {
        captureLastAliveAt = now
    }

    /// Reacts to something that may have killed the capture (F275).
    ///
    /// Internal so `CaptureRestartWiringTests` can drive it without a display to lose.
    ///
    /// **The case this exists for has no power event at all.** A lid close on a *docked* Mac kills
    /// the display-bound `SCStream` and the machine never sleeps, so neither `willSleep` nor
    /// `didWake` fires; the recording stays "running" while nothing is captured. That is what took
    /// 63 minutes of the user's meeting. So the triggers are the display set changing, the stream
    /// reporting its own death, and waking — and the decision is the same for all three, which is
    /// why `CaptureRestartPolicy` takes the trigger for the record and not for the outcome.
    func handleCaptureInterruption(
        trigger: CaptureRestartPolicy.Trigger,
        gap: TimeInterval? = nil,
        now: Date = Date()
    ) async {
        guard !isHandlingCaptureInterruption else { return }
        isHandlingCaptureInterruption = true
        defer { isHandlingCaptureInterruption = false }
        // Measured from when the capture was last known alive, unless the caller knows better (a
        // wake knows the sleep duration; a test states it outright).
        let measuredGap = gap ?? captureLastAliveAt.map { now.timeIntervalSince($0) } ?? 0
        let action = CaptureRestartPolicy.action(
            trigger: trigger,
            state: recordingState.policyState,
            streamIsAlive: !recorder.hasStreamError,
            gap: measuredGap,
            restartsSoFar: recorder.restartCount
        )
        switch action {
        case .none:
            if recordingState.isLive, !recorder.hasStreamError { captureLastAliveAt = now }
            return
        case let .restart(padding):
            let frames = CaptureRestartPolicy.paddingFrames(
                forGap: padding,
                sampleRate: AudioCaptureEngine.captureSampleRate
            )
            // F283: the outage began `padding` seconds ago, not now — a rival reading this while
            // the restart is in flight should see when the audio actually stopped, since that is
            // what its own growth probe is measuring against.
            updateRecordingSession { $0.outageBeganAt = now.addingTimeInterval(-padding) }
            do {
                try await recorder.restartAfterFailure(paddingFrames: frames)
                // Recorded only now, after the silence is actually on disk. Noting it first meant a
                // failed restart left a claim in the sidecar that a gap had been padded when none
                // was — and startup recovery would then describe an unpatched set of tracks as
                // patched. Found by a red test.
                notePaddedGap(seconds: padding, resumedAt: now)
                // Capture is live again, so the folder will grow and needs no protection. Cleared
                // rather than left to age out: the flag describes now, and `paddedGaps` is the
                // durable record of what happened.
                updateRecordingSession { $0.outageBeganAt = nil }
                captureLastAliveAt = now
                captureRestartNotice = CaptureRestartPolicy.notice(for: action, trigger: trigger)
            } catch {
                // The restart itself failed — the display is likely gone for good. Save rather than
                // leave the capture dead, which is the state this ticket exists to end. The retry
                // was already counted, so a repeated failure reaches the bound and stops.
                await finalizeAfterFailedRestart(trigger: trigger)
            }
        case .finalize:
            await finalizeAfterFailedRestart(trigger: trigger)
        }
    }

    /// Saves what was captured and tells the user why the recording ended (F275).
    private func finalizeAfterFailedRestart(trigger: CaptureRestartPolicy.Trigger) async {
        guard recordingState.isLive else { return }
        let notice = CaptureRestartPolicy.notice(for: .finalize, trigger: trigger)
        captureRestartNotice = notice
        // F294: the banner is window-only, and this is the message saying the recording ENDED —
        // the highest-stakes thing the app can tell someone, and the case F257's channel did not
        // carry. A user recording from the menu bar with no window open learned nothing.
        //
        // Only when there is a notice: `notice(for:trigger:)` is optional and a nil one means the
        // policy had nothing to say, which must not become an empty alert.
        if let notice { report(notice) }
        // Synchronously, before the async stop, for the reason `handleSystemWillSleep` documents:
        // a second trigger arriving mid-stop must see `.stopping` and no-op rather than race it.
        recordingState = .stopping
        // F298: the user's own title, not `""`. The comment here used to explain that the title
        // lived in `ContentView`'s `@State` and could not reach the model — true when written, and
        // false once F298 moved it. This is the path that ends a recording *because* the capture
        // died, so it is exactly the case where the typed name has to survive.
        _ = await stopRecording(title: recordingTitle)
    }

    /// Reads the live recording's sidecar, applies `change`, and writes it back (F284).
    ///
    /// **The one writer.** There were three, and each built a fresh `RecordingSession` and called
    /// the whole-file `write` without reading, so they erased each other's fields: a sleep note
    /// dropped the padded gaps, a padded gap dropped the sleep note, and adding a marker dropped
    /// both. Found by whisper-62 while checking whether the sidecar could carry F283's outage
    /// signal, rather than assuming it could.
    ///
    /// The lost sleep marker was not the worst of it. Startup recovery reads `paddedGaps` to choose
    /// a rebuild's alignment, so a dropped gap made a patched timeline describe itself as clean —
    /// **F282's defect reachable again**, through a lost field rather than through the label logic
    /// that ticket fixed. A recording that slept, resumed, then slept again did it.
    ///
    /// `markers` is refreshed from `pendingMarkers` on every write rather than merged, because the
    /// model holds the whole list and the file is a mirror of it; the fields that are NOT derivable
    /// from the model — the sleep note, the padded gaps — are what reading first preserves.
    private func updateRecordingSession(_ change: (inout RecordingSession) -> Void) {
        guard let id = activeMeetingID else { return }
        let startedAt: Date
        switch recordingState {
        case let .recording(at): startedAt = at
        // A stop in progress still has a sidecar worth updating: `handleSystemWillSleep` moves the
        // state to `.stopping` synchronously and then notes the interruption, and F275's finalize
        // does the same. Refusing here would drop exactly the notes those paths exist to write.
        case .stopping, .starting, .idle:
            guard let existing = RecordingSessionSidecar.read(
                in: store.recordingDirectoryURL(for: id)
            ) else { return }
            startedAt = existing.startedAt
        }
        let directory = store.recordingDirectoryURL(for: id)
        var session = RecordingSessionSidecar.read(in: directory) ?? RecordingSession(
            id: id,
            startedAt: startedAt,
            title: "",
            markers: []
        )
        session.markers = pendingMarkers
        // F298: the title is a mirror of the model too, for the same reason `markers` is — the
        // model holds the whole value and the file reflects it. Mirrored rather than merged so
        // clearing the field clears it on disk; a user who deleted what they typed has said the
        // meeting has no name, and recovery must not resurrect it.
        session.title = recordingTitle
        change(&session)
        try? RecordingSessionSidecar.write(session, in: directory)
    }

    /// Records a padded gap in the sidecar, so recovery does not read a patched timeline as clean.
    private func notePaddedGap(seconds: TimeInterval, resumedAt: Date) {
        updateRecordingSession {
            $0.paddedGaps.append(
                RecordingSession.PaddedGap(seconds: seconds, resumedAt: resumedAt)
            )
        }
    }

    /// Records in the session sidecar that sleep interrupted this capture (F253).
    private func noteSleepInterruption(id: UUID, startedAt: Date, at now: Date) {
        // Through `updateRecordingSession` since F284: this used to build a fresh session and write
        // the whole file, which erased any padded gaps F275 had recorded.
        updateRecordingSession {
            $0.interruptedBySleepAt = now
            // F283: written HERE, before the machine suspends, so the fact that this capture is
            // about to stop growing is on disk before it stops growing. A second instance launching
            // on wake then reads it whenever it happens to look, instead of the answer depending on
            // whether `didWake` beats that launch.
            $0.outageBeganAt = now
        }
    }

    /// Writes the live recording's session sidecar (F258).
    ///
    /// Best-effort by design: a metadata write must never be able to interrupt or fail a capture
    /// that is working. It is also not surfaced — an alert mid-recording over a marker file would
    /// cost the user more than the markers are worth — so the failure mode is silently losing the
    /// metadata this exists to keep, which is still strictly better than the RAM-only behaviour it
    /// replaces. `RecordingSessionSidecar.read` tolerates everything this can leave behind.
    private func persistRecordingSession(id: UUID, startedAt: Date) {
        // The title rides along now (F298): `updateRecordingSession` mirrors `recordingTitle` on
        // every write, so this call persists it at start and `recordingTitle`'s `didSet` keeps it
        // current as the user types. It used to live in `ContentView`'s `@State` and reach the
        // model only as an argument to `stopRecording(title:)`, which meant the sidecar's `title`
        // was written empty by every caller — a field that looked supported and was not.
        //
        // Through `updateRecordingSession` since F284. This is the caller a user triggers most
        // often — every marker rewrites the sidecar — so as a whole-file write it was the most
        // likely of the three to erase a padded gap or a sleep note.
        updateRecordingSession { _ in }
    }

    /// Adds a marker to an already-saved meeting (e.g. from playback at the current time).
    func addMarker(to meetingID: UUID, offset: TimeInterval, label: String? = nil) {
        store.update(id: meetingID) { meeting in
            meeting.markers = RecordingMarkers.inserting(
                RecordingMarker(offset: offset, label: label),
                into: meeting.markers ?? []
            )
        }
    }

    /// Removes a marker from a saved meeting.
    func removeMarker(_ markerID: UUID, from meetingID: UUID) {
        store.update(id: meetingID) { meeting in
            meeting.markers = (meeting.markers ?? []).filter { $0.id != markerID }
        }
    }

    /// Renames a marker on a saved meeting (a blank label clears it, reverting to "Marker N").
    func renameMarker(_ markerID: UUID, to label: String, in meetingID: UUID) {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        store.update(id: meetingID) { meeting in
            guard var markers = meeting.markers else { return }
            for index in markers.indices where markers[index].id == markerID {
                markers[index].label = trimmed.isEmpty ? nil : trimmed
            }
            meeting.markers = markers
        }
    }

    // MARK: - Preflight test recording

    /// Records a short, disposable sample of both channels and reports whether each is capturing.
    /// Uses a dedicated engine and a temp directory — never the meeting library — and never becomes
    /// a meeting. See `docs/PREFLIGHT_TEST.md`.
    func startPreflightTest() {
        guard recordingState == .idle, !isImporting, !isMicrophoneBusy else { return }
        guard !isInstallingRecognitionRuntime else {
            alertMessage = "Wait for the local recognition model installation to finish before testing a recording."
            return
        }
        guard !isDictationActive() else {
            alertMessage = "Finish Quick Dictation before running a test recording — they can't share the microphone at the same time."
            return
        }
        let engine = AudioCaptureEngine()
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("WhisperMeet-Preflight-\(UUID().uuidString)", isDirectory: true)
        preflightRecorder = engine
        preflightDirectory = directory
        preflightTest = .recording(secondsRemaining: Self.preflightDurationSeconds)
        preflightTask = Task { [weak self] in
            await self?.runPreflightTest(engine: engine, directory: directory)
        }
    }

    /// The task owns the engine's *entire* lifecycle. `AudioCaptureEngine.start()` is not
    /// cancellation-aware, so we always let it finish and then re-check cancellation — that way a
    /// Cancel tapped during `start()` still results in the just-created stream being torn down here
    /// (rather than orphaned). `teardownPreflight()` only cancels this task; it never touches the
    /// engine while the task is live, so `engine.cancel()` is called from exactly one place.
    private func runPreflightTest(engine: AudioCaptureEngine, directory: URL) async {
        do {
            try await engine.start(in: directory, onHealthUpdate: { _ in }, onLevels: { _ in })
            try Task.checkCancellation()  // Cancel during start() → stop the stream we just created.
            for remaining in stride(from: Self.preflightDurationSeconds - 1, through: 0, by: -1) {
                try await Task.sleep(for: .seconds(1))
                try Task.checkCancellation()
                preflightTest = .recording(secondsRemaining: remaining)
            }
            try Task.checkCancellation()
            preflightTest = .analyzing
            let artifact = try await engine.stop()
            try Task.checkCancellation()
            let report = await Self.analyzePreflight(artifact: artifact)
            try Task.checkCancellation()
            let playbackURL = FileManager.default.fileExists(atPath: artifact.mixedRecordingURL.path)
                ? artifact.mixedRecordingURL
                : nil
            preflightRecorder = nil
            preflightTask = nil
            preflightTest = .result(report, playbackURL: playbackURL)
        } catch is CancellationError {
            await engine.cancel()  // stops the stream and removes the temp session directory
            releasePreflightOwnership(of: engine)
            // teardownPreflight() already set the phase to .idle; don't disturb it.
        } catch {
            await engine.cancel()
            let owned = releasePreflightOwnership(of: engine)
            // A Cancel that landed alongside a real error must not resurrect a dismissed sheet, and
            // a newer test that took ownership during engine.cancel() must not be clobbered either.
            if owned, !Task.isCancelled {
                preflightTest = .failed(error.localizedDescription)
            }
        }
    }

    /// Clears the engine/task/temp-directory references for a finished run — but only if they still
    /// describe *this* engine. `engine.cancel()` above is a suspension point during which a new test
    /// (e.g. "Test Again") can install its own engine/task; the resuming old task must not nil those.
    /// Returns whether this run still owned the state.
    @discardableResult
    private func releasePreflightOwnership(of engine: AudioCaptureEngine) -> Bool {
        guard preflightRecorder === engine else { return false }
        preflightRecorder = nil
        preflightTask = nil
        preflightDirectory = nil
        return true
    }

    private static func analyzePreflight(artifact: RecordingArtifact) async -> PreflightReport {
        await Task.detached(priority: .utility) {
            let micData = (try? Data(contentsOf: artifact.microphoneTrackURL)) ?? Data()
            let systemData = (try? Data(contentsOf: artifact.systemTrackURL)) ?? Data()
            return PreflightAssessment.evaluate(
                microphone: PreflightSignalAnalyzer.analyze(float32LittleEndian: micData),
                system: PreflightSignalAnalyzer.analyze(float32LittleEndian: systemData)
            )
        }.value
    }

    /// Cancels an in-progress test and discards its temp files.
    func cancelPreflightTest() { teardownPreflight() }

    /// Dismisses a finished (result/failed) test and discards its temp files.
    func dismissPreflightTest() { teardownPreflight() }

    /// Ends any preflight test.
    ///
    /// - If the capture task is still running, we only cancel it and set `.idle`; the task's
    ///   cancellation path (the single owner of the engine) stops the stream and `engine.cancel()`
    ///   removes the temp directory. This avoids a second, concurrent `engine.cancel()`.
    /// - If the task has already finished (a result/failed sheet), the engine is gone and the temp
    ///   files were retained for playback, so we remove the directory directly.
    private func teardownPreflight() {
        if let task = preflightTask {
            task.cancel()
            preflightTest = .idle
            return
        }
        let directory = preflightDirectory
        preflightDirectory = nil
        preflightTest = .idle
        if let directory {
            Task.detached(priority: .utility) {
                try? FileManager.default.removeItem(at: directory)
            }
        }
    }

    /// Imports an existing audio or video file as a new meeting and transcribes it. The file is
    /// copied into the recording library so the imported audio becomes the source of truth, exactly
    /// like a live recording. Whisper (via FFmpeg) decodes any supported container directly, so no
    /// conversion is needed here.
    func importRecording(from sourceURL: URL, title: String) async -> UUID? {
        guard recordingState == .idle, !isImporting, !isPreflightTestActive else { return nil }
        guard !isInstallingRecognitionRuntime else {
            alertMessage = "Wait for the local recognition model installation to finish before importing."
            return nil
        }
        // Must precede the copy below: while the library is read-only the `store.upsert` in
        // `adoptImportedRecording` is refused, so the file would be copied into the library and then
        // never indexed — and `orphanedRecordings()` reports nothing while degraded, so the import
        // would vanish with no error shown (F187).
        guard libraryAcceptsChanges("Import") else { return nil }
        refreshRecordingPreflight()
        if let available = recordingPreflight.availableStorageBytes {
            // The file is copied into the library, so require room for it plus a safety margin.
            let sourceSize = (try? sourceURL.resourceValues(forKeys: [.fileSizeKey]))?.fileSize ?? 0
            let needed = Int64(sourceSize) + 500_000_000
            if available < needed {
                alertMessage = "Importing this recording needs about \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)) free, but less is available. Free some storage and try again."
                return nil
            }
        }
        isImporting = true
        let id = UUID()
        let directory = store.recordingDirectoryURL(for: id)
        let cleanTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        do {
            let copiedURL = try await Task.detached(priority: .userInitiated) {
                try Self.copyImportedRecording(from: sourceURL, into: directory)
            }.value
            let fallbackTitle = sourceURL.deletingPathExtension().lastPathComponent
            let displayTitle = cleanTitle.isEmpty
                ? (fallbackTitle.isEmpty ? "Imported Recording" : fallbackTitle)
                : cleanTitle
            return await adoptImportedRecording(id: id, at: copiedURL, title: displayTitle)
        } catch {
            isImporting = false
            try? FileManager.default.removeItem(at: directory)
            alertMessage = "The recording could not be imported: \(error.localizedDescription)"
            return nil
        }
    }

    /// Fetches a link's audio into a new meeting and transcribes it locally (F183). The fetch is
    /// inbound-only: nothing about the meeting is uploaded, and only the audio is retrieved.
    ///
    /// Ordering matters and follows the plan's traps: probe *before* downloading (so the storage guard
    /// and the long-duration confirmation are possible at all), write the provenance sidecar *before*
    /// the bytes arrive (so an interrupted download is recoverable as a link import rather than an
    /// anonymous orphan), download straight into the meeting folder (never temp-then-copy, which would
    /// double peak disk for a long video), and finish through the shared adopt path so transcription
    /// starts exactly the way it does for a file import.
    @discardableResult
    func importFromURL(_ raw: String, confirmedLongDuration: Bool = false) async -> UUID? {
        guard linkImportEnabled else {
            alertMessage = "Turn on “Import from a link” in Settings to fetch audio from a link."
            return nil
        }
        guard recordingState == .idle, !isImporting, !isPreflightTestActive else {
            alertMessage = "Finish the current recording or import before adding from a link."
            return nil
        }
        guard !isInstallingRecognitionRuntime else {
            alertMessage = "Wait for the local recognition model installation to finish before importing."
            return nil
        }
        // Before the probe, let alone the download: the same unindexed-audio trap as a file import,
        // with a network transfer in front of it (F187).
        guard libraryAcceptsChanges("Import") else { return nil }

        let parsed: MediaSourceURL.Parsed
        do {
            parsed = try MediaSourceURL.validate(raw)
        } catch {
            alertMessage = "That doesn't look like a web link. Paste a full https:// address to a single video."
            return nil
        }
        guard !parsed.isPlaylist else {
            alertMessage = MediaDownloadError.playlistNotSupported.localizedDescription
            return nil
        }

        let probe: MediaProbe
        do {
            probe = try await probeMediaURL(parsed.url)
        } catch {
            alertMessage = error.localizedDescription
            return nil
        }
        guard !probe.isLive else {
            alertMessage = MediaDownloadError.liveInProgress.localizedDescription
            return nil
        }
        // Long media is confirmed, never capped.
        if let duration = probe.durationSeconds,
           duration > Self.longMediaDurationThreshold,
           !confirmedLongDuration {
            pendingLongMediaConfirmation = probe
            return nil
        }
        // The storage guard needs the probe's size: the file-import guard reads `.fileSizeKey` from the
        // source, which is meaningless for a remote URL and would silently degrade to a flat margin.
        refreshRecordingPreflight()
        if let available = recordingPreflight.availableStorageBytes {
            let needed = (probe.approximateBytes ?? 0) + 500_000_000
            if available < needed {
                alertMessage = "Downloading this needs about \(ByteCountFormatter.string(fromByteCount: needed, countStyle: .file)) free, but less is available. Free some storage and try again."
                return nil
            }
        }

        isImporting = true
        pendingLongMediaConfirmation = nil
        mediaDownloadProgress = MediaDownloadProgress()
        let id = UUID()
        let directory = store.recordingDirectoryURL(for: id)
        let source = MediaSource(
            kind: parsed.kind,
            pageURL: parsed.url,
            host: parsed.host,
            videoID: parsed.videoID,
            uploader: probe.uploader,
            uploadDate: probe.uploadDate,
            fetchedAt: Date()
        )

        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            // Provenance first, so a crash mid-download still leaves a recoverable link import.
            if let sidecar = try? JSONEncoder().encode(source) {
                try? sidecar.write(to: directory.appendingPathComponent(MediaSource.sidecarFilename))
            }
            let downloaded = try await downloadMedia(parsed.url, directory) { [weak self] progress in
                Task { @MainActor in self?.mediaDownloadProgress = progress }
            }
            mediaDownloadProgress = nil
            // Captions are a reviewable reference only, pinned to the video's OWN language so a
            // machine-translated track can never enter the transcript. When the probe doesn't report a
            // language, captions are skipped entirely rather than guessed: asking for a fixed language
            // on an unknown-language video is exactly how an auto-translated track would be fetched,
            // and adopting one would break "preserve the original spoken language".
            let reference: [TranscriptSegment]
            if let language = probe.language?.trimmingCharacters(in: .whitespaces), !language.isEmpty {
                reference = await downloadCaptions(parsed.url, directory, language)
            } else {
                reference = []
            }
            let title = (probe.title?.trimmingCharacters(in: .whitespacesAndNewlines)).flatMap {
                $0.isEmpty ? nil : $0
            } ?? "Imported from \(parsed.host)"
            return await adoptImportedRecording(
                id: id, at: downloaded, title: title, source: source, referenceSegments: reference
            )
        } catch {
            isImporting = false
            mediaDownloadProgress = nil
            // No resume in v1: a failed or cancelled download leaves nothing behind.
            try? FileManager.default.removeItem(at: directory)
            if !(error is CancellationError) {
                alertMessage = error.localizedDescription
            }
            return nil
        }
    }

    /// The tag a link import carries so it can be found among ordinary meetings, or nil when there
    /// is no source or it suggests nothing usable.
    ///
    /// One function because there are two places a link import becomes a meeting — the import
    /// itself and the startup recovery of one that was interrupted (F308) — and a recovered import
    /// that is tagged differently from a completed one is the kind of drift nobody files.
    ///
    /// The provenance tag is the FIRST tag, never appended to others: `normalized` stops at 12
    /// tags, and the sidebar renders only the first 4, so an appended marker can be silently
    /// dropped or invisible.
    static func provenanceTags(for source: MediaSource?) -> [String]? {
        guard let source else { return nil }
        let tags = MeetingTags.normalized([source.suggestedTag])
        return tags.isEmpty ? nil : tags
    }

    /// The single place an imported recording becomes a real meeting: measure the written file's
    /// duration (never a probe's metadata — `MeetingIntegrityChecker` cross-checks the WAV header
    /// against the indexed duration), upsert the record, then start transcription if the engine is
    /// installed. Both import entry points — local file and link — call this, so there is exactly one
    /// place where a meeting becomes real (F183).
    ///
    /// It carries NO read-only guard of its own, and that is a deliberate dependency on its callers,
    /// not an oversight: both `importRecording` and `importFromURL` call `libraryAcceptsChanges`
    /// before they copy or download anything, so this is unreachable while the library is degraded.
    /// A third caller added without that guard would reach the `upsert` below, which `MeetingStore`
    /// silently refuses — correctness is safe, but the user would have paid for the copy first. Guard
    /// any new caller up front, the way the two existing ones do (F187).
    @discardableResult
    func adoptImportedRecording(
        id: UUID,
        at fileURL: URL,
        title: String,
        source: MediaSource? = nil,
        referenceSegments: [TranscriptSegment]? = nil
    ) async -> UUID {
        let duration = await Self.loadDuration(of: fileURL)
        store.upsert(MeetingRecord(
            id: id,
            title: title,
            duration: duration,
            recordingPath: store.relativeRecordingPath(for: fileURL),
            status: .recorded,
            tags: Self.provenanceTags(for: source),
            source: source,
            referenceSegments: (referenceSegments?.isEmpty ?? true) ? nil : referenceSegments
        ))
        isImporting = false
        refreshRuntime()
        if isSelectedEngineInstalled {
            beginTranscription(id: id)
        } else {
            alertMessage = transcriptionUnavailableMessage
        }
        return id
    }

    /// Imports several files, enqueueing each for transcription. Returns the first meeting's id so
    /// the UI can navigate to it. Only a single-file import adopts the typed title.
    func importRecordings(from urls: [URL], title: String) async -> UUID? {
        // Guarded here as well as in `importRecording`, so a multi-file drop yields one message
        // instead of the same refusal repeated once per file (F187).
        guard libraryAcceptsChanges("Import") else { return nil }
        var firstID: UUID?
        for url in urls {
            let itemTitle = urls.count == 1 ? title : ""
            if let id = await importRecording(from: url, title: itemTitle), firstID == nil {
                firstID = id
            }
        }
        return firstID
    }

    nonisolated private static func copyImportedRecording(
        from sourceURL: URL,
        into directory: URL
    ) throws -> URL {
        let didAccess = sourceURL.startAccessingSecurityScopedResource()
        defer { if didAccess { sourceURL.stopAccessingSecurityScopedResource() } }

        try FileManager.default.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        let ext = sourceURL.pathExtension.isEmpty ? "wav" : sourceURL.pathExtension.lowercased()
        let destination = directory.appendingPathComponent("recording").appendingPathExtension(ext)
        if FileManager.default.fileExists(atPath: destination.path) {
            try FileManager.default.removeItem(at: destination)
        }
        try FileManager.default.copyItem(at: sourceURL, to: destination)
        return destination
    }

    nonisolated private static func loadDuration(of url: URL) async -> TimeInterval {
        let asset = AVURLAsset(url: url)
        guard let duration = try? await asset.load(.duration) else { return 0 }
        let seconds = duration.seconds
        return seconds.isFinite && seconds > 0 ? seconds : 0
    }

    /// Requests transcription for a meeting. If another transcription is already running, this one
    /// waits in the queue and starts automatically when the active one finishes.
    /// Meetings that have audio on disk but no transcript yet — the queue candidates (F185).
    var readyToTranscribeMeetings: [MeetingRecord] {
        store.meetings.filter { $0.status == .recorded && !$0.recordingPath.isEmpty }
    }

    /// Queues every ready meeting for transcription in one action (F185). Each goes through the normal
    /// `beginTranscription` path, so the engine/settings snapshot, the install guards, and the existing
    /// one-at-a-time queue all still apply — this only saves the user pressing Transcribe once per
    /// meeting, which is tedious after a bulk import.
    @discardableResult
    func beginTranscriptionForAllReady() -> Int {
        // Guarded here as well as in `beginTranscription`, so the returned count cannot claim work
        // that was never started — the caller reports this number to the user (F187).
        guard libraryAcceptsChanges("Transcription") else { return 0 }
        let ready = readyToTranscribeMeetings
        for meeting in ready {
            beginTranscription(id: meeting.id)
        }
        return ready.count
    }

    func beginTranscription(id: UUID) {
        guard !isInstallingRecognitionRuntime else {
            alertMessage = "Wait for the local recognition model installation to finish before transcribing."
            return
        }
        guard !isDictationActive() else {
            alertMessage = "Finish the current Quick Dictation before starting a meeting transcription."
            return
        }
        // A second-opinion or segment re-run is holding the engine; don't start a normal run atop it (F140).
        guard !isRunningAuxiliaryEngine else {
            alertMessage = "Finish the second-opinion or segment re-run before transcribing this meeting."
            return
        }
        // Must precede the enqueue: the model can run for minutes, and the `store.update` that stores
        // the transcript is refused while the library is read-only, so the whole run would be thrown
        // away in silence (F187).
        guard libraryAcceptsChanges("Transcription") else { return }
        refreshRuntime()
        let settings = MeetingTranscriptionSelection(
            engine: selectedEngine,
            language: selectedLanguage
        )
        let engineIsInstalled = settings.engine == .qwenBalanced
            ? isQwenInstalled
            : isRuntimeInstalled
        guard engineIsInstalled else {
            // F262: one message for all three gates. The per-engine "install this runtime" strings
            // are still right when nothing else is installed, but they cannot say "…and the other
            // engine you just installed is available", which is the case that confused users.
            alertMessage = TranscriptionEngineAvailability.unavailableMessage(
                selected: settings.engine,
                isWhisperInstalled: isRuntimeInstalled,
                isQwenInstalled: isQwenInstalled
            )
            return
        }
        guard transcription.enqueue(id) else { return }
        transcriptionSettings.snapshot(settings, for: id)
        pumpTranscriptionQueue()
    }

    /// Starts the next queued transcription if nothing is currently running.
    private func pumpTranscriptionQueue() {
        guard let next = transcription.startNext() else { return }
        // A pending id never has a live task (tasks exist only for the active job and are cleared
        // before finishActive), so this holds by construction — asserted rather than guarded, so a
        // future regression can never strand the active slot with no task.
        assert(transcriptionTasks[next] == nil, "pending transcription unexpectedly had a task")
        let task = Task {
            await performTranscription(id: next)
            transcriptionTasks[next] = nil
            transcriptionSettings.remove(next)
            transcription.finishActive()
            pumpTranscriptionQueue()
            if !hasActiveTranscription, !isRunningAuxiliaryEngine {
                warmIdleDictationRecognition()
            }
        }
        transcriptionTasks[next] = task
    }

    func cancelTranscription(id: UUID) {
        // A waiting job is just dropped; an active job is cancelled and its task completion frees
        // the slot and starts the next one.
        if transcription.isPending(id) {
            transcription.remove(id)
            transcriptionSettings.remove(id)
            return
        }
        if transcription.activeID == id {
            transcriptionTasks[id]?.cancel()
        }
    }


    /// Deletes a whole selection. Cancels each meeting's transcription first, exactly as
    /// `deleteMeeting(id:)` does, then removes them in a single index write.
    func deleteMeetings(ids: [UUID]) {
        for id in ids { cancelTranscription(id: id) }
        store.delete(ids: ids)
    }

    func summarize(id: UUID, style: SummaryStyle = .balanced, template: MeetingTemplate = .general) {
        guard summarizationTasks[id] == nil else { return }
        // Ahead of the per-engine preconditions, so a read-only library is reported as the real
        // blocker rather than a missing model or key — and, for Claude, before an API call is spent
        // on a summary the store would then refuse to save (F187).
        guard libraryAcceptsChanges("Summarization") else { return }
        let engine = summarizationEngine
        // Honest per-engine preconditions: local needs its model installed (offer to install rather
        // than fail); Claude needs a saved key. Neither uploads anything for `.local` (F164).
        let apiKey: String
        switch engine {
        case .local:
            guard isSummarizerModelInstalled() else {
                alertMessage = SummarizerError.modelNotInstalled.localizedDescription
                return
            }
            apiKey = ""
        case .claude:
            guard let key = KeychainStore.string(for: Self.claudeAPIKeyAccount) else {
                alertMessage = SummarizerError.missingAPIKey.localizedDescription
                return
            }
            apiKey = key
        }
        guard activeSummarizationID == nil else {
            alertMessage = "Another meeting is being summarized. Try again when it finishes."
            return
        }
        guard let meeting = store.meeting(id: id) else { return }

        activeSummarizationID = id
        let transcript = meeting.transcriptText
        let language = meeting.languageCode
        let task = Task {
            await performSummarization(
                id: id, engine: engine, apiKey: apiKey,
                transcript: transcript, language: language, style: style, template: template
            )
            summarizationTasks[id] = nil
            activeSummarizationID = nil
        }
        summarizationTasks[id] = task
    }

    func performSummarization(
        id: UUID,
        engine: SummarizationEngine,
        apiKey: String,
        transcript: String,
        language: String?,
        style: SummaryStyle,
        template: MeetingTemplate = .general
    ) async {
        let summarizer = makeSummarizer(engine, apiKey)
        // F249: a summarization model never reads the `MM:SS  ` prefix that
        // `TranscriptFormatter.timestamped` puts on every line for the transcript VIEW, but it pays
        // for them — measured with the local model's own tokenizer at 7,278 of 30,784 prompt tokens
        // (23.6%) on the largest meeting in this library, and 6,004 of 14,014 (42.8%) on another.
        // That is prefill time on the local engine and input-token cost on the Claude engine, spent
        // on digits the summary cannot use. Stripping happens here because `performSummarization` is
        // the one choke point every caller passes through on the way to `makeSummarizer`, so a new
        // entry point cannot skip it.
        //
        // Only when timed segments actually back the text. Without them a leading clock-like token
        // ("3:00 PM", or a standup moved to "12:30") is prose the user typed, not a line prefix —
        // the same rule `TranscriptExporter.render` already applies for `.plainText` (F42). This
        // read is deliberately separate from the F177 one below, which stays after the await so its
        // evidence resolution keeps reading the segments as they are when it runs.
        let promptSegments = store.meeting(id: id)?.segments ?? []
        let prompt = promptSegments.isEmpty
            ? transcript
            : TranscriptFormatter.stripTimestamps(transcript)
        do {
            let summary = try await summarizer.summarize(
                transcript: prompt, language: language, style: style, template: template
            )
            // F177: link each action item to its best supporting transcript segment (quote + timestamp)
            // locally, from the stored segments — no extra model call, nothing leaves this Mac.
            let segments = store.meeting(id: id)?.segments ?? []
            var resolved = summary
            resolved.actionItems = ActionItemEvidence.resolved(summary.actionItems, segments: segments)
            store.update(id: id) { meeting in
                // F307: `$0.summary = resolved` replaced the whole struct, and `ActionItem` holds
                // three fields the model never produces and the user does — `done`, `owner`, `due`,
                // the last two documented "Optional, user-entered". So re-summarizing to try a
                // different style or template, which is the reason those controls exist, cleared
                // every tick and every owner. Nothing warned and nothing failed.
                //
                // The previous items are read HERE rather than before the await: this runs after a
                // model call that takes seconds, and the user can tick something off while it does.
                // Reading them earlier would merge against a stale list and lose exactly the edit
                // they just made.
                var merged = resolved
                merged.actionItems = ActionItemMerge.carryingUserEdits(
                    from: meeting.summary?.actionItems ?? [], onto: resolved.actionItems
                )
                meeting.summary = merged
            }
        } catch is CancellationError {
            // The user cancelled (or the app is tearing down); leave the meeting unchanged, no alert.
        } catch {
            alertMessage = error.localizedDescription
        }
    }

    /// Edits one action item on a meeting's summary — its done state, owner, or due — and persists the
    /// change to the index (F177). An out-of-range index or a meeting without a summary is a safe no-op.
    func updateActionItem(at index: Int, for id: UUID, _ mutation: (inout ActionItem) -> Void) {
        store.update(id: id) { record in
            guard record.summary != nil,
                  record.summary!.actionItems.indices.contains(index) else { return }
            mutation(&record.summary!.actionItems[index])
        }
    }

    /// Proposed spelling corrections toward the user's vocabulary for a meeting's transcript (F82).
    /// Read-only — computes over the stored segments; the user reviews before any apply.
    func glossaryCorrections(for id: UUID) -> [GlossaryCorrection] {
        guard let meeting = store.meeting(id: id) else { return [] }
        // Local matching, not a prompt: it must see EVERY stored term, so it stays on the full list (F187).
        return GlossaryCorrector.corrections(vocabulary: store.vocabulary, segments: meeting.segments)
    }

    /// Proposed corrections from the user's exact `heard → preferred` replacement rules (F179).
    /// Read-only — computes over the stored segments; the proposals flow through the same F82 review
    /// sheet + `applyGlossaryCorrections` apply path, and the recording is never opened.
    func replacementRuleCorrections(for id: UUID) -> [GlossaryCorrection] {
        guard let meeting = store.meeting(id: id) else { return [] }
        return ReplacementRuleMatcher.corrections(rules: store.replacementRules, segments: meeting.segments)
    }

    /// Cited cross-meeting retrieval (F180): rank transcript segments across the completed meetings in
    /// `scope` against `query`, returning citations (meeting + timestamp + snippet). Local-only,
    /// transcript-only — the tested `MeetingScopeResolver` + `MeetingRetrieval` do the work; this thin
    /// adapter just gathers the in-scope meetings from the store and hands their segments across.
    func askMeetings(query: String, scope: MeetingScope, limit: Int = 10) -> [CitedResult] {
        let inScope = store.meetings.filter { meeting in
            MeetingScopeResolver.inScope(
                tags: meeting.tags ?? [],
                isCompleted: meeting.status == .completed,
                scope: scope
            )
        }
        let searchable = inScope.map { meeting in
            SearchableMeeting(
                id: meeting.id,
                title: meeting.title,
                segments: meeting.segments.enumerated().map { index, segment in
                    SearchableSegment(index: index, start: segment.start, text: segment.text)
                }
            )
        }
        return MeetingRetrieval.rank(query: query, in: searchable, limit: limit)
    }

    // MARK: - Ask Meetings: a written answer (F182)

    /// How many of the top passages ground an answer. Five keeps the prompt small enough to answer
    /// in a few seconds and is as many citations as three sentences can carry.
    static let answerPassageLimit = 5

    /// Runs the on-device model. Injectable so the decision around it is tested without a model.
    var meetingAnswerRunner: @Sendable (_ question: String, _ passages: [CitedResult]) async throws -> String = {
        try await LocalSummarizer().answerText(question: $0, passages: $1)
    }

    @Published private(set) var isAnsweringMeetingsQuestion = false

    /// Whether Ask Meetings can offer a written answer right now: the local model is installed and
    /// nothing else that loads a model is running (one 5 GB model in memory at a time).
    var canWriteMeetingAnswer: Bool {
        isSummarizerInstalled && !isAnsweringMeetingsQuestion && !isSummarizing
            && !isProposingCorrections && !hasActiveTranscription && !isRunningAuxiliaryEngine
    }

    /// Writes an answer from the top passages, or says why there is none (F182).
    ///
    /// Read-only: nothing is saved, so a read-only library can still ask. A thrown error and a
    /// refusal both leave the user exactly where they were — looking at the passages.
    func writeMeetingAnswer(question: String, passages: [CitedResult]) async -> MeetingAnswerPolicy.Outcome? {
        guard canWriteMeetingAnswer, !passages.isEmpty else { return nil }
        isAnsweringMeetingsQuestion = true
        defer { isAnsweringMeetingsQuestion = false }
        let grounding = Array(passages.prefix(Self.answerPassageLimit))
        do {
            let raw = try await meetingAnswerRunner(question, grounding)
            return MeetingAnswerPolicy.evaluate(
                raw, question: question, passages: grounding, protectedTerms: store.vocabulary
            )
        } catch is CancellationError {
            return nil
        } catch {
            alertMessage = "The on-device model could not write an answer: \(error.localizedDescription)"
            return nil
        }
    }

    /// Applies the user-accepted corrections to a meeting's transcript, rebuilding the timestamped
    /// text from the corrected segments. Skipped when the transcript was hand-edited (segment-derived
    /// text no longer matches what's shown). The recording is never opened (F82).
    func applyGlossaryCorrections(_ corrections: [GlossaryCorrection], to id: UUID) {
        guard let meeting = store.meeting(id: id), !meeting.isTranscriptEdited, !corrections.isEmpty else { return }
        let corrected = GlossaryCorrector.apply(corrections, to: meeting.segments)
        store.update(id: id) {
            $0.segments = corrected
            $0.transcriptText = TranscriptFormatter.timestamped(corrected)
        }
    }

    /// Proposes on-device LLM corrections for a meeting's transcript, guided by the business vocabulary
    /// and an optional reference document (F165). Read-only: returns reviewable `GlossaryCorrection`s
    /// that flow through the same F82 review sheet + `applyGlossaryCorrections` apply path — nothing is
    /// applied here, and the recording is never opened. Skipped on a hand-edited transcript so proposals
    /// can't be computed against text that no longer matches the segments.
    func proposeLocalCorrections(for id: UUID, reference: String? = nil) async -> [GlossaryCorrection] {
        guard !isProposingCorrections else { return [] }
        guard isCorrectionModelInstalled() else {
            alertMessage = "Install or update the local model in Settings to use AI transcript correction."
            return []
        }
        guard let meeting = store.meeting(id: id) else { return [] }
        guard !meeting.isTranscriptEdited else {
            alertMessage = "This transcript was hand-edited, so AI correction is unavailable — it would not match your edits."
            return []
        }
        // Feed the plain segment text (no timestamps) so a proposed `from` span matches a segment.
        let plainText = meeting.segments.map(\.text).joined(separator: "\n")
        // Goes into a model prompt, so it takes the capped view rather than the full stored list (F187).
        let vocabulary = store.promptVocabulary
        proposingCorrectionsID = id
        defer { proposingCorrectionsID = nil }
        do {
            let corrections = try await proposeTranscriptCorrections(plainText, vocabulary, reference)
            return TranscriptCorrection.glossaryCorrections(from: corrections, segments: meeting.segments)
        } catch is CancellationError {
            return []
        } catch {
            alertMessage = error.localizedDescription
            return []
        }
    }

    /// Whether the segments reconstruct the full text (by alphanumeric character count). Segments are
    /// derived from the text, so equal-or-greater coverage means no content is lost; a shortfall means
    /// the alignment was partial and the segment-derived text would drop content (F144).
    private static func segmentsCoverText(_ segments: [TranscriptSegment], _ fullText: String) -> Bool {
        func alphanumericCount(_ s: String) -> Int {
            s.unicodeScalars.reduce(0) { CharacterSet.alphanumerics.contains($1) ? $0 + 1 : $0 }
        }
        let full = alphanumericCount(fullText)
        guard full > 0 else { return true } // no text to lose
        return alphanumericCount(segments.map(\.text).joined()) >= full
    }

    /// Flush any pending debounced transcript/notes write immediately. Called from the app-lifecycle
    /// observers (termination, resign-active) so an edit made in the last debounce window is not lost on
    /// a normal quit — the editor's `.onDisappear` flush doesn't fire reliably on app termination (F138).
    func flushPendingWrites() {
        store.flushPendingEdits()
    }

    func recoverInterruptedTranscriptions() {
        for meeting in store.meetings where meeting.status == .processing {
            store.update(id: meeting.id) {
                $0.status = .recorded
                $0.errorMessage = "Local transcription was interrupted. Start it again; the recording is unchanged."
            }
        }
    }

    private func performTranscription(id: UUID) async {
        // The meeting may have been deleted while queued; that is not an error.
        guard let meeting = store.meeting(id: id),
              let settings = transcriptionSettings.selection(for: id) else {
            return
        }
        store.update(id: id) {
            $0.status = .processing
            $0.errorMessage = nil
        }

        do {
            let recordingURL = store.recordingURL(for: meeting)
            let result = try await executeEngine(settings, on: recordingURL) { progress in
                await self.apply(progress: progress, to: id)
            }
            apply(result: result, to: id, requestedLanguage: settings.language, engine: settings.engine)
        } catch is CancellationError {
            handleCancellation(id: id)
        } catch {
            handle(error: error, id: id)
        }
    }

    private func apply(progress: LocalTranscriptionProgress, to id: UUID) {
        transcriptionProgress[id] = progress
        // Persist the .processing transition once. Later progress ticks only move the in-memory
        // progress bar (transcriptionProgress isn't stored), so re-running the meeting index's
        // backup-validate + two atomic writes on every tick is pure waste.
        if store.meeting(id: id)?.status != .processing {
            store.update(id: id) { $0.status = .processing }
        }
    }

    /// Applies a completed transcription to the stored meeting. Exposed to `WhisperMeetTests` (not
    /// `private`) so the alignment-warning persistence hop is testable without a GUI (F30). The
    /// `requestedLanguage` is the engine snapshot's selected language, used for the
    /// "original language only" advisory (F32); it defaults to `.automatic`, which never flags.
    func apply(result: TranscriptionResult, to id: UUID, requestedLanguage: WhisperLanguage = .automatic, engine: MeetingTranscriptionEngine? = nil) {
        // Only use segment-derived (timestamped) text when the segments actually reconstruct the full
        // text; otherwise a partially-aligned result would drop content. Fall back to the complete
        // text and drop the incomplete segments so text and segments stay consistent (F144).
        let covers = !result.segments.isEmpty && Self.segmentsCoverText(result.segments, result.text)
        let effectiveSegments = covers ? result.segments : []
        store.update(id: id) {
            $0.status = .completed
            $0.transcriptText = effectiveSegments.isEmpty
                ? result.text
                : TranscriptFormatter.timestamped(effectiveSegments)
            $0.languageCode = result.languageCode
            // Revive the header confidence label from the quality review; nil (no claim) when the
            // transcript carries no scorable segments (F56).
            let quality = TranscriptQuality.review(effectiveSegments)
            $0.confidence = quality.isUnscored ? nil : quality.confidence
            $0.segments = effectiveSegments
            $0.errorMessage = nil
            // F273: `recoverySource` is deliberately NOT cleared here. Provenance is true of the
            // recording whatever happens to its transcript, and clearing `errorMessage` — which
            // used to be the only place it lived — is the whole defect that ticket reports.
            //
            // `staleTranscriptWarning` IS cleared, and the two point opposite ways on purpose.
            // F267 sets it when a rebuild leaves an old transcript describing audio that no longer
            // exists; a fresh transcript describes the audio that is actually there, so keeping the
            // notice would be a false claim in the other direction. My own F267 comment promised
            // this and nothing did it until now.
            $0.staleTranscriptWarning = nil
            // Carry the alignment warning onto the meeting so the detail view can explain why a
            // Qwen transcript has no seekable timestamps, instead of dropping it silently (F30).
            $0.alignmentWarning = result.alignmentWarning
            // "Original language only" advisory: if the user pinned a language and the transcript's
            // dominant script disagrees, surface it rather than trusting the model blindly. Advisory
            // only — the transcript and recording are untouched (F32).
            $0.languageWarning = LanguageConsistency.mismatchWarning(
                requested: requestedLanguage,
                transcript: result.text
            )
            // Freshly produced text is already final; never rebuild it from segments later.
            $0.transcriptNormalized = true
            // Record which engine produced this transcript so a later "second opinion" runs the genuine
            // other engine regardless of current Settings (F142).
            if let engine { $0.transcriptionEngine = engine }
        }
        transcriptionProgress[id] = nil
        postTranscriptionNotification(
            title: store.meeting(id: id)?.title ?? "Meeting",
            outcome: .completed,
            segmentCount: result.segments.count
        )
    }

    /// Local OS notification when a transcription finishes while the app is backgrounded. Reuses the
    /// dictation notification pattern; the body carries only the meeting title + outcome, never
    /// transcript content (F57). No-op when frontmost or on cancellation.
    private func postTranscriptionNotification(
        title: String,
        outcome: TranscriptionOutcome,
        segmentCount: Int
    ) {
        // `NSApp` is always set in the running app but nil in a headless test process; binding it
        // (rather than force-unwrapping) keeps production behaviour identical while letting
        // WhisperMeetTests drive `apply(result:)` without a GUI (a prerequisite for the F30 test).
        guard let app = NSApp else { return }
        guard TranscriptionNotification.shouldNotify(outcome: outcome, appIsActive: app.isActive),
              let content = TranscriptionNotification.content(
                title: title, outcome: outcome, segmentCount: segmentCount
              ) else { return }
        Self.deliverNotification(title: content.title, body: content.body)
    }

    private func handleCancellation(id: UUID) {
        store.update(id: id) {
            $0.status = .recorded
            $0.errorMessage = "Local transcription was cancelled. The recording is unchanged."
        }
        transcriptionProgress[id] = nil
    }

    /// Privacy-safe diagnostics JSON built from the live library (F86 → delivers F70). The mapping and
    /// its exclusion guarantee (never transcript, summary, vocabulary, title, or paths) are unit-tested
    /// in `DiagnosticsExport`; this hop only supplies the live store and real recording byte sizes.
    func diagnosticsJSON() -> String {
        let input = DiagnosticsExport.input(
            meetings: store.meetings,
            // Diagnostics report what is actually stored (a count, never the terms), so this is the
            // full list — the prompt-capped view would understate the library (F187).
            vocabulary: store.vocabulary,
            recordingBytes: { meeting in
                let path = store.recordingURL(for: meeting).path
                let size = try? FileManager.default.attributesOfItem(atPath: path)[.size]
                return (size as? NSNumber)?.int64Value
            }
        )
        return DiagnosticsBundleBuilder.json(input)
    }

    private func handle(error: Error, id: UUID) {
        // Classify the failure so the message tells the user what to actually do (install / re-import /
        // retry) instead of a blind "Transcribe" retry (F68).
        let category = TranscriptionFailureClassifier.classify(error)
        var message = category.explanation
        // Keep the underlying detail (e.g. a subprocess message) for transient/subprocess failures.
        if category.action == .retry {
            let detail = error.localizedDescription
            if !detail.isEmpty { message += " (\(detail))" }
            let recordingIsSafe = store.meeting(id: id).map {
                FileManager.default.fileExists(atPath: store.recordingURL(for: $0).path)
            } ?? false
            if recordingIsSafe { message += " The recording is safe on this Mac." }
        }
        store.update(id: id) {
            $0.status = .failed
            $0.errorMessage = message
        }
        transcriptionProgress[id] = nil
        alertMessage = message
        postTranscriptionNotification(
            title: store.meeting(id: id)?.title ?? "Meeting",
            outcome: .failed,
            segmentCount: 0
        )
    }

    private func runInstaller(scriptURL: URL, runtimeDirectory: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            try FileManager.default.createDirectory(
                at: runtimeDirectory,
                withIntermediateDirectories: true
            )
            let logURL = runtimeDirectory.appendingPathComponent("install.log")
            try Data().write(to: logURL, options: .atomic)
            let handle = try FileHandle(forWritingTo: logURL)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = [scriptURL.path, runtimeDirectory.path]
            process.standardOutput = handle
            process.standardError = handle
            try process.run()
            process.waitUntilExit()
            try? handle.close()
            let log = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
            guard process.terminationStatus == 0 else {
                let tail = String(log.suffix(2_000))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw LocalWhisperError.processFailed(
                    tail.isEmpty ? "The installer exited with status \(process.terminationStatus)." : tail
                )
            }
        }.value
    }

    private func runQwenInstaller(scriptURL: URL, runtimeDirectory: URL) async throws {
        try await Task.detached(priority: .userInitiated) {
            let parent = runtimeDirectory.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: parent,
                withIntermediateDirectories: true
            )
            let logURL = parent.appendingPathComponent("qwen-install.log")
            try Data().write(to: logURL, options: .atomic)
            let handle = try FileHandle(forWritingTo: logURL)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = [scriptURL.path, runtimeDirectory.path]
            process.standardOutput = handle
            process.standardError = handle
            try process.run()
            process.waitUntilExit()
            try? handle.close()
            let log = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
            guard process.terminationStatus == 0 else {
                let tail = String(log.suffix(2_000))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw QwenASRError.processFailed(
                    tail.isEmpty
                        ? "The installer exited with status \(process.terminationStatus)."
                        : tail
                )
            }
        }.value
    }

    /// Runs the bundled `setup-local-summarizer.sh`, exporting the RAM-chosen model repository so the
    /// script downloads the matching pinned model. Mirrors `runQwenInstaller` (F164).
    private func runSummarizerInstaller(
        scriptURL: URL,
        runtimeDirectory: URL,
        repository: String
    ) async throws {
        try await Task.detached(priority: .userInitiated) {
            let parent = runtimeDirectory.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: parent,
                withIntermediateDirectories: true
            )
            let logURL = parent.appendingPathComponent("summarizer-install.log")
            try Data().write(to: logURL, options: .atomic)
            let handle = try FileHandle(forWritingTo: logURL)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = [scriptURL.path, runtimeDirectory.path]
            var environment = ProcessInfo.processInfo.environment
            environment["SUMMARIZER_REPOSITORY"] = repository
            process.environment = environment
            process.standardOutput = handle
            process.standardError = handle
            try process.run()
            process.waitUntilExit()
            try? handle.close()
            let log = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
            guard process.terminationStatus == 0 else {
                let tail = String(log.suffix(2_000))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw SummarizerError.helperFailed(
                    tail.isEmpty
                        ? "The installer exited with status \(process.terminationStatus)."
                        : tail
                )
            }
        }.value
    }

    /// Runs the bundled `setup-speaker-diarization.sh` over the runtime directory, logging to
    /// `diarization-install.log` beside the other runtimes' logs. Mirrors `runQwenInstaller` (F219);
    /// a non-zero exit carries the log tail so the alert says what actually went wrong. Note that a
    /// clean exit is still not proof of an install — `installSpeakerDiarization` re-probes the disk.
    nonisolated static func spawnDiarizationInstaller(
        scriptURL: URL,
        runtimeDirectory: URL
    ) async throws {
        try await Task.detached(priority: .userInitiated) {
            let parent = runtimeDirectory.deletingLastPathComponent()
            try FileManager.default.createDirectory(
                at: parent,
                withIntermediateDirectories: true
            )
            let logURL = parent.appendingPathComponent("diarization-install.log")
            try Data().write(to: logURL, options: .atomic)
            let handle = try FileHandle(forWritingTo: logURL)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/bin/zsh")
            process.arguments = [scriptURL.path, runtimeDirectory.path]
            process.standardOutput = handle
            process.standardError = handle
            try process.run()
            process.waitUntilExit()
            try? handle.close()
            let log = (try? String(contentsOf: logURL, encoding: .utf8)) ?? ""
            guard process.terminationStatus == 0 else {
                let tail = String(log.suffix(2_000))
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                throw LocalDiarizationError.processFailed(
                    tail.isEmpty
                        ? "The installer exited with status \(process.terminationStatus)."
                        : tail
                )
            }
        }.value
    }
}

// MARK: - Library integrity sweep (F83 — wires the tested F66 core to the running app)

extension AppModel {
    /// One meeting's read-only integrity result. Advisory only — the audio is never repaired.
    struct LibraryIntegrityResult: Sendable, Equatable {
        let meeting: MeetingRecord
        let findings: [IntegrityFinding]
    }

    /// Read-only sweep of the whole meeting library. Reachable from launch (`performStartupRecovery`)
    /// and Settings ("Verify Library"). Flags missing/truncated/inconsistent audio; never touches it.
    /// The footnote for controls disabled because the library is read-only, or nil when it is not
    /// (F194). The `.disabled` clauses and this string are read from one place so a control can
    /// never be greyed out without the menu saying why.
    var libraryReadOnlyFootnote: String? {
        store.isDegraded ? ReadOnlyLibraryNotice.menuFootnote : nil
    }

    /// Offers the retained index generations for review — the way out of a read-only library.
    ///
    /// `ReadOnlyLibraryNotice` tells the user to "resolve recovery" in four places; until F193 there
    /// was nothing in the app that could. Reads and reports only: listing generations is safe while
    /// degraded because it touches nothing.
    /// One meeting's pending "rebuild from source audio" offer, with the title so the confirmation
    /// can name what it is about to change (F267).
    struct SourceRebuildRequest: Equatable {
        let meetingID: UUID
        let meetingTitle: String
        let offer: SourceRebuild.Offer
    }

    /// Whether the meeting-detail view should show the rebuild action at all. A pure read.
    func canRebuildFromSourceTracks(id: UUID) -> Bool {
        sourceRebuildOffer(for: id) != nil
    }

    private func sourceRebuildOffer(for id: UUID) -> SourceRebuild.Offer? {
        guard let meeting = store.meeting(id: id), !meeting.recordingPath.isEmpty else { return nil }
        let directory = store.recordingURL(for: meeting).deletingLastPathComponent()
        return SourceRebuild.offer(in: directory, currentDuration: meeting.duration)
    }

    /// Offers a rebuild for review. Never rebuilds anything itself (F267, in F193's shape).
    func requestSourceRebuild(id: UUID) {
        guard !store.isDegraded else {
            // The F187 read-only promise covers this too: a library we could not fully read is not
            // one to start rewriting recordings in.
            alertMessage = ReadOnlyLibraryNotice.lead
            return
        }
        guard let meeting = store.meeting(id: id) else { return }
        guard let offer = sourceRebuildOffer(for: id) else {
            // Explained rather than silently absent — the user asked for something, and the two
            // reasons are different enough to be worth distinguishing.
            let directory = store.recordingURL(for: meeting).deletingLastPathComponent()
            alertMessage = FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("meeting.wav").path
            )
                ? "This meeting's recording finished normally, so there is nothing to rebuild. Replacing it with a rebuild of the raw tracks would leave the finished recording on disk with nothing pointing at it."
                : "The original microphone and system tracks for this meeting are no longer in its folder, so it cannot be rebuilt. The recording you have is unchanged."
            return
        }
        pendingSourceRebuild = SourceRebuildRequest(
            meetingID: id,
            meetingTitle: meeting.title,
            offer: offer
        )
    }

    /// Performs the reviewed rebuild. Does nothing at all unless `confirmed` is true (F267).
    ///
    /// The unconfirmed call is the seam the confirmation dialog hangs on, exactly as
    /// `recoverLibrary(from:confirmed:)` and `importFromURL(_:confirmedLongDuration:)` do — and it
    /// leaves the offer standing, because the user has not answered yet.
    ///
    /// What changes is the audio's own facts: duration, and the truncation notice, which the new
    /// rebuild either reproduces or clears. **Nothing the user wrote is touched** — F148 #1, and
    /// the reason this action is safe enough to offer at all.
    func performSourceRebuild(confirmed: Bool) {
        guard confirmed, let request = pendingSourceRebuild else { return }
        do {
            guard let rebuilt = try SourceRebuild.rebuild(request.offer) else {
                alertMessage = "The source tracks for this meeting held no audio to rebuild. Nothing was changed."
                pendingSourceRebuild = nil
                return
            }
            let previousDuration = store.meeting(id: request.meetingID)?.duration ?? 0
            store.update(id: request.meetingID) { meeting in
                meeting.duration = rebuilt.duration
                meeting.recoveryWarning = Self.recoveryWarning(for: rebuilt)
                // A second rebuild is still a rebuild: re-declare it, so a meeting whose first
                // recovery predates F273 gains the provenance rather than staying silent (F273).
                meeting.recoverySource = rebuilt.source.rawValue
                // F281's rule in a new case. The transcript describes audio that has been
                // superseded; it is kept because blanking it is forbidden and would be the greater
                // harm, so the meeting says so instead. Only when there IS a transcript — and
                // `staleTranscriptNotice` answers nil when the audio did not actually move, since
                // a rebuild that reproduces the same thing has nothing to declare.
                if !meeting.transcriptText.isEmpty,
                   let notice = Self.staleTranscriptNotice(
                       previous: previousDuration,
                       rebuilt: rebuilt.duration,
                       previousAudioKept: request.offer.wouldSupersedeRecording
                   ) {
                    meeting.staleTranscriptWarning = notice
                }
            }
            pendingSourceRebuild = nil
            var message = "The recording was rebuilt from its source tracks."
            if request.offer.wouldSupersedeRecording {
                message += " The previous version is kept in this meeting's folder."
            }
            if let warning = Self.recoveryWarning(for: rebuilt) { message += " \(warning)" }
            alertMessage = message
        } catch {
            // The offer stays up, as F193 leaves `pendingLibraryRecovery` populated: the failure
            // may be specific to this attempt, and `SourceRebuild` has already put the previous
            // recording back, so trying again is safe.
            alertMessage = "The recording could not be rebuilt, and nothing was changed. The original microphone and system tracks are still in this meeting's folder. \(error.localizedDescription)"
        }
    }

    /// What a rebuilt meeting says about the transcript it already had, or nil when the audio did
    /// not move (F267, F309).
    ///
    /// **The direction decides the advice.** A longer rebuild leaves the transcript covering only
    /// a prefix, and transcribing again is the repair. A shorter one is the opposite case: the
    /// transcript covers more than the recording now does, so it is the more complete artefact and
    /// transcribing again would destroy the better of the two. Until F309 one sentence served both
    /// — `abs()` admitted either direction and the wording admitted one — so the shorter case was
    /// told the reverse of the truth and advised to do the destructive thing.
    ///
    /// `previousAudioKept` is `Offer.wouldSupersedeRecording`: whether there was an earlier
    /// recording on disk for the rebuild to move aside. When there was not, nothing in the folder
    /// covers the transcript's tail, and saying the earlier audio "is kept" would be a new false
    /// sentence in the place an old one was just removed.
    static func staleTranscriptNotice(
        previous: TimeInterval, rebuilt: TimeInterval, previousAudioKept: Bool
    ) -> String? {
        guard abs(rebuilt - previous) > 0.05 else { return nil }
        let was = TranscriptFormatter.clock(previous)
        let now = TranscriptFormatter.clock(rebuilt)
        if rebuilt > previous {
            return "This transcript was made from an earlier, \(was) version of the audio, which has since been rebuilt to \(now). Its text and timestamps do not cover the whole recording — transcribe again to replace it."
        }
        let lead = "This transcript was made from an earlier, \(was) version of the audio. The recording has since been rebuilt from its source tracks and is now \(now), so the transcript covers more than the recording does. "
        return previousAudioKept
            ? lead + "The earlier audio is kept in this meeting's folder. Transcribing again would replace this transcript with a shorter one."
            : lead + "The earlier audio is no longer in this meeting's folder, so this transcript is the only record of what was said after \(now). Transcribing again would replace it with a shorter one."
    }

    /// The rebuild confirmation's body (F267).
    ///
    /// Here rather than in the view, and static, because the view that shows it is `private` and
    /// so unreachable from tests. This copy makes three promises the user is relying on — what
    /// changes, what is kept, and what it costs — and a promise nothing asserts is a promise that
    /// drifts. `severelyTruncatedRecoveryMessage` sits here for the same reason.
    static func rebuildConfirmationMessage(_ request: AppModel.SourceRebuildRequest) -> String {
        let current = TranscriptFormatter.clock(request.offer.currentDurationSeconds)
        let available = TranscriptFormatter.clock(request.offer.expectedDurationSeconds)
        var text = "\(request.meetingTitle) currently has \(current) of audio. "
            + "Its source tracks hold up to \(available). "
        if request.offer.wouldSupersedeRecording {
            text += "The current audio is kept in this meeting's folder rather than replaced, so "
                + "the folder will grow by about one more copy of the recording. "
        }
        text += "Your title, transcript, notes, tags and summary are not changed."
        return text
    }

    /// Dismisses a pending rebuild offer without rebuilding anything.
    func cancelSourceRebuild() {
        pendingSourceRebuild = nil
    }

    func requestLibraryRecovery() {
        guard store.isDegraded else {
            // Rolling an older index over a healthy library is data loss dressed as a repair, so it
            // is refused rather than offered. Say so, rather than presenting an empty sheet.
            alertMessage = """
                The meeting library is readable, so there is nothing to recover. \
                Restoring an earlier copy would discard newer meetings.
                """
            return
        }
        do {
            let generations = try store.indexGenerations()
            guard !generations.isEmpty else {
                // F289: with no earlier copy to restore, offer the rebuild from the recording
                // folders themselves — F191 slice E4, which was tested and reachable from nothing.
                // Here rather than a button of its own, because the two routes are alternatives
                // chosen by what is on disk, and this is the branch where the other one is not.
                // The proposal is shown before anything is written; a proposal of nothing falls
                // through to the message below, so an empty recovery is never offered as one.
                let proposal = try FolderRebuild.propose(in: store.rootDirectory)
                if proposal.isWorthApplying {
                    pendingFolderRebuild = proposal
                    return
                }
                // F252's dead end, and the message now names what the user actually still has.
                //
                // "Your recordings are untouched — see the documentation" is true and leaves them
                // believing their transcripts are gone with the index. They are not: every
                // meeting's transcript and summary is mirrored as `notes.md` beside its audio,
                // which is the entire reason F198 exists. The app knew something reassuring and
                // was not saying it — the same omission F281 is about, one screen over.
                alertMessage = """
                    \(ReadOnlyLibraryNotice.lead) No earlier copy of the index was retained, so it \
                    cannot be restored from inside WhisperMeet. Nothing has been deleted: each \
                    meeting's audio is still in its own folder inside the library, and its \
                    transcript and summary are in a notes.md file beside that audio. See Recovery \
                    in the documentation for the manual steps.
                    """
                return
            }
            pendingLibraryRecovery = generations
        } catch {
            alertMessage = """
                \(ReadOnlyLibraryNotice.lead) The retained copies could not be listed. \
                Your recordings are untouched. \(error.localizedDescription)
                """
        }
    }

    /// Restores one reviewed generation. Does nothing at all unless `confirmed` is true (F193).
    ///
    /// The unconfirmed call is not a no-op by accident — it is the seam the UI's confirmation dialog
    /// hangs on, in the same shape as `importFromURL(_:confirmedLongDuration:)`. Audio is never
    /// touched: this replaces an index, and the quarantined bytes of the damaged one stay on disk
    /// because the restore goes through the ordinary append-only write.
    func recoverLibrary(from generation: RetainedGeneration, confirmed: Bool) {
        guard confirmed else { return }
        // "User-reviewed" made structural rather than conventional (F193): only a generation this
        // model actually offered can be restored. Without this, a caller could restore one the user
        // never saw, which is the whole property the ticket asks for.
        guard pendingLibraryRecovery?.contains(generation) == true else { return }
        do {
            try store.restoreIndexGeneration(generation)
            pendingLibraryRecovery = nil
            if !store.isDegraded {
                // Resume the work `performStartupRecovery` skipped while the library was read-only
                // (F193). It sets `didPerformStartupRecovery` BEFORE its degraded early-return, so
                // without this reset the notes-sidecar backfill and — the one that matters — the
                // interrupted-recording rebuild never run in this session, and nothing tells the
                // user to relaunch. `orphanedRecordings()` also returns [] while degraded, so the
                // rebuild could not have run earlier even if it had been reached. Every step in
                // that method is idempotent, so re-running it is safe; the store has just cleared
                // `startupRecoveryMessages`, so it reports what the reload found, not the stale
                // read-only notice.
                didPerformStartupRecovery = false
                Task { await performStartupRecovery() }
            }
            if store.isDegraded {
                // The index came back but the library is still not writable, so another persisted
                // store is damaged too. Never report success in that case — the F187 honesty rule.
                alertMessage = """
                    The meeting index was restored, but WhisperMeet still could not fully read its \
                    library, so it stays in read-only mode. Your recordings are untouched.
                    """
            }
        } catch {
            // `pendingLibraryRecovery` is deliberately left populated: a restore can fail for a
            // reason specific to one generation (unreadable bytes, a fingerprint mismatch), so the
            // user keeps the list and can try an older one without starting over.
            alertMessage = """
                The meeting index could not be restored. Nothing was changed and your recordings are \
                untouched. \(error.localizedDescription)
                """
        }
    }

    /// Dismisses a pending recovery offer without restoring anything.
    func cancelLibraryRecovery() {
        pendingLibraryRecovery = nil
    }

    /// Applies the reviewed folder rebuild. Does nothing at all unless `confirmed` is true (F289).
    ///
    /// F193's shape exactly, for F193's reasons: the unconfirmed call is the seam the confirmation
    /// hangs on, and only a proposal this model produced and showed can be applied, so a caller
    /// cannot rebuild what the user never reviewed. Audio is never touched — this writes an index,
    /// through the append-only path, and the damaged one stays on disk.
    func rebuildLibraryFromFolders(confirmed: Bool) {
        guard confirmed, let proposal = pendingFolderRebuild else { return }
        do {
            try store.installRebuiltIndex(proposal.meetings)
            pendingFolderRebuild = nil
            if !store.isDegraded {
                // As `recoverLibrary` does: resume the work startup skipped while read-only.
                didPerformStartupRecovery = false
                Task { await performStartupRecovery() }
            } else {
                // The index came back but another persisted store is still damaged. Never report
                // success in that case — the F187 honesty rule.
                alertMessage = """
                    The meeting index was rebuilt from the recording folders, but WhisperMeet still \
                    could not fully read its library, so it stays in read-only mode. Your recordings \
                    are untouched.
                    """
            }
        } catch {
            // The offer stays up, as F193 leaves `pendingLibraryRecovery` populated: the failure
            // may be specific to this attempt, and nothing was changed.
            alertMessage = """
                The meeting index could not be rebuilt. Nothing was changed and your recordings are \
                untouched. \(error.localizedDescription)
                """
        }
    }

    /// Dismisses a pending folder rebuild without writing anything.
    func cancelFolderRebuild() {
        pendingFolderRebuild = nil
    }

    /// The rebuild confirmation's body (F289). Static and here, as `rebuildConfirmationMessage` is,
    /// because the view is private and a promise nothing asserts is a promise that drifts. It
    /// leads with what the rebuild cannot bring back — F193's constraint — so the user commits
    /// knowing it rather than discovering it afterwards.
    static func folderRebuildMessage(_ proposal: FolderRebuild.Proposal) -> String {
        var text = "No earlier copy of the index was kept, but \(proposal.meetings.count) meeting"
            + (proposal.meetings.count == 1 ? "" : "s")
            + " can be rebuilt from the recording folders. "
        if proposal.deferredToRecovery > 0 {
            text += "\(proposal.deferredToRecovery) interrupted recording"
                + (proposal.deferredToRecovery == 1 ? " is" : "s are")
                + " left for the usual recovery afterwards. "
        }
        text += "Your recordings are never changed by this, and the damaged index is kept so the rebuild can be undone.\n\n"
        text += proposal.cannotRestore.joined(separator: "\n")
        return text
    }

    func verifyLibraryIntegrity() -> [LibraryIntegrityResult] {
        var results: [LibraryIntegrityResult] = []
        for meeting in store.meetings {
            guard let descriptor = integrityDescriptor(for: meeting) else { continue }
            let findings = checkMeetingIntegrity(descriptor)
            if !findings.isEmpty {
                results.append(LibraryIntegrityResult(meeting: meeting, findings: findings))
            }
        }
        return results
    }

    /// Runs the sweep and surfaces any findings through the shared alert. The thin action behind the
    /// Settings "Verify Library" button (F83). Read-only — it reports, never repairs.
    func verifyLibrary() {
        // The check reads the very index whose health is in question (F194). On a library that
        // failed to decode it finds no meetings, therefore no problems, and would report a clean
        // result — the most reassuring possible answer at the least reassuring possible moment.
        guard !store.isDegraded else {
            alertMessage = ReadOnlyLibraryNotice.integrityCheckDeclined
            return
        }
        let messages = Self.integrityMessages(verifyLibraryIntegrity())
        if messages.isEmpty {
            alertMessage = "Library check complete — no audio problems were found."
        } else {
            let header = "Library check found problems with \(messages.count) recording"
                + (messages.count == 1 ? "" : "s")
                + ". The recordings were not changed."
            alertMessage = ([header] + messages).joined(separator: "\n\n")
        }
    }

    /// Builds a read-only integrity descriptor for a meeting from its on-disk files. Returns nil for
    /// a meeting with no recording (nothing to check).
    private func integrityDescriptor(for meeting: MeetingRecord) -> MeetingIntegrityDescriptor? {
        guard !meeting.recordingPath.isEmpty else { return nil }
        let recordingURL = store.recordingURL(for: meeting)
        let directory = recordingURL.deletingLastPathComponent()
        return MeetingIntegrityDescriptor(
            recordingURL: recordingURL,
            sourceTracks: Self.sourceTracks(in: directory),
            indexDurationSeconds: meeting.duration > 0 ? meeting.duration : nil
        )
    }

    /// Maps integrity results into user-facing advisory lines. Presentation only.
    static func integrityMessages(_ results: [LibraryIntegrityResult]) -> [String] {
        results.flatMap { result in
            result.findings.map { describe($0, title: result.meeting.title) }
        }
    }

    /// Decodes `source-tracks.json` (or the recovery variant) into descriptor source tracks. A
    /// missing or unreadable manifest yields no track checks — an imported meeting may have none.
    static func sourceTracks(in directory: URL) -> [MeetingIntegrityDescriptor.SourceTrack] {
        struct Manifest: Decodable {
            struct Track: Decodable {
                let file: String
                let frameCount: Int64
            }
            let systemAudio: Track
            let microphoneAudio: Track
        }
        for name in ["source-tracks.json", "source-tracks.recovered.json"] {
            let url = directory.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let manifest = try? JSONDecoder().decode(Manifest.self, from: data) else { continue }
            return [
                .init(
                    name: "system",
                    url: directory.appendingPathComponent(manifest.systemAudio.file),
                    expectedFrameCount: manifest.systemAudio.frameCount
                ),
                .init(
                    name: "microphone",
                    url: directory.appendingPathComponent(manifest.microphoneAudio.file),
                    expectedFrameCount: manifest.microphoneAudio.frameCount
                ),
            ]
        }
        return []
    }

    private static func describe(_ finding: IntegrityFinding, title: String) -> String {
        switch finding {
        case .recordingMissing:
            return "“\(title)”: the recording file is missing from disk. The meeting entry was kept; its audio could not be found."
        case .recordingEmpty:
            return "“\(title)”: the recording file is empty."
        case .wavHeaderUnreadable:
            return "“\(title)”: the recording’s audio header could not be read."
        case let .wavTruncated(declaredBytes, actualBytes):
            return "“\(title)”: the recording looks truncated — its header expects \(declaredBytes) bytes but only \(actualBytes) are present."
        case let .sourceTrackFrameMismatch(track, expectedFrames, actualFrames):
            return "“\(title)”: the \(track) source track is shorter than recorded (\(actualFrames) of \(expectedFrames) frames)."
        case let .durationInconsistent(headerSeconds, indexSeconds):
            return "“\(title)”: the recording’s length (\(String(format: "%.1f", headerSeconds))s) doesn’t match its saved duration (\(String(format: "%.1f", indexSeconds))s)."
        }
    }
}

// MARK: - Interrupted Qwen-install reclaim (F33 — wires the tested setup-qwen-asr.sh recovery to launch)

extension AppModel {
    /// Reclaim an interrupted Qwen install on launch — but only when orphaned install artifacts
    /// actually exist under the runtime parent, so a clean launch (or a Mac that never installed Qwen)
    /// spawns nothing. A force-quit mid-install can strand the previous ~4 GB runtime in a
    /// `.Qwen3ASR-backup-*` dir while `Qwen3ASR/` is gone and Qwen reports "not installed"; the tested
    /// recovery-only reclaim restores it (or clears an incomplete one) without a manual reinstall
    /// (F33). Returns whether the reclaim was run. The reclaim itself is the injected
    /// `runQwenInstallRecovery` seam, so this hop is headless-testable without spawning a process.
    @discardableResult
    func reclaimInterruptedQwenInstall(
        runtimeDirectory: URL = QwenASRRuntime.managedDirectory()
    ) async -> Bool {
        let parent = runtimeDirectory.deletingLastPathComponent()
        guard Self.hasOrphanedQwenInstallArtifacts(in: parent) else { return false }
        _ = await runQwenInstallRecovery(runtimeDirectory)
        return true
    }

    /// True when the runtime parent holds installer-owned orphan artifacts — a leftover backup or an
    /// abandoned staging directory from an interrupted Qwen install. Only the installer's hidden
    /// `.Qwen3ASR-backup-*` / `.Qwen3ASR-install-*` names match, so this never fires on a clean runtime
    /// (the live `Qwen3ASR/`, `venv/`, and helper carry none of these prefixes).
    nonisolated static func hasOrphanedQwenInstallArtifacts(in parent: URL) -> Bool {
        hasOrphanedInstallArtifacts(in: parent, for: .qwen)
    }

    /// Spawns the bundled `setup-qwen-asr.sh` in recovery-only mode over the runtime directory and
    /// returns its exit status. Runs off the main actor. Returns a non-zero sentinel if the bundled
    /// script is missing or the process cannot start.
    nonisolated static func spawnQwenInstallRecovery(runtimeDirectory: URL) async -> Int32 {
        await spawnInstallRecovery(runtimeDirectory: runtimeDirectory, for: .qwen)
    }
}

// MARK: - Interrupted local-summarizer install reclaim (F167 — completes the F33/F219 set)

extension AppModel {
    /// Reclaim an interrupted local-summarizer install on launch, only when orphaned artifacts
    /// actually exist — so a clean launch, or a Mac that never installed the summarizer, spawns
    /// nothing. Returns whether the reclaim ran.
    ///
    /// The installer's own reclaim is unchanged and already tested; this wires it to launch, which
    /// is the whole of F167. Before it, a force-quit mid-install left the previous model in a
    /// `.Summarizer-backup-*` directory and the feature reporting "not installed" until the user
    /// happened to open the installer again — which someone whose summaries had stopped working has
    /// no particular reason to do.
    @discardableResult
    func reclaimInterruptedSummarizerInstall(
        runtimeDirectory: URL = SummarizerRuntime.managedDirectory()
    ) async -> Bool {
        let parent = runtimeDirectory.deletingLastPathComponent()
        guard Self.hasOrphanedSummarizerInstallArtifacts(in: parent) else { return false }
        _ = await runSummarizerInstallRecovery(runtimeDirectory)
        return true
    }

    /// True when the runtime parent holds installer-owned orphan artifacts.
    ///
    /// Only the installer's hidden `.Summarizer-backup-*` / `.Summarizer-install-*` names match, so
    /// this never fires on a clean runtime — the live `Summarizer/` carries neither prefix. An
    /// unlistable parent reports false: a Mac that never installed the summarizer has no parent
    /// directory at all, and that is the common case rather than an error.
    nonisolated static func hasOrphanedSummarizerInstallArtifacts(in parent: URL) -> Bool {
        hasOrphanedInstallArtifacts(in: parent, for: .summarizer)
    }

    /// Spawns the bundled `setup-local-summarizer.sh` in recovery-only mode and returns its exit
    /// status. Runs off the main actor; returns a non-zero sentinel if the script is missing or the
    /// process cannot start.
    nonisolated static func spawnSummarizerInstallRecovery(runtimeDirectory: URL) async -> Int32 {
        await spawnInstallRecovery(runtimeDirectory: runtimeDirectory, for: .summarizer)
    }
}

// MARK: - Interrupted speaker-analysis install reclaim (F219 — mirrors the F33 Qwen wiring)

extension AppModel {
    /// Reclaim an interrupted speaker-analysis install on launch — but only when installer-owned
    /// orphans actually exist under the runtime parent, so a clean launch (or a Mac that never
    /// installed speaker analysis) spawns nothing. A force-quit mid-install can strand the previous
    /// runtime in a `.Diarization-backup-*` dir while `Diarization/` is gone and the app reports "not
    /// installed"; the installer's recovery-only branch restores it (or clears an incomplete one)
    /// without a manual reinstall. Returns whether the reclaim was run. The reclaim itself is the
    /// injected `runDiarizationInstallRecovery` seam, so this hop is headless-testable without
    /// spawning a process.
    ///
    /// `runtimeDirectory` defaults to `diarizationRuntimeDirectory` (a default argument cannot read
    /// an instance property, hence the optional).
    @discardableResult
    func reclaimInterruptedDiarizationInstall(runtimeDirectory: URL? = nil) async -> Bool {
        let directory = runtimeDirectory ?? diarizationRuntimeDirectory
        let parent = directory.deletingLastPathComponent()
        guard Self.hasOrphanedDiarizationInstallArtifacts(in: parent) else { return false }
        _ = await runDiarizationInstallRecovery(directory)
        return true
    }

    /// True when the runtime parent holds installer-owned orphan artifacts — a leftover backup or an
    /// abandoned staging directory from an interrupted speaker-analysis install. Only the installer's
    /// hidden `.Diarization-backup-*` / `.Diarization-install-*` names match, so this never fires on a
    /// clean runtime (the live `Diarization/` and its sibling runtimes carry none of these prefixes),
    /// nor on the `.Diarization-install.lock` file, whose staleness `shlock` already settles.
    nonisolated static func hasOrphanedDiarizationInstallArtifacts(in parent: URL) -> Bool {
        hasOrphanedInstallArtifacts(in: parent, for: .diarization)
    }

    /// Spawns the bundled `setup-speaker-diarization.sh` in recovery-only mode over the runtime
    /// directory and returns its exit status. Runs off the main actor. Returns a non-zero sentinel if
    /// the bundled script is missing or the process cannot start.
    nonisolated static func spawnDiarizationInstallRecovery(runtimeDirectory: URL) async -> Int32 {
        await spawnInstallRecovery(runtimeDirectory: runtimeDirectory, for: .diarization)
    }
}
