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

struct ContentView: View {
    @ObservedObject var model: AppModel
    @ObservedObject private var store: MeetingStore
    @State private var selection: SidebarItem? = .record
    @State private var pendingDeletion: MeetingRecord?

    init(model: AppModel) {
        self.model = model
        store = model.store
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
                    }
                    ForEach(store.meetings) { meeting in
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
                store.delete(id: meeting.id)
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
                TranscriptDetailView(model: model, store: store, meetingID: id)
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
                TimelineView(.periodic(from: .now, by: 1)) { context in
                    Text(duration(Date.now.timeIntervalSince(startedAt)))
                        .font(.system(.title, design: .monospaced).weight(.medium))
                        .contentTransition(.numericText())
                }
                recordingHealthPanel
            } else if model.recordingState == .idle {
                VStack(alignment: .leading, spacing: 16) {
                    TextField("Meeting title (optional)", text: $title)
                        .textFieldStyle(.roundedBorder)
                    preflightPanel
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
            .disabled(model.recordingState == .starting || model.recordingState == .stopping)

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

    @ViewBuilder
    private var recordingHealthPanel: some View {
        if let health = model.recordingHealth {
            VStack(alignment: .leading, spacing: 12) {
                Text("Recording health")
                    .font(.headline)
                levelRow(
                    title: "Microphone",
                    systemImage: "mic.fill",
                    level: health.microphoneLevel.rms
                )
                levelRow(
                    title: "System audio",
                    systemImage: "speaker.wave.2.fill",
                    level: health.systemAudioLevel.rms
                )
                HStack(spacing: 9) {
                    Image(systemName: "internaldrive.fill")
                        .frame(width: 18)
                    Text(storageDescription(health.availableStorageBytes) + " available")
                        .foregroundStyle(storageColor(health.availableStorageBytes))
                }
                ForEach(health.warnings, id: \.self) { warning in
                    Label(warningMessage(warning), systemImage: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                }
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
                Label("Not granted — check System Settings", systemImage: "exclamationmark.circle.fill")
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

    private func levelRow(
        title: String,
        systemImage: String,
        level: Float
    ) -> some View {
        HStack(spacing: 9) {
            Image(systemName: systemImage)
                .frame(width: 18)
            Text(title)
                .frame(width: 96, alignment: .leading)
            ProgressView(value: min(1, Double(level) * 4))
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

    var body: some View {
        if let meeting = store.meeting(id: meetingID) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header(meeting)
                    statusCard(meeting)

                    if meeting.status == .completed {
                        recordingPlayer(meeting)
                        summarySection(meeting)
                        transcriptEditor(meeting)
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
            Text(meeting.title)
                .font(.largeTitle.bold())
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
            HStack(spacing: 14) {
                if meeting.status == .processing {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: meeting.status == .failed ? "exclamationmark.triangle.fill" : "waveform.badge.plus")
                        .foregroundStyle(meeting.status == .failed ? .red : .orange)
                }
                VStack(alignment: .leading, spacing: 3) {
                    Text(meeting.status.title).fontWeight(.semibold)
                    if let error = meeting.errorMessage {
                        Text(error).foregroundStyle(.secondary)
                    } else if meeting.status == .recorded {
                        Text("The audio is safely stored on this Mac.").foregroundStyle(.secondary)
                    }
                }
                Spacer()
                if meeting.status == .processing {
                    Button("Cancel", role: .destructive) {
                        model.cancelTranscription(id: meeting.id)
                    }
                } else if meeting.status == .recorded || meeting.status == .failed {
                    Button("Transcribe") {
                        model.beginTranscription(id: meeting.id)
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .padding(18)
            .background(.quaternary.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
        }
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

    private func transcriptEditor(_ meeting: MeetingRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Transcript").font(.headline)
                Spacer()
                Button("Copy") { copy(currentTranscript()) }
                Button("Export…") { export(meeting: meeting, text: currentTranscript()) }
            }
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
    }

    /// Upgrades meetings transcribed before the unified-transcript change: if a completed
    /// meeting still has plain text plus segments, rebuild its transcript with inline
    /// timestamps once. Freeform edits (already timestamped) are left untouched.
    private func normalizeTranscriptIfNeeded(_ meeting: MeetingRecord) {
        guard meeting.status == .completed, !meeting.segments.isEmpty,
              !TranscriptFormatter.isTimestamped(meeting.transcriptText) else { return }
        let rebuilt = TranscriptFormatter.timestamped(meeting.segments)
        guard !rebuilt.isEmpty else { return }
        store.update(id: meeting.id) { $0.transcriptText = rebuilt }
    }

    private func currentTranscript() -> String {
        store.meeting(id: meetingID)?.transcriptText ?? ""
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }

    private func export(meeting: MeetingRecord, text: String) {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = meeting.title.replacingOccurrences(of: "/", with: "-") + ".txt"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try text.write(to: url, atomically: true, encoding: .utf8)
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
