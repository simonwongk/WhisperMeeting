import AppKit
import AVFoundation
import AVKit
import SwiftUI
import UniformTypeIdentifiers
import WhisperCore

private enum SidebarItem: Hashable {
    case record
    case vocabulary
    case settings
    case meeting(UUID)
}

private enum TranscriptMode: Hashable {
    case read
    case edit
}

struct ContentView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var store: MeetingStore
    @State private var selection: SidebarItem? = .record
    @State private var pendingDeletion: MeetingRecord?
    @State private var searchText = ""

    init(model: AppModel) {
        self.model = model
        store = model.store
    }

    private var filteredMeetings: [MeetingRecord] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return store.meetings }
        return store.meetings.filter {
            TextSearch.matches(query, in: [$0.title, $0.transcriptText])
        }
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    Label("New Meeting", systemImage: "record.circle")
                        .tag(SidebarItem.record)
                    Label("Business Vocabulary", systemImage: "text.book.closed")
                        .tag(SidebarItem.vocabulary)
                    Label("Settings", systemImage: "gearshape")
                        .tag(SidebarItem.settings)
                }

                Section("Meetings") {
                    if store.meetings.isEmpty {
                        Text("Your recordings will appear here.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .listRowSeparator(.hidden)
                    } else if filteredMeetings.isEmpty {
                        Text("No meetings match “\(searchText)”.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .listRowSeparator(.hidden)
                    }
                    ForEach(filteredMeetings) { meeting in
                        MeetingRow(meeting: meeting)
                            .tag(SidebarItem.meeting(meeting.id))
                            .contextMenu {
                                Button("Delete Meeting", role: .destructive) {
                                    pendingDeletion = meeting
                                }
                            }
                    }
                }
            }
            .navigationTitle("WhisperMeet")
            .searchable(text: $searchText, placement: .sidebar, prompt: "Search meetings & transcripts")
            .navigationSplitViewColumnWidth(min: 245, ideal: 290)
        } detail: {
            detail
        }
        .alert(
            "WhisperMeet",
            isPresented: Binding(
                get: {
                    model.alertMessage != nil || store.storageErrorMessage != nil
                },
                set: {
                    if !$0 {
                        model.alertMessage = nil
                        store.clearStorageError()
                    }
                }
            )
        ) {
            Button("OK") {
                model.alertMessage = nil
                store.clearStorageError()
            }
        } message: {
            Text([model.alertMessage, store.storageErrorMessage]
                .compactMap { $0 }
                .joined(separator: "\n\n"))
        }
        .confirmationDialog(
            "Permanently delete this meeting?",
            isPresented: Binding(
                get: { pendingDeletion != nil },
                set: { if !$0 { pendingDeletion = nil } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Recording and Transcript", role: .destructive) {
                guard let meeting = pendingDeletion else { return }
                model.deleteMeeting(id: meeting.id)
                if selection == .meeting(meeting.id) {
                    selection = .record
                }
                pendingDeletion = nil
            }
            Button("Keep Meeting", role: .cancel) {
                pendingDeletion = nil
            }
        } message: {
            Text("This removes the local recording, its source tracks, and its transcript. This action cannot be undone by WhisperMeet.")
        }
    }

    @ViewBuilder
    private var detail: some View {
        switch selection ?? .record {
        case .record:
            RecordMeetingView(model: model) { meetingID in
                selection = .meeting(meetingID)
            }
        case .vocabulary:
            VocabularyView(store: store)
        case .settings:
            SettingsView(model: model)
                .padding(32)
        case let .meeting(id):
            if store.meeting(id: id) != nil {
                // Fresh identity per meeting so per-meeting @State (transcript mode, in-flight
                // vocabulary suggestion, dialogs) never leaks across a selection change.
                TranscriptDetailView(model: model, store: store, meetingID: id)
                    .id(id)
            } else {
                ContentUnavailableView("Meeting Not Found", systemImage: "doc.questionmark")
            }
        }
    }
}

private struct MeetingRow: View {
    let meeting: MeetingRecord

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(meeting.title)
                .fontWeight(.medium)
                .lineLimit(1)
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                Text(meeting.status.title)
                if meeting.duration > 0 {
                    Text("·")
                    Text(TranscriptFormatter.clock(meeting.duration))
                        .monospacedDigit()
                }
                Spacer()
                Text(meeting.createdAt, format: .dateTime.month(.abbreviated).day())
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 4)
    }

    private var statusColor: Color {
        switch meeting.status {
        case .completed: .green
        case .failed: .red
        case .recorded: .orange
        case .processing: .blue
        }
    }
}

private struct RecordMeetingView: View {
    @ObservedObject var model: AppModel
    let onMeetingSaved: (UUID) -> Void
    @State private var title = ""
    @State private var isConfirmingCancellation = false
    @State private var showsImporter = false

