import SwiftUI

struct WorkItemsView: View {
    @ObservedObject var store: AppStore
    var onOpenMeeting: (UUID, String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var filter = GlobalWorkItemsFilter()
    @State private var cache = GlobalWorkItemsCache()

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Label("Tüm işler", systemImage: "checklist").font(.title2.weight(.semibold))
                    Text("Toplantılardan çıkan işleri kaynağıyla takip et.").font(.callout).foregroundStyle(WorkspaceStyle.muted)
                }
                Spacer(minLength: 8)
                Text("\(cache.snapshot.rows.count) / \(cache.snapshot.totalCount) iş").font(.caption).foregroundStyle(WorkspaceStyle.muted)
            }
            TextField("İş, sorumlu veya toplantı ara", text: $filter.search).textFieldStyle(.roundedBorder)
                .accessibilityLabel("Tüm işlerde ara")
            ViewThatFits(in: .horizontal) {
                HStack(alignment: .top, spacing: 10) { ownerFilter; projectFilter; seriesFilter; statusFilter }
                VStack(alignment: .leading, spacing: 8) {
                    HStack { ownerFilter; statusFilter }
                    HStack { projectFilter; seriesFilter }
                }
            }
            meetingDateFilter.frame(maxWidth: 320)
            if cache.snapshot.ambiguousCount > 0 {
                Label("\(cache.snapshot.ambiguousCount) işin kimliği belirsiz olduğu için listelenemiyor. Özgün toplantıyı kontrol et.", systemImage: "exclamationmark.triangle")
                    .font(.caption).foregroundStyle(WorkspaceStyle.recording)
            }
            if cache.snapshot.rows.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "checklist").font(.system(size: 34)).foregroundStyle(WorkspaceStyle.muted)
                    Text(cache.snapshot.totalCount == 0 ? "Henüz toplantı işi yok" : "Bu filtrelerde iş bulunamadı").font(.headline)
                    Text("Sorumlusu veya tarihi belirtilmeyen işler de burada görünür.").font(.callout).foregroundStyle(WorkspaceStyle.muted)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 12) {
                        ForEach(cache.snapshot.rows) { row in workItem(row) }
                    }.padding(.vertical, 2)
                }
            }
            HStack {
                Text("Teslim tarihleri toplantıda yazıldığı gibi gösterilir. Tarih filtresi ve sıralama toplantı tarihini kullanır.")
                    .font(.caption2).foregroundStyle(WorkspaceStyle.muted)
                Spacer()
                Button("Kapat") { dismiss() }.buttonStyle(WorkspaceQuietButtonStyle()).keyboardShortcut(.cancelAction)
            }
        }
        .padding(24).frame(minWidth: 580, idealWidth: 800, maxWidth: 1040, minHeight: 480, idealHeight: 700, maxHeight: 920)
        .foregroundStyle(WorkspaceStyle.ink).background(WorkspaceStyle.canvas).tint(WorkspaceStyle.accent)
        .onChange(of: store.meetings, initial: true) { _, _ in refresh() }
        .onChange(of: store.workspaceCatalog) { _, _ in refresh() }
        .onChange(of: filter) { _, _ in refresh() }
    }

    private var ownerFilter: some View {
        Picker("Sorumlu", selection: $filter.owner) {
            Text("Tüm sorumlular").tag(String?.none)
            Text("Sorumlu belirtilmedi").tag(String?.some(""))
            ForEach(cache.snapshot.owners, id: \.self) { Text($0).tag(String?.some($0)) }
        }.accessibilityLabel("İşleri sorumluya göre filtrele")
    }
    private var projectFilter: some View {
        Picker("Proje", selection: $filter.project) {
            Text("Tüm projeler").tag(WorkItemMembershipFilter.all)
            Text("Projesiz").tag(WorkItemMembershipFilter.unassigned)
            ForEach(store.workspaceCatalog.projects) { Text($0.name).tag(WorkItemMembershipFilter.id($0.id)) }
        }.accessibilityLabel("İşleri projeye göre filtrele")
    }
    private var seriesFilter: some View {
        Picker("Seri", selection: $filter.series) {
            Text("Tüm seriler").tag(WorkItemMembershipFilter.all)
            Text("Serisiz").tag(WorkItemMembershipFilter.unassigned)
            ForEach(store.workspaceCatalog.series) { Text($0.name).tag(WorkItemMembershipFilter.id($0.id)) }
        }.accessibilityLabel("İşleri seriye göre filtrele")
    }
    private var statusFilter: some View {
        Picker("Durum", selection: $filter.status) {
            ForEach(WorkItemStatus.allCases) { Text($0.label).tag($0) }
        }.accessibilityLabel("İşleri tamamlanma durumuna göre filtrele")
    }
    private var meetingDateFilter: some View {
        Picker("Toplantı tarihi", selection: $filter.meetingDate) {
            ForEach(WorkItemMeetingDateFilter.allCases) { Text($0.label).tag($0) }
        }.accessibilityLabel("İşleri kaynak toplantının tarihine göre filtrele")
    }

    private func workItem(_ row: GlobalWorkItem) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Button {
                store.setGlobalWorkItemCompletion(row, isCompleted: !row.isCompleted)
            } label: {
                Image(systemName: row.isCompleted ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 20)).frame(width: 28, height: 28)
            }.buttonStyle(.plain).foregroundStyle(WorkspaceStyle.accent).disabled(!store.canEditCarryover)
                .accessibilityLabel("\(row.action.text): \(row.isCompleted ? "yeniden aç" : "tamamlandı işaretle")")
            VStack(alignment: .leading, spacing: 8) {
                Text(row.action.text).font(.callout).strikethrough(row.isCompleted).textSelection(.enabled)
                ViewThatFits(in: .horizontal) {
                    HStack(spacing: 14) { ownerLabel(row); dueLabel(row) }
                    VStack(alignment: .leading, spacing: 5) { ownerLabel(row); dueLabel(row) }
                }
                if row.projectName != nil || row.seriesName != nil {
                    Text([row.projectName, row.seriesName].compactMap { $0 }.joined(separator: " · "))
                        .font(.caption).foregroundStyle(WorkspaceStyle.muted)
                }
                HStack(alignment: .firstTextBaseline) {
                    Button(row.meetingTitle) { onOpenMeeting(row.meetingID, nil) }
                        .buttonStyle(.plain).foregroundStyle(WorkspaceStyle.accent).disabled(store.workInProgress)
                        .accessibilityLabel("\(row.meetingTitle) toplantısını aç")
                    Spacer(minLength: 6)
                    Text(row.meetingDate.formatted(date: .abbreviated, time: .omitted)).foregroundStyle(WorkspaceStyle.muted)
                    if !row.sources.isEmpty {
                        Menu {
                            ForEach(row.sources) { source in
                                Button("Kaynak · \(timeLabel(source.time))") { onOpenMeeting(row.meetingID, source.id) }
                            }
                        } label: { Label("Kaynak", systemImage: "text.quote") }
                        .menuStyle(.borderlessButton).fixedSize().disabled(store.workInProgress)
                        .accessibilityLabel("İşin transkript kaynaklarını aç")
                    }
                }.font(.caption)
                if row.notesNeedRefresh {
                    Text("Bu toplantının özeti güncellenmeyi bekliyor.").font(.caption2).foregroundStyle(WorkspaceStyle.recording)
                }
            }.frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(16).background(WorkspaceStyle.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(WorkspaceStyle.border))
    }

    private func ownerLabel(_ row: GlobalWorkItem) -> some View {
        Label(row.owner.isEmpty ? "Sorumlu belirtilmedi" : row.owner, systemImage: "person").font(.caption).foregroundStyle(WorkspaceStyle.muted)
    }
    private func dueLabel(_ row: GlobalWorkItem) -> some View {
        Label(row.due.isEmpty ? "Tarih belirtilmedi" : row.due, systemImage: "calendar").font(.caption).foregroundStyle(WorkspaceStyle.muted)
    }
    private func refresh() { cache.refresh(meetings: store.meetings, catalog: store.workspaceCatalog, filter: filter) }
}
