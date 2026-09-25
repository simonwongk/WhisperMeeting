import AppKit
import AVFoundation
import AVKit
import ServiceManagement
import SwiftUI
import UniformTypeIdentifiers
import WhisperCore

private enum SidebarItem: Hashable {
    case record
    case vocabulary
    case askMeetings
    case dictation
    case settings
    case meeting(UUID)
}

private enum TranscriptMode: Hashable {
    case read
    case edit
}

struct ContentView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var dictation: DictationController
    @ObservedObject private var store: MeetingStore
    // A set, not an optional: this is what gives the sidebar macOS's native shift-range and
    // ⌘-toggle selection. Navigation rows share the list with meetings, so a shift-range can
    // include them; `selectedMeetingIDs` filters them out rather than trying to make them
    // unselectable, which a single SwiftUI `List` cannot express.
    @State private var selection: Set<SidebarItem> = [.record]
    @State private var selectedTags: Set<String> = []
    /// Meetings awaiting delete confirmation. A list rather than one record, so a multi-selection
    /// confirms once and names everything it is about to remove.
    @State private var pendingDeletion: [MeetingRecord] = []
    @State private var searchText = ""
    // F180 "Ask Meetings" query + scope, held here (like searchText/selectedTags) so they survive the
    // detail view's per-selection recreation and are restored on return.
    @State private var askQuery = ""
    @State private var askScopeTags: Set<String> = []
    @State private var askTagMode: MeetingTags.MatchMode = .any
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    init(model: AppModel, dictation: DictationController) {
        self.model = model
        self.dictation = dictation
        store = model.store
    }

    private var filteredMeetings: [MeetingRecord] {
        let raw = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        let query = raw.isEmpty ? nil : MeetingQuery.parse(raw)
        let selected = Array(selectedTags)
        guard query != nil || !selected.isEmpty else { return store.meetings }
        return store.meetings.filter { meeting in
            MeetingLibraryFilter.includes(
                query: query,
                facets: MeetingFacets(
                    languageCode: meeting.languageCode,
                    status: meeting.status.rawValue,
                    durationSeconds: meeting.duration,
                    createdAt: meeting.createdAt,
                    textFields: [meeting.title, meeting.transcriptText, meeting.notes ?? ""]
                ),
                meetingTags: meeting.tags ?? [],
                selectedTags: selected,
                tagMode: .any
            )
        }
    }

    /// The selected meetings in sidebar order. Navigation items in the selection are ignored, so a
    /// shift-range that crosses the Meetings section boundary never "selects Settings".
    private var selectedMeetingIDs: [UUID] {
        let chosen = Set(selection.compactMap { item -> UUID? in
            if case let .meeting(id) = item { return id }
            return nil
        })
        return filteredMeetings.map(\.id).filter { chosen.contains($0) }
    }

    /// The single selected item, when exactly one thing is selected.
    private var singleSelection: SidebarItem? {
        selection.count == 1 ? selection.first : nil
    }

    var body: some View {
        NavigationSplitView {
            List(selection: $selection) {
                Section {
                    Label("New Meeting", systemImage: "record.circle")
                        .tag(SidebarItem.record)
                    Label("Business Vocabulary", systemImage: "text.book.closed")
                        .tag(SidebarItem.vocabulary)
                    Label("Ask Meetings", systemImage: "text.magnifyingglass")
                        .tag(SidebarItem.askMeetings)
                    Label("Dictation", systemImage: "mic.fill")
                        .tag(SidebarItem.dictation)
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
                        MeetingRow(meeting: meeting, selectedTags: $selectedTags)
                            .tag(SidebarItem.meeting(meeting.id))
                            .contextMenu {
                                // Right-clicking inside a multi-selection acts on the whole
                                // selection; right-clicking outside it keeps the single-row menu,
                                // which is the Finder grammar users already expect.
                                let batch = selectedMeetingIDs.count > 1
                                    && selectedMeetingIDs.contains(meeting.id)
                                if batch {
                                    Button("Delete \(selectedMeetingIDs.count) Meetings", role: .destructive) {
                                        let chosen = Set(selectedMeetingIDs)
                                        pendingDeletion = store.meetings.filter { chosen.contains($0.id) }
                                    }
                                } else {
                                    Button((meeting.pinned ?? false) ? "Unpin" : "Pin to Top") {
                                        // The row glides to its new position instead of teleporting
                                        // (F116). Call-site animation, so search filtering stays
                                        // instant.
                                        withAnimation(reduceMotion ? nil : .uiSpring) {
                                            store.togglePin(id: meeting.id)
                                        }
                                    }
                                    Button("Delete Meeting", role: .destructive) {
                                        pendingDeletion = [meeting]
                                    }
                                }
                            }
                    }
                }
            }
            .navigationTitle("WhisperMeet")
            .navigationSplitViewColumnWidth(min: 245, ideal: 290)
        } detail: {
            // F313: the standing sign that the library is read-only, on a surface that is not
            // modal. F194 put that job on the storage alert and made dismissing it restore the
            // message, which made the alert impossible to close. This shows for as long as the
            // library is degraded and never asks to be dismissed. An overlay, because the two
            // layout-affecting placements were tried on screen and both failed: `.safeAreaInset`
            // and a `VStack` each pushed the banner to y = -716 (the accessibility tree still
            // listed it, off the top of the window) and blanked the sidebar list. An overlay draws
            // on top of the column and cannot move anything underneath it.
            detail
                .overlay(alignment: .top) {
                    ReadOnlyLibraryBanner(model: model)
                }
        }
        // Attached to the split view, not the sidebar list: on the list, even .toolbar placement
        // renders inside the sidebar and scrolls beneath the window controls (observed live,
        // F126); at this level it lands in the window toolbar like Finder/Mail.
        .searchable(text: $searchText, placement: .toolbar, prompt: "Search — try lang:zh, min:30m, before:2026-06-01")
        // F180: an "Ask Meetings" cited result drives the sidebar selection from the model (survives the
        // detail view's per-selection recreation). The detail view consumes the seek on appear.
        .onChange(of: model.pendingNavigation) { _, request in
            guard let request else { return }
            selection = [.meeting(request.meetingID)]
        }
        .sheet(isPresented: $model.showsShortcutsSheet) { KeyboardShortcutsView() }
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
            pendingDeletion.count > 1
                ? "Permanently delete \(pendingDeletion.count) meetings?"
                : "Permanently delete this meeting?",
            isPresented: Binding(
                get: { !pendingDeletion.isEmpty },
                set: { if !$0 { pendingDeletion = [] } }
            ),
            titleVisibility: .visible
        ) {
            Button("Delete Recording and Transcript", role: .destructive) {
                let doomed = pendingDeletion
                guard !doomed.isEmpty else { return }
                // Only the list mutation animates (rows collapse); the selection swap stays outside
                // the transaction so the detail column changes instantly (F116).
                withAnimation(reduceMotion ? nil : .uiSpring) {
                    model.deleteMeetings(ids: doomed.map(\.id))
                }
                let removed = Set(doomed.map { SidebarItem.meeting($0.id) })
                selection.subtract(removed)
                if selection.isEmpty { selection = [.record] }
                pendingDeletion = []
            }
            Button("Keep Meeting", role: .cancel) {
                pendingDeletion = []
            }
        } message: {
            if pendingDeletion.count > 1 {
                Text("This removes the local recording, its source tracks, and its transcript for each of:\n\n"
                    + pendingDeletion.map { "• \($0.title)" }.joined(separator: "\n")
                    + "\n\nThis action cannot be undone by WhisperMeet.")
            } else {
                Text("This removes the local recording, its source tracks, and its transcript. This action cannot be undone by WhisperMeet.")
            }
        }
    }

    @ViewBuilder
    private var detail: some View {
        if selectedMeetingIDs.count > 1 {
            MeetingBatchView(store: store, meetingIDs: selectedMeetingIDs) {
                let chosen = Set(selectedMeetingIDs)
                pendingDeletion = store.meetings.filter { chosen.contains($0.id) }
            }
        } else {
            singleDetail
        }
    }

    @ViewBuilder
    private var singleDetail: some View {
        switch singleSelection ?? .record {
        case .record:
            RecordMeetingView(model: model) { meetingID in
                selection = [.meeting(meetingID)]
            }
        case .vocabulary:
            VocabularyView(store: store)
        case .askMeetings:
            AskMeetingsView(
                model: model,
                store: store,
                query: $askQuery,
                scopeTags: $askScopeTags,
                tagMode: $askTagMode
            )
        case .dictation:
            DictationView(dictation: dictation, log: dictation.logStore, model: model)
        case .settings:
            SettingsView(model: model, dictation: dictation)
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
    @Binding var selectedTags: Set<String>

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                if meeting.pinned ?? false {
                    Image(systemName: "pin.fill")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("Pinned")
                }
                Text(meeting.title)
                    .fontWeight(.medium)
                    .lineLimit(1)
            }
            HStack(spacing: 6) {
                Circle()
                    .fill(statusColor)
                    .frame(width: 7, height: 7)
                    // Color-only handoff as the meeting moves through its pipeline (F162);
                    // value-scoped so list filtering/selection changes never animate the dot.
                    .animation(.tintShift, value: meeting.status)
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

            if let tags = meeting.tags, !tags.isEmpty {
                HStack(spacing: 4) {
                    ForEach(tags.prefix(4), id: \.self) { tag in
                        let isSelected = selectedTags.contains(tag)
                        Button {
                            if isSelected { selectedTags.remove(tag) } else { selectedTags.insert(tag) }
                        } label: {
                            Text(tag)
                                .font(.caption2)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(
                                    isSelected ? Color.accentColor : Color.secondary.opacity(0.18),
                                    in: Capsule()
                                )
                                .foregroundStyle(isSelected ? Color.white : Color.primary)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(AccessibilityPhrase.meetingRow(
            title: meeting.title,
            statusRaw: meeting.status.rawValue,
            duration: meeting.duration
        ))
        .accessibilityActions {
            // The tag chips group into the row's single accessibility element, so expose tag
            // filtering as VoiceOver actions rather than leaving it mouse-only (F84).
            ForEach(meeting.tags ?? [], id: \.self) { tag in
                let isSelected = selectedTags.contains(tag)
                Button(isSelected ? "Remove tag filter \(tag)" : "Filter by tag \(tag)") {
                    if isSelected { selectedTags.remove(tag) } else { selectedTags.insert(tag) }
                }
            }
        }
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
    // F298: the title lives on the model, not here. A `@State` copy existed nowhere but this
    // view, so F258's sidecar had nothing to persist at start and a crash, ⌘Q or a shutdown took
    // the title with it. Binding straight to the model means there is no second copy to keep in
    // step — and no moment where the two disagree.
    @State private var showsImporter = false
    @State private var showsLinkSheet = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @ScaledMetric(relativeTo: .largeTitle) private var heroIconSize: CGFloat = 44

    /// The record screen's content column, hosted in `body`'s ScrollView (F125).
    private var recordContent: some View {
        VStack(spacing: 28) {
            VStack(spacing: 12) {
                heroBadge
                Text(recordingHeadline)
                    .font(.largeTitle.bold())
                Text(recordingSubtitle)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: 520)
            }

            // Outside the state branch on purpose (F275). The health panel renders only while
            // `.recording`, so putting this inside it would show the "resumed" notice and hide the
            // "stopped and saved" one — the more important of the two, since that is the case where
            // the recording ended without the user asking and they are owed the reason.
            captureRestartBanner
                .frame(maxWidth: 560)

            if case let .recording(startedAt) = model.recordingState {
                liveRecordingPanel(startedAt: startedAt)
                recordingHealthPanel
            } else if model.recordingState == .idle {
                VStack(alignment: .leading, spacing: 16) {
                    TextField("Meeting title (optional)", text: $model.recordingTitle)
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
            .buttonBorderShape(.capsule)
            .tint(isRecording ? .red : .accentColor)
            .controlSize(.large)
            .disabled(isPrimaryActionBusy)
            .accessibilityLabel(AccessibilityPhrase.recordButton(
                isRecording: isRecording,
                isBusy: isPrimaryActionBusy
            ))

            if isRecording {
                Button("Cancel Recording", role: .destructive) {
                    model.requestCancelConfirmation()
                }
                .buttonStyle(LinkPressStyle())
            }

            Label(
                "Make sure everyone has agreed to the recording. Headphones reduce echo and improve accuracy.",
                systemImage: "hand.raised"
            )
            .font(.callout)
            .foregroundStyle(.secondary)
            .frame(maxWidth: 560)
        }
    }

    var body: some View {
        GeometryReader { geometry in
            ScrollView {
                recordContent
                    .padding(40)
                    // Take the full ideal height: without this, the minHeight frame compresses
                    // the column into the viewport — captions truncate to one line and scrolling
                    // goes dead (observed live, F125).
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity)
                    // Center when the content fits the window; scroll when it does not — the
                    // Stop button must always be reachable (F125).
                    .frame(minHeight: geometry.size.height)
            }
        }
        // One critically-damped spring for the idle ⇄ recording layout swap; disabled entirely
        // under Reduce Motion.
        .animation(reduceMotion ? nil : .uiSpring, value: model.recordingState)
        .navigationTitle("New Meeting")
        .onAppear { model.refreshRecordingPreflight() }
        .confirmationDialog(
            "Discard this recording?",
            isPresented: $model.isConfirmingCancellation,
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
                    if let id = await model.importRecordings(from: urls, title: model.recordingTitle).firstID {
                        onMeetingSaved(id)
                        model.recordingTitle = ""
                    }
                }
            case let .failure(error):
                model.alertMessage = error.localizedDescription
            }
        }
        .sheet(isPresented: Binding(
            get: { model.isPreflightTestActive },
            set: { if !$0 { model.dismissPreflightTest() } }
        )) {
            PreflightTestSheet(model: model)
        }
        .sheet(isPresented: $showsLinkSheet) {
            LinkImportSheet(model: model) { meetingID in
                onMeetingSaved(meetingID)
                model.recordingTitle = ""
            }
        }
    }

    private var isRecording: Bool {
        if case .recording = model.recordingState { return true }
        return false
    }

    private var isPrimaryActionBusy: Bool {
        model.recordingState == .starting
            || model.recordingState == .stopping
            || model.isImporting
            || model.isInstallingRecognitionRuntime
    }

    /// The tinted orb behind the state icon — the screen's visual anchor. Pulses only while
    /// recording, and never when the user has asked for reduced motion.
    private var heroBadge: some View {
        ZStack {
            Circle()
                .fill(heroTint.opacity(0.13))
            Circle()
                .strokeBorder(heroTint.opacity(0.22), lineWidth: 1)
            Image(systemName: recordingIcon)
                .font(.system(size: heroIconSize, weight: .light))
                .foregroundStyle(heroTint)
                .symbolEffect(.pulse, isActive: isRecording && !reduceMotion)
        }
        .frame(width: heroIconSize * 2.4, height: heroIconSize * 2.4)
        .accessibilityHidden(true)
    }

    private var heroTint: Color { isRecording ? .red : .accentColor }

    private var preflightPanel: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Before recording")
                    .font(.headline)
                Spacer()
                Button("Check Again") { model.refreshRecordingPreflight() }
                    .buttonStyle(LinkPressStyle())
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
            Divider()
            Button {
                model.startPreflightTest()
            } label: {
                Label("Test Recording…", systemImage: "waveform.badge.mic")
            }
            .buttonStyle(LinkPressStyle())
            .foregroundStyle(.tint)
            .disabled(model.isInstallingRecognitionRuntime)
            .help("Record a few disposable seconds and check that both your microphone and Mac system audio are actually captured.")
        }
        .font(.callout)
        .padding(18)
        .cardSurface()
    }

    private func liveRecordingPanel(startedAt: Date) -> some View {
        VStack(spacing: 16) {
            TimelineView(.periodic(from: .now, by: 1)) { _ in
                let elapsed = max(0, Date.now.timeIntervalSince(startedAt))
                VStack(spacing: 4) {
                    Text(duration(elapsed))
                        .font(.system(.largeTitle, design: .rounded).weight(.medium))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                    Text("Estimated recording size: \(recordingSizeText(elapsed))")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("Using \(workingSizeText(elapsed)) on disk while the source tracks are kept")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            LiveVolumeBar(meter: model.recordingMeter)
                .frame(maxWidth: 560)
            markerControls
        }
    }

    private var markerControls: some View {
        VStack(spacing: 6) {
            Button {
                model.addLiveMarker()
            } label: {
                Label("Add Marker", systemImage: "bookmark.fill")
                    .frame(minWidth: 150)
            }
            .buttonStyle(.bordered)
            // ⇧⌘M is owned by the Recording command menu (F85) — a second registration here would
            // make it an ambiguous shortcut. The button remains; only its duplicate binding is removed.
            .help("Flag this moment (⇧⌘M). Markers are timestamps only — they never change the recording.")
            Text(model.pendingMarkers.isEmpty
                ? "No markers yet — press ⇧⌘M to flag an important moment."
                : "\(model.pendingMarkers.count) marker\(model.pendingMarkers.count == 1 ? "" : "s") dropped")
                .font(.caption)
                .foregroundStyle(.secondary)
                .contentTransition(.numericText())
        }
    }

    private var importPanel: some View {
        VStack(alignment: .leading, spacing: 8) {
            Button {
                showsImporter = true
            } label: {
                Label("Import Recordings…", systemImage: "square.and.arrow.down")
            }
            .disabled(model.isImporting || model.isInstallingRecognitionRuntime)
            // F183: opt-in link import. The button appears only once the user has switched the feature
            // on in Settings, so the network path is never ambient.
            if model.linkImportEnabled {
                Button {
                    showsLinkSheet = true
                } label: {
                    Label("Add from a Link…", systemImage: "link")
                }
                .disabled(model.isImporting || model.isInstallingRecognitionRuntime)
            }
            // F185: after a bulk import, pressing Transcribe once per meeting is tedious — queue them
            // all in one action. Uses the normal per-meeting path, so the one-at-a-time queue applies.
            let ready = model.readyToTranscribeMeetings.count
            if ready > 1 {
                Button {
                    model.beginTranscriptionForAllReady()
                } label: {
                    Label("Transcribe \(ready) Ready Meetings", systemImage: "text.badge.checkmark")
                }
                .disabled(model.isImporting || model.isInstallingRecognitionRuntime || model.isRunningAuxiliaryEngine)
            }
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
                RecordingChannelHealthRow(
                    title: "Microphone (you)",
                    systemImage: "mic.fill",
                    meter: model.recordingMeter,
                    channel: .microphone,
                    health: health
                )
                RecordingChannelHealthRow(
                    title: "System audio (others)",
                    systemImage: "speaker.wave.2.fill",
                    meter: model.recordingMeter,
                    channel: .systemAudio,
                    health: health
                )
                storageRow(health)
                healthExplainer
            }
            .font(.callout)
            .padding(18)
            .frame(maxWidth: 560)
            .cardSurface()
        } else {
            ProgressView("Checking both audio channels…")
                .frame(maxWidth: 560)
        }
    }

    /// What a restart did, when one happened (F275).
    ///
    /// Shown rather than logged because "never restart silently" is an invariant, not copy polish:
    /// the transcript's timestamps mean different things depending on whether the recording was
    /// continuous, so a user who cannot tell a continuous recording from a patched one has no way
    /// to read them.
    @ViewBuilder
    private var captureRestartBanner: some View {
        if let notice = model.captureRestartNotice {
            HStack(alignment: .firstTextBaseline, spacing: 11) {
                Image(systemName: "arrow.clockwise.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.orange)
                Text(notice)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Recording interruption")
            .accessibilityValue(notice)
        }
    }

    private func healthStatusBanner(_ health: RecordingHealthSnapshot) -> some View {
        HStack(spacing: 11) {
            Image(systemName: statusIcon(health.overallStatus))
                .font(.title3)
                .foregroundStyle(statusColor(health.overallStatus))
                .contentTransition(reduceMotion ? .opacity : .symbolEffect(.replace))
            VStack(alignment: .leading, spacing: 2) {
                Text(statusTitle(health.overallStatus))
                    .fontWeight(.semibold)
                    .contentTransition(.opacity)
                Text(statusReason(health))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .contentTransition(.opacity)
            }
            Spacer()
        }
        // The continuously watched surface: status flips fade (color/text only, no movement)
        // instead of teleporting, so a warning reads as a monitored transition, not a glitch.
        .animation(.tintShift, value: health.overallStatus)
        .animation(.tintShift, value: health.warnings)
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
        if health.captureStoppedOnBothChannels {
            // F292: a lid closed while docked, or a display unplugged — not a microphone fault.
            // No "…is trying to restart it" here (F344): this is a pure function of one snapshot,
            // and the claim is false once the padding cap is reached and while the recording is
            // finishing. The restart, when there is one, says so itself through
            // `captureRestartNotice`, which knows the state this does not.
            return "Audio capture stopped on both channels. This happens when a display is disconnected or the lid is closed."
        }
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
        case .captureWritesFailing:
            // The one warning that means audio is being lost as they read it, so the instruction
            // comes first (F386).
            "Stop this recording: audio is no longer being written to disk. Check free space. What was captured before now is safe."
        case .approachingLengthLimit:
            // Says what happens and what to do, and does not mention the format. A user cannot act
            // on "the WAV data-size field is a UInt32"; they can act on "stop and start another".
            "This recording is nearly 12 hours long. Stop and start a new one soon — past that length, some apps will only read the first part of the file."
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

    /// The headline above the record button. Renamed from `recordingTitle` when F298 put the
    /// user's own title on the model under that name — one identifier meaning both "Recording" and
    /// the name of the user's meeting, in one file, is how someone later writes one and gets the
    /// other.
    private var recordingHeadline: String {
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
                if let id = await model.stopRecording(title: model.recordingTitle) {
                    onMeetingSaved(id)
                    model.recordingTitle = ""
                }
            }
        case .starting, .stopping:
            break
        }
    }

    private func duration(_ interval: TimeInterval) -> String {
        // `Int(saturating:)` before the clamp, not after: `max(0, Int(interval))` traps before
        // `max` can run, which is F287's exact shape.
        let total = max(0, Int(saturating: interval))
        return String(format: "%02d:%02d:%02d", total / 3_600, (total / 60) % 60, total % 60)
    }
}

/// Markers shown before a transcript exists (e.g. recorded-but-not-yet-transcribed, or transcription
/// failed) so they can always be reviewed, renamed, or removed. Seeking lives in the richer playback
/// strip that appears once there are segments.
private struct SimpleMarkersList: View {
    @ObservedObject var model: AppModel
    let meetingID: UUID
    let markers: [RecordingMarker]
    @State private var renamingMarker: RecordingMarker?
    @State private var renameText = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label("Markers", systemImage: "bookmark.fill")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            ForEach(Array(markers.enumerated()), id: \.element.id) { index, marker in
                HStack(spacing: 8) {
                    // The timestamp + label pair reads as one VoiceOver element ("Marker <label>
                    // at MM:SS", F87); the Rename/Delete buttons stay individually reachable.
                    HStack(spacing: 8) {
                        Text(TranscriptFormatter.timestamp(marker.offset))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                            .frame(width: 48, alignment: .leading)
                        Text(RecordingMarkers.displayLabel(for: marker, at: index + 1))
                            .font(.callout)
                    }
                    .accessibilityElement(children: .ignore)
                    .accessibilityLabel(AccessibilityPhrase.marker(
                        label: RecordingMarkers.displayLabel(for: marker, at: index + 1),
                        offset: marker.offset
                    ))
                    Spacer()
                    Button("Rename") {
                        renameText = marker.label ?? ""
                        renamingMarker = marker
                    }
                    .buttonStyle(LinkPressStyle())
                    .foregroundStyle(.tint)
                    Button(role: .destructive) {
                        model.removeMarker(marker.id, from: meetingID)
                    } label: {
                        Image(systemName: "trash")
                    }
                    .buttonStyle(LinkPressStyle())
                    .foregroundStyle(.secondary)
                    .accessibilityLabel("Delete marker")
                }
                .font(.callout)
            }
        }
        .padding(14)
        .cardSurface(cornerRadius: 12)
        .alert("Rename Marker", isPresented: Binding(
            get: { renamingMarker != nil },
            set: { if !$0 { renamingMarker = nil } }
        )) {
            TextField("Label", text: $renameText)
            Button("Save") {
                if let marker = renamingMarker {
                    model.renameMarker(marker.id, to: renameText, in: meetingID)
                }
                renamingMarker = nil
            }
            Button("Cancel", role: .cancel) { renamingMarker = nil }
        } message: {
            Text("Give this moment a name, or clear it to revert to a numbered marker.")
        }
    }
}

/// A disposable "does my recording actually work?" check: records a few seconds, then reports
/// whether the microphone and Mac system audio were each captured. Never becomes a meeting.
private struct PreflightTestSheet: View {
    @ObservedObject var model: AppModel
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    // Scaled (not fixed) display sizes so the sheet follows the user's text size (F87).
    @ScaledMetric(relativeTo: .largeTitle) private var heroSymbolSize: CGFloat = 40
    @ScaledMetric(relativeTo: .largeTitle) private var countdownSize: CGFloat = 48
    @ScaledMetric(relativeTo: .title) private var statusSymbolSize: CGFloat = 32

    var body: some View {
        // A ZStack, not a VStack: during a phase cross-fade the outgoing and incoming views
        // overlay in place instead of transiently stacking, so nothing slides (F116).
        ZStack {
            switch model.preflightTest {
            case .idle:
                // The sheet is dismissing; render nothing.
                Color.clear.frame(height: 1)
            case let .recording(secondsRemaining):
                recordingView(secondsRemaining)
                    .transition(.gentleFade(reduceMotion: reduceMotion))
            case .analyzing:
                analyzingView
                    .transition(.gentleFade(reduceMotion: reduceMotion))
            case let .result(report, playbackURL):
                resultView(report, playbackURL: playbackURL)
                    .transition(.gentleFade(reduceMotion: reduceMotion))
            case let .failed(message):
                failedView(message)
                    .transition(.gentleFade(reduceMotion: reduceMotion))
            }
        }
        .padding(28)
        .frame(width: 470)
        // Phases cross-fade instead of hard-swapping (F116). Keyed on a case discriminant, not
        // the enum itself, so the per-second countdown never re-triggers the transition. The
        // sheet's height settles with the same spring (it is not fixed); under Reduce Motion the
        // resize is instant and only the fade remains.
        .animation(reduceMotion ? nil : .uiSpring, value: phaseKey)
    }

    private var phaseKey: Int {
        switch model.preflightTest {
        case .idle: 0
        case .recording: 1
        case .analyzing: 2
        case .result: 3
        case .failed: 4
        }
    }

    private func recordingView(_ secondsRemaining: Int) -> some View {
        VStack(spacing: 18) {
            Image(systemName: "waveform.badge.mic")
                .font(.system(size: heroSymbolSize, weight: .light))
                .foregroundStyle(.tint)
                .symbolEffect(.pulse, isActive: !reduceMotion)
            Text("Testing your recording")
                .font(.title2.bold())
            Text("Speak normally. If your meeting will share audio — a video, call, or music — play some now so both channels are exercised.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            Text("\(secondsRemaining)")
                .font(.system(size: countdownSize, design: .rounded).weight(.semibold))
                .monospacedDigit()
                .contentTransition(.numericText())
                .frame(minWidth: 70)
            Button("Cancel", role: .cancel) { model.cancelPreflightTest() }
                .controlSize(.large)
        }
    }

    private var analyzingView: some View {
        VStack(spacing: 18) {
            ProgressView()
                .controlSize(.large)
            Text("Analyzing both channels…")
                .font(.title3.weight(.medium))
        }
        .frame(minHeight: 160)
    }

    private func resultView(_ report: PreflightReport, playbackURL: URL?) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: headlineIcon(report))
                    .font(.system(size: statusSymbolSize))
                    .foregroundStyle(headlineColor(report))
                Text(report.headline)
                    .font(.headline)
                    .fixedSize(horizontal: false, vertical: true)
            }

            channelRow(
                title: "Microphone (you)",
                systemImage: "mic.fill",
                channel: report.microphone
            )
            channelRow(
                title: "Mac system audio (others)",
                systemImage: "speaker.wave.2.fill",
                channel: report.system
            )

            if let playbackURL {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Play back the test").font(.caption).foregroundStyle(.secondary)
                    AudioPlayerView(url: playbackURL)
                        .frame(height: 40)
                        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                }
            }

            HStack {
                Button("Test Again") {
                    model.dismissPreflightTest()
                    model.startPreflightTest()
                }
                Spacer()
                Button("Done") { model.dismissPreflightTest() }
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
    }

    private func failedView(_ message: String) -> some View {
        VStack(spacing: 16) {
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: statusSymbolSize))
                .foregroundStyle(.orange)
            Text("The test could not complete")
                .font(.title3.bold())
            Text(message)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            HStack {
                Button("Try Again") {
                    model.dismissPreflightTest()
                    model.startPreflightTest()
                }
                Button("Close", role: .cancel) { model.dismissPreflightTest() }
                    .buttonStyle(.borderedProminent)
            }
        }
    }

    private func channelRow(
        title: String,
        systemImage: String,
        channel: PreflightChannelReport
    ) -> some View {
        let style = levelStyle(channel.signal.level)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 10) {
                Image(systemName: systemImage)
                    .frame(width: 20)
                    .foregroundStyle(.secondary)
                Text(title)
                Spacer()
                Label(style.label, systemImage: style.icon)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(style.color)
            }
            if let note = channel.note {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 30)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .cardSurface(cornerRadius: 10)
    }

    private func levelStyle(
        _ level: ChannelSignalLevel
    ) -> (label: String, icon: String, color: Color) {
        switch level {
        case .silent: return ("No signal", "xmark.circle.fill", .red)
        case .faint: return ("Very quiet", "exclamationmark.triangle.fill", .yellow)
        case .ok: return ("Good", "checkmark.circle.fill", .green)
        case .hot: return ("Too loud", "exclamationmark.triangle.fill", .orange)
        }
    }

    private func headlineIcon(_ report: PreflightReport) -> String {
        if !report.isReady { return "xmark.octagon.fill" }
        if report.microphone.note != nil || report.system.note != nil {
            return "exclamationmark.triangle.fill"
        }
        return "checkmark.seal.fill"
    }

    private func headlineColor(_ report: PreflightReport) -> Color {
        if !report.isReady { return .red }
        if report.microphone.note != nil || report.system.note != nil { return .orange }
        return .green
    }
}

