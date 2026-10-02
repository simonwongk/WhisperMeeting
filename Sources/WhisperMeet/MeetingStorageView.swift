import SwiftUI
import WhisperCore

/// Every meeting by the space it uses, largest first, with Shrink per row and for a selection (F795).
/// Presentation only: every decision is `AppModel`'s.
struct MeetingStorageView: View {
    @ObservedObject var model: AppModel
    @ObservedObject var store: MeetingStore
    @Environment(\.dismiss) private var dismiss
    @State private var selection: Set<UUID> = []

    private var rows: [MeetingRecord] {
        store.meetings.sorted { (model.storageBytes(for: $0.id) ?? -1) > (model.storageBytes(for: $1.id) ?? -1) }
    }

    private func size(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Meeting storage").font(.title2.bold())
            Text("Meetings use \(size(model.measuredLibraryBytes)).")
                .foregroundStyle(.secondary)
            List(rows, id: \.id, selection: $selection) { meeting in
                let reason = model.shrinkUnavailability(for: meeting)
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(meeting.title)
                        if let reason, reason != .alreadyShrunk {
                            Text(reason.message).font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                    Text(meeting.createdAt.formatted(date: .abbreviated, time: .omitted))
                        .foregroundStyle(.secondary)
                    Text(model.storageBytes(for: meeting.id).map(size) ?? "Measuring…")
                        .monospacedDigit()
                        .frame(minWidth: 80, alignment: .trailing)
                    Button(reason == .alreadyShrunk ? "Shrunk" : "Shrink…") {
                        model.requestShrink(ids: [meeting.id])
                    }
                    .disabled(reason != nil || model.storageBytes(for: meeting.id) == nil)
                }
            }
            .frame(minWidth: 640, minHeight: 360)
            if let outcome = model.alertMessage, model.shrinkRunningID == nil, !outcome.isEmpty {
                // The window's alert may sit behind this sheet, so the outcome is said here too.
                Text(outcome).font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
            }
            HStack {
                Button("Shrink Selected…") { model.requestShrink(ids: Array(selection)) }
                    .disabled(selection.isEmpty || model.shrinkRunningID != nil)
                if model.shrinkRunningID != nil {
                    ProgressView().controlSize(.small)
                    Text("Shrinking…").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .task { await model.refreshStorage(ids: store.meetings.map(\.id)) }
        .onAppear { model.isStorageSheetOpen = true }
        .onDisappear { model.isStorageSheetOpen = false }
        .confirmationDialog(
            model.pendingShrink.map(AppModel.shrinkConfirmationTitle) ?? "",
            isPresented: .init(get: { model.pendingShrink != nil }, set: { if !$0 { model.cancelShrink() } }),
            titleVisibility: .visible
        ) {
            Button("Shrink", role: .destructive) { model.performShrink(confirmed: true) }
            Button("Cancel", role: .cancel) { model.cancelShrink() }
        } message: {
            if let request = model.pendingShrink { Text(AppModel.shrinkConfirmationMessage(request)) }
        }
    }
}