    var body: some View {
        VStack(spacing: 28) {
            Spacer()
            VStack(spacing: 8) {
                Image(systemName: recordingIcon)
                    .font(.system(size: 58, weight: .light))
                    .foregroundStyle(isRecording ? Color.red : Color.accentColor)
                    .symbolEffect(.pulse, isActive: isRecording)
                Text(recordingTitle)
                    .font(.largeTitle.bold())
                Text(recordingSubtitle)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 520)
            }

            if case let .recording(startedAt) = model.recordingState {
                liveRecordingPanel(startedAt: startedAt)
                recordingHealthPanel
            } else if model.recordingState == .idle {
                VStack(alignment: .leading, spacing: 16) {
                    TextField("Meeting title (optional)", text: $title)
                        .textFieldStyle(.roundedBorder)
                    preflightPanel
                    importPanel
                }
                .frame(maxWidth: 560)
            }

            Button {
                handlePrimaryAction()
            } label: {
                Label(primaryButtonTitle, systemImage: primaryButtonIcon)
                    .frame(minWidth: 180)
                    .padding(.vertical, 7)
            }
            .buttonStyle(.borderedProminent)
            .tint(isRecording ? .red : .accentColor)
            .controlSize(.large)
            .disabled(model.recordingState == .starting || model.recordingState == .stopping || model.isImporting)

            if isRecording {
                Button("Cancel Recording", role: .destructive) {
                    isConfirmingCancellation = true
                }
                .buttonStyle(.plain)
            }

            Label(
                "Make sure everyone has agreed to the recording. Headphones reduce echo and improve accuracy.",
                systemImage: "hand.raised"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: 560)
            Spacer()
        }
        .padding(40)
        .navigationTitle("New Meeting")
        .onAppear { model.refreshRecordingPreflight() }
        .confirmationDialog(
            "Discard this recording?",
            isPresented: $isConfirmingCancellation,
            titleVisibility: .visible
        ) {
            Button("Discard Recording", role: .destructive) {
                Task { await model.cancelRecording() }
            }
            Button("Keep Recording", role: .cancel) {}
        } message: {
            Text("The unfinished recording and its source tracks will be permanently removed. Choose Stop Meeting if you want to keep the audio.")
        }
        .fileImporter(
            isPresented: $showsImporter,
            allowedContentTypes: [.audio, .movie, .audiovisualContent],
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case let .success(urls):
                guard !urls.isEmpty else { return }
                Task {
                    if let id = await model.importRecordings(from: urls, title: title) {
                        onMeetingSaved(id)
                        title = ""
                    }
                }
            case let .failure(error):
                model.alertMessage = error.localizedDescription
            }
        }
    }

    private var isRecording: Bool {
        if case .recording = model.recordingState { return true }
        return false
    }

    private var preflightPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Before recording")
                    .font(.headline)
                Spacer()
                Button("Check Again") { model.refreshRecordingPreflight() }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tint)
            }
            preflightRow(
                title: model.recordingPreflight.microphoneName,
                systemImage: "mic.fill",
                access: model.recordingPreflight.microphoneAccess
            )
            preflightRow(
                title: "Mac system audio",
                systemImage: "speaker.wave.2.fill",
                access: model.recordingPreflight.systemAudioAccess
            )
            HStack(spacing: 9) {
                Image(systemName: "internaldrive.fill")
                    .frame(width: 18)
                Text("Recording storage")
                Spacer()
                Text(storageDescription(model.recordingPreflight.availableStorageBytes))
                    .foregroundStyle(storageColor(model.recordingPreflight.availableStorageBytes))
            }
        }
        .font(.callout)
        .padding(16)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
    }

    private func liveRecordingPanel(startedAt: Date) -> some View {
        VStack(spacing: 16) {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let elapsed = max(0, Date.now.timeIntervalSince(startedAt))
                VStack(spacing: 4) {
                    Text(duration(elapsed))
                        .font(.system(.title, design: .monospaced).weight(.medium))
                        .contentTransition(.numericText())
                    Text("Estimated recording size: \(recordingSizeText(elapsed))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("Using \(workingSizeText(elapsed)) on disk while the source tracks are kept")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            LiveVolumeBar(levels: model.recordingLevels)
                .frame(maxWidth: 560)
        }
    }

    private var importPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                showsImporter = true
            } label: {
                Label("Import Recordings…", systemImage: "square.and.arrow.down")
            }
            .disabled(model.isImporting)
            if model.isImporting {
                ProgressView("Importing…").controlSize(.small)
            } else {
                Text("Transcribe existing audio or video files. They are copied into your library, stay on this Mac, and transcribe one after another.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private var recordingHealthPanel: some View {
        if let health = model.recordingHealth {
            VStack(alignment: .leading, spacing: 14) {
                healthStatusBanner(health)
                Divider()
                channelHealthRow(
                    title: "Microphone (you)",
                    systemImage: "mic.fill",
                    level: liveMicrophoneLevel,
                    state: microphoneState(health)
                )
                channelHealthRow(
                    title: "System audio (others)",
                    systemImage: "speaker.wave.2.fill",
                    level: liveSystemLevel,
                    state: systemAudioState(health)
                )
                storageRow(health)
                healthExplainer
            }
            .font(.callout)
            .padding(16)
            .frame(maxWidth: 560)
            .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
        } else {
            ProgressView("Checking both audio channels…")
                .frame(maxWidth: 560)
        }
    }

    private var liveMicrophoneLevel: Float {
        model.recordingLevels?.microphone.rms ?? model.recordingHealth?.microphoneLevel.rms ?? 0
    }

    private var liveSystemLevel: Float {
        model.recordingLevels?.systemAudio.rms ?? model.recordingHealth?.systemAudioLevel.rms ?? 0
    }

    private func healthStatusBanner(_ health: RecordingHealthSnapshot) -> some View {
        HStack(spacing: 11) {
            Image(systemName: statusIcon(health.overallStatus))
                .font(.title3)
                .foregroundStyle(statusColor(health.overallStatus))
            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle(health.overallStatus))
                    .fontWeight(.semibold)
                Text(statusReason(health))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
        }
    }

    private struct ChannelState {
        let text: String
        let color: Color
    }

    private func channelHealthRow(
        title: String,
        systemImage: String,
        level: Float,
        state: ChannelState
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 9) {
                Image(systemName: systemImage).frame(width: 18)
                Text(title)
                Spacer()
                Text(state.text)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(state.color)
            }
            ProgressView(value: min(1, Double(level) * 4))
        }
    }

    private func storageRow(_ health: RecordingHealthSnapshot) -> some View {
        HStack(spacing: 9) {
            Image(systemName: "internaldrive.fill").frame(width: 18)
            Text("Storage available")
            Spacer()
            Text(storageDescription(health.availableStorageBytes))
                .foregroundStyle(storageColor(health.availableStorageBytes))
        }
    }

    private var healthExplainer: some View {
        DisclosureGroup("How this is measured") {
            VStack(alignment: .leading, spacing: 6) {
                Text("The meters show the loudness of the exact audio being written to disk for each channel — microphone for you, system audio for everyone else.")
                Text("Checks run once per second. A channel that was working and then delivers no audio for 3 seconds is flagged as stopped.")
                Text("“Too loud” means the audio reached maximum level and may distort. Silence on the system channel is normal until someone else speaks.")
                Text("Storage is watched so you can stop before the disk fills.")
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            .padding(.top, 4)
        }
        .font(.callout)
    }

    private func microphoneState(_ health: RecordingHealthSnapshot) -> ChannelState {
        if health.warnings.contains(.microphoneCaptureStopped) {
            return ChannelState(text: "No audio for 3s+", color: .red)
        }
        if health.warnings.contains(.microphoneClipping) {
            return ChannelState(text: "Too loud", color: .orange)
        }
        return liveMicrophoneLevel > 0.02
            ? ChannelState(text: "Receiving audio", color: .green)
            : ChannelState(text: "Silent", color: .secondary)
    }

    private func systemAudioState(_ health: RecordingHealthSnapshot) -> ChannelState {
        if health.warnings.contains(.systemAudioCaptureStopped) {
            return ChannelState(text: "No audio for 3s+", color: .red)
        }
        if health.warnings.contains(.systemAudioNotDetected) {
            return ChannelState(text: "Not detected yet", color: .orange)
        }
        if health.warnings.contains(.systemAudioClipping) {
            return ChannelState(text: "Too loud", color: .orange)
        }
        return liveSystemLevel > 0.02
            ? ChannelState(text: "Receiving audio", color: .green)
            : ChannelState(text: "Silent (normal until others speak)", color: .secondary)
    }

    private func statusIcon(_ status: RecordingHealthStatus) -> String {
        switch status {
        case .good: "checkmark.circle.fill"
        case .caution: "exclamationmark.circle.fill"
        case .atRisk: "exclamationmark.triangle.fill"
        }
    }

    private func statusColor(_ status: RecordingHealthStatus) -> Color {
        switch status {
        case .good: .green
        case .caution: .orange
        case .atRisk: .red
        }
    }

    private func statusTitle(_ status: RecordingHealthStatus) -> String {
        switch status {
        case .good: "Recording is healthy"
        case .caution: "Worth a quick check"
        case .atRisk: "Recording needs attention"
        }
    }

    private func statusReason(_ health: RecordingHealthSnapshot) -> String {
        if let warning = health.warnings.first {
            return warningMessage(warning)
        }
        return "Both channels are being captured and saved to this Mac."
    }

    private func recordingSizeText(_ elapsed: TimeInterval) -> String {
        ByteCountFormatter.string(
            fromByteCount: RecordingSizeEstimator.mixedBytes(forDuration: elapsed),
            countStyle: .file
        )
    }

    private func workingSizeText(_ elapsed: TimeInterval) -> String {
        ByteCountFormatter.string(
            fromByteCount: RecordingSizeEstimator.workingBytes(forDuration: elapsed),
            countStyle: .file
        )
    }

    private func preflightRow(
        title: String,
        systemImage: String,
        access: RecordingPreflightStatus.Access
    ) -> some View {
        HStack(spacing: 9) {
            Image(systemName: systemImage)
                .frame(width: 18)
            Text(title)
            Spacer()
            switch access {
            case .granted:
                Label("Ready", systemImage: "checkmark.circle.fill")
                    .foregroundStyle(.green)
            case .permissionNeeded:
                Text("Permission requested at start")
                    .foregroundStyle(.orange)
            case .notGranted:
                Label("Enable, then quit with ⌘Q", systemImage: "exclamationmark.circle.fill")
                    .foregroundStyle(.orange)
            case .denied:
                Label("Permission denied", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
            case .unavailable:
                Label("No input device", systemImage: "xmark.circle.fill")
                    .foregroundStyle(.red)
            }
        }
    }

    private func warningMessage(_ warning: RecordingHealthWarning) -> String {
        switch warning {
        case .microphoneCaptureStopped:
            "Microphone audio stopped arriving. Check the microphone connection."
        case .systemAudioCaptureStopped:
            "System audio stopped arriving. The other participants may not be recorded."
        case .systemAudioNotDetected:
            "No system audio has been detected yet. Play meeting audio to verify this channel."
        case .microphoneClipping:
            "The microphone is too loud and may sound distorted."
        case .systemAudioClipping:
            "System audio is clipping and may sound distorted."
        case .lowStorage:
            "Storage is running low. Stop soon to protect the recording."
        }
    }

    private func storageDescription(_ bytes: Int64?) -> String {
        guard let bytes else { return "Storage unavailable" }
        return ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    private func storageColor(_ bytes: Int64?) -> Color {
        guard let bytes else { return .secondary }
        return bytes < 2_000_000_000 ? .orange : .secondary
    }

    private var recordingIcon: String {
        switch model.recordingState {
        case .idle: "waveform.circle"
        case .starting, .stopping: "hourglass.circle"
        case .recording: "record.circle.fill"
        }
    }

    private var recordingTitle: String {
        switch model.recordingState {
        case .idle: "Capture every word"
        case .starting: "Preparing audio…"
        case .recording: "Recording"
        case .stopping: "Preparing transcript audio…"
        }
    }

    private var recordingSubtitle: String {
        switch model.recordingState {
        case .idle:
            "WhisperMeet records your microphone and Mac system audio. Transcription begins after the meeting ends."
        case .starting:
            "Approve microphone and screen-recording permissions if macOS asks."
        case .recording:
            "System audio and microphone are being kept as separate source tracks."
        case .stopping:
            "Aligning and mixing the source tracks without aggressive filtering."
        }
    }

    private var primaryButtonTitle: String {
        switch model.recordingState {
        case .idle: "Start Recording"
        case .starting: "Starting…"
        case .recording: "Stop & Transcribe"
        case .stopping: "Finishing…"
        }
    }

    private var primaryButtonIcon: String {
        isRecording ? "stop.fill" : "record.circle"
    }

    private func handlePrimaryAction() {
        switch model.recordingState {
        case .idle:
            Task { await model.startRecording() }
        case .recording:
            Task {
                if let id = await model.stopRecording(title: title) {
                    onMeetingSaved(id)
                    title = ""
                }
            }
        case .starting, .stopping:
            break
        }
    }

    private func duration(_ interval: TimeInterval) -> String {
        let total = max(0, Int(interval))
        return String(format: "%02d:%02d:%02d", total / 3_600, (total / 60) % 60, total % 60)
    }
}

/// A prominent live meter that reacts to whoever is currently speaking (microphone or system
/// audio), driven by the fast ~15 Hz level stream.
private struct LiveVolumeBar: View {
    let levels: RecordingLevels?

    private var level: Double { Double(min(1, (levels?.combinedPeak ?? 0))) }
    private var isSpeaking: Bool {
        guard let levels else { return false }
        return levels.combinedRMS > 0.02 || levels.combinedPeak > 0.08
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(
                isSpeaking ? "Someone is speaking" : "Listening — no one is speaking",
                systemImage: isSpeaking ? "waveform" : "waveform.slash"
            )
            .font(.callout.weight(.medium))
            .foregroundStyle(isSpeaking ? Color.accentColor : Color.secondary)

            GeometryReader { geometry in
                ZStack(alignment: .leading) {
                    Capsule().fill(.quaternary)
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [.green, .yellow, .orange],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .frame(width: max(4, geometry.size.width * level))
                        .animation(.linear(duration: 0.08), value: level)
                }
            }
            .frame(height: 14)
            .accessibilityLabel("Live input volume")
            .accessibilityValue("\(Int(level * 100)) percent")
        }
    }
}

struct SettingsView: View {
    @ObservedObject var model: AppModel
    @State private var apiKeyDraft = ""

    var body: some View {
        Form {
            Section("Local Whisper") {
                HStack {
                    Label(
                        model.isRuntimeInstalled ? "Ready on this Mac" : "Not installed",
                        systemImage: model.isRuntimeInstalled
                            ? "checkmark.circle.fill"
                            : "arrow.down.circle"
                    )
                    .foregroundStyle(model.isRuntimeInstalled ? .green : .orange)
                    Spacer()
                    Button(model.isRuntimeInstalled ? "Repair or Update" : "Install Local Whisper") {
                        model.installLocalWhisper()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(model.isInstallingRuntime || model.hasActiveTranscription)
                }
                if model.isInstallingRuntime {
                    ProgressView("Installing. This can take several minutes…")
                } else if let message = model.installationMessage {
                    Text(message)
                        .foregroundStyle(.secondary)
                }
                Text("Audio and transcripts stay on this Mac. No account, API key, or usage payment is required.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("The installer uses an existing Homebrew installation to add FFmpeg and an isolated Python environment.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("Transcription") {
                Picker("Model", selection: $model.selectedModel) {
                    ForEach(WhisperModel.allCases, id: \.self) { model in
                        Text(model.displayName).tag(model)
                    }
                }
                Picker("Meeting language", selection: $model.selectedLanguage) {
                    ForEach(WhisperLanguage.allCases, id: \.self) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                Text("Large is the accuracy-first multilingual choice for English and Mandarin. Turbo is much faster with a small accuracy tradeoff. A model downloads once on first use.")
                    .foregroundStyle(.secondary)
                Text("OpenAI Whisper produces timestamps but does not identify different people. WhisperMeet still preserves separate microphone and system-audio source files.")
                    .foregroundStyle(.secondary)
            }

            Section("Claude Summaries (optional)") {
                HStack {
                    Label(
                        model.hasClaudeAPIKey ? "API key saved" : "No API key",
                        systemImage: model.hasClaudeAPIKey ? "checkmark.circle.fill" : "key"
                    )
                    .foregroundStyle(model.hasClaudeAPIKey ? .green : .secondary)
                    Spacer()
                    if model.hasClaudeAPIKey {
                        Button("Remove", role: .destructive) {
                            model.setClaudeAPIKey(nil)
                            apiKeyDraft = ""
                        }
                    }
                }
                SecureField("sk-ant-…", text: $apiKeyDraft)
                Button("Save API Key") {
                    model.setClaudeAPIKey(apiKeyDraft)
                    apiKeyDraft = ""
                }
                .buttonStyle(.borderedProminent)
                .disabled(apiKeyDraft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Text("Summaries are the one feature that leaves this Mac: the transcript is sent to Anthropic's Claude API, which requires your own paid API key. Recording and transcription stay fully local.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
    }
}

private struct VocabularyView: View {
    @ObservedObject var store: MeetingStore
    @State private var manualTerms = ""
    @State private var showsImporter = false
    @State private var importMessage: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Business Vocabulary")
                    .font(.largeTitle.bold())
                Text("Every term shown below stays on this Mac and is included in Whisper’s local prompt. Up to 100 reviewed terms are kept.")
                    .foregroundStyle(.secondary)
            }

            HStack(alignment: .top, spacing: 12) {
                TextField("Add terms separated by commas or new lines", text: $manualTerms, axis: .vertical)
                    .lineLimit(2...5)
                    .textFieldStyle(.roundedBorder)
                Button("Add") { addManualTerms() }
                    .buttonStyle(.borderedProminent)
                Button("Import Documents…") { showsImporter = true }
            }

            if let importMessage {
                Text(importMessage)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if store.vocabulary.isEmpty {
                ContentUnavailableView(
                    "No Vocabulary Yet",
                    systemImage: "text.book.closed",
                    description: Text("Import PDF, DOCX, TXT, or Markdown documents, then review the extracted terms.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    ForEach(store.vocabulary, id: \.self) { term in
                        HStack {
                            Text(term)
                            Spacer()
                            Button {
                                store.removeVocabulary(term)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(.tertiary)
                            .accessibilityLabel("Remove \(term)")
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
        .padding(32)
        .fileImporter(
            isPresented: $showsImporter,
            allowedContentTypes: supportedTypes,
            allowsMultipleSelection: true
        ) { result in
            switch result {
            case let .success(urls):
                importDocuments(urls)
            case let .failure(error):
                importMessage = error.localizedDescription
            }
        }
    }

    private var supportedTypes: [UTType] {
        var types: [UTType] = [.pdf, .plainText, .commaSeparatedText]
        if let docx = UTType(filenameExtension: "docx") { types.append(docx) }
        if let markdown = UTType(filenameExtension: "md") { types.append(markdown) }
        return types
    }

    private func addManualTerms() {
        let terms = manualTerms.components(separatedBy: CharacterSet(charactersIn: ",\n"))
        let before = Set(store.vocabulary)
        store.addVocabulary(terms)
        let added = Set(store.vocabulary).subtracting(before).count
        importMessage = added == 0
            ? "No terms were added. The prompt may already be at its 100-term limit."
            : "Added \(added) term\(added == 1 ? "" : "s") to the local prompt."
        manualTerms = ""
    }

    private func importDocuments(_ urls: [URL]) {
        importMessage = "Reading \(urls.count) document\(urls.count == 1 ? "" : "s")…"
        Task {
            do {
                let extracted = try await Task.detached(priority: .userInitiated) {
                    try urls.flatMap(VocabularyExtractor.extract(from:))
                }.value
                let before = Set(store.vocabulary)
                store.addVocabulary(extracted)
                let added = Set(store.vocabulary).subtracting(before).count
                importMessage = "Added \(added) candidate term\(added == 1 ? "" : "s"). Remove anything that should not influence transcription."
            } catch {
                importMessage = error.localizedDescription
            }
        }
    }
}

private struct TranscriptDetailView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: MeetingStore
    let meetingID: UUID
    @State private var confirmSummarize = false
    @State private var transcriptMode: TranscriptMode = .read
    @State private var vocabularySuggestions: [String]?
    @State private var isSuggestingVocab = false

    var body: some View {
        if let meeting = store.meeting(id: meetingID) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header(meeting)
                    statusCard(meeting)

                    if meeting.status == .completed {
                        summarySection(meeting)
                        transcriptSection(meeting)
                    }
                }
                .frame(maxWidth: 860, alignment: .leading)
                .padding(32)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle(meeting.title)
            .onAppear { normalizeTranscriptIfNeeded(meeting) }
            .alert("Summarize with Claude?", isPresented: $confirmSummarize) {
                Button("Cancel", role: .cancel) {}
                Button("Send to Claude") { model.summarize(id: meetingID) }
            } message: {
                Text("This sends the meeting transcript to Anthropic's Claude API using your saved key. It's the only feature that leaves this Mac.")
            }
            .sheet(isPresented: Binding(
                get: { vocabularySuggestions != nil },
                set: { if !$0 { vocabularySuggestions = nil } }
            )) {
                VocabularySuggestionSheet(suggestions: vocabularySuggestions ?? []) { chosen in
                    store.addVocabulary(chosen)
                }
            }
        }
    }

    @ViewBuilder
    private func summarySection(_ meeting: MeetingRecord) -> some View {
        let isSummarizing = model.activeSummarizationID == meeting.id
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Summary").font(.headline)
                Spacer()
                if let summary = meeting.summary {
                    Button("Copy") { copy(Self.summaryText(summary)) }
                    Button("Export…") { export(meeting: meeting, text: Self.summaryText(summary)) }
                }
                Button(meeting.summary == nil ? "Summarize with Claude" : "Re-summarize") {
                    if model.hasClaudeAPIKey {
                        confirmSummarize = true
                    } else {
                        model.alertMessage = "Add a Claude API key in Settings to create summaries."
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSummarizing || meeting.transcriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if isSummarizing {
                ProgressView("Summarizing with Claude…").controlSize(.small)
            } else if let summary = meeting.summary {
                summaryBody(summary)
            } else if !model.hasClaudeAPIKey {
                Text("Add a Claude API key in Settings to turn this transcript into a summary, key points, and action items.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func summaryBody(_ summary: MeetingSummary) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(summary.summary)
            if !summary.keyPoints.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Key points").font(.subheadline.bold())
                    ForEach(summary.keyPoints.indices, id: \.self) { index in
                        Text("• \(summary.keyPoints[index])")
                    }
                }
            }
            if !summary.actionItems.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Action items").font(.subheadline.bold())
                    ForEach(summary.actionItems.indices, id: \.self) { index in
                        Label(summary.actionItems[index], systemImage: "checkmark.square")
                    }
                }
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 10))
    }

    private static func summaryText(_ summary: MeetingSummary) -> String {
        var lines = ["Summary", summary.summary]
        if !summary.keyPoints.isEmpty {
            lines.append("\nKey points")
            lines.append(contentsOf: summary.keyPoints.map { "• \($0)" })
        }
        if !summary.actionItems.isEmpty {
            lines.append("\nAction items")
            lines.append(contentsOf: summary.actionItems.map { "- [ ] \($0)" })
        }
        return lines.joined(separator: "\n")
    }

    @ViewBuilder
    private func header(_ meeting: MeetingRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            EditableMeetingTitle(store: store, meetingID: meetingID)
                .id(meetingID)
            HStack(spacing: 14) {
                Label(meeting.createdAt.formatted(date: .long, time: .shortened), systemImage: "calendar")
                Label(formatDuration(meeting.duration), systemImage: "clock")
                if let language = meeting.languageCode {
                    Label(language.uppercased(), systemImage: "character.bubble")
                }
                if let confidence = meeting.confidence {
                    Label(confidence.formatted(.percent.precision(.fractionLength(0))), systemImage: "checkmark.seal")
                }
                Spacer()
                Button("Show Recording in Finder") {
                    NSWorkspace.shared.activateFileViewerSelecting([
                        store.recordingURL(for: meeting)
                    ])
                }
                .disabled(!FileManager.default.fileExists(
                    atPath: store.recordingURL(for: meeting).path
                ))
            }
            .font(.callout)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func statusCard(_ meeting: MeetingRecord) -> some View {
        if meeting.status != .completed {
            let isQueued = model.isQueuedForTranscription(meeting.id)
            VStack(alignment: .leading, spacing: 12) {
                HStack(spacing: 14) {
                    if meeting.status == .processing {
                        ProgressView()
                            .controlSize(.small)
                    } else {
                        Image(systemName: statusIcon(meeting, isQueued: isQueued))
                            .foregroundStyle(!isQueued && meeting.status == .failed ? .red : .orange)
                    }
                    VStack(alignment: .leading, spacing: 3) {
                        Text(isQueued ? "Queued" : meeting.status.title).fontWeight(.semibold)
                        if meeting.status == .processing {
                            Text(transcriptionPhaseLabel(meeting)).foregroundStyle(.secondary)
                        } else if isQueued {
                            Text("Waiting for the current transcription to finish.").foregroundStyle(.secondary)
                        } else if let error = meeting.errorMessage {
                            Text(error).foregroundStyle(.secondary)
                        } else if meeting.status == .recorded {
                            Text("The audio is safely stored on this Mac.").foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    if meeting.status == .processing || isQueued {
                        Button(isQueued ? "Remove" : "Cancel", role: .destructive) {
                            model.cancelTranscription(id: meeting.id)
                        }
                    } else if meeting.status == .recorded || meeting.status == .failed {
                        Button("Transcribe") {
                            model.beginTranscription(id: meeting.id)
                        }
                        .buttonStyle(.borderedProminent)
                    }
                }
                if meeting.status == .processing {
                    transcriptionProgressBar(meeting)
                }
            }
            .padding(18)
            .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
        }
    }

    private func statusIcon(_ meeting: MeetingRecord, isQueued: Bool) -> String {
        if isQueued { return "hourglass" }
        if meeting.status == .failed { return "exclamationmark.triangle.fill" }
        return "waveform.badge.plus"
    }

    @ViewBuilder
    private func transcriptionProgressBar(_ meeting: MeetingRecord) -> some View {
        let progress = model.transcriptionProgress[meeting.id]
        if let fraction = progress?.fractionCompleted {
            VStack(alignment: .leading, spacing: 4) {
                ProgressView(value: fraction)
                if let remaining = etaText(progress?.estimatedSecondsRemaining) {
                    Text(remaining)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } else {
            // Model load / download has no fraction yet — show an animated indeterminate bar
            // rather than a frozen 0%.
            ProgressView()
                .progressViewStyle(.linear)
        }
    }

    private func transcriptionPhaseLabel(_ meeting: MeetingRecord) -> String {
        guard let progress = model.transcriptionProgress[meeting.id] else {
            return "Transcribing locally with Whisper…"
        }
        switch progress.phase {
        case .preparing:
            return "Preparing…"
        case .loadingModel:
            return "Loading the Whisper model…"
        case .downloadingModel:
            return "Downloading the Whisper model (first use)… \(percentText(progress.fractionCompleted))"
        case .transcribing:
            return "Transcribing locally with Whisper… \(percentText(progress.fractionCompleted))"
        }
    }

    private func percentText(_ fraction: Double?) -> String {
        guard let fraction else { return "" }
        return fraction.formatted(.percent.precision(.fractionLength(0)))
    }

    private func etaText(_ seconds: TimeInterval?) -> String? {
        guard let seconds else { return nil }
        let total = Int(seconds.rounded())
        if total < 1 { return "Almost done" }
        if total < 60 { return "About \(total)s left" }
        let minutes = total / 60
        let secs = total % 60
        return secs == 0 ? "About \(minutes)m left" : "About \(minutes)m \(secs)s left"
    }

    @ViewBuilder
    private func recordingPlayer(_ meeting: MeetingRecord) -> some View {
        let recordingURL = store.recordingURL(for: meeting)
        VStack(alignment: .leading, spacing: 10) {
            Text("Recording").font(.headline)
            if FileManager.default.fileExists(atPath: recordingURL.path) {
                AudioPlayerView(url: recordingURL)
                    .frame(height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(.separator, lineWidth: 1)
                    }
            } else {
                Text("Recording unavailable on this Mac.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder
    private func transcriptSection(_ meeting: MeetingRecord) -> some View {
        let hasSegments = !meeting.segments.isEmpty
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Transcript").font(.headline)
                Spacer()
                if hasSegments {
                    Picker("Transcript view", selection: $transcriptMode) {
                        Text("Read").tag(TranscriptMode.read)
                        Text("Edit").tag(TranscriptMode.edit)
                    }
                    .pickerStyle(.segmented)
                    .labelsHidden()
                    .fixedSize()
                }
                Button {
                    suggestVocabulary(meeting)
                } label: {
                    if isSuggestingVocab {
                        ProgressView().controlSize(.small)
                    } else {
                        Label("Suggest Vocab", systemImage: "text.badge.plus")
                    }
                }
                .disabled(isSuggestingVocab)
                .help("Find names and key terms in this transcript to add to your business vocabulary")
                Button("Copy") { copy(currentTranscript()) }
                Menu("Export…") {
                    Button("Meeting Notes — Summary + Transcript (.md)") {
                        exportMeetingNotes(meeting: meeting)
                    }
                    Divider()
                    ForEach(TranscriptExportFormat.allCases, id: \.self) { format in
                        Button(format.displayName) {
                            exportTranscript(meeting: meeting, format: format)
                        }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            if hasSegments && transcriptMode == .read {
                PlayableTranscriptView(
                    store: store,
                    meetingID: meetingID,
                    recordingURL: store.recordingURL(for: meeting),
                    segments: meeting.segments
                )
                .id(meetingID)
            } else {
                recordingPlayer(meeting)
                transcriptTextEditor(meeting)
            }
        }
    }

    private func transcriptTextEditor(_ meeting: MeetingRecord) -> some View {
        TextEditor(text: Binding(
            get: { store.meeting(id: meeting.id)?.transcriptText ?? "" },
            set: { value in store.update(id: meeting.id) { $0.transcriptText = value } }
        ))
        .font(.body)
        .scrollContentBackground(.hidden)
        .padding(12)
        .frame(minHeight: 360)
        .background(.background, in: RoundedRectangle(cornerRadius: 10))
        .overlay {
            RoundedRectangle(cornerRadius: 10)
                .stroke(.separator, lineWidth: 1)
        }
    }

    /// Upgrades meetings transcribed before the unified-transcript change exactly once: if a
    /// completed meeting still has plain text plus segments, rebuild its transcript with inline
    /// timestamps. After this runs (or is skipped) the meeting is marked normalized and its text is
    /// never rebuilt again, so subsequent user edits — including removing the first timestamp — are
    /// never overwritten.
    private func normalizeTranscriptIfNeeded(_ meeting: MeetingRecord) {
        guard meeting.status == .completed, meeting.transcriptNormalized != true else { return }
        if !meeting.segments.isEmpty,
           !TranscriptFormatter.isTimestamped(meeting.transcriptText) {
            let rebuilt = TranscriptFormatter.timestamped(meeting.segments)
            if !rebuilt.isEmpty {
                store.update(id: meeting.id) {
                    $0.transcriptText = rebuilt
                    $0.transcriptNormalized = true
                }
                return
            }
        }
        store.update(id: meeting.id) { $0.transcriptNormalized = true }
    }

    private func currentTranscript() -> String {
        store.meeting(id: meetingID)?.transcriptText ?? ""
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    /// Finds candidate proper nouns / key terms in the transcript and offers the ones not already
    /// saved for the user to review before they take effect — vocabulary is never added silently.
    private func suggestVocabulary(_ meeting: MeetingRecord) {
        guard !isSuggestingVocab else { return }
        isSuggestingVocab = true
        let transcript = TranscriptFormatter.stripTimestamps(currentTranscript())
        let existing = Set(store.vocabulary.map { $0.lowercased() })
        Task {
            let candidates = await Task.detached(priority: .userInitiated) {
                VocabularyExtractor.candidates(in: transcript, includeLineHeuristic: false)
            }.value
            let fresh = candidates.filter { !existing.contains($0.lowercased()) }
            isSuggestingVocab = false
            if fresh.isEmpty {
                model.alertMessage = "No new vocabulary terms were found in this transcript. Everything detected is already in your business vocabulary."
            } else {
                vocabularySuggestions = fresh
            }
        }
    }

    private func export(meeting: MeetingRecord, text: String) {
        saveExport(text, suggestedName: meeting.title, fileExtension: "txt")
    }

    private func exportTranscript(meeting: MeetingRecord, format: TranscriptExportFormat) {
        let current = store.meeting(id: meeting.id) ?? meeting
        let request = TranscriptExportRequest(
            title: current.title,
            languageCode: current.languageCode,
            durationSeconds: current.duration,
            transcriptText: current.transcriptText,
            segments: current.segments
        )
        saveExport(
            TranscriptExporter.render(format, request),
            suggestedName: current.title,
            fileExtension: format.fileExtension
        )
    }

    private func exportMeetingNotes(meeting: MeetingRecord) {
        let current = store.meeting(id: meeting.id) ?? meeting
        let notes = MeetingNotesExporter.markdown(
            title: current.title,
            dateText: current.createdAt.formatted(date: .abbreviated, time: .shortened),
            durationSeconds: current.duration,
            languageCode: current.languageCode,
            summary: current.summary,
            transcriptText: current.transcriptText
        )
        saveExport(notes, suggestedName: "\(current.title) Notes", fileExtension: "md")
    }

    private func saveExport(_ content: String, suggestedName: String, fileExtension: String) {
        let panel = NSSavePanel()
        if let type = UTType(filenameExtension: fileExtension) {
            panel.allowedContentTypes = [type]
        }
        let safeName = suggestedName.replacingOccurrences(of: "/", with: "-")
        panel.nameFieldStringValue = "\(safeName).\(fileExtension)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try content.write(to: url, atomically: true, encoding: .utf8)
        } catch {
            model.alertMessage = error.localizedDescription
        }
    }

    private func formatDuration(_ duration: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = duration >= 3_600 ? [.hour, .minute] : [.minute, .second]
        formatter.unitsStyle = .abbreviated
        return formatter.string(from: duration) ?? "0m"
    }
}

/// Presents transcript-derived vocabulary candidates for review. Nothing is added until the user
/// confirms — vocabulary only takes effect after explicit review, per the product spec.
private struct VocabularySuggestionSheet: View {
    let suggestions: [String]
    let onAdd: ([String]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<String>

    init(suggestions: [String], onAdd: @escaping ([String]) -> Void) {
        self.suggestions = suggestions
        self.onAdd = onAdd
        _selected = State(initialValue: Set(suggestions))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Suggested Vocabulary").font(.headline)
                Text("Detected names and key terms from this transcript. Add the ones you want Whisper to recognize in future meetings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()

            List {
                ForEach(suggestions, id: \.self) { term in
                    Toggle(isOn: Binding(
                        get: { selected.contains(term) },
                        set: { isOn in
                            if isOn { selected.insert(term) } else { selected.remove(term) }
                        }
                    )) {
                        Text(term)
                    }
                }
            }

            HStack {
                Button(selected.count == suggestions.count ? "Deselect All" : "Select All") {
                    selected = selected.count == suggestions.count ? [] : Set(suggestions)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Add \(selected.count) Term\(selected.count == 1 ? "" : "s")") {
                    onAdd(suggestions.filter(selected.contains))
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selected.isEmpty)
            }
            .padding()
        }
        .frame(width: 440, height: 540)
    }
}

/// An inline, editable meeting title. Commits to the store on Return, on focus loss, and when the
/// view is torn down — so a rename is never lost, yet it does not persist on every keystroke. The
/// call site gives this view `.id(meetingID)`, so each instance has a fixed `meetingID` for its
/// lifetime; a commit can therefore never be written to a different meeting than the one edited.
private struct EditableMeetingTitle: View {
    @ObservedObject var store: MeetingStore
    let meetingID: UUID
    @State private var text = ""
    @State private var seeded = false
    @FocusState private var focused: Bool

    var body: some View {
        TextField("Meeting title", text: $text)
            .font(.largeTitle.bold())
            .textFieldStyle(.plain)
            .focused($focused)
            .onAppear {
                text = store.meeting(id: meetingID)?.title ?? ""
                seeded = true
            }
            .onSubmit(commit)
            .onChange(of: focused) { _, isFocused in
                if !isFocused { commit() }
            }
            .onDisappear(perform: commit)
    }

    private func commit() {
        guard seeded else { return }
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            text = store.meeting(id: meetingID)?.title ?? ""
            return
        }
        if trimmed != store.meeting(id: meetingID)?.title {
            store.update(id: meetingID) { $0.title = trimmed }
        }
    }
}

/// Owns one AVPlayer for a meeting recording and publishes its current time so the transcript can
/// highlight and scroll to the segment being heard. Tapping a segment seeks this same player.
@MainActor
private final class TranscriptPlaybackController: ObservableObject {
    let player: AVPlayer
    @Published var currentTime: Double = 0
    private var timeObserver: Any?

    init(url: URL) {
        player = AVPlayer(url: url)
        let interval = CMTime(seconds: 0.25, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(
            forInterval: interval,
            queue: .main
        ) { [weak self] time in
            // The observer is scheduled on the main queue, so this is genuinely main-actor work.
            MainActor.assumeIsolated {
                self?.currentTime = time.seconds
            }
        }
    }

    func seek(to seconds: Double) {
        player.seek(
            to: CMTime(seconds: max(0, seconds), preferredTimescale: 600),
            toleranceBefore: .zero,
            toleranceAfter: .zero
        )
        player.play()
    }

    deinit {
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
    }
}

/// A read-and-listen transcript: an inline player, a find box, and timestamped segments that
/// highlight while playing, scroll into view, and seek playback when clicked.
private struct PlayableTranscriptView: View {
    private struct IndexedSegment: Identifiable {
        let id: Int
        let segment: TranscriptSegment
    }

    @ObservedObject var store: MeetingStore
    let meetingID: UUID
    let recordingURL: URL
    let segments: [TranscriptSegment]
    @StateObject private var playback: TranscriptPlaybackController
    @State private var findText = ""
    // The filtered list is cached and recomputed only when the query changes — never on the 4 Hz
    // playback tick, which only drives the active-segment highlight.
    @State private var visible: [IndexedSegment]
    @State private var followPlayback = true

    init(
        store: MeetingStore,
        meetingID: UUID,
        recordingURL: URL,
        segments: [TranscriptSegment]
    ) {
        self.store = store
        self.meetingID = meetingID
        self.recordingURL = recordingURL
        self.segments = segments
        _playback = StateObject(wrappedValue: TranscriptPlaybackController(url: recordingURL))
        _visible = State(initialValue: segments.enumerated().map {
            IndexedSegment(id: $0.offset, segment: $0.element)
        })
    }

    private var activeIndex: Int? {
        TranscriptPlayback.activeIndex(at: playback.currentTime, in: segments)
    }

    private var isSearching: Bool {
        !findText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func recomputeVisible() {
        let query = findText.trimmingCharacters(in: .whitespacesAndNewlines)
        visible = segments.enumerated().compactMap { index, segment in
            guard query.isEmpty || TextSearch.matches(query, in: [segment.text]) else { return nil }
            return IndexedSegment(id: index, segment: segment)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if FileManager.default.fileExists(atPath: recordingURL.path) {
                AVPlayerContainer(player: playback.player)
                    .frame(height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 10))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10).stroke(.separator, lineWidth: 1)
                    }
            } else {
                Text("Recording unavailable on this Mac.").foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find in transcript", text: $findText).textFieldStyle(.plain)
                if !findText.isEmpty {
                    Button { findText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(.plain)
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("Clear search")
                }
                Divider().frame(height: 16)
                Toggle(isOn: $followPlayback) {
                    Label("Follow", systemImage: "arrow.down.circle")
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .help("Auto-scroll to the segment that is currently playing")
            }
            .padding(8)
            .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 8))

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 2) {
                        ForEach(visible) { item in
                            segmentRow(index: item.id, segment: item.segment)
                                .id(item.id)
                        }
                        if visible.isEmpty && isSearching {
                            Text("No lines match “\(findText)”.")
                                .font(.callout)
                                .foregroundStyle(.secondary)
                                .padding(12)
                        }
                    }
                    .padding(.vertical, 4)
                }
                .frame(minHeight: 320, maxHeight: 460)
                .background(.background, in: RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10).stroke(.separator, lineWidth: 1)
                }
                .onChange(of: activeIndex) { _, newValue in
                    guard followPlayback, !isSearching, let newValue else { return }
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(newValue, anchor: .center)
                    }
                }
            }
        }
        .onChange(of: findText) { _, _ in recomputeVisible() }
    }

    @ViewBuilder
    private func segmentRow(index: Int, segment: TranscriptSegment) -> some View {
        let isActive = index == activeIndex
        Button {
            if let start = segment.start { playback.seek(to: start) }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Text(segment.start.map(TranscriptFormatter.timestamp) ?? "--:--")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(isActive ? Color.accentColor : .secondary)
                    .frame(width: 52, alignment: .leading)
                Text(segment.text)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
            }
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(
                isActive ? Color.accentColor.opacity(0.15) : Color.clear,
                in: RoundedRectangle(cornerRadius: 6)
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Copy Text") { copyToPasteboard(segment.text) }
            if let start = segment.start {
                Button("Copy with Timestamp") {
                    copyToPasteboard("\(TranscriptFormatter.timestamp(start))  \(segment.text)")
                }
            }
        }
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Wraps an AVPlayerView around an externally owned AVPlayer (so the transcript and the controls
/// share one player).
private struct AVPlayerContainer: NSViewRepresentable {
    let player: AVPlayer

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.player = player
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        if nsView.player !== player {
            nsView.player = player
        }
    }
}

private struct AudioPlayerView: NSViewRepresentable {
    let url: URL

    func makeNSView(context: Context) -> AVPlayerView {
        let view = AVPlayerView()
        view.controlsStyle = .inline
        view.player = AVPlayer(url: url)
        return view
    }

    func updateNSView(_ nsView: AVPlayerView, context: Context) {
        let currentURL = (nsView.player?.currentItem?.asset as? AVURLAsset)?.url
        if currentURL != url {
            nsView.player = AVPlayer(url: url)
        }
    }
}