/// A prominent live meter that reacts to whoever is currently speaking (microphone or system
/// audio), driven by the fast ~15 Hz level stream.
private struct LiveVolumeBar: View {
    @ObservedObject var meter: RecordingMeterViewModel

    private var level: Double { Double(meter.snapshot.combined) }
    private var isSpeaking: Bool { meter.snapshot.isSpeaking }

    var body: some View {
        VStack(alignment: .leading, spacing: 7) {
            Label(
                isSpeaking ? "Someone is speaking" : "Listening — no one is speaking",
                systemImage: isSpeaking ? "waveform" : "waveform.slash"
            )
            .font(.callout.weight(.medium))
            .foregroundStyle(isSpeaking ? Color.accentColor : Color.secondary)

            Capsule()
                .fill(.quaternary.opacity(0.6))
                .overlay(alignment: .leading) {
                    Capsule()
                        .fill(
                            LinearGradient(
                                colors: [.green, .yellow, .orange],
                                startPoint: .leading,
                                endPoint: .trailing
                            )
                        )
                        .mask(alignment: .leading) {
                            Rectangle()
                                // Reveal, don't resize: the mask scales (a transform), so the 15 Hz tick
                                // never invalidates layout, and the gradient stays fixed — orange now means
                                // the signal actually reached the hot zone.
                                .scaleEffect(x: max(CGFloat(level), 0.02), y: 1, anchor: .leading)
                                // Live tracking stays *linear* and short — 1:1 with the signal, never a spring.
                                .animation(.meterTracking, value: level)
                        }
                }
            .frame(height: 12)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(AccessibilityPhrase.levelMeter(
                channel: "Live input",
                level: meter.snapshot.combined
            ))
        }
    }
}

private struct RecordingChannelMeter: View {
    @ObservedObject var meter: RecordingMeterViewModel
    let channel: RecordingChannel

    private var level: Double {
        switch channel {
        case .microphone:
            Double(meter.snapshot.microphone)
        case .systemAudio:
            Double(meter.snapshot.systemAudio)
        }
    }

    var body: some View {
        ProgressView(value: level)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(AccessibilityPhrase.levelMeter(
                channel: channelName,
                level: Float(level)
            ))
    }

    private var channelName: String {
        switch channel {
        case .microphone: "Microphone"
        case .systemAudio: "System audio"
        }
    }
}

/// Keeps the fast channel activity label and meter inside one narrowly observed subtree. Capture
/// warnings still come from the slower health monitor and always take precedence over activity.
private struct RecordingChannelHealthRow: View {
    private struct State {
        let text: String
        let color: Color
    }

    let title: String
    let systemImage: String
    @ObservedObject var meter: RecordingMeterViewModel
    let channel: RecordingChannel
    let health: RecordingHealthSnapshot

    private var state: State {
        switch channel {
        case .microphone:
            if health.warnings.contains(.microphoneCaptureStopped) {
                return State(text: "No audio for 3s+", color: .red)
            }
            if health.warnings.contains(.microphoneClipping) {
                return State(text: "Too loud", color: .orange)
            }
            return meter.snapshot.microphoneActive
                ? State(text: "Receiving audio", color: .green)
                : State(text: "Silent", color: .secondary)
        case .systemAudio:
            if health.warnings.contains(.systemAudioCaptureStopped) {
                return State(text: "No audio for 3s+", color: .red)
            }
            if health.warnings.contains(.systemAudioNotDetected) {
                return State(text: "Not detected yet", color: .orange)
            }
            if health.warnings.contains(.systemAudioClipping) {
                return State(text: "Too loud", color: .orange)
            }
            return meter.snapshot.systemAudioActive
                ? State(text: "Receiving audio", color: .green)
                : State(text: "Silent (normal until others speak)", color: .secondary)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 9) {
                Image(systemName: systemImage).frame(width: 18)
                Text(title)
                Spacer()
                Text(state.text)
                    .font(.caption.weight(.medium))
                    .foregroundStyle(state.color)
            }
            RecordingChannelMeter(meter: meter, channel: channel)
        }
    }
}

struct SettingsView: View {
    /// F239's confirmation. The command is irreversible and gives up the undo protection, so it
    /// asks — and the dialog names what is lost rather than asking "are you sure".
    @State private var confirmForgetHistory = false
    @State private var forgetHistoryResult: String?
    @ObservedObject var model: AppModel
    @ObservedObject var dictation: DictationController
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var apiKeyDraft = ""
    @State private var launchAtLogin = SMAppService.mainApp.status == .enabled
    @State private var capturingKey = false
    @State private var keyMonitor: Any?
    @State private var keyCaptureHint: String?

