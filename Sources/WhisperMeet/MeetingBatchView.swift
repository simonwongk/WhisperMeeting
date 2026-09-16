// Sources/WhisperMeet/MeetingBatchView.swift
import SwiftUI
import WhisperCore

/// The detail pane for a multi-meeting sidebar selection: what is selected, and the two actions that
/// make sense across many meetings at once. Tagging is add/remove only — never "replace the tag set" —
/// because a mixed selection has tags the user cannot see, and replacing would silently destroy them.
struct MeetingBatchView: View {
    @ObservedObject var store: MeetingStore
    let meetingIDs: [UUID]
    let onDelete: () -> Void
    @State private var draft = ""

    private var meetings: [MeetingRecord] {
        let chosen = Set(meetingIDs)
        return store.meetings.filter { chosen.contains($0.id) }
    }

    /// Every tag across the selection, with whether it is on all of them or only some.
    private var tagStates: [(tag: String, onAll: Bool)] {
        var counts: [String: Int] = [:]
        var display: [String: String] = [:]
        for meeting in meetings {
            for tag in Set((meeting.tags ?? []).map { $0.lowercased() }) {
                counts[tag, default: 0] += 1
            }
            for tag in meeting.tags ?? [] where display[tag.lowercased()] == nil {
                display[tag.lowercased()] = tag
            }
        }
        return counts.keys.sorted()
            .map { (display[$0] ?? $0, counts[$0] == meetings.count) }
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("\(meetings.count) meetings selected")
                    .font(.title2).bold()

                VStack(alignment: .leading, spacing: 4) {
                    ForEach(meetings) { meeting in
                        Text(meeting.title).font(.callout).foregroundStyle(.secondary)
                    }
                }

                Divider()

                Text("Tags").font(.headline)
                Text("Adding applies to all selected meetings. A dimmed tag is only on some of them.")
                    .font(.caption).foregroundStyle(.secondary)

                WrapLayout(spacing: 6) {
                    ForEach(tagStates, id: \.tag) { state in
                        HStack(spacing: 4) {
                            Text(state.tag)
                            Button {
                                store.removeTag(state.tag, from: meetingIDs)
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove tag \(state.tag) from all selected meetings")
                        }
                        .padding(.horizontal, 8).padding(.vertical, 3)
                        .background(.quaternary, in: Capsule())
                        .opacity(state.onAll ? 1 : 0.55)
                    }
                    TextField("Add a tag to all…", text: $draft)
                        .textFieldStyle(.plain)
                        .frame(width: 170)
                        .onSubmit {
                            let tag = draft.trimmingCharacters(in: .whitespacesAndNewlines)
                            guard !tag.isEmpty else { return }
                            store.addTag(tag, to: meetingIDs)
                            draft = ""
                        }
                }

                Divider()

                Button("Delete \(meetings.count) Meetings…", role: .destructive, action: onDelete)
            }
            .padding(24)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}
