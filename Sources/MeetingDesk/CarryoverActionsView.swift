import SwiftUI

struct CarryoverActionsView: View {
    let meeting: Meeting
    let meetings: [Meeting]
    let previousMeetingID: UUID?
    var previousLinks: [UUID: UUID] = [:]
    var canEdit = true
    var canNavigate = true
    let onSelectPrevious: (UUID?) -> Void
    let onOpenMeeting: (UUID) -> Void
    let onCompleteAction: (UUID, String) -> Void
    @State private var expanded = false

    private var reminder: CarryoverReminder {
        CarryoverActions.reminder(for: meeting, previousMeetingID: previousMeetingID, in: meetings, previousLinks: previousLinks)
    }
    private var candidates: [Meeting] { CarryoverActions.eligiblePreviousMeetings(for: meeting, in: meetings) }
    private var suggestion: Meeting? { CarryoverActions.suggestedPreviousMeeting(for: meeting, in: meetings) }

    var body: some View {
        let snapshot = reminder
        return VStack(alignment: .leading, spacing: 13) {
            HStack(spacing: 10) {
                Label("Önceki toplantıdan", systemImage: "arrow.triangle.branch").lineLimit(1)
                    .font(.system(size: 13, weight: .semibold))
                if snapshot.source != nil {
                    Text("\(snapshot.tasks.count) açık iş").font(.system(size: 10, weight: .medium)).fixedSize()
                        .padding(.horizontal, 7).padding(.vertical, 4)
                        .foregroundStyle(WorkspaceStyle.accent).background(WorkspaceStyle.accent.opacity(0.08), in: Capsule())
                }
                Spacer(minLength: 6)
                previousMenu
            }
            if let source = snapshot.source {
                linkedSource(source)
                if snapshot.issue == .brokenHistory {
                    Label("Bağlı geçmişin bir bölümü kullanılamıyor. Görüntülenebilen işler aşağıda korunuyor.", systemImage: "exclamationmark.triangle")
                        .font(.system(size: 11)).foregroundStyle(WorkspaceStyle.recording)
                }
                if snapshot.tasks.isEmpty {
                    Label("Bağlı toplantılarda açık iş bulunmuyor.", systemImage: "checkmark.circle")
                        .font(.system(size: 12)).foregroundStyle(WorkspaceStyle.muted)
                } else {
                    DisclosureGroup(isExpanded: $expanded) {
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 12) {
                                ForEach(snapshot.tasks) { task in taskRow(task, showOrigin: snapshot.linkedMeetingIDs.count > 1) }
                            }.padding(.top, 12).padding(.bottom, 3)
                        }.frame(height: min(280, CGFloat(snapshot.tasks.count) * 108))
                    } label: {
                        Text(snapshot.linkedMeetingIDs.count > 1 ? "Bağlı geçmişten kalan işler" : "Kalan işler")
                            .font(.system(size: 11, weight: .medium)).foregroundStyle(WorkspaceStyle.muted)
                    }
                }
            } else if snapshot.issue == .unavailableSource {
                Label("Bağlı toplantı artık kullanılamıyor. Önceki toplantıyı yeniden seç.", systemImage: "exclamationmark.triangle")
                    .font(.system(size: 12)).foregroundStyle(WorkspaceStyle.recording)
            } else if let suggestion {
                Text("Önceki görüşme önerisi: \(suggestion.title)")
                    .font(.system(size: 12)).foregroundStyle(WorkspaceStyle.muted)
                HStack {
                    Text(suggestion.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.system(size: 10)).foregroundStyle(WorkspaceStyle.muted)
                    Spacer()
                    Button("Bu toplantıyı bağla") { guard canEdit else { return }; onSelectPrevious(suggestion.id) }
                        .buttonStyle(WorkspaceQuietButtonStyle()).disabled(!canEdit)
                }
            } else {
                Text(candidates.isEmpty ? "Önceki bir toplantı kaydettiğinde kalan işleri buraya bağlayabilirsin." : "Aynı konunun önceki toplantısını bağla; kalan işleri burada takip et.")
                    .font(.system(size: 12)).foregroundStyle(WorkspaceStyle.muted)
            }
        }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
            .background(WorkspaceStyle.surface, in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(WorkspaceStyle.border))
            .foregroundStyle(WorkspaceStyle.ink)
    }

    private var previousMenu: some View {
        Menu {
            if previousMeetingID != nil {
                Button("Bağı kaldır") { guard canEdit else { return }; onSelectPrevious(nil) }
                Divider()
            }
            ForEach(candidates) { candidate in
                Button("\(candidate.title) · \(candidate.createdAt.formatted(date: .abbreviated, time: .shortened))") {
                    guard canEdit else { return }; onSelectPrevious(candidate.id)
                }
            }
        } label: {
            Label(previousMeetingID == nil ? "Toplantı seç" : "Değiştir", systemImage: "link")
                .font(.system(size: 11))
        }.menuStyle(.borderlessButton).fixedSize().disabled(!canEdit || (candidates.isEmpty && previousMeetingID == nil))
            .accessibilityLabel("Kalan işler için önceki toplantıyı seç")
    }

    private func linkedSource(_ source: Meeting) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Button { guard canNavigate else { return }; onOpenMeeting(source.id) } label: {
                Label(source.title, systemImage: "arrow.up.forward.square").font(.system(size: 12, weight: .medium))
                    .multilineTextAlignment(.leading)
            }.buttonStyle(.plain).foregroundStyle(WorkspaceStyle.accent).disabled(!canNavigate)
                .help("Önceki toplantıyı aç")
            Spacer(minLength: 4)
            Text(source.createdAt.formatted(date: .abbreviated, time: .omitted))
                .font(.system(size: 10)).foregroundStyle(WorkspaceStyle.muted)
        }
    }

    private func taskRow(_ task: CarryoverTask, showOrigin: Bool) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Button {
                guard canEdit else { return }
                onCompleteAction(task.sourceMeetingID, task.action.id)
            } label: {
                Image(systemName: "circle").font(.system(size: 17)).frame(width: 24, height: 24)
            }.buttonStyle(.plain).foregroundStyle(WorkspaceStyle.accent).disabled(!canEdit)
                .accessibilityLabel("Görevi tamamla: \(task.action.text)")
                .help("Özgün toplantıdaki görevi tamamlandı olarak işaretle")
            VStack(alignment: .leading, spacing: 7) {
                Text(task.action.text).font(.system(size: 12)).lineSpacing(3).textSelection(.enabled)
                if let owner = task.action.owner, !owner.isEmpty {
                    Label(owner, systemImage: "person").font(.system(size: 10)).foregroundStyle(WorkspaceStyle.muted)
                }
                if let due = task.action.due, !due.isEmpty {
                    Label(due, systemImage: "calendar").font(.system(size: 10)).foregroundStyle(WorkspaceStyle.muted)
                }
                if showOrigin {
                    Button(task.sourceMeetingTitle) {
                        guard canNavigate else { return }; onOpenMeeting(task.sourceMeetingID)
                    }.buttonStyle(.plain).font(.system(size: 10)).foregroundStyle(WorkspaceStyle.accent).disabled(!canNavigate)
                        .help("Görevin özgün toplantısını aç")
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }.padding(11).frame(maxWidth: .infinity, alignment: .leading)
            .background(WorkspaceStyle.canvas, in: RoundedRectangle(cornerRadius: 10))
    }
}
