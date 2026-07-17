import AppKit
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
                                    store.delete(id: meeting.id)
                                    if selection == .meeting(meeting.id) {
                                        selection = .record
                                    }
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
                get: { model.alertMessage != nil },
                set: { if !$0 { model.alertMessage = nil } }
            )
        ) {
            Button("OK") { model.alertMessage = nil }
        } message: {
            Text(model.alertMessage ?? "")
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
            } else if model.recordingState == .idle {
                VStack(alignment: .leading, spacing: 16) {
                    TextField("Meeting title (optional)", text: $title)
                        .textFieldStyle(.roundedBorder)
                }
                .frame(maxWidth: 440)
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
                    Task { await model.cancelRecording() }
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
    }

    private var isRecording: Bool {
        if case .recording = model.recordingState { return true }
        return false
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
    @State private var draft = ""

    var body: some View {
        if let meeting = store.meeting(id: meetingID) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header(meeting)
                    statusCard(meeting)

                    if meeting.status == .completed {
                        if !meeting.segments.isEmpty {
                            transcriptSegments(meeting)
                        } else {
                            transcriptEditor(meeting)
                        }
                    }
                }
                .frame(maxWidth: 860, alignment: .leading)
                .padding(32)
                .frame(maxWidth: .infinity)
            }
            .navigationTitle(meeting.title)
            .onAppear { draft = meeting.transcriptText }
            .onChange(of: meeting.transcriptText) { _, value in
                if draft != value { draft = value }
            }
        }
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

    private func transcriptSegments(_ meeting: MeetingRecord) -> some View {
        return VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Timestamped Transcript").font(.headline)
                Spacer()
                Button("Copy") { copy(meeting.transcriptText) }
                Button("Export…") {
                    export(meeting: meeting, text: meeting.transcriptText)
                }
            }
            .padding(.bottom, 10)
            ForEach(meeting.segments.indices, id: \.self) { index in
                let segment = meeting.segments[index]
                HStack(alignment: .top, spacing: 14) {
                    VStack(alignment: .trailing, spacing: 3) {
                        if let start = segment.start {
                            Text(timestamp(start))
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                    }
                    .frame(width: 64, alignment: .trailing)
                    TextEditor(text: Binding(
                        get: {
                            guard let current = store.meeting(id: meeting.id),
                                  current.segments.indices.contains(index) else { return "" }
                            return current.segments[index].text
                        },
                        set: { value in updateSegmentText(value, meetingID: meeting.id, index: index) }
                    ))
                    .scrollContentBackground(.hidden)
                    .frame(maxWidth: .infinity, minHeight: 52, maxHeight: 130)
                    .padding(6)
                    .background(.background, in: RoundedRectangle(cornerRadius: 7))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7)
                            .stroke(.separator, lineWidth: 1)
                    }
                }
                .padding(.vertical, 11)
                Divider()
            }
        }
    }

    private func transcriptEditor(_ meeting: MeetingRecord) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Editable Transcript").font(.headline)
                Spacer()
                Button("Copy") { copy(draft) }
                Button("Export…") { export(meeting: meeting, text: draft) }
                Button("Save Changes") {
                    store.update(id: meeting.id) { $0.transcriptText = draft }
                }
                .buttonStyle(.borderedProminent)
                .disabled(draft == meeting.transcriptText)
            }
            TextEditor(text: $draft)
                .font(.body)
                .scrollContentBackground(.hidden)
                .padding(12)
                .frame(minHeight: 320)
                .background(.background, in: RoundedRectangle(cornerRadius: 10))
                .overlay {
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(.separator, lineWidth: 1)
                }
        }
    }

    private func updateSegmentText(_ text: String, meetingID: UUID, index: Int) {
        store.update(id: meetingID) { meeting in
            guard meeting.segments.indices.contains(index) else { return }
            meeting.segments[index].text = text
            meeting.transcriptText = meeting.segments.map(\.text).joined(separator: "\n")
        }
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

    private func timestamp(_ seconds: Double) -> String {
        let total = max(0, Int(seconds))
        return String(format: "%02d:%02d", total / 60, total % 60)
    }
}