    var body: some View {
        Form {
            Section(header: Label("Local recognition", systemImage: "waveform.circle")) {
                HStack {
                    Label(
                        model.isRuntimeInstalled ? "Whisper ready" : "Whisper not installed",
                        systemImage: model.isRuntimeInstalled
                            ? "checkmark.circle.fill"
                            : "arrow.down.circle"
                    )
                    .foregroundStyle(model.isRuntimeInstalled ? .green : .orange)
                    Spacer()
                    Button(model.isRuntimeInstalled ? "Repair or Update" : "Install Local Whisper") {
                        model.installLocalWhisper()
                    }
                    .buttonStyle(.bordered)
                    .disabled(
                        model.isInstallingRuntime
                            || model.isInstallingQwenRuntime
                            || model.isInstallingDiarizationRuntime
                            || model.hasActiveTranscription
                            || model.isMicrophoneBusy
                            || model.isImporting
                            || dictation.isActive
                    )
                }
                // The install → result swap after a minutes-long wait fades in as a readable
                // payoff instead of snapping (F161, the F116 vocabulary).
                if model.isInstallingRuntime {
                    ProgressView("Installing. This can take several minutes…")
                        .transition(.gentleFade(reduceMotion: reduceMotion))
                } else if let message = model.installationMessage {
                    Text(message)
                        .foregroundStyle(.secondary)
                        .transition(.gentleFade(reduceMotion: reduceMotion))
                }
                if MeetingTranscriptionEngine.qwenBalanced.isSupportedOnCurrentMac {
                    HStack {
                        Label(
                            model.isQwenInstalled ? "Qwen3-ASR ready" : "Qwen3-ASR not installed",
                            systemImage: model.isQwenInstalled
                                ? "checkmark.circle.fill"
                                : "arrow.down.circle"
                        )
                        .foregroundStyle(model.isQwenInstalled ? .green : .orange)
                        Spacer()
                        Button(model.isQwenInstalled ? "Repair or Update" : "Install Qwen3-ASR") {
                            model.installQwenASR()
                        }
                        .buttonStyle(.bordered)
                        .disabled(
                            model.isInstallingRuntime
                                || model.isInstallingQwenRuntime
                                || model.isInstallingDiarizationRuntime
                                || model.hasActiveTranscription
                                || model.isMicrophoneBusy
                                || model.isImporting
                                || dictation.isActive
                        )
                    }
                    if model.isInstallingQwenRuntime {
                        ProgressView("Installing about 4.5 GB. This can take several minutes…")
                            .transition(.gentleFade(reduceMotion: reduceMotion))
                    } else if let message = model.qwenInstallationMessage {
                        Text(message)
                            .foregroundStyle(.secondary)
                            .transition(.gentleFade(reduceMotion: reduceMotion))
                    }
                } else {
                    Text("Qwen3-ASR requires an Apple-silicon Mac; Whisper remains available here.")
                        .foregroundStyle(.secondary)
                }
                // F220: the optional speaker-analysis model, mirroring the Qwen row above — same
                // architecture gate, same Install / Repair or Update verb, same compound disabled
                // rule, same indeterminate progress line. It is separate from transcription because
                // it is optional, post-meeting, and nothing else depends on it.
                if AppModel.diarizationIsSupportedOnCurrentMac {
                    HStack {
                        Label(
                            model.isDiarizationInstalled
                                ? "Speaker analysis ready"
                                : "Speaker analysis not installed",
                            systemImage: model.isDiarizationInstalled
                                ? "checkmark.circle.fill"
                                : "arrow.down.circle"
                        )
                        .foregroundStyle(model.isDiarizationInstalled ? .green : .orange)
                        Spacer()
                        Button(model.isDiarizationInstalled ? "Repair or Update" : "Install Speaker Analysis") {
                            model.installSpeakerDiarization()
                        }
                        .buttonStyle(.bordered)
                        .disabled(
                            model.isInstallingRuntime
                                || model.isInstallingQwenRuntime
                                || model.isInstallingDiarizationRuntime
                                || model.hasActiveTranscription
                                || model.isRunningAuxiliaryEngine
                                || model.isMicrophoneBusy
                                || model.isImporting
                                || dictation.isActive
                        )
                    }
                    if model.isInstallingDiarizationRuntime {
                        ProgressView(SpeakerAnalysisCopy.installProgressLabel)
                            .transition(.gentleFade(reduceMotion: reduceMotion))
                    } else if let message = model.diarizationInstallationMessage {
                        Text(message)
                            .foregroundStyle(.secondary)
                            .transition(.gentleFade(reduceMotion: reduceMotion))
                    }
                    Text(SpeakerAnalysisCopy.installDescription)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else {
                    Text(SpeakerAnalysisCopy.appleSiliconOnly)
                        .foregroundStyle(.secondary)
                }
                Text("Audio and transcripts stay on this Mac. No account, API key, or usage payment is required.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Both installers use an existing Homebrew installation and isolated Python environments. Qwen uses about 4.5 GB including its timestamp model and runtime.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            // Scoped to the installer states so only their swaps animate, nothing else in the
            // Form (F161).
            .animation(reduceMotion ? nil : .uiSpring, value: model.isInstallingRuntime)
            .animation(reduceMotion ? nil : .uiSpring, value: model.installationMessage)
            .animation(reduceMotion ? nil : .uiSpring, value: model.isInstallingQwenRuntime)
            .animation(reduceMotion ? nil : .uiSpring, value: model.qwenInstallationMessage)
            .animation(reduceMotion ? nil : .uiSpring, value: model.isInstallingDiarizationRuntime)
            .animation(reduceMotion ? nil : .uiSpring, value: model.diarizationInstallationMessage)

            Section(header: Label("Meeting library", systemImage: "books.vertical")) {
                HStack {
                    Label("Check recordings for problems", systemImage: "checkmark.shield")
                    Spacer()
                    Button("Verify Library") {
                        model.verifyLibrary()
                    }
                    .buttonStyle(.bordered)
                }
                Text("Scans your saved recordings for missing, truncated, or inconsistent audio and reports what it finds. It never changes or deletes a recording.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Label("Export a privacy-safe diagnostics report", systemImage: "doc.badge.gearshape")
                    Spacer()
                    Button("Export diagnostics…") { exportDiagnostics() }
                        .buttonStyle(.bordered)
                }
                Text("Writes a support file with only structural details — meeting counts, durations, statuses, byte sizes, and any error messages. It never includes transcript text, summaries, vocabulary terms, or file paths.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                HStack {
                    Label("Back up recordings and indexes to a folder", systemImage: "externaldrive.badge.timemachine")
                    Spacer()
                    Picker("Keep", selection: $model.backupRetention) {
                        ForEach([3, 5, 10, 20], id: \.self) { Text("Keep \($0)").tag($0) }
                    }
                    .labelsHidden()
                    .fixedSize()
                    Button("Back up library…") { backUpLibrary() }
                        .buttonStyle(.bordered)
                        .disabled(model.isRestoringLibrary)
                    // F191 slice E3. Beside the backup it restores from, because that is where a
                    // user looks for it — and a restore flow nobody can reach is not a restore
                    // flow, which is why this ships with the slices rather than after them.
                    Button("Restore…") { restoreLibrary() }
                        .buttonStyle(.bordered)
                        .disabled(model.isRestoringLibrary)
                }
                // F506: a restore copies every recording and takes minutes, and every change is
                // refused until it ends. Said here, under the button that started it, so the
                // refusals elsewhere have a visible cause.
                if model.isRestoringLibrary {
                    HStack(spacing: 6) {
                        ProgressView().controlSize(.small)
                        Text("Restoring your library. Changes are paused until it finishes.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                // F193: the recovery action, where library-level operations now live.
                //
                // The ticket suggested hanging this off `libraryReadOnlyFootnote`, which was
                // written before this section had any library actions — that footnote is inside a
                // per-meeting "Improve" menu, which is the wrong surface for a library-wide repair
                // and invisible until you open a meeting. It goes beside Back up and Restore, and
                // appears only when the library actually is read-only, so it is not a button
                // inviting people to "recover" a healthy library.
                if model.libraryReadOnlyFootnote != nil {
                    Divider()
                    // F313: this section's own sentence, not the Improve menu's — that one talks
                    // about suggestions and transcripts, which is not what a Library section is
                    // about. The F289 dialog hangs here rather than on the button below, because
                    // the button already carries the restore dialog and SwiftUI honours one
                    // presentation modifier of a kind per view: with both on the button, neither
                    // appeared on screen.
                    Text(ReadOnlyLibraryNotice.librarySectionNotice)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        // F289: the other route out of a read-only library, offered by the
                        // Recover Library button when there is no earlier copy to restore. F191
                        // slice E4 was tested and reachable from nothing until this dialog existed.
                        .confirmationDialog(
                            "Rebuild the meeting index from the recording folders?",
                            isPresented: .init(
                                get: { model.pendingFolderRebuild != nil },
                                set: { if !$0 { model.cancelFolderRebuild() } }
                            ),
                            titleVisibility: .visible
                        ) {
                            Button("Rebuild Index") {
                                model.rebuildLibraryFromFolders(confirmed: true)
                            }
                            Button("Cancel", role: .cancel) { model.cancelFolderRebuild() }
                        } message: {
                            if let proposal = model.pendingFolderRebuild {
                                Text(AppModel.folderRebuildMessage(proposal))
                            }
                        }
                    Button("Recover Library…") { model.requestLibraryRecovery() }
                        .buttonStyle(.borderedProminent)
                        .confirmationDialog(
                            "Restore an earlier copy of the meeting index?",
                            isPresented: .init(
                                get: { model.pendingLibraryRecovery != nil },
                                set: { if !$0 { model.cancelLibraryRecovery() } }
                            ),
                            titleVisibility: .visible
                        ) {
                            ForEach(model.pendingLibraryRecovery ?? [], id: \.name) { generation in
                                Button(AppModel.generationLabel(generation)) {
                                    model.recoverLibrary(from: generation, confirmed: true)
                                }
                                .disabled(!generation.bytesMatchName)
                            }
                            Button("Cancel", role: .cancel) { model.cancelLibraryRecovery() }
                        } message: {
                            Text("Your recordings are never changed by this. Each option is a copy of the index saved earlier; the meetings it did not know about will be missing until you restore a newer one.")
                        }
                }
                Text("Copies your recordings and indexes to a folder you choose as a dated snapshot, keeping the most recent backups. Unchanged files are not re-copied and every copy is checksum-verified. Your library is only ever read — never changed or deleted.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Text("Restoring checks the backup first and shows you exactly what it would replace, add, and leave behind before anything is written. Your current library is copied aside and kept, so a restore can be undone.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .confirmationDialog(
                        "Restore your library from this backup?",
                        isPresented: .init(
                            get: { model.pendingLibraryRestore != nil },
                            set: { if !$0 { model.cancelLibraryRestore() } }
                        ),
                        titleVisibility: .visible
                    ) {
                        // F434: each action calls the model directly, never inside a `Task`. The
                        // dismissal that follows the action clears the offer before a Task body
                        // runs, so a deferred call found nothing to restore and did nothing.
                        if let pending = model.pendingLibraryRestore, pending.plan.isSafeToApply {
                            Button("Restore Library", role: .destructive) { model.performLibraryRestore(confirmed: true) }
                        } else if let pending = model.pendingLibraryRestore,
                                  pending.plan.requiresExplicitOverride {
                            // Only the unverifiable case gets an override button. A backup known to
                            // be DAMAGED offers none, because there is no reading of "the user
                            // chose it" that makes copying corrupt bytes over good ones correct.
                            Button("Restore Anyway", role: .destructive) {
                                model.performLibraryRestore(confirmed: true, acceptingUnverifiedBackup: true)
                            }
                        }
                        Button("Cancel", role: .cancel) { model.cancelLibraryRestore() }
                    } message: {
                        if let pending = model.pendingLibraryRestore {
                            Text(AppModel.restoreConfirmationMessage(pending))
                        }
                    }
                // F239, F295: "Delete Meeting" removes the recording folder at once and the
                // meeting's text from the retained index generations a week later, on its own.
                // This removes all of that history now. Destructive role and a confirmation,
                // because this is the one command here that discards protection rather than
                // adding any.
                HStack {
                    Label("Forget saved index history", systemImage: "clock.badge.xmark")
                    Spacer()
                    Button("Forget History…", role: .destructive) { confirmForgetHistory = true }
                        .buttonStyle(.bordered)
                }
                Text("Deleting a meeting removes its recording at once; its title, transcript and notes are removed from the saved index history a week later, so a mistaken delete can still be undone in between. This removes that whole history now — every past copy of the index — without waiting. Your meetings and recordings are not touched.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let forgotten = forgetHistoryResult {
                    Text(forgotten)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            Section(header: Label("Transcription", systemImage: "captions.bubble")) {
                Picker("Model", selection: $model.selectedEngine) {
                    ForEach(MeetingTranscriptionEngine.availableCases, id: \.self) { engine in
                        Text(engine.displayName).tag(engine)
                    }
                }
                Picker("Meeting language", selection: $model.selectedLanguage) {
                    ForEach(WhisperLanguage.allCases, id: \.self) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                Text("Whisper Large remains the default. Qwen3-ASR was the most accurate option in the app's short English, Mandarin, and mixed-language benchmark while remaining fast; it is opt-in until it is proven on long, real meetings.")
                    .foregroundStyle(.secondary)
                Text("Qwen does not yet use Business Vocabulary. Whisper always produces timestamps; Qwen reconciles its own word timings against the transcript, so a passage it cannot match is kept as text without a timestamp and says so. Neither engine identifies different people. WhisperMeet still preserves separate microphone and system-audio source files.")
                    .foregroundStyle(.secondary)
            }

            Section(header: Label("Quick Dictation", systemImage: "keyboard")) {
                Toggle("Enable push-to-talk dictation", isOn: Binding(
                    get: { dictation.enabled },
                    set: { dictation.setEnabled($0) }
                ))
                Picker("Trigger mode", selection: Binding(
                    get: { dictation.hotkey.mode },
                    set: { dictation.hotkey = DictationHotkey(keyCode: dictation.hotkey.keyCode, mode: $0) }
                )) {
                    Text("Hold to talk").tag(DictationHotkey.Mode.hold)
                    Text("Toggle on/off").tag(DictationHotkey.Mode.toggle)
                }
                HStack {
                    Text("Trigger key")
                    Spacer()
                    Text(DictationKeyName.display(for: dictation.hotkey.keyCode))
                        .foregroundStyle(.secondary)
                    Button(capturingKey ? "Press a key…" : "Change") { toggleKeyCapture() }
                }
                Text("Hold this key to talk. A Command/Control key or an F-key works best — they don't type text while held.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let keyCaptureHint {
                    Text(keyCaptureHint).font(.caption).foregroundStyle(.orange)
                }
                Picker("Recognition model", selection: Binding(
                    get: { dictation.selectedEngine },
                    set: { dictation.setSelectedEngine($0) }
                )) {
                    ForEach(DictationTranscriptionEngine.availableCases, id: \.self) { engine in
                        Text(engine.displayName).tag(engine)
                    }
                }
                .disabled(dictation.isActive || dictation.isSelfTesting)
                Picker("Language", selection: $dictation.language) {
                    ForEach(WhisperLanguage.allCases, id: \.self) { language in
                        Text(language.displayName).tag(language)
                    }
                }
                Toggle("Paste into the focused field (else copy to clipboard)", isOn: $dictation.autoPaste)
                Toggle("Use business vocabulary for dictation", isOn: $dictation.useVocabulary)
                    .disabled(!dictation.selectedEngine.supportsVocabularyPrompt)
                if !dictation.selectedEngine.supportsVocabularyPrompt {
                    Text("Qwen does not currently accept Business Vocabulary prompts.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle("Refine with local AI (grammar cleanup)", isOn: $dictation.refineEnabled)
                    .disabled(!dictation.isRefineRuntimeInstalled)
                if !dictation.isRefineRuntimeInstalled {
                    Text(SummarizerRuntime.isSupportedOnCurrentMac
                        ? "Requires the local AI model — install or update it in the Summaries settings."
                        : "Requires an Apple silicon Mac.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                } else if dictation.refineEnabled {
                    Text("Fixes grammar, punctuation, and filler words before pasting. If the model can't answer within about two seconds, the raw transcript is pasted instead. Keeps the local AI model in memory while dictation is warm (about 2–5 GB).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, enabled in
                        do {
                            if enabled { try SMAppService.mainApp.register() }
                            else { try SMAppService.mainApp.unregister() }
                        } catch {
                            model.alertMessage = "Could not update launch-at-login: \(error.localizedDescription)"
                            launchAtLogin = (SMAppService.mainApp.status == .enabled)
                        }
                    }
                HStack {
                    Label(
                        dictation.isAccessibilityTrusted ? "Accessibility granted" : "Accessibility needed",
                        systemImage: dictation.isAccessibilityTrusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill"
                    )
                    .foregroundStyle(dictation.isAccessibilityTrusted ? .green : .orange)
                    Spacer()
                    if !dictation.isAccessibilityTrusted {
                        Button("Grant…") { dictation.requestAccessibility() }
                    }
                }
                Text("Use \(DictationKeyName.display(for: dictation.hotkey.keyCode)) anywhere to dictate. \(dictation.selectedEngine.displayName) runs 100% locally. Accessibility is required to paste and detect the trigger.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section(header: Label("Summaries", systemImage: "sparkles")) {
                Picker("Engine", selection: $model.summarizationEngine) {
                    ForEach(SummarizationEngine.allCases, id: \.self) { engine in
                        Text(engine.displayName).tag(engine)
                    }
                }
                if model.summarizationEngine == .local {
                    if SummarizerRuntime.isSupportedOnCurrentMac {
                        HStack {
                            Label(
                                model.isSummarizerInstalled ? "Local model ready" : "Local model not installed",
                                systemImage: model.isSummarizerInstalled
                                    ? "checkmark.circle.fill"
                                    : "arrow.down.circle"
                            )
                            .foregroundStyle(model.isSummarizerInstalled ? .green : .orange)
                            Spacer()
                            Button(model.isSummarizerInstalled ? "Repair or Update" : "Install Local Model") {
                                model.installSummarizer()
                            }
                            .buttonStyle(.bordered)
                            .disabled(
                                model.isInstallingSummarizer
                                    || model.isInstallingRuntime
                                    || model.isInstallingQwenRuntime
                                    || model.isInstallingDiarizationRuntime
                                    || model.hasActiveTranscription
                                    || model.isMicrophoneBusy
                                    || model.isImporting
                                    || dictation.isActive
                            )
                        }
                        if model.isInstallingSummarizer {
                            ProgressView("Downloading the local summarization model. This can take several minutes…")
                        } else if let message = model.summarizerInstallationMessage {
                            Text(message).foregroundStyle(.secondary)
                        }
                        Text("Local summaries run entirely on this Mac — no API key, and nothing leaves the device.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Local summaries require an Apple-silicon Mac. Choose Claude to summarize on this Mac.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                } else {
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
                    Text("Claude summaries are the one feature that leaves this Mac: the transcript is sent to Anthropic's Claude API, which requires your own paid API key. Recording and transcription stay fully local.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            // F318 — a watched folder is opt-in: nothing is imported that the user did not put there
            // after turning this on.
            Section("Watched Folder") {
                Toggle("Import new recordings from a folder", isOn: $model.watchedFolderEnabled)
                Text("Off by default. When on, a recording you add to the folder is imported and transcribed on this Mac once it has finished copying, and a notification says so first. Files already in the folder are left alone, the originals are never moved or deleted, and WhisperMeet never records on its own.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if model.watchedFolderEnabled {
                    HStack {
                        Text(model.watchedFolderPath.map { ($0 as NSString).abbreviatingWithTildeInPath } ?? "No folder chosen")
                            .foregroundStyle(model.watchedFolderPath == nil ? .secondary : .primary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Spacer()
                        Button("Choose Folder…") { chooseWatchedFolder() }
                            .buttonStyle(.bordered)
                    }
                    // F325 — an unreadable folder used to be indistinguishable from an empty one,
                    // so the feature could sit here looking on while nothing was ever read.
                    if let problem = model.watchedFolderProblem {
                        Label(problem, systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }

            // F183 — link import is opt-in, like every other capability here that crosses a boundary.
            Section("Import from a Link") {
                Toggle("Allow importing audio from a link", isOn: $model.linkImportEnabled)
                Text("Off by default. When on, an “Add from a Link…” button appears on the record screen. WhisperMeet fetches only the audio and transcribes it on this Mac — nothing about your meetings is uploaded, but the request does reach the site you link to, so that site sees it. Make sure you have the right to download the content.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if model.linkImportEnabled {
                    HStack {
                        Label(
                            model.isDownloaderInstalled ? "Downloader ready" : "Downloader not installed",
                            systemImage: model.isDownloaderInstalled ? "checkmark.circle.fill" : "arrow.down.circle"
                        )
                        .foregroundStyle(model.isDownloaderInstalled ? .green : .orange)
                        Spacer()
                        Button("Update Downloader") { model.updateDownloader() }
                            .buttonStyle(.bordered)
                            .disabled(
                                !model.isDownloaderInstalled
                                    || model.isUpdatingDownloader
                                    || model.isInstallingRuntime
                                    || model.isImporting
                            )
                    }
                    if model.isUpdatingDownloader {
                        ProgressView("Updating the downloader…").controlSize(.small)
                    } else if let message = model.downloaderUpdateMessage {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                    if !model.isDownloaderInstalled {
                        Text("The downloader ships with the local Whisper runtime — install that above and it will be available.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else {
                        Text("Sites change how they serve media, so the downloader needs updating from time to time. If a link fails with “the downloader is out of date”, update it here.")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .navigationTitle("Settings")
        .confirmationDialog(
            "Forget the saved index history?",
            isPresented: $confirmForgetHistory,
            titleVisibility: .visible
        ) {
            Button("Forget History", role: .destructive) {
                if let count = model.store.forgetIndexHistory() {
                    // Reports what happened rather than claiming success. "Nothing to forget" is a
                    // real and reassuring outcome, and conflating it with "removed 7" would be the
                    // kind of small lie that makes a privacy command untrustworthy.
                    forgetHistoryResult = count == 0
                        ? "There was no saved history to remove."
                        : "Removed \(count) saved \(count == 1 ? "generation" : "generations")."
                } else {
                    forgetHistoryResult = nil
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            // Names what is LOST, not just what is removed. This is the only command in Settings
            // that gives up a protection, so the dialog has to say which one (F239/F190).
            Text("This removes the saved copies of your meeting index that let WhisperMeet undo a bad save — including any deleted meeting's title, transcript and notes that are still in them. Your meetings, recordings and current index are not touched, but until the next save there will be nothing to roll back to.")
        }
        .onDisappear { endKeyCapture() }
    }

    private func exportDiagnostics() {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "WhisperMeet Diagnostics.json"
        panel.allowedContentTypes = [.json]
        guard panel.runModal() == .OK, let url = panel.url else { return }
        try? Data(model.diagnosticsJSON().utf8).write(to: url)
    }

    private func chooseWatchedFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Watch This Folder"
        panel.message = "Recordings you add to this folder from now on will be imported."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        model.watchedFolderPath = url.path
    }

    private func backUpLibrary() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.prompt = "Back Up Here"
        panel.message = "Choose a folder to back up your WhisperMeet library into."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.backUpLibrary(to: url) }
    }

    /// Picks a backup generation and asks the model for a plan (F191 slice E3).
    ///
    /// The panel points at the generation directory rather than the backup root, because a
    /// generation IS the unit that gets restored and choosing between them is the user's decision
    /// — the app must not pick "the newest" on their behalf when the reason they are here may be
    /// that the newest is the bad one.
    private func restoreLibrary() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = false
        panel.prompt = "Check This Backup"
        panel.message = "Choose one dated backup folder inside “\(BackupCoordinator.managedSubfolder)”. Nothing is written until you review what the restore would do."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        Task { await model.requestLibraryRestore(from: url) }
    }

    private func toggleKeyCapture() {
        if capturingKey { endKeyCapture(); return }
        capturingKey = true
        keyCaptureHint = nil
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown, .flagsChanged]) { event in
            let code = UInt16(event.keyCode)
            if DictationKeyName.isTriggerCandidate(code) {
                dictation.hotkey = DictationHotkey(keyCode: code, mode: dictation.hotkey.mode)
                endKeyCapture()
            } else {
                keyCaptureHint = "That key can’t be a trigger — pick a modifier (⌘ ⌃ ⌥ ⇧) or an F-key."
            }
            return nil // swallow so nothing types while capturing
        }
    }
    private func endKeyCapture() {
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor); self.keyMonitor = nil }
        capturingKey = false
    }
}

/// F183 — paste a link, see what was found, then fetch just its audio into a new meeting that the
/// existing local pipeline transcribes. Only reachable when the feature is switched on in Settings.
///
/// The two disclosures are stated plainly and once: many sites' terms prohibit downloading and the
/// content is usually someone else's copyrighted work, and the fetch reaches the video's host, so that
/// host sees the request. The app cannot resolve either — they are disclosures, not gates.
private struct LinkImportSheet: View {
    @ObservedObject var model: AppModel
    let onImported: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var link = ""
    @State private var isWorking = false
    /// The in-flight import, held so Cancel actually stops the download instead of only closing the
    /// sheet and leaving the fetch (and the isImporting latch) running invisibly.
    @State private var importTask: Task<Void, Never>?

    private var trimmedLink: String {
        link.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Add from a Link").font(.headline)
                Text("WhisperMeet downloads only the audio, then transcribes it on this Mac like any other meeting.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()

            VStack(alignment: .leading, spacing: 14) {
                TextField("https://…", text: $link)
                    .textFieldStyle(.roundedBorder)
                    .disabled(isWorking)
                    .onSubmit { start(confirmed: false) }

                if let progress = model.mediaDownloadProgress {
                    if let fraction = progress.fractionCompleted {
                        ProgressView(value: fraction) {
                            Text("Downloading audio… \(Int(saturating: fraction * 100))%")
                        }
                    } else {
                        ProgressView("Preparing the download…").controlSize(.small)
                    }
                } else if isWorking {
                    ProgressView("Checking the link…").controlSize(.small)
                }

                VStack(alignment: .leading, spacing: 6) {
                    Label(
                        "The request goes to the site you linked, so that site sees it. Nothing about your meetings is uploaded.",
                        systemImage: "network"
                    )
                    Label(
                        "Make sure you have the right to download and transcribe this content — many sites' terms don't allow it.",
                        systemImage: "exclamationmark.triangle"
                    )
                }
                .font(.caption)
                .foregroundStyle(.secondary)
            }
            .padding(.horizontal)

            Spacer(minLength: 12)

            HStack {
                Spacer()
                Button(isWorking ? "Stop" : "Cancel") { cancel() }
                Button("Download and Transcribe") { start(confirmed: false) }
                    .buttonStyle(.borderedProminent)
                    .disabled(trimmedLink.isEmpty || isWorking)
            }
            .padding()
        }
        .frame(width: 460, height: 340)
        // Long media is confirmed, never capped: a legitimate 4-hour conference recording stays possible.
        .alert(
            "This is a long recording",
            isPresented: Binding(
                get: { model.pendingLongMediaConfirmation != nil },
                set: { if !$0 { model.pendingLongMediaConfirmation = nil } }
            )
        ) {
            Button("Cancel", role: .cancel) { model.pendingLongMediaConfirmation = nil }
            Button("Download Anyway") { start(confirmed: true) }
        } message: {
            let probe = model.pendingLongMediaConfirmation
            let clock = probe?.durationSeconds.map { TranscriptFormatter.clock($0) } ?? "over two hours"
            Text("“\(probe?.title ?? "This video")” runs \(clock). Downloading and transcribing it will take a while and use disk space.")
        }
    }

    private func start(confirmed: Bool) {
        guard !trimmedLink.isEmpty, !isWorking else { return }
        isWorking = true
        importTask = Task {
            let id = await model.importFromURL(trimmedLink, confirmedLongDuration: confirmed)
            isWorking = false
            importTask = nil
            if let id {
                onImported(id)
                dismiss()
            }
            // A nil result that is only awaiting confirmation keeps the sheet open for the alert.
        }
    }

    /// Stops an in-flight download (the runner kills the whole process group and the import cleans up
    /// its folder) before closing, so Cancel never leaves an invisible fetch running.
    private func cancel() {
        importTask?.cancel()
        importTask = nil
        isWorking = false
        dismiss()
    }
}

/// F180 — ask a question across a chosen set of completed meetings and get cited, timestamped results.
/// Local keyword retrieval (BM25) over the transcript segments; every result links to its meeting and
/// (when the transcript is aligned) the moment it was said. Clicking a result opens that meeting and
/// seeks the recording there, reusing the F177 playback path.
private struct AskMeetingsView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: MeetingStore
    @Binding var query: String
    @Binding var scopeTags: Set<String>
    @Binding var tagMode: MeetingTags.MatchMode
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var results: [CitedResult] = []
    @State private var hasSearched = false
    /// The written answer for the results on screen (F182). Cleared whenever the results change.
    @State private var answerOutcome: MeetingAnswerPolicy.Outcome?
    @State private var answerTask: Task<Void, Never>?
    @State private var searchTask: Task<Void, Never>?

    private var libraryTags: [String] {
        MeetingTags.distinct(across: store.meetings.map { $0.tags ?? [] })
    }

    private var scope: MeetingScope {
        MeetingScope(tags: Array(scopeTags), tagMode: tagMode)
    }

    private var scopedCount: Int {
        store.meetings.filter {
            MeetingScopeResolver.inScope(tags: $0.tags ?? [], isCompleted: $0.status == .completed, scope: scope)
        }.count
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Ask Meetings").font(.largeTitle.bold())
                Text("Search across your meetings and jump to where it was said. Everything runs on this Mac — nothing is uploaded, and only completed transcripts are searched.")
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 8) {
                TextField("Ask about your meetings — e.g. pricing discount", text: $query)
                    .textFieldStyle(.roundedBorder)
                    .submitLabel(.search)
                    .onSubmit(runSearch)
                Button("Ask") { runSearch() }
                    .buttonStyle(.borderedProminent)
                    .disabled(query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if !libraryTags.isEmpty {
                VStack(alignment: .leading, spacing: 6) {
                    HStack {
                        Text("Scope").font(.subheadline.bold())
                        Text(scopeCaption).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if scopeTags.count > 1 {
                            Picker("Match", selection: $tagMode) {
                                Text("Any tag").tag(MeetingTags.MatchMode.any)
                                Text("All tags").tag(MeetingTags.MatchMode.all)
                            }
                            .pickerStyle(.segmented)
                            .fixedSize()
                            .onChange(of: tagMode) { _, _ in runSearchIfActive() }
                        }
                    }
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 6) {
                            ForEach(libraryTags, id: \.self) { tag in
                                scopeChip(tag)
                            }
                        }
                    }
                }
            }

            meaningSearchRow
            resultsSection
        }
        .padding(32)
        .navigationTitle("Ask Meetings")
        // Restore results when returning to this tab: the view's @State (results/hasSearched) is
        // recreated, but `query` is bound to ContentView and survives, so recompute from it.
        .onAppear {
            if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { runSearch() }
        }
    }

    private var scopeCaption: String {
        if scopeTags.isEmpty {
            return "all completed meetings (\(scopedCount))"
        }
        return "\(scopedCount) meeting\(scopedCount == 1 ? "" : "s") matching the selected tags"
    }

    private func scopeChip(_ tag: String) -> some View {
        let selected = scopeTags.contains(tag)
        return Button {
            if selected { scopeTags.remove(tag) } else { scopeTags.insert(tag) }
            runSearchIfActive()
        } label: {
            Text(tag)
                .font(.caption)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .background(
                    selected ? AnyShapeStyle(Color.accentColor) : AnyShapeStyle(.quaternary),
                    in: Capsule()
                )
                .foregroundStyle(selected ? Color.white : Color.primary)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(selected ? "Remove tag \(tag) from scope" : "Add tag \(tag) to scope")
    }

    @ViewBuilder
    private var resultsSection: some View {
        if !hasSearched {
            ContentUnavailableView(
                "Ask a question",
                systemImage: "text.magnifyingglass",
                description: Text("Type a question or keywords above to find the moments across your meetings that answer it.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if results.isEmpty {
            ContentUnavailableView(
                "No matches",
                systemImage: "magnifyingglass",
                description: Text("Nothing in the selected meetings matched. Try different words or widen the scope.")
            )
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else {
            answerSection
            List(results) { result in
                Button {
                    model.pendingNavigation = AppModel.MeetingNavigationRequest(
                        meetingID: result.meetingID, seek: result.timestamp
                    )
                } label: {
                    resultRow(result)
                }
                .buttonStyle(.plain)
            }
            .alternatingRowBackgrounds()
            .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 12, style: .continuous)
                    .strokeBorder(.separator.opacity(0.55), lineWidth: 1)
            )
        }
    }

    /// F316: search by meaning is an optional download on top of the local summary model.
    @ViewBuilder
    private var meaningSearchRow: some View {
        if model.isSummarizerInstalled {
            HStack(spacing: 8) {
                if model.isAskEmbeddingInstalled {
                    Label(model.isIndexingForAsk ? "Preparing your meetings for search by meaning…" : "Also searching by meaning, on this Mac",
                          systemImage: "sparkle.magnifyingglass")
                        .font(.caption).foregroundStyle(.secondary)
                    if model.isIndexingForAsk { ProgressView().controlSize(.mini) }
                } else if model.isInstallingAskEmbeddings {
                    ProgressView().controlSize(.small)
                    Text("Downloading the search model…").font(.caption).foregroundStyle(.secondary)
                } else {
                    Text("Keyword search only — it misses a question worded differently from what was said.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Add Search by Meaning (490 MB)") { model.installAskEmbeddingModel() }
                        .controlSize(.small)
                        .help("Downloads intfloat/multilingual-e5-small (MIT) from Hugging Face once. Searching then runs on this Mac; nothing about your meetings is uploaded.")
                }
                Spacer()
            }
            if let message = model.askEmbeddingInstallMessage {
                Text(message).font(.caption).foregroundStyle(.orange)
            }
        }
    }

    /// F182: an optional written answer above the passages. Opt-in per question — the model only
    /// runs when asked — and what it writes is shown only if `MeetingAnswerPolicy` accepts it.
    @ViewBuilder
    private var answerSection: some View {
        if model.isSummarizerInstalled {
            VStack(alignment: .leading, spacing: 6) {
                if model.isAnsweringMeetingsQuestion {
                    HStack(spacing: 8) {
                        ProgressView().controlSize(.small)
                        Text("Writing an answer on this Mac…").foregroundStyle(.secondary)
                        Button("Cancel") { answerTask?.cancel() }.buttonStyle(.link)
                    }
                } else if let answerOutcome {
                    switch answerOutcome {
                    case let .answer(answer):
                        Text(answer.text).textSelection(.enabled)
                        Text("Written by the on-device model from passages \(answer.citedPassages.map { String($0 + 1) }.joined(separator: ", ")) below. It can be wrong — the passages are what was said.")
                            .font(.caption).foregroundStyle(.secondary)
                    case .notFound:
                        Text("The model found no answer in these passages. They are still the closest matches.")
                            .font(.callout).foregroundStyle(.secondary)
                    case .refused:
                        Text("The model did not give an answer it could tie to these passages, so none is shown. The passages below are what was said.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                } else {
                    Button("Write an Answer from These Passages") { writeAnswer() }
                        .disabled(!model.canWriteMeetingAnswer)
                        .help("Uses the local summary model on this Mac. Nothing is uploaded.")
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(12)
            .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
    }

    private func writeAnswer() {
        let question = query
        let passages = results
        answerTask = Task {
            let outcome = await model.writeMeetingAnswer(question: question, passages: passages)
            // The user may have searched again while the model ran; an answer to the old question
            // above the new passages would be worse than none.
            if passages == results { answerOutcome = outcome }
        }
    }

    private func resultRow(_ result: CitedResult) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(result.meetingTitle.isEmpty ? "Untitled meeting" : result.meetingTitle)
                    .font(.subheadline.bold())
                if let timestamp = result.timestamp {
                    Label(TranscriptFormatter.clock(timestamp), systemImage: "play.circle")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                } else {
                    Text("no timestamp")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
                Spacer()
                Image(systemName: "chevron.right").font(.caption2).foregroundStyle(.tertiary)
            }
            Text(result.snippet)
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(3)
        }
        .padding(.vertical, 4)
        .contentShape(Rectangle())
    }

    private func runSearch() {
        hasSearched = true
        answerTask?.cancel()
        answerOutcome = nil
        // Keyword results appear at once; with the search model installed, the fused list replaces
        // them a moment later (F316). A newer search supersedes an older one still embedding.
        results = model.askMeetings(query: query, scope: scope)
        searchTask?.cancel()
        guard model.isAskEmbeddingInstalled else { return }
        let asked = query, askedScope = scope
        searchTask = Task {
            let fused = await model.askMeetingsByMeaning(query: asked, scope: askedScope)
            if !Task.isCancelled, asked == query { results = fused }
        }
    }

    /// Re-run only when a search is already showing, so toggling scope before the first query is quiet.
    private func runSearchIfActive() {
        guard hasSearched else { return }
        runSearch()
    }
}

/// Editor for exact `heard → preferred` replacement rules (F179). Rules are reviewed before they apply
/// — they surface as proposals in a meeting's Improve ▸ Apply Replacement Rules and go through the same
/// approve-then-apply sheet as vocabulary corrections; the audio is never touched.
private struct ReplacementRulesEditor: View {
    @ObservedObject var store: MeetingStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var heardDraft = ""
    @State private var preferredDraft = ""

    private var canAdd: Bool {
        !heardDraft.trimmingCharacters(in: .whitespaces).isEmpty
            && !preferredDraft.trimmingCharacters(in: .whitespaces).isEmpty
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Replacement Rules").font(.headline)
            Text("Exact fixes for a term that is always misheard the same way. Nothing changes until you review and approve them in a meeting's Improve ▸ Apply Replacement Rules.")
                .font(.caption)
                .foregroundStyle(.secondary)

            HStack(spacing: 8) {
                TextField("Heard", text: $heardDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addRule() }
                Image(systemName: "arrow.right").foregroundStyle(.tertiary)
                TextField("Preferred", text: $preferredDraft)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit { addRule() }
                Button("Add Rule") { addRule() }
                    .buttonStyle(.borderedProminent)
                    .disabled(!canAdd)
            }

            if !store.replacementRules.isEmpty {
                ScrollView {
                    VStack(spacing: 0) {
                        ForEach(store.replacementRules, id: \.self) { rule in
                            HStack(spacing: 6) {
                                Text(rule.heard).foregroundStyle(.secondary)
                                Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                                Text(rule.preferred).fontWeight(.medium)
                                Spacer()
                                Button {
                                    withAnimation(reduceMotion ? nil : .uiSpring) {
                                        store.removeReplacementRule(rule)
                                    }
                                } label: {
                                    Image(systemName: "xmark.circle.fill")
                                }
                                .buttonStyle(LinkPressStyle())
                                .foregroundStyle(.tertiary)
                                .accessibilityLabel("Remove rule \(rule.heard) to \(rule.preferred)")
                            }
                            .padding(.vertical, 4)
                        }
                    }
                }
                .frame(maxHeight: 160)
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.opacity(0.4), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.separator.opacity(0.5)))
    }

    private func addRule() {
        guard canAdd else { return }
        store.addReplacementRule(heard: heardDraft, preferred: preferredDraft)
        heardDraft = ""
        preferredDraft = ""
    }
}

private struct VocabularyView: View {
    @ObservedObject var store: MeetingStore
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var manualTerms = ""
    @State private var showsImporter = false
    @State private var importMessage: String?
    @StateObject private var copyAck = TransientAcknowledgment()

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Business Vocabulary")
                        .font(.largeTitle.bold())
                    Spacer()
                    Button {
                        copyGenerationPrompt()
                    } label: {
                        Label(
                            copyAck.isActive ? "Prompt Copied" : "Copy AI Prompt",
                            systemImage: copyAck.isActive ? "checkmark" : "sparkles"
                        )
                    }
                    .help("Copy a ready-made prompt to paste into any AI chat, then paste the terms it lists back into the Add box. Note: whatever you paste into that external chat (notes, rosters, docs) leaves this Mac and goes to that provider.")
                }
                // F272: this used to claim "Every term shown below … is included in Whisper's local
                // prompt". F265 made that false — the prompt is budgeted in tokens now, so a long
                // list is trimmed. Say what is true, and show the real numbers when it bites.
                Text("Every term shown below stays on this Mac. Up to 100 reviewed terms are kept, and as many as fit the model’s prompt budget are sent to the recognizer.")
                    .foregroundStyle(.secondary)
                // The starred count too (F333): once more terms are starred than fit, "star the
                // terms that matter most" asks for something already done and every star is filled.
                if let coverage = VocabularyPrompt.coverageNotice(
                    for: store.vocabulary, starredCount: store.prioritizedVocabulary.count
                ) {
                    Label(coverage, systemImage: "exclamationmark.triangle")
                        .font(.callout)
                        .foregroundStyle(.orange)
                }
                Text("“Copy AI Prompt” is for an external AI chat: anything you paste there leaves this Mac. Don’t include confidential material.")
                    .font(.caption)
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

            ReplacementRulesEditor(store: store)

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
                            // F300: a star sends the term to the recognizer first, so when the
                            // list is over the prompt budget it is another term that is trimmed.
                            let starred = store.prioritizedVocabulary.contains(term)
                            Button {
                                store.setVocabularyPriority(term, prioritized: !starred)
                            } label: {
                                Image(systemName: starred ? "star.fill" : "star")
                            }
                            .buttonStyle(LinkPressStyle())
                            .foregroundStyle(starred ? AnyShapeStyle(.yellow) : AnyShapeStyle(.tertiary))
                            .accessibilityLabel(starred ? "Stop sending \(term) first" : "Send \(term) to the recognizer first")
                            .help("Starred terms are sent to the recognizer first when the list is over its limit.")
                            Text(term)
                            Spacer()
                            Button {
                                withAnimation(reduceMotion ? nil : .uiSpring) {
                                    store.removeVocabulary(term)
                                }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(LinkPressStyle())
                            .foregroundStyle(.tertiary)
                            .accessibilityLabel("Remove \(term)")
                        }
                    }
                }
                .alternatingRowBackgrounds()
                .clipShape(RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay(
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.separator.opacity(0.55), lineWidth: 1)
                )
            }
        }
        .padding(32)
        .navigationTitle("Business Vocabulary")
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

    private func copyGenerationPrompt() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(VocabularyPrompt.generationPrompt, forType: .string)
        // Re-triggerable acknowledgment (F159): a rapid second press keeps "Prompt Copied"
        // visible for its own full window instead of being cleared by the first press's timer.
        copyAck.trigger()
    }

    private func addManualTerms() {
        let terms = manualTerms.components(separatedBy: CharacterSet(charactersIn: ",\n"))
        let before = Set(store.vocabulary)
        withAnimation(reduceMotion ? nil : .uiSpring) {
            store.addVocabulary(terms)
        }
        let added = Set(store.vocabulary).subtracting(before).count
        // F196: this said "the prompt may already be at its 100-term limit", which stopped being
        // true when F187 separated stored vocabulary from the prompt subset. Nothing about an import
        // touches the prompt — `added == 0` means the terms were already there, the 5,000-term
        // storage ceiling is full, or the library is read-only. Naming the prompt's limit sent a
        // user to prune a list that was not the one refusing them.
        importMessage = added == 0
            // A read-only library is deliberately not named here: `MeetingStore.mutationIsAllowed`
            // already sets `storageErrorMessage` to `ReadOnlyLibraryNotice.mutationRefused` for
            // that case, and saying it twice in two different wordings is how two explanations
            // start to disagree.
            ? "Nothing new was added. Those terms are already saved, or the list is at its 5,000-term limit."
            : "Saved \(added) term\(added == 1 ? "" : "s")."
        manualTerms = ""
    }

    private func importDocuments(_ urls: [URL]) {
        importMessage = "Reading \(urls.count) document\(urls.count == 1 ? "" : "s")…"
        Task {
            let result = await Task.detached(priority: .userInitiated) {
                VocabularyExtractor.extractBatch(from: urls)
            }.value
            if result.terms.isEmpty && !result.failed.isEmpty {
                importMessage = "None of the selected document\(result.failed.count == 1 ? "" : "s") could be read."
                return
            }
            let before = Set(store.vocabulary)
            // One animated layout change for the whole batch — deliberately no stagger (F116).
            withAnimation(reduceMotion ? nil : .uiSpring) {
                store.addVocabulary(result.terms)
            }
            let added = Set(store.vocabulary).subtracting(before).count
            var message = "Saved \(added) candidate term\(added == 1 ? "" : "s"). Remove anything that should not influence transcription."
            if !result.failed.isEmpty {
                message += " \(result.failed.count) file\(result.failed.count == 1 ? "" : "s") could not be read and were skipped."
            }
            importMessage = message
        }
    }
}

private struct TranscriptDetailView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: MeetingStore
    let meetingID: UUID
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var confirmSummarize = false
    // F515: Transcribe Again replaces the transcript, so it always asks first.
    @State private var confirmTranscribeAgain = false
    // F220: the disclosure shown before every speaker analysis — the inverse of `confirmSummarize`,
    // which warns that content leaves this Mac.
    @State private var confirmDiarization = false
    @AppStorage("summaryStyle") private var summaryStyle: SummaryStyle = .balanced
    // F178: the meeting template reshapes the summary's structure (independent of the length/emphasis
    // that `summaryStyle` controls). Persisted like the style; local-only.
    @AppStorage("summaryTemplate") private var summaryTemplate: MeetingTemplate = .general
    @State private var transcriptMode: TranscriptMode = .read
    @State private var vocabularySuggestions: [String]?
    @State private var glossaryProposals: [GlossaryCorrection]?
    @State private var showSecondOpinion = false
    @State private var showsReferenceImporter = false
    @State private var isSuggestingVocab = false
    // F177: an action item's "Play source" writes its timestamp here; the transcript player below
    // observes it, seeks, and resets it to nil.
    @State private var seekRequest: Double?
    // F186: the cross-segment repetition notice, computed once per meeting rather than per redraw.
    @State private var repetitionNotice: String?
    // F422: how many echoes Remove Repeated Lines would take out, computed with the notice above.
    @State private var removableRepeats = 0
    // F437: the summary's "Not mentioned" note, with the summary text it was worked out for.
    @State private var coverageNote: (summaryText: String, terms: [String])?
    // F424: the lines Remove Lines in Another Language offers, while its confirmation sheet is up.
    @State private var languageRemovalOffer: LanguageRemovalOffer?
    @Environment(\.undoManager) private var undoManager
    @State private var notesDraft = ""
    @State private var notesLoadedFor: UUID?
    @StateObject private var copyAck = TransientAcknowledgment(hold: .seconds(1.5))

    /// A plain per-meeting scratchpad (agenda / attendee notes), separate from the transcript and the
    /// Claude summary. Loaded once per meeting; flushed to the index on edit. Never sent to Claude.
    private var notesSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Notes").font(.headline)
            TextEditor(text: $notesDraft)
                .font(.body)
                .frame(minHeight: 72)
                .padding(6)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                // An empty scratchpad says what it is for (F171): the hint sits where typed text
                // will land and never intercepts clicks.
                .overlay(alignment: .topLeading) {
                    if notesDraft.isEmpty {
                        Text("Add agenda, attendees, or follow-ups — notes stay on this Mac.")
                            .font(.body)
                            .foregroundStyle(.tertiary)
                            .padding(.leading, 11)
                            .padding(.top, 6)
                            .allowsHitTesting(false)
                    }
                }
                // Debounced write (F133): coalesce the per-keystroke whole-index write.
                .onChange(of: notesDraft) { _, newValue in
                    store.editNotes(id: meetingID, text: newValue)
                }
        }
        .confirmationDialog(
            "Rebuild this meeting's audio?",
            isPresented: .init(
                get: { model.pendingSourceRebuild?.meetingID == meetingID },
                set: { if !$0 { model.cancelSourceRebuild() } }
            ),
            titleVisibility: .visible
        ) {
            Button("Rebuild Audio") { model.performSourceRebuild(confirmed: true) }
            Button("Cancel", role: .cancel) { model.cancelSourceRebuild() }
        } message: {
            if let request = model.pendingSourceRebuild {
                // States what changes, what is kept, and the cost, rather than only asking. The
                // disk growth is disclosed instead of solved: a silent cap that discarded the
                // user's audio would be a worse defect in a smaller font (F267).
                Text(AppModel.rebuildConfirmationMessage(request))
            }
        }
        .onAppear {
            if notesLoadedFor != meetingID {
                notesDraft = store.meeting(id: meetingID)?.notes ?? ""
                notesLoadedFor = meetingID
            }
        }
        // Persist a pending notes edit if the view goes away before the debounce fires (F133).
        .onDisappear { store.flushPendingEdits() }
    }

    /// Tags as directly manipulable chips (F171). Tags are labels for organizing/filtering — never
    /// speaker identity (F67). Editing state lives in `TagChipsEditor`; `.id` resets its
    /// in-progress input when the selection moves to another meeting.
    private var tagsEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Tags").font(.headline)
            TagChipsEditor(store: store, meetingID: meetingID)
                .id(meetingID)
        }
    }

    var body: some View {
        if let meeting = store.meeting(id: meetingID) {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    header(meeting)
                    statusCard(meeting)
                    if let advisory = meeting.healthReport.flatMap(RecordingHealthAdvisory.message) {
                        Label(advisory, systemImage: "exclamationmark.triangle.fill")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                            .padding(12)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(.yellow.opacity(0.12), in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
                    // Everything true of the RECORDING rather than of the transcript, as one
                    // list (F273). Was three hand-written banners, which is how F273's provenance
                    // sentence came to exist in `notes.md` and nowhere on screen: a new member of
                    // the family had to be added in two places to be visible. Now it cannot be.
                    //
                    // Beside the capture-health advisory and NOT in `transcriptSection`, which the
                    // body renders only for `.completed` — a truncated recovery is `.recorded` and
                    // a severe one `.failed`, so those are exactly the states that need it.
                    let recordingCaveats = MeetingStore.recoveryCaveats(for: meeting)
                    if !recordingCaveats.isEmpty {
                        VStack(alignment: .leading, spacing: 6) {
                            ForEach(recordingCaveats, id: \.self) { caveat in
                                Label(caveat, systemImage: "waveform.badge.exclamationmark")
                                    .font(.callout)
                                    .foregroundStyle(.secondary)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                            }
                        }
                        .padding(10)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .bannerSurface(.orange)
                        .accessibilityElement(children: .combine)
                    }
                    // F306: the offer, back, and deliberately NOT inside the banner above.
                    //
                    // It used to live inside one of the three hand-written banners F273 replaced,
                    // and went with it — `requestSourceRebuild` then had no production caller at
                    // all, so F267's whole rebuild was unreachable and `staleTranscriptWarning`
                    // could never be set. A control nested inside a message is deleted whenever
                    // that message is restructured; as its own sibling it survives the next
                    // consolidation.
                    //
                    // Gated only on `canRebuildFromSourceTracks`, not on there being a caveat: raw
                    // tracks worth rebuilding from can outlive the banner that first mentioned them,
                    // and the previous coupling is what made this deletable.
                    if model.canRebuildFromSourceTracks(id: meetingID) {
                        Button("Rebuild Audio from Source Tracks…") {
                            model.requestSourceRebuild(id: meetingID)
                        }
                        .buttonStyle(.link)
                        .help("Mix the raw microphone and system tracks again, in case more audio survived than the first recovery found.")
                    }
                    tagsEditor
                    notesSection

                    if meeting.status == .completed {
                        summarySection(meeting)
                            .transition(.gentleFade(reduceMotion: reduceMotion))
                        transcriptSection(meeting)
                            .transition(.gentleFade(reduceMotion: reduceMotion))
                    }
                }
                .frame(maxWidth: 860, alignment: .leading)
                .padding(32)
                .frame(maxWidth: .infinity)
                // The status-card → transcript swap when transcription completes is the app's
                // payoff moment — cross-fade and settle instead of hard-cutting (F116). Under
                // Reduce Motion the layout spring is dropped; the cross-fade itself survives via
                // gentleFade's own animation.
                .animation(reduceMotion ? nil : .uiSpring, value: meeting.status)
            }
            .navigationTitle(meeting.title)
            .onAppear { normalizeTranscriptIfNeeded(meeting) }
            // F180: consume a "jump to this cited moment" request once this (freshly recreated) detail
            // view for the requested meeting appears, feeding the F177 seek path. `.task(id:)` runs on
            // (re)appear for this meeting id; the seek is a one-shot cleared from the model.
            .task(id: meetingID) {
                if let request = model.pendingNavigation, request.meetingID == meetingID {
                    transcriptMode = .read // the player only exists in read mode
                    seekRequest = request.seek
                    model.pendingNavigation = nil
                }
                refreshRepetitionState()
            }
            // F422/F423: removing lines changes what the repetition notices describe, so they are
            // recomputed when the lines change — still never per redraw.
            .onChange(of: store.meeting(id: meetingID)?.segments) { _, _ in refreshRepetitionState() }
            .alert("Transcribe this meeting again?", isPresented: $confirmTranscribeAgain) {
                Button("Cancel", role: .cancel) {}
                Button("Transcribe Again") { model.transcribeAgain(id: meetingID) }
            } message: {
                Text("A new transcript is made from the recording and replaces this one, including any edits, deleted lines and removed repeats. It uses the engine and language selected in Settings. The recording is unchanged, and if the new run is cancelled or fails, this transcript stays.")
            }
            .alert("Summarize with Claude?", isPresented: $confirmSummarize) {
                Button("Cancel", role: .cancel) {}
                Button("Send to Claude") { model.summarize(id: meetingID, style: summaryStyle, template: summaryTemplate) }
            } message: {
                Text("This sends the meeting transcript to Anthropic's Claude API using your saved key. It's the only feature that leaves this Mac.")
            }
            // F220: the same shape as the Claude confirmation above, stating the opposite boundary —
            // the analysis stays on this Mac — and then saying plainly what the result is worth. The
            // copy is pinned by `SpeakerAnalysisCopyTests`; nothing about it is decided here.
            .alert(SpeakerAnalysisCopy.disclosureTitle, isPresented: $confirmDiarization) {
                Button("Cancel", role: .cancel) {}
                Button("Analyze") { model.requestSpeakerDiarization(for: meetingID) }
            } message: {
                Text(SpeakerAnalysisCopy.disclosureMessage)
            }
            .sheet(isPresented: Binding(
                get: { vocabularySuggestions != nil },
                set: { if !$0 { vocabularySuggestions = nil } }
            )) {
                VocabularySuggestionSheet(suggestions: vocabularySuggestions ?? []) { chosen in
                    withAnimation(reduceMotion ? nil : .uiSpring) {
                        store.addVocabulary(chosen)
                    }
                }
            }
            .sheet(isPresented: Binding(
                get: { glossaryProposals != nil },
                set: { if !$0 { glossaryProposals = nil } }
            )) {
                GlossarySuggestionSheet(proposals: glossaryProposals ?? [], protectedTerms: store.vocabulary) { accepted in
                    model.applyGlossaryCorrections(accepted, to: meetingID)
                }
            }
            .sheet(item: $languageRemovalOffer) { offer in
                LanguageLineRemovalSheet(offer: offer) { indices in
                    guard let removal = model.removeTranscriptLines(at: IndexSet(indices), from: meetingID) else { return }
                    registerLineRemovalUndo(removal, model: model, undoManager: undoManager, actionName: "Remove Lines")
                }
            }
            .sheet(isPresented: $showSecondOpinion) {
                SecondOpinionSheet(
                    spans: model.secondOpinionSpans,
                    isRunning: model.isRunningAuxiliaryEngine,
                    engineName: model.secondOpinionEngine?.displayName,
                    progress: model.secondOpinionProgress,
                    failed: model.secondOpinionFailed,
                    failureReason: model.secondOpinionFailureReason,
                    onReplace: { span in model.applySecondOpinionSpan(span, to: meetingID) },
                    onCancel: { model.cancelSecondOpinion() }
                )
            }
            // F170: pick a local reference document (spec/glossary) to guide the on-device correction
            // pass. The file is read and capped off the main actor, then passed to the same
            // review-before-apply path; nothing is uploaded and the recording is never touched.
            .fileImporter(
                isPresented: $showsReferenceImporter,
                allowedContentTypes: Self.referenceContentTypes,
                allowsMultipleSelection: false
            ) { result in
                switch result {
                case let .success(urls):
                    guard let url = urls.first else { return }
                    correctWithReference(url, meetingID: meetingID)
                case let .failure(error):
                    model.alertMessage = error.localizedDescription
                }
            }
        }
    }

    /// Document types accepted as a correction reference — the same set the Vocabulary importer reads.
    private static var referenceContentTypes: [UTType] {
        var types: [UTType] = [.pdf, .plainText, .commaSeparatedText]
        if let docx = UTType(filenameExtension: "docx") { types.append(docx) }
        if let markdown = UTType(filenameExtension: "md") { types.append(markdown) }
        return types
    }

    /// Reads the chosen reference document off the main actor, then runs the on-device correction pass
    /// guided by it (F170). An unreadable/empty document says so instead of silently doing nothing.
    private func correctWithReference(_ url: URL, meetingID: UUID) {
        Task {
            let reference = await Task.detached(priority: .userInitiated) {
                VocabularyExtractor.referenceText(from: url)
            }.value
            guard let reference else {
                model.alertMessage = "That reference document couldn't be read, or had no usable text. Choose a PDF, DOCX, TXT, or Markdown file."
                return
            }
            let proposals = await model.proposeLocalCorrections(for: meetingID, reference: reference)
            if proposals.isEmpty {
                // Only speak up if the model ran and found nothing; the AppModel guard already set a
                // message for install-required / hand-edited / error cases.
                if model.alertMessage == nil {
                    model.alertMessage = "The local model found nothing to correct against that reference."
                }
            } else {
                glossaryProposals = proposals
            }
        }
    }

    private static func summaryStyleName(_ style: SummaryStyle) -> String {
        switch style {
        case .balanced: return "Balanced"
        case .brief: return "Brief"
        case .detailed: return "Detailed"
        case .actionItemsFocused: return "Action items"
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
                Picker("Meeting template", selection: $summaryTemplate) {
                    ForEach(MeetingTemplate.allCases, id: \.self) { template in
                        Text(template.displayName).tag(template)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 150)
                .disabled(isSummarizing)
                .help("Choose a template that shapes the summary's structure for this kind of meeting. Everything stays on this Mac.")
                Picker("Summary style", selection: $summaryStyle) {
                    ForEach(SummaryStyle.allCases, id: \.self) { style in
                        Text(Self.summaryStyleName(style)).tag(style)
                    }
                }
                .labelsHidden()
                .frame(maxWidth: 150)
                .disabled(isSummarizing)
                .help("Choose how detailed the summary should be.")
                Button(meeting.summary == nil
                    ? (model.summarizationEngine == .local ? "Summarize" : "Summarize with Claude")
                    : "Re-summarize") {
                    switch model.summarizationEngine {
                    case .local:
                        // The AppModel guard offers install if the model is missing (honest fallback).
                        model.summarize(id: meetingID, style: summaryStyle, template: summaryTemplate)
                    case .claude:
                        if model.hasClaudeAPIKey {
                            confirmSummarize = true
                        } else {
                            model.alertMessage = "Add a Claude API key in Settings to create summaries."
                        }
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSummarizing || meeting.transcriptText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            if isSummarizing {
                // F512: a summary could not be stopped, and a stuck one held the summary slot until
                // the app was quit.
                HStack(spacing: 10) {
                    ProgressView(model.summarizationEngine == .local ? "Summarizing on this Mac…" : "Summarizing with Claude…")
                        .controlSize(.small)
                    Button("Cancel") { model.cancelSummarization(id: meetingID) }
                        .controlSize(.small)
                }
                .transition(.gentleFade(reduceMotion: reduceMotion))
            } else if let summary = meeting.summary {
                summaryBody(summary, transcript: meeting.transcriptText)
                    .transition(.gentleFade(reduceMotion: reduceMotion))
            } else if model.summarizationEngine == .local, !model.isSummarizerInstalled, SummarizerRuntime.isSupportedOnCurrentMac {
                Text("Install the local summarization model in Settings to turn this transcript into a summary, key points, and action items — privately, on this Mac.")
                    .foregroundStyle(.secondary)
            } else if model.summarizationEngine == .claude, !model.hasClaudeAPIKey {
                Text("Add a Claude API key in Settings to turn this transcript into a summary, key points, and action items.")
                    .foregroundStyle(.secondary)
            }
        }
        // The spinner → summary swap after a multi-second Claude wait fades and settles instead
        // of cutting (F116). Keyed on both the in-flight flag and summary presence because they
        // can change in separate renders.
        .animation(reduceMotion ? nil : .uiSpring, value: isSummarizing)
        .animation(reduceMotion ? nil : .uiSpring, value: meeting.summary == nil)
    }

    @ViewBuilder
    private func summaryBody(_ summary: MeetingSummary, transcript: String) -> some View {
        let coverageInput = SummaryCoverageInput(summary: summary, transcript: transcript, terms: store.vocabulary)
        VStack(alignment: .leading, spacing: 14) {
            Text(summary.summary)
                .textSelection(.enabled)
            // F245: a summary omits by design and a dropped claim leaves no trace. This is the
            // cheapest honest signal — the user's own vocabulary terms the transcript mentions
            // and the summary does not — recomputed whenever the vocabulary changes.
            //
            // F437: filled by the `.task(id:)` below, never computed here. Shown only beside the
            // summary text it was worked out for, so a new summary never carries the last one's note.
            if let note = coverageNote, note.summaryText == summary.summary, !note.terms.isEmpty {
                Label {
                    Text("Not mentioned in this summary: \(note.terms.joined(separator: ", "))")
                } icon: {
                    Image(systemName: "text.badge.minus")
                }
                .font(.caption)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
            }
            if !summary.keyPoints.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    HStack {
                        Text("Key points").font(.subheadline.bold())
                        Button("Copy") { copy(summary.keyPoints.map { "• \($0)" }.joined(separator: "\n")) }
                            .controlSize(.small)
                            .help("Copy the key points only")
                    }
                    ForEach(summary.keyPoints.indices, id: \.self) { index in
                        Text("• \(summary.keyPoints[index])")
                    }
                    .textSelection(.enabled)
                }
            }
            if !summary.actionItems.isEmpty {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Text("Action items").font(.subheadline.bold())
                        Button("Copy") { copy(summary.actionItems.map(MeetingNotesExporter.actionItemLine).joined(separator: "\n")) }
                            .controlSize(.small)
                            .help("Copy the action items only, with owner and due date")
                    }
                    ForEach(summary.actionItems.indices, id: \.self) { index in
                        ActionItemCard(
                            item: summary.actionItems[index],
                            onToggleDone: { done in
                                model.updateActionItem(at: index, for: meetingID) { $0.done = done }
                            },
                            onCommitOwner: { owner in
                                model.updateActionItem(at: index, for: meetingID) { $0.owner = owner }
                            },
                            onCommitDue: { due in
                                model.updateActionItem(at: index, for: meetingID) { $0.due = due }
                            },
                            onPlaySource: summary.actionItems[index].timestamp.map { time in
                                { transcriptMode = .read; seekRequest = time }
                            }
                        )
                    }
                }
            }
        }
        .padding(18)
        .frame(maxWidth: .infinity, alignment: .leading)
        .cardSurface()
        // F437: once per change of the summary, the transcript or the vocabulary, off the main
        // thread. A keystroke in the Edit view changes the input; the run it overtakes is cancelled
        // here — a detached check cannot be cancelled once spawned, so a burst of keystrokes waits
        // out this short pause and spawns one check, not one per key. Until the new answer lands
        // the previous note stays on screen, deliberately: blanking it on every keystroke would
        // flicker, and the button-free note can mislead for at most one recompute.
        .task(id: coverageInput) {
            do { try await Task.sleep(for: .milliseconds(250)) } catch { return }
            let terms = await model.unmentionedSummaryTerms(for: coverageInput)
            // A newer input replaced this one while it ran; that input's own task answers.
            guard !Task.isCancelled else { return }
            coverageNote = (summaryText: summary.summary, terms: terms)
        }
    }

    private static func summaryText(_ summary: MeetingSummary) -> String {
        var lines = ["Summary", summary.summary]
        if !summary.keyPoints.isEmpty {
            lines.append("\nKey points")
            lines.append(contentsOf: summary.keyPoints.map { "• \($0)" })
        }
        if !summary.actionItems.isEmpty {
            lines.append("\nAction items")
            lines.append(contentsOf: summary.actionItems.map(MeetingNotesExporter.actionItemLine))
        }
        return lines.joined(separator: "\n")
    }

    @ViewBuilder
    private func header(_ meeting: MeetingRecord) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            EditableMeetingTitle(store: store, meetingID: meetingID)
                .id(meetingID)
            // F183: where a link-imported meeting came from, with a way back to the original page.
            if let source = meeting.source {
                HStack(spacing: 6) {
                    Image(systemName: "link").font(.caption2).foregroundStyle(.tertiary)
                    if let uploader = source.uploader, !uploader.isEmpty {
                        Text(uploader).font(.caption).foregroundStyle(.secondary)
                        Text("·").font(.caption).foregroundStyle(.tertiary)
                    }
                    if let pageURL = URL(string: source.pageURL) {
                        Link(source.host, destination: pageURL).font(.caption)
                    } else {
                        Text(source.host).font(.caption).foregroundStyle(.secondary)
                    }
                }
                .accessibilityElement(children: .combine)
                .accessibilityLabel("Imported from \(source.host)")
            }
            HStack(spacing: 8) {
                metadataChip(
                    meeting.createdAt.formatted(date: .abbreviated, time: .shortened),
                    systemImage: "calendar"
                )
                metadataChip(formatDuration(meeting.duration), systemImage: "clock")
                if let language = meeting.languageCode {
                    metadataChip(language.uppercased(), systemImage: "character.bubble")
                }
                if let confidence = meeting.confidence {
                    metadataChip(
                        confidence.formatted(.percent.precision(.fractionLength(0))),
                        systemImage: "checkmark.seal"
                    )
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
        }
    }

    /// Meeting facts as quiet capsule chips — scannable at a glance without competing with the title.
    private func metadataChip(_ text: String, systemImage: String) -> some View {
        Label(text, systemImage: systemImage)
            .font(.callout)
            .foregroundStyle(.secondary)
            .padding(.horizontal, 9)
            .padding(.vertical, 3)
            .background(.quaternary.opacity(0.5), in: Capsule())
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
                            Text(model.queuedTranscriptionWaitMessage).foregroundStyle(.secondary)
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
            .cardSurface()
            .transition(.gentleFade(reduceMotion: reduceMotion))
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
            return "Transcribing locally…"
        }
        switch progress.phase {
        case .preparing:
            return "Preparing…"
        case .loadingModel:
            return "Loading the recognition model…"
        case .downloadingModel:
            return "Downloading the recognition model (first use)… \(percentText(progress.fractionCompleted))"
        case .transcribing:
            return "Transcribing locally… \(percentText(progress.fractionCompleted))"
        }
    }

    private func percentText(_ fraction: Double?) -> String {
        guard let fraction else { return "" }
        return fraction.formatted(.percent.precision(.fractionLength(0)))
    }

    private func etaText(_ seconds: TimeInterval?) -> String? {
        guard let seconds else { return nil }
        let total = Int(saturating: seconds)   // traps otherwise; see SaturatingConversion
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
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
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
        let isEdited = store.isTranscriptEdited(meeting)
        VStack(alignment: .leading, spacing: 12) {
            // Four improvement actions live in one labeled menu (F172): seven inline controls
            // compressed every label to "Suggest…"/"Correct…"; menu items have room for full
            // names, and the top row keeps only the mode picker and the two instant actions.
            HStack(spacing: 10) {
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
                improveMenu(meeting)
                Button {
                    copy(currentTranscript())
                    copyAck.trigger()
                } label: {
                    Text(copyAck.isActive ? "Copied" : "Copy")
                        .frame(minWidth: 48)
                }
                .fixedSize()
                Menu("Export…") {
                    Button("Meeting Notes — Summary + Transcript (.md)") {
                        exportMeetingNotes(meeting: meeting)
                    }
                    Divider()
                    // F220: the NINE ordinary formats, listed explicitly by `standardFormats` rather
                    // than by `allCases`. A labeled format added to the enum must never opt itself
                    // into this list — a speaker label reaching an ordinary export is the leak this
                    // whole feature is built to avoid.
                    ForEach(TranscriptExportFormat.standardFormats, id: \.self) { format in
                        Button(format.displayName) {
                            exportTranscript(meeting: meeting, format: format)
                        }
                    }
                    // Offered only when there are labels to carry: no analysis, a stale one, or a
                    // single distinguished voice all produce no request, and the action is absent
                    // rather than exporting a file identical to the ordinary transcript.
                    if model.speakerLabeledExportRequest(for: meetingID) != nil {
                        Divider()
                        Button(TranscriptExportFormat.labeledMarkdown.displayName) {
                            exportSpeakerLabeledTranscript(meeting: meeting)
                        }
                    }
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }
            improvementStatus(meeting)

            // Explain in plain language when timestamp alignment was unavailable, so a transcript
            // with no seekable timestamps never looks like a silent failure (F30). The complete text
            // below is authoritative; only the per-segment timing is missing.
            //
            // F515: transcribing again is what brings the timestamps back (F420), so the control that
            // does it sits beside this message — beside, never inside it (F306).
            if let warning = meeting.alignmentWarning {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Label(warning, systemImage: "clock.badge.exclamationmark")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Transcribe Again…") { confirmTranscribeAgain = true }
                        .disabled(model.transcribeAgainBlockedReason(for: meetingID) != nil)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .bannerSurface(.orange)
            }

            // Flag when the transcript's language disagrees with the language the user selected, so
            // "original language only" is visibly enforced rather than silently trusted (F32).
            if let warning = meeting.languageWarning {
                Label(warning, systemImage: "character.bubble.badge.exclamationmark")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .bannerSurface(.red)
                    .accessibilityElement(children: .combine)
            }

            // A looping decode is clean segment-by-segment, so the per-segment quality review scores it
            // and reports full confidence; only judging the whole segment list reveals it (F186).
            // Computed once per meeting in `.task` below, never per redraw — the segment list can run to
            // thousands of entries and this sits in a view that repaints during playback (F160).
            //
            // F422: echoes this transcript still has, with the control that removes them BESIDE the
            // message, never inside it (F306: nesting is what made a banner's button deletable). When
            // there are any, they are the actionable explanation, so the F186/F261 warning waits until
            // nothing removable is left.
            if removableRepeats > 0 {
                HStack(alignment: .firstTextBaseline, spacing: 12) {
                    Label(
                        TranscriptRepetitionCleanup.removableNotice(count: removableRepeats),
                        systemImage: "repeat.circle"
                    )
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Remove Repeated Lines") { removeRepeatedLines() }
                        .disabled(model.lineRemovalBlockedReason(for: meetingID) != nil)
                }
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .bannerSurface(.orange)
            } else if let notice = repetitionNotice {
                Label(notice, systemImage: "repeat.circle")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .bannerSurface(.red)
                    .accessibilityElement(children: .combine)
            }
            // F422: said once text was removed, from the stored count, so it outlives the session.
            if let removed = meeting.repeatsRemoved, removed > 0 {
                Label(TranscriptRepetitionCleanup.removedNote(count: removed), systemImage: "checkmark.circle")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            if hasSegments && transcriptMode == .read {
                if isEdited {
                    Text("Read view shows the original timestamped transcription; your edits are in Edit view. Quality flags are hidden here because they describe the original text.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                PlayableTranscriptView(
                    store: store,
                    model: model,
                    meetingID: meetingID,
                    recordingURL: store.recordingURL(for: meeting),
                    segments: meeting.segments,
                    isEdited: isEdited,
                    seekRequest: $seekRequest
                )
                .id(meetingID)
            } else {
                recordingPlayer(meeting)
                if !meeting.orderedMarkers.isEmpty {
                    SimpleMarkersList(model: model, meetingID: meetingID, markers: meeting.orderedMarkers)
                }
                transcriptTextEditor(meeting)
            }
        }
        // The status row's arrival/departure fades and settles (F116) instead of snapping the
        // section layout; each animation is scoped to the state that inserts or removes it.
        .animation(reduceMotion ? nil : .uiSpring, value: isSuggestingVocab)
        .animation(reduceMotion ? nil : .uiSpring, value: model.proposingCorrectionsID)
        .animation(reduceMotion ? nil : .uiSpring, value: model.secondOpinionRunningID)
        .animation(reduceMotion ? nil : .uiSpring, value: model.segmentReTranscriptionRunningID)
        .animation(reduceMotion ? nil : .uiSpring, value: showSecondOpinion)
    }

    /// The transcript-improvement actions as one labeled pull-down (F172). Items keep full
    /// descriptive labels; when something is disabled, a plain-language footnote in the same menu
    /// says why instead of leaving a mystery-gray row.
    private func improveMenu(_ meeting: MeetingRecord) -> some View {
        // F220: Apple-silicon only, like Qwen3-ASR and local summaries — on Intel the entry is absent
        // and the Settings row says why. The reason is resolved once here rather than inside
        // `.disabled` and again in the footnote, so the greyed-out row and the sentence explaining it
        // can never disagree.
        let offersSpeakerAnalysis = AppModel.diarizationIsSupportedOnCurrentMac
        let speakerReason = offersSpeakerAnalysis
            ? model.speakerAnalysisUnavailability(for: meeting)
            : nil
        let isEdited = store.isTranscriptEdited(meeting)
        return Menu {
            // F515: first, because it is the one that replaces everything below it. Asks first.
            Button {
                confirmTranscribeAgain = true
            } label: {
                Label("Transcribe Again…", systemImage: "arrow.clockwise")
            }
            .disabled(model.transcribeAgainBlockedReason(for: meetingID) != nil)
            Divider()
            Button {
                suggestVocabulary(meeting)
            } label: {
                Label("Suggest Vocabulary Terms…", systemImage: "text.badge.plus")
            }
            .disabled(isSuggestingVocab)
            Button {
                let proposals = model.glossaryCorrections(for: meetingID)
                if proposals.isEmpty {
                    model.alertMessage = "No transcript spans look close to a vocabulary term."
                } else {
                    glossaryProposals = proposals
                }
            } label: {
                Label("Correct Toward Vocabulary…", systemImage: "wand.and.stars")
            }
            .disabled(store.vocabulary.isEmpty || isEdited)
            // F179: exact user-defined replacement rules, reviewed through the same sheet. No model.
            Button {
                let proposals = model.replacementRuleCorrections(for: meetingID)
                if proposals.isEmpty {
                    model.alertMessage = "None of your replacement rules matched this transcript."
                } else {
                    glossaryProposals = proposals
                }
            } label: {
                Label("Apply Replacement Rules…", systemImage: "arrow.left.arrow.right")
            }
            .disabled(store.replacementRules.isEmpty || isEdited
                      || model.libraryReadOnlyFootnote != nil)
            if SummarizerRuntime.isSupportedOnCurrentMac {
                Button {
                    Task {
                        let proposals = await model.proposeLocalCorrections(for: meetingID)
                        if proposals.isEmpty {
                            // Only speak up if the model ran and simply found nothing; the AppModel
                            // guard already set a message for install-required / edited / errors.
                            if model.alertMessage == nil {
                                model.alertMessage = "The local model found nothing to correct."
                            }
                        } else {
                            glossaryProposals = proposals
                        }
                    }
                } label: {
                    Label("Correct with Local AI…", systemImage: "wand.and.stars.inverse")
                }
                .disabled(model.isProposingCorrections || isEdited || store.vocabulary.isEmpty
                          || model.libraryReadOnlyFootnote != nil)
                // F170: guide the same on-device correction pass with a chosen reference document
                // (spec/glossary). Works without any vocabulary — the reference is the target — so it is
                // NOT disabled on an empty vocabulary, unlike the vocabulary-only correction above.
                Button {
                    showsReferenceImporter = true
                } label: {
                    Label("Correct with Local AI + Reference File…", systemImage: "doc.text.magnifyingglass")
                }
                .disabled(model.isProposingCorrections || isEdited
                          || model.libraryReadOnlyFootnote != nil)
            }
            Divider()
            Button {
                model.secondOpinionSpans = nil
                // F512: only a run that started has a sheet to show; a refusal is its alert alone.
                if model.requestSecondOpinion(id: meetingID) {
                    showSecondOpinion = true
                }
            } label: {
                Label("Second Opinion (Other Engine)…", systemImage: "person.2.wave.2")
            }
            .disabled(model.isRunningAuxiliaryEngine || model.hasActiveTranscription || isEdited
                      || meeting.segments.isEmpty || model.libraryReadOnlyFootnote != nil)
            // F424: pick out a side-conversation in the meeting's other language. It opens a list to
            // confirm; nothing is removed from here.
            Button {
                offerLanguageLineRemoval()
            } label: {
                Label("Remove Lines in Another Language…", systemImage: "character.bubble")
            }
            .disabled(model.lineRemovalBlockedReason(for: meetingID) != nil)
            // F220: optional, post-meeting, entirely local speaker-turn analysis. The disclosure
            // always comes first — this button opens it and nothing else, so no analysis can start
            // without the user having read what the labels are and are not.
            if offersSpeakerAnalysis {
                Divider()
                Button {
                    confirmDiarization = true
                } label: {
                    Label(SpeakerAnalysisCopy.menuItemTitle, systemImage: "person.wave.2")
                }
                .disabled(speakerReason != nil)
            }
            if isEdited || store.vocabulary.isEmpty || store.replacementRules.isEmpty
                || meeting.segments.isEmpty || speakerReason != nil || model.libraryReadOnlyFootnote != nil {
                Divider()
                // F194: first, because it outranks the others — when the library is read-only none of
                // these can be applied whatever else is true of the transcript.
                if let readOnly = model.libraryReadOnlyFootnote {
                    Text(readOnly)
                }
                if isEdited {
                    Text("Unavailable after manual edits — these tools work on the original transcription.")
                }
                if store.vocabulary.isEmpty {
                    Text("Vocabulary-based corrections need Business Vocabulary terms (see the Vocabulary tab). The reference-file option works without them.")
                }
                if store.replacementRules.isEmpty {
                    Text("Replacement rules (exact heard → preferred) are added in the Vocabulary tab.")
                }
                // F512: why Second Opinion is greyed out, in the words the sheet would have used.
                if meeting.segments.isEmpty {
                    Text(AppModel.secondOpinionNeedsTimestampsMessage)
                }
                if let speakerReason {
                    Text(SpeakerAnalysisCopy.footnote(for: speakerReason))
                }
            }
        } label: {
            Label("Improve", systemImage: "sparkles")
        }
        .fixedSize()
        .help("Tools that work on this transcript: transcribing it again, vocabulary suggestions, spelling corrections, a second engine's comparison, and optional anonymous speaker-turn analysis. Everything runs on this Mac.")
    }

    /// Ongoing improvement work surfaced as a labeled status line under the header instead of a
    /// spinner squeezed into a button (F172): the running tool is named, and second-opinion
    /// progress can be reopened after its sheet was dismissed.
    @ViewBuilder
    private func improvementStatus(_ meeting: MeetingRecord) -> some View {
        if isSuggestingVocab {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Scanning the transcript for vocabulary terms…")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .transition(.gentleFade(reduceMotion: reduceMotion))
        } else if model.proposingCorrectionsID == meetingID {
            // Scoped to THIS meeting (F173) — another meeting's run must not present here.
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("The local model is proposing corrections…")
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .transition(.gentleFade(reduceMotion: reduceMotion))
        } else if model.secondOpinionRunningID == meetingID && !showSecondOpinion {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Second opinion in progress…")
                Button("Show Progress") { showSecondOpinion = true }
                    .controlSize(.small)
                // F512: a whole-meeting pass that holds the engine every queued transcription waits
                // behind; quitting was the only way to stop it.
                Button("Cancel") { model.cancelSecondOpinion() }
                    .controlSize(.small)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .transition(.gentleFade(reduceMotion: reduceMotion))
        } else if model.segmentReTranscriptionRunningID == meetingID {
            // F512: the segment re-run had no progress line at all, so nothing said why transcription
            // and dictation were waiting, and nothing could stop it.
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("Re-transcribing a segment…")
                Button("Cancel") { model.cancelSegmentReTranscription() }
                    .controlSize(.small)
            }
            .font(.callout)
            .foregroundStyle(.secondary)
            .transition(.gentleFade(reduceMotion: reduceMotion))
        }
    }


    private func transcriptTextEditor(_ meeting: MeetingRecord) -> some View {
        TextEditor(text: Binding(
            get: { store.meeting(id: meeting.id)?.transcriptText ?? "" },
            // Debounced write (F40): update in memory immediately, coalesce the whole-index disk write.
            set: { value in store.editTranscript(id: meeting.id, text: value) }
        ))
        .font(.body)
        .scrollContentBackground(.hidden)
        .padding(12)
        .frame(minHeight: 360)
        .background(.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .stroke(.separator, lineWidth: 1)
        }
        // Flush any pending debounced edit when the editor goes away (tab switch, detail close) so an
        // edit made in the last debounce window is never lost (F40).
        .onDisappear { store.flushPendingEdits() }
    }

    /// The two repetition notices, off the render path (F186, F422). Suppressed on a hand-edited
    /// transcript, like every other segment-derived overlay — the segments no longer describe what
    /// is shown.
    private func refreshRepetitionState() {
        let meeting = store.meeting(id: meetingID)
        let edited = meeting.map { store.isTranscriptEdited($0) } ?? false
        repetitionNotice = edited ? nil : TranscriptQuality.repetitionNotice(meeting?.segments ?? [])
        removableRepeats = edited ? 0 : model.removableRepeatCount(for: meetingID)
    }

    private func removeRepeatedLines() {
        guard let removal = model.removeRepeatedLines(from: meetingID) else { return }
        registerLineRemovalUndo(removal, model: model, undoManager: undoManager, actionName: "Remove Repeated Lines")
    }

    /// Builds the list for Remove Lines in Another Language (F424). Nothing is removed here; the
    /// sheet's Remove button does that, for the lines still ticked.
    private func offerLanguageLineRemoval() {
        guard let meeting = store.meeting(id: meetingID),
              let offer = model.linesOutsideMeetingLanguage(for: meetingID) else {
            model.alertMessage = "WhisperMeet can't tell which language this meeting is in, so it can't pick out lines in another one."
            return
        }
        guard !offer.indices.isEmpty else {
            model.alertMessage = "Every line of this transcript reads as \(offer.language.displayName)."
            return
        }
        languageRemovalOffer = LanguageRemovalOffer(
            language: offer.language,
            lines: offer.indices.map { index in
                let segment = meeting.segments[index]
                return LanguageRemovalOffer.Line(
                    index: index,
                    timestamp: segment.start.map { TranscriptFormatter.timestamp($0) },
                    text: segment.text
                )
            }
        )
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
            segments: current.segments,
            markers: current.orderedMarkers
        )
        saveExport(
            TranscriptExporter.render(format, request),
            suggestedName: current.title,
            fileExtension: format.fileExtension
        )
    }

    /// The one export that carries the anonymous speaker overlay (F220). A separate, named action —
    /// never a variant of an ordinary format — and it asks `AppModel` for the payload, so the labels
    /// and the rows are assembled in the single place allowed to put them in an export request.
    private func exportSpeakerLabeledTranscript(meeting: MeetingRecord) {
        guard let request = model.speakerLabeledExportRequest(for: meeting.id) else {
            // Only reachable if the analysis was cleared or went stale between the menu opening and
            // the click. Say so rather than writing an unlabeled file under a labeled name.
            model.alertMessage = "There are no speaker labels to export for this meeting. Your transcript is unchanged."
            return
        }
        saveExport(
            TranscriptExporter.render(.labeledMarkdown, request),
            suggestedName: "\(request.title) with Speaker Labels",
            fileExtension: TranscriptExportFormat.labeledMarkdown.fileExtension
        )
    }

    private func exportMeetingNotes(meeting: MeetingRecord) {
        let current = store.meeting(id: meeting.id) ?? meeting
        saveExport(store.notesMarkdown(for: current), suggestedName: "\(current.title) Notes", fileExtension: "md")
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

/// A left-aligned wrapping layout for tag chips (F171): rows fill the proposed width then wrap,
/// like text. Sized by the sum of its rows so it composes with the surrounding VStack.
/// Used by `TagChipsEditor` here and by `MeetingBatchView` in its own file.
struct WrapLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrangement(proposal: proposal, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        for (subview, origin) in zip(subviews, arrangement(proposal: proposal, subviews: subviews).origins) {
            subview.place(
                at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y),
                proposal: .unspecified
            )
        }
    }

    private func arrangement(
        proposal: ProposedViewSize, subviews: Subviews
    ) -> (size: CGSize, origins: [CGPoint]) {
        let maxWidth = proposal.width ?? .infinity
        var origins: [CGPoint] = []
        var x: CGFloat = 0
        var y: CGFloat = 0
        var rowHeight: CGFloat = 0
        var width: CGFloat = 0
        for subview in subviews {
            let size = subview.sizeThatFits(.unspecified)
            if x > 0, x + size.width > maxWidth {
                x = 0
                y += rowHeight + spacing
                rowHeight = 0
            }
            origins.append(CGPoint(x: x, y: y))
            rowHeight = max(rowHeight, size.height)
            width = max(width, x + size.width)
            x += size.width + spacing
        }
        return (CGSize(width: width, height: y + rowHeight), origins)
    }
}

/// A token-style tag editor (F171): every applied tag is a chip with a visible remove control,
/// new tags are typed inline (Return or comma commits; Backspace in the empty field removes the
/// last tag), and tags already used on other meetings are offered for one-click reuse so
/// spellings stay consistent. `MeetingStore.setTags` normalization (F67) remains the single
/// gatekeeper for what is persisted.
private struct TagChipsEditor: View {
    @ObservedObject var store: MeetingStore
    let meetingID: UUID
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var draft = ""
    @FocusState private var inputFocused: Bool

    private var tags: [String] { store.meeting(id: meetingID)?.tags ?? [] }
    private var atCapacity: Bool { tags.count >= MeetingTags.maxCount }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            WrapLayout(spacing: 6) {
                ForEach(tags, id: \.self) { tag in
                    chip(tag)
                }
                if !atCapacity {
                    TextField(tags.isEmpty ? "Add a tag (Return commits)" : "Add…", text: $draft)
                        .textFieldStyle(.plain)
                        // Wide enough for the longer placeholder: at 150 it rendered as
                        // "Add a tag (Return commi", clipped mid-word, on the first look at this
                        // editor on screen (F174, 2026-09-17).
                        .frame(width: tags.isEmpty ? 210 : 150)
                        .focused($inputFocused)
                        .onSubmit { commit(draft) }
                        // Comma commits mid-typing, so "budget, hiring" becomes chips as it is
                        // typed — the grammar the old comma-separated field trained users into.
                        .onChange(of: draft) { _, newValue in
                            let split = MeetingTags.liveSplit(newValue)
                            guard !split.ready.isEmpty else { return }
                            commit(split.ready.joined(separator: ","))
                            draft = split.remainder
                        }
                        // Backspace in the empty field removes the last chip — standard
                        // token-field grammar, so deleting needs no pointer travel.
                        .onKeyPress(.delete) {
                            guard draft.isEmpty, let last = tags.last else { return .ignored }
                            remove(last)
                            return .handled
                        }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
            .contentShape(Rectangle())
            // The whole well focuses the field, like a real token field — the click target is
            // the control, not a thin text line.
            .onTapGesture { inputFocused = true }

            if atCapacity {
                Text("Tag limit reached (\(MeetingTags.maxCount)). Remove one to add another.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            let suggestions = MeetingTags.reuseSuggestions(
                library: store.meetings.map { $0.tags ?? [] },
                applied: tags,
                query: draft
            )
            if inputFocused && !atCapacity && !suggestions.isEmpty {
                HStack(spacing: 6) {
                    ForEach(suggestions, id: \.self) { tag in
                        Button {
                            commit(tag)
                        } label: {
                            Label(tag, systemImage: "plus")
                                .font(.caption)
                                .padding(.horizontal, 8)
                                .padding(.vertical, 3)
                                .background(.quaternary.opacity(0.35), in: Capsule())
                        }
                        .buttonStyle(PressableChipStyle())
                        .accessibilityLabel("Add tag \(tag)")
                    }
                }
                .transition(.gentleFade(reduceMotion: reduceMotion))
            }
        }
        .animation(reduceMotion ? nil : .uiSpring, value: tags)
        .animation(reduceMotion ? nil : .uiSpring, value: inputFocused)
        // Commit whatever is typed when focus leaves, so an un-Returned tag is never lost.
        .onChange(of: inputFocused) { _, focused in
            if !focused { commit(draft) }
        }
    }

    private func chip(_ tag: String) -> some View {
        HStack(spacing: 5) {
            Text(tag)
            Button {
                remove(tag)
            } label: {
                Image(systemName: "xmark.circle.fill")
            }
            .buttonStyle(LinkPressStyle())
            .foregroundStyle(.tertiary)
            .accessibilityLabel("Remove tag \(tag)")
            .help("Remove \(tag)")
        }
        .font(.callout)
        .padding(.horizontal, 9)
        .padding(.vertical, 4)
        .background(.quaternary.opacity(0.5), in: Capsule())
    }

    private func commit(_ text: String) {
        let parts = text
            .components(separatedBy: CharacterSet(charactersIn: ",\n"))
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !parts.isEmpty else { return }
        store.setTags(id: meetingID, tags + parts)
        draft = ""
    }

    private func remove(_ tag: String) {
        store.setTags(id: meetingID, tags.filter { $0 != tag })
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

/// One evidence-linked action item as a reviewable local card (F177): a done checkbox, the task text,
/// a user-entered owner and due, and — when the item was matched to a transcript moment — its quote
/// and a "Play source" button that seeks the recording. Owner/due commit on Return (or when the field
/// loses focus), so editing them does not rewrite the meeting index on every keystroke.
private struct ActionItemCard: View {
    let item: ActionItem
    let onToggleDone: (Bool) -> Void
    let onCommitOwner: (String?) -> Void
    let onCommitDue: (String?) -> Void
    /// Non-nil only when the item resolved to a timestamp; the closure seeks the transcript player.
    let onPlaySource: (() -> Void)?

    @State private var ownerDraft = ""
    @State private var dueDraft = ""
    @FocusState private var focus: Field?

    private enum Field { case owner, due }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Toggle(isOn: Binding(get: { item.done }, set: onToggleDone)) { EmptyView() }
                .toggleStyle(.checkbox)
                .labelsHidden()
                .accessibilityLabel(item.done ? "Mark action item not done" : "Mark action item done")

            VStack(alignment: .leading, spacing: 6) {
                Text(item.text)
                    .textSelection(.enabled)
                    .strikethrough(item.done, color: .secondary)
                    .foregroundStyle(item.done ? Color.secondary : Color.primary)

                HStack(spacing: 8) {
                    TextField("Owner", text: $ownerDraft)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 150)
                        .focused($focus, equals: .owner)
                        .onSubmit(commitOwner)
                    TextField("Due", text: $dueDraft)
                        .textFieldStyle(.roundedBorder)
                        .frame(maxWidth: 130)
                        .focused($focus, equals: .due)
                        .onSubmit(commitDue)
                    if let onPlaySource, let timestamp = item.timestamp {
                        Button(action: onPlaySource) {
                            Label(TranscriptFormatter.timestamp(timestamp), systemImage: "play.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Play the recording from where this was raised.")
                    }
                }

                if let quote = item.quote?.trimmingCharacters(in: .whitespacesAndNewlines), !quote.isEmpty {
                    Text("“\(quote)”")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.opacity(0.4), in: RoundedRectangle(cornerRadius: 8, style: .continuous))
        .overlay(RoundedRectangle(cornerRadius: 8, style: .continuous).stroke(.separator.opacity(0.6)))
        .onAppear {
            ownerDraft = item.owner ?? ""
            dueDraft = item.due ?? ""
        }
        // Commit on Return (onSubmit above), on focus loss (a field the user leaves by clicking the
        // checkbox / Play source / another field), and on teardown — the detail view is `.id(meetingID)`,
        // so switching meetings destroys this card, and without the teardown flush a typed-but-not-
        // submitted owner/due would be lost. Mirrors EditableMeetingTitle.
        .onChange(of: focus) { previous, _ in
            if previous == .owner { commitOwner() }
            if previous == .due { commitDue() }
        }
        .onDisappear {
            commitOwner()
            commitDue()
        }
    }

    /// Commit guarded on an actual change so leaving an untouched field doesn't rewrite the index.
    private func commitOwner() {
        let value = normalized(ownerDraft)
        if value != item.owner { onCommitOwner(value) }
    }

    private func commitDue() {
        let value = normalized(dueDraft)
        if value != item.due { onCommitDue(value) }
    }

    private func normalized(_ text: String) -> String? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

/// Presents proposed spelling corrections toward the user's vocabulary for review. Nothing is applied
/// until the user confirms — corrections only take effect after explicit review (F82/F65).
/// Registers Edit ▸ Undo for a line removal (F423). Undo only: `undoTranscriptLineRemoval` refuses
/// once the transcript has changed again, so a stale undo does nothing rather than overwrite.
@MainActor
private func registerLineRemovalUndo(
    _ removal: AppModel.TranscriptLineRemoval,
    model: AppModel,
    undoManager: UndoManager?,
    actionName: String
) {
    guard let undoManager else { return }
    undoManager.registerUndo(withTarget: model) { model in
        MainActor.assumeIsolated { _ = model.undoTranscriptLineRemoval(removal) }
    }
    undoManager.setActionName(actionName)
}

/// The lines Remove Lines in Another Language offers (F424), captured when the sheet opens.
private struct LanguageRemovalOffer: Identifiable {
    struct Line: Identifiable {
        let index: Int
        let timestamp: String?
        let text: String
        var id: Int { index }
    }

    let id = UUID()
    /// The meeting's language — the lines listed are in the OTHER one.
    let language: TranscriptLanguage
    let lines: [Line]
}

/// Lists the lines in the meeting's other language, all ticked, for the user to confirm (F424).
/// Nothing is removed until Remove is pressed; the recording is never touched.
private struct LanguageLineRemovalSheet: View {
    let offer: LanguageRemovalOffer
    let onRemove: ([Int]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<Int>

    init(offer: LanguageRemovalOffer, onRemove: @escaping ([Int]) -> Void) {
        self.offer = offer
        self.onRemove = onRemove
        _selected = State(initialValue: Set(offer.lines.map(\.index)))
    }

    private var otherLanguageName: String {
        (offer.language == .english ? TranscriptLanguage.chinese : .english).displayName
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Remove Lines Not in \(offer.language.displayName)").font(.headline)
                Text("These lines read as \(otherLanguageName) — often a side-conversation the microphone picked up. Untick any you want to keep. The recording is unchanged, and Edit ▸ Undo puts removed lines back.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()

            List {
                ForEach(offer.lines) { line in
                    Toggle(isOn: Binding(
                        get: { selected.contains(line.index) },
                        set: { isOn in
                            if isOn { selected.insert(line.index) } else { selected.remove(line.index) }
                        }
                    )) {
                        HStack(alignment: .firstTextBaseline, spacing: 8) {
                            if let timestamp = line.timestamp {
                                Text(timestamp).monospacedDigit().foregroundStyle(.secondary)
                            }
                            Text(line.text)
                        }
                    }
                }
            }

            HStack {
                Button(selected.count == offer.lines.count ? "Deselect All" : "Select All") {
                    selected = selected.count == offer.lines.count ? [] : Set(offer.lines.map(\.index))
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Remove \(selected.count) Line\(selected.count == 1 ? "" : "s")", role: .destructive) {
                    onRemove(selected.sorted())
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(selected.isEmpty)
            }
            .padding()
        }
        .frame(width: 520, height: 540)
    }
}

private struct GlossarySuggestionSheet: View {
    let proposals: [GlossaryCorrection]
    /// The user's vocabulary (F245): a proposal that would rewrite one of these arrives unticked
    /// and marked, because a model's rename of a term the user taught the app must not land on
    /// one click. `GlossaryReviewDefaults` is the rule; this view only renders it.
    let protectedTerms: [String]
    let onApply: ([GlossaryCorrection]) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var selected: Set<Int>

    init(
        proposals: [GlossaryCorrection],
        protectedTerms: [String] = [],
        onApply: @escaping ([GlossaryCorrection]) -> Void
    ) {
        self.proposals = proposals
        self.protectedTerms = protectedTerms
        self.onApply = onApply
        _selected = State(initialValue: GlossaryReviewDefaults.preselected(proposals, protectedTerms: protectedTerms))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Correct toward Vocabulary").font(.headline)
                Text("Proposed spelling corrections that nudge transcript spans toward your business vocabulary. Apply the ones you want — the audio is never changed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()

            List {
                ForEach(Array(proposals.enumerated()), id: \.offset) { index, proposal in
                    Toggle(isOn: Binding(
                        get: { selected.contains(index) },
                        set: { isOn in
                            if isOn { selected.insert(index) } else { selected.remove(index) }
                        }
                    )) {
                        VStack(alignment: .leading, spacing: 2) {
                            HStack(spacing: 6) {
                                Text(proposal.from).foregroundStyle(.secondary)
                                Image(systemName: "arrow.right").font(.caption2).foregroundStyle(.tertiary)
                                Text(proposal.to).fontWeight(.medium)
                            }
                            if GlossaryReviewDefaults.touchesProtectedTerm(proposal, protectedTerms) {
                                Label("Rewrites a vocabulary term — not applied unless you tick it", systemImage: "exclamationmark.triangle")
                                    .font(.caption)
                                    .foregroundStyle(.orange)
                            }
                        }
                    }
                }
            }

            HStack {
                Button(selected.count == proposals.count ? "Deselect All" : "Select All") {
                    selected = selected.count == proposals.count ? [] : Set(proposals.indices)
                }
                Spacer()
                Button("Cancel") { dismiss() }
                Button("Apply \(selected.count) Correction\(selected.count == 1 ? "" : "s")") {
                    onApply(selected.sorted().map { proposals[$0] })
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

/// Presents a cross-engine "second opinion" comparison: where the other local engine agrees with or
/// diverges from the stored transcript. Replacing a diverging span is explicit — nothing changes the
/// transcript until the user taps Replace (F88/F73).
private struct SecondOpinionSheet: View {
    let spans: [TranscriptComparisonSpan]?
    let isRunning: Bool
    let engineName: String?
    let progress: LocalTranscriptionProgress?
    let failed: Bool
    /// Said instead of the engine-failure line when the comparison could not be made for another
    /// reason, such as a transcript with no timestamped lines (F512).
    let failureReason: String?
    let onReplace: (TranscriptComparisonSpan) -> Void
    let onCancel: () -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var replaced: Set<Int> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Second Opinion").font(.headline)
                Text("The other local engine's reading of this recording. Replace a line only where you prefer it — the audio is never changed.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding()

            if failed {
                Spacer()
                Label(failureReason ?? "The other engine couldn't run, so there's no comparison. Make sure it's installed, then try again.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary).frame(maxWidth: .infinity).padding(.horizontal)
                Spacer()
            } else if isRunning && spans == nil {
                Spacer()
                VStack(spacing: 10) {
                    let engine = engineName ?? "the other engine"
                    if let fraction = progress?.fractionCompleted, progress?.phase == .transcribing {
                        ProgressView(value: fraction) {
                            Text("Re-transcribing with \(engine)… \(Int(saturating: fraction * 100))%")
                        }
                        .frame(maxWidth: 320)
                    } else {
                        ProgressView().controlSize(.small)
                        Text(secondOpinionPhaseText(engine))
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Text("This runs a full transcription with \(engine), so it can take a while. You can keep using the app.")
                        .font(.caption).foregroundStyle(.tertiary).multilineTextAlignment(.center)
                    // F512: beside the progress it stops. Meeting transcriptions queue behind this
                    // run, so it has to be stoppable from where it is watched.
                    Button("Cancel Second Opinion") {
                        onCancel()
                        dismiss()
                    }
                    .controlSize(.small)
                }
                .padding(.horizontal, 24)
                .frame(maxWidth: .infinity)
                Spacer()
            } else if let spans, !spans.isEmpty {
                List {
                    ForEach(Array(spans.enumerated()), id: \.offset) { index, span in
                        secondOpinionRow(index: index, span: span)
                    }
                }
            } else if spans != nil {
                Spacer()
                Text("Both engines agree — no differences to show.").foregroundStyle(.secondary).frame(maxWidth: .infinity)
                Spacer()
            } else {
                Spacer()
                Text("Preparing…").foregroundStyle(.secondary).frame(maxWidth: .infinity)
                Spacer()
            }

            HStack {
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
            .padding()
        }
        .frame(width: 520, height: 560)
    }

    @ViewBuilder
    private func secondOpinionRow(index: Int, span: TranscriptComparisonSpan) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(label(span.kind)).font(.caption).foregroundStyle(color(span.kind))
                Spacer()
                if span.kind == .diverge, span.secondaryText != nil {
                    Button(replaced.contains(index) ? "Replaced" : "Replace") {
                        onReplace(span)
                        replaced.insert(index)
                    }
                    .disabled(replaced.contains(index))
                    .controlSize(.small)
                }
            }
            Text(span.primaryText)
            if let secondary = span.secondaryText, span.kind == .diverge {
                Text(secondary).foregroundStyle(.secondary)
            }
        }
        .padding(.vertical, 2)
    }

    private func secondOpinionPhaseText(_ engine: String) -> String {
        switch progress?.phase {
        case .loadingModel: return "Loading \(engine)…"
        case .downloadingModel: return "Downloading \(engine) (first use)…"
        case .transcribing: return "Re-transcribing with \(engine)…"
        default: return "Starting \(engine)…"
        }
    }

    private func label(_ kind: TranscriptComparisonSpan.Kind) -> String {
        switch kind {
        case .agree: return "Both engines agree"
        case .diverge: return "Engines differ"
        case .nonOverlapping: return "Only in this transcript"
        }
    }

    private func color(_ kind: TranscriptComparisonSpan.Kind) -> Color {
        switch kind {
        case .agree: return .secondary
        case .diverge: return .orange
        case .nonOverlapping: return .secondary
        }
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
    @Published var duration: Double?
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
                guard let self else { return }
                self.currentTime = time.seconds
                if let itemDuration = self.player.currentItem?.duration.seconds,
                   itemDuration.isFinite,
                   itemDuration > 0 {
                    self.duration = itemDuration
                }
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
    @ObservedObject var model: AppModel
    let meetingID: UUID
    let recordingURL: URL
    let segments: [TranscriptSegment]
    /// A "Play source" request from an action item card (F177): a start time to seek to, or nil.
    @Binding var seekRequest: Double?
    @StateObject private var playback: TranscriptPlaybackController
    @State private var findText = ""
    // The filtered list is cached and recomputed only when the query changes — never on the 4 Hz
    // playback tick, which only drives the active-segment highlight.
    @State private var visible: [IndexedSegment]
    @State private var followPlayback = true
    @State private var selectedSearchPosition = 0
    @State private var searchOccurrences: [TextSearchOccurrence] = []
    // Per-segment highlight ranges, computed with searchOccurrences in recomputeVisible() — only
    // when the query changes, never on the playback tick that redraws the rows (F160).
    @State private var searchRangesByIndex: [Int: [Range<String.Index>]] = [:]
    // Quality review: step through the segments Whisper was least sure about.
    @State private var reviewPosition = 0
    @State private var reviewNudge = 0
    // Marker rename.
    @State private var renamingMarker: RecordingMarker?
    @State private var renameText = ""
    // Anonymous speaker labels (F220). Every one of these is PRECOMPUTED and stored, never derived in
    // a row body: this view redraws every visible row on the 4 Hz playback tick, so a per-row overlay
    // search plus an alias lookup there is the exact regression F160 documents for the search
    // highlighter. `refreshSpeakerReview()` rebuilds them when the stored analysis actually changes.
    @State private var speakerLabelsByIndex: [Int: String] = [:]
    @State private var speakerReviewState: SpeakerReviewState = .notAnalyzed
    @State private var speakerClusterIDs: [Int] = []
    @State private var speakerAliases: [Int: String] = [:]
    // Speaker-label rename / clear / rerun.
    @State private var renamingSpeakerCluster: Int?
    @State private var speakerRenameText = ""
    @State private var confirmClearSpeakerLabels = false
    @State private var confirmAnalyzeAgain = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @Environment(\.undoManager) private var undoManager
    // Distinguishes chevron navigation (glides) from typing (snaps): recomputeVisible() leaves
    // this false; moveSearchSelection(by:) sets it just before changing the selection.
    @State private var animateNextSearchScroll = false

    // F541: the quality review runs when the lines or the edited state change. The detail view
    // above rebuilds this view on every render — each Notes keystroke, each progress update the
    // model publishes — and the review used to run in the initializer every time.
    @State private var reviewMemo = LastValueMemo<TranscriptReviewOverlay.Input, TranscriptReviewOverlay>()

    private var review: TranscriptReviewOverlay {
        reviewMemo.value(for: TranscriptReviewOverlay.Input(segments: segments, isEdited: isEdited)) {
            TranscriptReviewOverlay($0)
        }
    }
    private var qualityReport: TranscriptQualityReport { review.report }
    private var flagsByIndex: [Int: [SegmentQualityFlag]] { review.flagsByIndex }

    /// When the transcript has been edited, the segment-derived quality flags no longer describe the
    /// shown text, so they're suppressed (see MeetingStore.isTranscriptEdited).
    private let isEdited: Bool

    init(
        store: MeetingStore,
        model: AppModel,
        meetingID: UUID,
        recordingURL: URL,
        segments: [TranscriptSegment],
        isEdited: Bool = false,
        seekRequest: Binding<Double?> = .constant(nil)
    ) {
        self.store = store
        self.model = model
        self.meetingID = meetingID
        self.recordingURL = recordingURL
        self.segments = segments
        self.isEdited = isEdited
        _seekRequest = seekRequest
        _playback = StateObject(wrappedValue: TranscriptPlaybackController(url: recordingURL))
        _visible = State(initialValue: segments.enumerated().map {
            IndexedSegment(id: $0.offset, segment: $0.element)
        })
    }

    private var activeIndex: Int? {
        TranscriptPlayback.activeIndex(
            at: playback.currentTime,
            in: segments,
            recordingDuration: playback.duration
        )
    }

    private var isSearching: Bool {
        !findText.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private var selectedSearchID: Int? {
        selectedSearchOccurrence?.fieldIndex
    }

    private var selectedSearchOccurrence: TextSearchOccurrence? {
        guard isSearching, !searchOccurrences.isEmpty else { return nil }
        return searchOccurrences[min(selectedSearchPosition, searchOccurrences.count - 1)]
    }

    private func recomputeVisible() {
        // Typing must never inherit a chevron press's pending glide (a same-segment chevron step
        // can leave the flag latched because selectedSearchID does not change).
        animateNextSearchScroll = false
        let query = findText.trimmingCharacters(in: .whitespacesAndNewlines)
        // One pass builds both the occurrence list and the highlight ranges (F160); rendering
        // reads the cached ranges, so the per-segment text scan never repeats on redraw.
        let index = query.isEmpty
            ? (occurrences: [], rangesByField: [:])
            : TextSearch.occurrenceIndex(query, in: segments.map(\.text))
        searchOccurrences = index.occurrences
        searchRangesByIndex = index.rangesByField
        let matchingSegmentIDs = Set(searchOccurrences.map(\.fieldIndex))
        visible = segments.enumerated().compactMap { index, segment in
            guard query.isEmpty || matchingSegmentIDs.contains(index) else { return nil }
            return IndexedSegment(id: index, segment: segment)
        }
        selectedSearchPosition = 0
    }

    private func moveSearchSelection(by offset: Int) {
        guard !searchOccurrences.isEmpty else { return }
        animateNextSearchScroll = true
        selectedSearchPosition = (
            selectedSearchPosition + offset + searchOccurrences.count
        ) % searchOccurrences.count
    }

    private var flaggedCount: Int { qualityReport.flagged.count }

    /// The transcript index of the flagged segment currently being reviewed. Steps through the
    /// worst segments first (severity-ranked), not transcript order, so the riskiest get seen first.
    private var reviewTargetID: Int? {
        guard flaggedCount > 0 else { return nil }
        return qualityReport.flaggedBySeverity[min(reviewPosition, flaggedCount - 1)].index
    }

    /// Move to another flagged segment and scroll to it (bumping the nudge so re-selecting the same
    /// position still triggers a scroll).
    private func moveReview(by offset: Int) {
        guard flaggedCount > 0 else { return }
        // A deliberate jump owns the viewport; Follow visibly disengages (re-enable to resume).
        followPlayback = false
        reviewPosition = (reviewPosition + offset + flaggedCount) % flaggedCount
        reviewNudge += 1
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if FileManager.default.fileExists(atPath: recordingURL.path) {
                AVPlayerContainer(player: playback.player)
                    .frame(height: 44)
                    .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 10, style: .continuous)
                            .stroke(.separator, lineWidth: 1)
                    }
            } else {
                Text("Recording unavailable on this Mac.").foregroundStyle(.secondary)
            }

            markersStrip

            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("Find in transcript", text: $findText).textFieldStyle(.plain)
                if !findText.isEmpty {
                    Button { findText = "" } label: {
                        Image(systemName: "xmark.circle.fill")
                    }
                    .buttonStyle(LinkPressStyle())
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("Clear search")
                }
                if isSearching {
                    Text(searchOccurrences.isEmpty ? "0 of 0" : "\(selectedSearchPosition + 1) of \(searchOccurrences.count)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Button { moveSearchSelection(by: -1) } label: {
                        Image(systemName: "chevron.up")
                    }
                    .buttonStyle(LinkPressStyle())
                    .disabled(searchOccurrences.isEmpty)
                    .accessibilityLabel("Previous transcript match")
                    Button { moveSearchSelection(by: 1) } label: {
                        Image(systemName: "chevron.down")
                    }
                    .buttonStyle(LinkPressStyle())
                    .disabled(searchOccurrences.isEmpty)
                    .accessibilityLabel("Next transcript match")
                }
                Divider().frame(height: 16)
                Toggle(isOn: $followPlayback) {
                    Label("Follow", systemImage: "arrow.down.circle")
                }
                .toggleStyle(.button)
                .controlSize(.small)
                .help("Auto-scroll to the segment that is currently playing")
            }
            .padding(10)
            .cardSurface(cornerRadius: 10)

            if flaggedCount > 0 && !isSearching {
                qualityReviewBanner
            }

            // F220. Shown for every state except "never analyzed" — five of them end with no labels
            // on screen, and an unexplained ordinary transcript is the one outcome a person who just
            // ran an analysis cannot interpret.
            if speakerReviewState.showsReviewBanner {
                speakerReviewBanner
            }

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
                .background(.background, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .stroke(.separator, lineWidth: 1)
                }
                .onChange(of: activeIndex) { _, newValue in
                    guard followPlayback, !isSearching, let newValue else { return }
                    withAnimation(reduceMotion ? nil : .transcriptScroll) {
                        proxy.scrollTo(newValue, anchor: .center)
                    }
                }
                .onChange(of: selectedSearchID) { _, newValue in
                    guard isSearching, let newValue else { return }
                    // Typing snaps to the first match instantly; only chevron navigation glides.
                    withAnimation(animateNextSearchScroll && !reduceMotion ? .transcriptScroll : nil) {
                        proxy.scrollTo(newValue, anchor: .center)
                    }
                    animateNextSearchScroll = false
                }
                .onChange(of: reviewNudge) { _, _ in
                    guard let target = reviewTargetID else { return }
                    withAnimation(reduceMotion ? nil : .transcriptScroll) {
                        proxy.scrollTo(target, anchor: .center)
                    }
                }
            }
        }
        .onChange(of: findText) { _, _ in recomputeVisible() }
        // F423: a deleted line (or an undone deletion) arrives as new segments, and the cached rows,
        // search ranges and speaker labels are all keyed by index — rebuild them. Array equality
        // short-circuits on shared storage, so the playback tick pays nothing here.
        .onChange(of: segments) { _, _ in
            recomputeVisible()
            refreshSpeakerReview()
        }
        // F177 "Play source": seek (and start playing) from where an action item was raised, then
        // clear the request. `initial: true` also handles the case where the request was set in the
        // same tick this view (re)appeared after switching back to read mode.
        .onChange(of: seekRequest, initial: true) { _, newValue in
            guard let time = newValue else { return }
            followPlayback = false
            playback.seek(to: time)
            playback.player.play()
            seekRequest = nil
        }
        // The precomputed labels are rebuilt only when the stored analysis moves: on appearance, when
        // a run starts or stops, and when `invalidateSpeakerOverlayCache()` bumps the revision after
        // an analysis, a rename, or a clear. Never on the playback tick (F160/F220).
        .task { refreshSpeakerReview() }
        .onChange(of: model.speakerOverlayRevision) { _, _ in refreshSpeakerReview() }
        .onChange(of: model.diarizationRunningID) { _, _ in refreshSpeakerReview() }
        .alert(SpeakerAnalysisCopy.renameTitle, isPresented: Binding(
            get: { renamingSpeakerCluster != nil },
            set: { if !$0 { renamingSpeakerCluster = nil } }
        )) {
            TextField(SpeakerAnalysisCopy.renameFieldLabel, text: $speakerRenameText)
            Button(SpeakerAnalysisCopy.renameSaveButton) {
                if let clusterID = renamingSpeakerCluster {
                    model.renameSpeaker(clusterID: clusterID, to: speakerRenameText, in: meetingID)
                }
                renamingSpeakerCluster = nil
            }
            Button("Cancel", role: .cancel) { renamingSpeakerCluster = nil }
        } message: {
            Text(SpeakerAnalysisCopy.renameMessage)
        }
        // Destructive and irreversible, so it is confirmed — and the cancel verb says what keeping
        // them costs rather than leaving "Cancel" to mean two different things.
        .confirmationDialog(
            SpeakerAnalysisCopy.clearTitle,
            isPresented: $confirmClearSpeakerLabels,
            titleVisibility: .visible
        ) {
            Button(SpeakerAnalysisCopy.clearConfirmButton, role: .destructive) {
                model.clearSpeakerDiarization(for: meetingID)
            }
            Button(SpeakerAnalysisCopy.clearCancelButton, role: .cancel) {}
        } message: {
            Text(SpeakerAnalysisCopy.clearMessage)
        }
        // A rerun is not a refresh: clusters are formed afresh and typed labels are deliberately not
        // carried across, so it is confirmed with that said plainly.
        .alert(SpeakerAnalysisCopy.analyzeAgainTitle, isPresented: $confirmAnalyzeAgain) {
            Button("Cancel", role: .cancel) {}
            Button(SpeakerAnalysisCopy.analyzeAgainButton) {
                model.requestSpeakerDiarization(for: meetingID)
            }
        } message: {
            Text(SpeakerAnalysisCopy.analyzeAgainMessage)
        }
        .alert("Rename Marker", isPresented: Binding(
            get: { renamingMarker != nil },
            set: { if !$0 { renamingMarker = nil } }
        )) {
            TextField("Label", text: $renameText)
            Button("Save") {
                if let marker = renamingMarker {
                    model.renameMarker(marker.id, to: renameText, in: meetingID)
                }
                renamingMarker = nil
            }
            Button("Cancel", role: .cancel) { renamingMarker = nil }
        } message: {
            Text("Give this moment a name, or clear it to revert to a numbered marker.")
        }
    }

    private var markers: [RecordingMarker] {
        store.meeting(id: meetingID)?.orderedMarkers ?? []
    }

    @ViewBuilder
    private var markersStrip: some View {
        HStack(spacing: 8) {
            Image(systemName: "bookmark.fill")
                .foregroundStyle(.orange)
                .help("Markers you flagged during (or after) recording")
            if markers.isEmpty {
                Text("No markers")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else {
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(markers.enumerated()), id: \.element.id) { index, marker in
                            markerChip(marker, index: index)
                        }
                    }
                }
            }
            Spacer(minLength: 6)
            Button {
                model.addMarker(to: meetingID, offset: playback.currentTime)
            } label: {
                Label("Add at \(TranscriptFormatter.timestamp(playback.currentTime))", systemImage: "bookmark.badge.plus")
                    .font(.caption)
            }
            .buttonStyle(LinkPressStyle())
            .foregroundStyle(.tint)
            .help("Add a marker at the current playback position")
        }
        .padding(10)
        .cardSurface(cornerRadius: 10)
    }

    private func markerChip(_ marker: RecordingMarker, index: Int) -> some View {
        Button {
            playback.seek(to: marker.offset)
        } label: {
            Text("\(TranscriptFormatter.timestamp(marker.offset))  \(RecordingMarkers.displayLabel(for: marker, at: index + 1))")
                .font(.caption.weight(.medium))
                .lineLimit(1)
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(Color.orange.opacity(0.15), in: Capsule())
                .overlay(Capsule().strokeBorder(Color.orange.opacity(0.25), lineWidth: 1))
        }
        .buttonStyle(PressableChipStyle())
        .accessibilityLabel(AccessibilityPhrase.marker(
            label: RecordingMarkers.displayLabel(for: marker, at: index + 1),
            offset: marker.offset
        ))
        .contextMenu {
            Button("Rename…") {
                renameText = marker.label ?? ""
                renamingMarker = marker
            }
            Button("Delete", role: .destructive) {
                model.removeMarker(marker.id, from: meetingID)
            }
        }
    }

    // MARK: - Anonymous speaker labels (F220)

    /// Rebuilds everything the label column and the banner read. Called on appearance and whenever the
    /// stored analysis changes — never from a view body, because this touches the sidecar-backed
    /// overlay and the body runs on the 4 Hz playback tick (the F160 rule).
    private func refreshSpeakerReview() {
        speakerReviewState = model.speakerReviewState(for: meetingID)
        speakerLabelsByIndex = model.speakerRowLabels(for: meetingID)
        let presentation = model.speakerOverlay(for: meetingID)
        speakerClusterIDs = presentation?.clusterIDs ?? []
        speakerAliases = presentation?.aliases ?? [:]
    }

    /// Why "Analyze Again" cannot run right now, or nil. The same rule the Improve menu uses, so a
    /// missing model, a busy Mac or a read-only library is stated here in the same words instead of
    /// leaving a dead button (`SpeakerAnalysisCopy.footnote(for:)`).
    private var speakerRerunUnavailability: SpeakerAnalysisUnavailability? {
        guard let meeting = store.meeting(id: meetingID) else { return nil }
        return model.speakerAnalysisUnavailability(for: meeting)
    }

    /// The legend. One banner that renders every state the PRD names — analyzing, stale, unreadable,
    /// no turns found, only one voice, nothing confidently attributable, and labels on screen — each
    /// with its own headline and its own plain explanation, plus the actions that state allows.
    private var speakerReviewBanner: some View {
        // Resolved once per render and handed down: `speakerAnalysisUnavailability` walks the meeting
        // list, and the banner needs the same answer twice (the button's enablement and the footnote
        // that says why it is off).
        let rerunReason = speakerReviewState.offersAnalyzeAgain ? speakerRerunUnavailability : nil
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                if speakerReviewState == .analyzing {
                    ProgressView().controlSize(.small)
                } else {
                    Image(systemName: "person.wave.2").foregroundStyle(.blue)
                }
                Text(SpeakerAnalysisCopy.reviewHeadline(for: speakerReviewState))
                    .font(.callout.weight(.medium))
                    .help(SpeakerAnalysisCopy.reviewDetail(for: speakerReviewState))
                Spacer(minLength: 8)
                speakerReviewActions(rerunReason: rerunReason)
            }
            if speakerReviewState == .analyzing, let fraction = model.diarizationProgress {
                ProgressView(value: fraction)
                    .progressViewStyle(.linear)
                    .accessibilityLabel("Speaker analysis \(Int(saturating: fraction * 100)) percent complete")
            }
            if speakerReviewState == .labeled, !speakerClusterIDs.isEmpty {
                speakerLegendChips
            }
            // For a labeled result the legend notice is the longer form: it also says a label is
            // renameable and that it never leaves this meeting. Every other state gets its own
            // explanation of what happened and what survived it.
            Text(speakerReviewState == .labeled
                ? SpeakerAnalysisCopy.legendNotice
                : SpeakerAnalysisCopy.reviewDetail(for: speakerReviewState))
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // A greyed-out "Analyze Again" always says why, in the same words as the Improve menu.
            if let reason = rerunReason {
                Text(SpeakerAnalysisCopy.footnote(for: reason))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .bannerSurface(.blue)
    }

    @ViewBuilder
    private func speakerReviewActions(rerunReason: SpeakerAnalysisUnavailability?) -> some View {
        if speakerReviewState == .analyzing {
            Button(SpeakerAnalysisCopy.cancelAnalysisButton) { model.cancelSpeakerDiarization() }
                .buttonStyle(LinkPressStyle())
                .help("Stop the analysis. Nothing has been saved yet, so nothing is lost.")
        } else {
            if speakerReviewState.offersAnalyzeAgain {
                Button(SpeakerAnalysisCopy.analyzeAgainButton) { confirmAnalyzeAgain = true }
                    .buttonStyle(LinkPressStyle())
                    .disabled(rerunReason != nil)
            }
            if speakerReviewState.offersClear {
                Button(SpeakerAnalysisCopy.clearConfirmButton) { confirmClearSpeakerLabels = true }
                    .buttonStyle(LinkPressStyle())
                    .foregroundStyle(.red)
            }
        }
    }

    /// The clusters actually on screen, in first-appearance order, each one a rename target. Text —
    /// never colour alone: the chip reads its own label, so the legend still works in greyscale, at
    /// any Dynamic Type size, and under VoiceOver.
    private var speakerLegendChips: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 6) {
                ForEach(speakerClusterIDs, id: \.self) { clusterID in
                    let name = SpeakerOverlay.typedAlias(speakerAliases[clusterID])
                        ?? TranscriptExporter.anonymousSpeakerName(clusterID: clusterID)
                    Button {
                        speakerRenameText = speakerAliases[clusterID] ?? ""
                        renamingSpeakerCluster = clusterID
                    } label: {
                        Label(name, systemImage: "pencil")
                            .font(.caption.weight(.medium))
                            .lineLimit(1)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 4)
                            .background(.quaternary.opacity(0.5), in: Capsule())
                            .overlay(Capsule().strokeBorder(.separator, lineWidth: 1))
                    }
                    .buttonStyle(PressableChipStyle())
                    .help("Rename this label. It applies to this meeting only.")
                    .accessibilityLabel("\(name), inferred label")
                    .accessibilityHint("Rename this label for this meeting")
                }
            }
            .padding(.vertical, 1)
        }
    }

    /// The label column for one row. A capsule in `metadataChip`'s quiet register, and an invisible
    /// one of the same width for a row the analysis could not attribute — so the timestamps and the
    /// text below stay in a straight line instead of jumping column to column down the transcript.
    @ViewBuilder
    private func speakerLabelColumn(_ label: String?) -> some View {
        Group {
            if let label {
                Text(label)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    .padding(.horizontal, 9)
                    .padding(.vertical, 3)
                    .background(.quaternary.opacity(0.5), in: Capsule())
                    .help(label)
            } else {
                Color.clear.frame(height: 1)
            }
        }
        .frame(width: 132, alignment: .leading)
    }

    private var qualityReviewBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.bubble")
                .foregroundStyle(.orange)
            Button {
                followPlayback = false
                reviewNudge += 1
            } label: {
                Text(flaggedCount == 1
                    ? "1 segment may need a look"
                    : "\(flaggedCount) segments may need a look")
                    .font(.callout)
            }
            .buttonStyle(LinkPressStyle())
            .help("Whisper flagged these as low-confidence, likely-silence (text over near-silent audio), or repetitive, worst first. Tap to review; this never changes your transcript.")
            Text("· \(Int(saturating: qualityReport.confidence * 100))% clean")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            Text("\(min(reviewPosition, flaggedCount - 1) + 1) of \(flaggedCount)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            Button { moveReview(by: -1) } label: {
                Image(systemName: "chevron.up")
            }
            .buttonStyle(LinkPressStyle())
            .accessibilityLabel("Previous flagged segment")
            Button { moveReview(by: 1) } label: {
                Image(systemName: "chevron.down")
            }
            .buttonStyle(LinkPressStyle())
            .accessibilityLabel("Next flagged segment")
        }
        .padding(10)
        .bannerSurface(.orange)
    }

    @ViewBuilder
    private func segmentRow(index: Int, segment: TranscriptSegment) -> some View {
        let isActive = index == activeIndex
        let isSelectedMatch = index == selectedSearchID
        // Quality markers are suppressed during search, when the explaining banner is hidden.
        let flags = isSearching ? nil : flagsByIndex[index]
        let isReviewTarget = index == reviewTargetID && !isSearching
        // One dictionary read. The map was built by `refreshSpeakerReview()` when the stored analysis
        // last changed, NOT here: this body runs for every visible row on the 4 Hz playback tick.
        let speakerLabel = speakerLabelsByIndex[index]
        Button {
            if let start = segment.start { playback.seek(to: start) }
        } label: {
            HStack(alignment: .top, spacing: 10) {
                Capsule()
                    .fill(flags == nil ? Color.clear : Color.orange)
                    .frame(width: 3)
                    .frame(maxHeight: .infinity)
                    .opacity(isReviewTarget ? 1 : (flags == nil ? 0 : 0.5))
                Text(segment.start.map(TranscriptFormatter.timestamp) ?? "--:--")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(isActive ? Color.accentColor : .secondary)
                    .frame(width: 52, alignment: .leading)
                // The column appears only once an analysis has labels to show, and then it appears on
                // every row — including the unlabeled ones, which get an empty column rather than
                // none, so the text below does not shift left and right down the transcript.
                if !speakerLabelsByIndex.isEmpty {
                    speakerLabelColumn(speakerLabel)
                }
                highlightedText(segment.text, segmentIndex: index)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .multilineTextAlignment(.leading)
            }
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 6)
            .padding(.horizontal, 10)
            .background(
                isSelectedMatch
                    ? Color.accentColor.opacity(0.22)
                    : (isReviewTarget
                        ? Color.orange.opacity(0.18)
                        : (isActive ? Color.accentColor.opacity(0.15) : Color.clear)),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .contentShape(Rectangle())
            // A short fade as the playing segment moves — a color-only change, safe under
            // Reduce Motion.
            .animation(.tintShift, value: isActive)
        }
        .buttonStyle(.plain)
        .help(flags.map(qualityHelp) ?? "")
        // VoiceOver reads the row on its own, without the legend that explains what a label is. The
        // qualification has to travel with the label, so the whole row is spoken through
        // `AccessibilityPhrase.speakerLabel`, which always says "inferred" (F220).
        .modifier(SpeakerRowAccessibility(
            label: speakerLabel, offset: segment.start ?? 0, text: segment.text
        ))
        .contextMenu {
            Button("Copy Text") { copyToPasteboard(segment.text) }
            if let start = segment.start {
                Button("Copy with Timestamp") {
                    copyToPasteboard("\(TranscriptFormatter.timestamp(start))  \(segment.text)")
                }
            }
            if segment.start != nil, segment.end != nil {
                Divider()
                // F436: greyed on a hand-edited transcript, like Delete Line below and for the same
                // reason — putting the new line in rebuilds the text from the lines.
                Button("Re-transcribe this segment") {
                    model.requestSegmentReTranscription(id: meetingID, index: index)
                }
                .disabled(isEdited || model.hasActiveTranscription || model.isRunningAuxiliaryEngine)
            }
            // F423: take a line out of the transcript — a side-conversation, an aside nobody needs.
            // The recording is untouched and Edit ▸ Undo puts the line back. Disabled from values
            // this view already holds, never from `lineRemovalBlockedReason`: this menu is built per
            // row, and that call looks the meeting up in the library again for every row (F160).
            Divider()
            Button("Delete Line", role: .destructive) { deleteLine(at: index) }
                .disabled(isEdited || model.libraryReadOnlyFootnote != nil || model.hasActiveTranscription)
            // F436: why the items above are grey, in the same menu, rather than a mystery-gray row.
            if isEdited {
                Text(AppModel.editedTranscriptReason)
            }
        }
    }

    private func deleteLine(at index: Int) {
        guard let removal = model.removeTranscriptLines(at: [index], from: meetingID) else { return }
        registerLineRemovalUndo(removal, model: model, undoManager: undoManager, actionName: "Delete Line")
    }

    private func qualityHelp(_ flags: [SegmentQualityFlag]) -> String {
        flags.map(\.reason).joined(separator: "\n")
    }

    private func highlightedText(_ text: String, segmentIndex: Int) -> Text {
        // Reads the ranges cached by recomputeVisible() (F160) — no text scanning on redraw.
        guard isSearching, let ranges = searchRangesByIndex[segmentIndex] else { return Text(text) }
        var highlighted = AttributedString(text)
        for (occurrenceIndex, range) in ranges.enumerated() {
            if let attributedRange = Range(range, in: highlighted) {
                let isSelected = selectedSearchOccurrence?.fieldIndex == segmentIndex
                    && selectedSearchOccurrence?.occurrenceIndex == occurrenceIndex
                highlighted[attributedRange].backgroundColor = isSelected
                    ? Color.orange.opacity(0.65)
                    : Color.yellow.opacity(0.45)
            }
        }
        return Text(highlighted)
    }

    private func copyToPasteboard(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
    }
}

/// Speaks a transcript row as "<label>, inferred, <timestamp>, <text>" when it carries an anonymous
/// speaker label, and leaves the row's default reading alone when it does not (F220).
///
/// A modifier rather than an `if` in the row body because `.accessibilityLabel` cannot be applied
/// conditionally without branching the view type inside the `Button`'s label builder.
private struct SpeakerRowAccessibility: ViewModifier {
    let label: String?
    let offset: TimeInterval
    let text: String

    func body(content: Content) -> some View {
        if let label {
            content
                .accessibilityElement(children: .ignore)
                .accessibilityLabel(AccessibilityPhrase.speakerLabel(label, offset: offset, text: text))
        } else {
            content
        }
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


/// The persistent read-only notice (F313). Rendered above the detail column while the library is
/// degraded, and nothing else: no dismiss control, because the state it describes is only resolved
/// by a recovery, and a notice the user can hide is the F194 problem again.
struct ReadOnlyLibraryBanner: View {
    @ObservedObject var model: AppModel

    var body: some View {
        if model.libraryReadOnlyFootnote != nil {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Image(systemName: "lock.fill")
                    .foregroundStyle(.secondary)
                Text(ReadOnlyLibraryNotice.banner)
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity)
            .background(.bar)
            .accessibilityElement(children: .combine)
        }
    }
}
