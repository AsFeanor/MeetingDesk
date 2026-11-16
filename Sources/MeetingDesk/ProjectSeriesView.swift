import SwiftUI

private enum OrganizationKind: String, CaseIterable, Identifiable {
    case project, series
    var id: String { rawValue }
    var label: String { self == .project ? "Projeler" : "Toplantı serileri" }
}

private struct OrganizationEditor: Identifiable {
    let id = UUID()
    let kind: OrganizationKind
    var entityID: UUID?
    var name = ""
    var projectID: UUID?
}

struct ProjectSeriesView: View {
    @ObservedObject var store: AppStore
    var onOpenMeeting: (UUID, String?) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var kind = OrganizationKind.project
    @State private var projectID: UUID?
    @State private var seriesID: UUID?
    @State private var editor: OrganizationEditor?
    @State private var meetingQuery = ""
    @State private var showAssignments = false
    @State private var associatedMeetings: [Meeting] = []
    @State private var assignmentMeetings: [Meeting] = []

    init(store: AppStore, initialProjectID: UUID? = nil, initialSeriesID: UUID? = nil,
         onOpenMeeting: @escaping (UUID, String?) -> Void) {
        self.store = store
        self.onOpenMeeting = onOpenMeeting
        _projectID = State(initialValue: initialProjectID)
        _seriesID = State(initialValue: initialSeriesID)
        _kind = State(initialValue: initialSeriesID == nil ? .project : .series)
    }

    private var selectedID: UUID? { kind == .project ? projectID : seriesID }
    private var selectedName: String? {
        kind == .project ? store.workspaceCatalog.projects.first { $0.id == projectID }?.name : store.workspaceCatalog.series.first { $0.id == seriesID }?.name
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Label("Projeler ve seriler", systemImage: "folder").font(.title2.weight(.semibold))
                    Text("Toplantılarını kendin grupla; kararları ve kalan işleri geçmişiyle gör.")
                        .font(.callout).foregroundStyle(WorkspaceStyle.muted)
                }
                Spacer(minLength: 8)
                Button("Kapat") { dismiss() }.buttonStyle(WorkspaceQuietButtonStyle()).keyboardShortcut(.cancelAction)
            }
            Picker("Görünüm", selection: $kind) {
                ForEach(OrganizationKind.allCases) { Text($0.label).tag($0) }
            }.pickerStyle(.segmented).frame(maxWidth: 390).accessibilityLabel("Proje veya toplantı serisi görünümü")
            HStack(spacing: 10) {
                if kind == .project {
                    Picker("Proje", selection: $projectID) {
                        Text("Proje seç").tag(UUID?.none)
                        ForEach(store.workspaceCatalog.projects) { Text($0.name).tag(UUID?.some($0.id)) }
                    }
                } else {
                    Picker("Seri", selection: $seriesID) {
                        Text("Seri seç").tag(UUID?.none)
                        ForEach(store.workspaceCatalog.series) { Text($0.name).tag(UUID?.some($0.id)) }
                    }
                }
                Button(kind == .project ? "Yeni proje" : "Yeni seri") {
                    editor = OrganizationEditor(kind: kind, projectID: projectID)
                }.buttonStyle(WorkspacePrimaryButtonStyle()).disabled(store.workInProgress)
                if let id = selectedID, let name = selectedName {
                    Menu {
                        Button("Adını değiştir") { editor = OrganizationEditor(kind: kind, entityID: id, name: name) }
                        Button("Sil", role: .destructive) {
                            let deleted = kind == .project ? store.deleteProject(id: id) : store.deleteSeries(id: id)
                            if deleted { if kind == .project { projectID = nil } else { seriesID = nil } }
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                    .menuStyle(.borderlessButton).fixedSize().disabled(store.workInProgress)
                    .accessibilityLabel("\(name) seçenekleri")
                }
            }
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 16) {
                    if let name = selectedName {
                        selectedHeader(name)
                        if associatedMeetings.isEmpty {
                            Text("Bu gruba henüz toplantı bağlanmadı.").font(.callout).foregroundStyle(WorkspaceStyle.muted).padding(.vertical, 12)
                        } else {
                            if associatedMeetings.count >= 2 { recentComparison }
                            ForEach(associatedMeetings) { meeting in history(meeting) }
                        }
                    } else {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Bir proje veya seri seç").font(.headline)
                            Text("Yeni bir grup oluşturabilir, ardından aşağıdan toplantılarını bağlayabilirsin. Gruplar yalnızca sen seçim yaptığında kaydedilir.")
                                .font(.callout).foregroundStyle(WorkspaceStyle.muted)
                        }.padding(.vertical, 14)
                    }
                    Divider()
                    DisclosureGroup("Toplantıların proje ve seri bağlarını düzenle", isExpanded: $showAssignments) {
                        VStack(alignment: .leading, spacing: 12) {
                            TextField("Toplantı başlığında ara", text: $meetingQuery).textFieldStyle(.roundedBorder)
                                .accessibilityLabel("Bağlanacak toplantıyı ara")
                            if assignmentMeetings.isEmpty {
                                Text("Toplantı bulunamadı.").font(.callout).foregroundStyle(WorkspaceStyle.muted)
                            }
                            ForEach(assignmentMeetings) { meeting in
                                MeetingOrganizationAssignmentView(store: store, meeting: meeting)
                            }
                        }.padding(.top, 12)
                    }.font(.callout)
                }.padding(.vertical, 2)
            }
        }
        .padding(24).frame(minWidth: 580, idealWidth: 820, maxWidth: 1040, minHeight: 480, idealHeight: 720, maxHeight: 940)
        .foregroundStyle(WorkspaceStyle.ink).background(WorkspaceStyle.canvas).tint(WorkspaceStyle.accent)
        .sheet(item: $editor) { value in
            OrganizationEditorView(store: store, editor: value) { id in
                if value.kind == .project { projectID = id } else { seriesID = id }
            }
        }
        .onAppear { store.loadWorkspaceCatalog(); refresh() }
        .onChange(of: store.meetings) { _, _ in refresh() }
        .onChange(of: store.workspaceCatalog) { _, _ in refresh() }
        .onChange(of: kind) { _, _ in refresh() }
        .onChange(of: projectID) { _, _ in refresh() }
        .onChange(of: seriesID) { _, _ in refresh() }
        .onChange(of: meetingQuery) { _, _ in refresh() }
    }

    private var recentComparison: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Son iki görüşme", systemImage: "rectangle.split.2x1").font(.headline)
            HStack(alignment: .top, spacing: 18) {
                comparisonColumn("Son görüşme", meeting: associatedMeetings[0])
                Divider()
                comparisonColumn("Önceki görüşme", meeting: associatedMeetings[1])
            }
        }.padding(16).background(WorkspaceStyle.surface, in: RoundedRectangle(cornerRadius: 12))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(WorkspaceStyle.border))
    }
    private func comparisonColumn(_ title: String, meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title.uppercased()).font(.system(size: 9, weight: .semibold)).tracking(0.8).foregroundStyle(WorkspaceStyle.muted)
            Button(meeting.title) { onOpenMeeting(meeting.id, nil) }
                .font(.system(size: 12, weight: .semibold)).buttonStyle(.plain).foregroundStyle(WorkspaceStyle.accent)
                .disabled(store.workInProgress)
            Text(meeting.createdAt.formatted(date: .abbreviated, time: .omitted)).font(.caption).foregroundStyle(WorkspaceStyle.muted)
            if let notes = meeting.notes {
                Text(notes.summary).font(.system(size: 11)).lineLimit(3)
                Text("\(notes.decisions.count) karar · \(notes.actions.filter { !meeting.completedActions.contains($0.id) }.count) açık iş")
                    .font(.system(size: 10)).foregroundStyle(WorkspaceStyle.muted)
                if meeting.notesNeedRefresh {
                    Label("Özetin yenilenmesi gerekiyor", systemImage: "arrow.clockwise").font(.caption2).foregroundStyle(WorkspaceStyle.recording)
                }
            } else { Text("Henüz özet oluşturulmadı.").font(.caption).foregroundStyle(WorkspaceStyle.muted) }
        }.frame(maxWidth: .infinity, alignment: .leading)
    }

    private func selectedHeader(_ name: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(name).font(.title3.weight(.semibold)).textSelection(.enabled)
            Text("\(associatedMeetings.count) toplantı · \(associatedMeetings.reduce(0) { $0 + ($1.notes?.decisions.count ?? 0) }) karar · \(associatedMeetings.reduce(0) { count, meeting in count + (meeting.notes?.actions.filter { !meeting.completedActions.contains($0.id) }.count ?? 0) }) açık iş")
                .font(.caption).foregroundStyle(WorkspaceStyle.muted)
            if kind == .series, let parent = store.workspaceCatalog.series.first(where: { $0.id == seriesID })?.projectID,
               let project = store.workspaceCatalog.projects.first(where: { $0.id == parent }) {
                Label(project.name, systemImage: "folder").font(.caption).foregroundStyle(WorkspaceStyle.muted)
            }
        }
    }

    private func history(_ meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 4) {
                    Button(meeting.title) { onOpenMeeting(meeting.id, nil) }
                        .buttonStyle(.plain).font(.headline).foregroundStyle(WorkspaceStyle.accent).disabled(store.workInProgress)
                    Text(meeting.createdAt.formatted(date: .abbreviated, time: .shortened))
                        .font(.caption).foregroundStyle(WorkspaceStyle.muted)
                }
                Spacer(minLength: 6)
            }
            if let notes = meeting.notes {
                if !notes.summary.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text(notes.summary).font(.callout).lineLimit(5).textSelection(.enabled)
                }
                if !notes.decisions.isEmpty {
                    Text("Kararlar").font(.caption.weight(.semibold)).foregroundStyle(WorkspaceStyle.muted)
                    ForEach(Array(notes.decisions.enumerated()), id: \.offset) { _, decision in
                        evidenceRow(text: decision.text, evidence: decision.evidence, meeting: meeting, symbol: "diamond")
                    }
                }
                let open = notes.actions.filter { !meeting.completedActions.contains($0.id) }
                if !open.isEmpty {
                    Text("Açık işler").font(.caption.weight(.semibold)).foregroundStyle(WorkspaceStyle.muted)
                    ForEach(Array(open.enumerated()), id: \.offset) { _, action in
                        evidenceRow(text: action.text, evidence: action.evidence, meeting: meeting, symbol: "circle")
                    }
                }
                if meeting.notesNeedRefresh {
                    Text("Bu toplantının özeti güncellenmeyi bekliyor.").font(.caption2).foregroundStyle(WorkspaceStyle.recording)
                }
            } else {
                Text("Bu toplantı için henüz özet yok.").font(.callout).foregroundStyle(WorkspaceStyle.muted)
            }
        }
        .padding(16).frame(maxWidth: .infinity, alignment: .leading)
        .background(WorkspaceStyle.surface, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(WorkspaceStyle.border))
    }

    private func evidenceRow(text: String, evidence: [String], meeting: Meeting, symbol: String) -> some View {
        HStack(alignment: .top, spacing: 9) {
            Image(systemName: symbol).font(.caption).foregroundStyle(WorkspaceStyle.accent).padding(.top, 3)
            Text(text).font(.callout).textSelection(.enabled).frame(maxWidth: .infinity, alignment: .leading)
            if let source = evidence.first(where: { id in meeting.segments.filter { $0.id == id }.count == 1 }) {
                Button { onOpenMeeting(meeting.id, source) } label: { Image(systemName: "text.quote") }
                    .buttonStyle(.plain).foregroundStyle(WorkspaceStyle.accent).disabled(store.workInProgress)
                    .accessibilityLabel("\(text) için transkript kaynağını aç")
            }
        }
    }

    private func refresh() {
        let unique = Dictionary(grouping: store.meetings, by: \.id).values.compactMap { $0.count == 1 ? $0[0] : nil }
        associatedMeetings = selectedID.map { id in unique.filter { kind == .project ? $0.projectID == id : $0.seriesID == id }.sorted(by: GlobalWorkItems.meetingOrder) } ?? []
        let query = meetingQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        assignmentMeetings = unique.filter { query.isEmpty || $0.title.range(of: query, options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "tr_TR")) != nil }
            .sorted(by: GlobalWorkItems.meetingOrder)
    }
}

struct MeetingOrganizationAssignmentView: View {
    @ObservedObject var store: AppStore
    let meeting: Meeting
    @State private var projectID: UUID?
    @State private var seriesID: UUID?

    init(store: AppStore, meeting: Meeting) {
        self.store = store; self.meeting = meeting
        _projectID = State(initialValue: meeting.projectID); _seriesID = State(initialValue: meeting.seriesID)
    }

    private var eligibleSeries: [MeetingSeries] { store.workspaceCatalog.series.filter { $0.projectID == nil || $0.projectID == projectID } }
    private var changed: Bool { projectID != meeting.projectID || seriesID != meeting.seriesID }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(meeting.title).font(.callout.weight(.medium)).lineLimit(2)
            Text(meeting.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption2).foregroundStyle(WorkspaceStyle.muted)
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 10) { projectPicker; seriesPicker; saveButton }
                VStack(alignment: .leading, spacing: 8) { projectPicker; seriesPicker; saveButton }
            }
        }
        .padding(12).background(WorkspaceStyle.surface, in: RoundedRectangle(cornerRadius: 10))
        .onChange(of: projectID) { _, _ in
            if let id = seriesID, !eligibleSeries.contains(where: { $0.id == id }) { seriesID = nil }
        }
        .onChange(of: meeting.projectID) { _, value in projectID = value }
        .onChange(of: meeting.seriesID) { _, value in seriesID = value }
    }

    private var projectPicker: some View {
        Picker("Proje", selection: $projectID) {
            Text("Proje yok").tag(UUID?.none)
            if let id = projectID, !store.workspaceCatalog.projects.contains(where: { $0.id == id }) {
                Text("Kullanılamayan proje").tag(UUID?.some(id))
            }
            ForEach(store.workspaceCatalog.projects) { Text($0.name).tag(UUID?.some($0.id)) }
        }.disabled(store.workInProgress).accessibilityLabel("\(meeting.title) için proje")
    }
    private var seriesPicker: some View {
        Picker("Seri", selection: $seriesID) {
            Text("Seri yok").tag(UUID?.none)
            if let id = seriesID, !eligibleSeries.contains(where: { $0.id == id }) {
                Text("Kullanılamayan seri").tag(UUID?.some(id))
            }
            ForEach(eligibleSeries) { Text($0.name).tag(UUID?.some($0.id)) }
        }.disabled(store.workInProgress).accessibilityLabel("\(meeting.title) için toplantı serisi")
    }
    private var saveButton: some View {
        Button("Bağları kaydet") {
            store.assignMeeting(meeting.id, projectID: projectID, seriesID: seriesID,
                expectedMembership: MeetingOrganizationMembership(meeting: meeting))
        }
            .buttonStyle(WorkspaceQuietButtonStyle()).disabled(store.workInProgress || !changed)
    }
}

private struct OrganizationEditorView: View {
    @ObservedObject var store: AppStore
    let editor: OrganizationEditor
    let onSaved: (UUID) -> Void
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var projectID: UUID?
    @State private var error: String?

    init(store: AppStore, editor: OrganizationEditor, onSaved: @escaping (UUID) -> Void) {
        self.store = store; self.editor = editor; self.onSaved = onSaved
        _name = State(initialValue: editor.name); _projectID = State(initialValue: editor.projectID)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(editor.entityID == nil ? (editor.kind == .project ? "Yeni proje" : "Yeni toplantı serisi") : "Adını değiştir")
                .font(.title2.weight(.semibold))
            TextField("Ad", text: $name).textFieldStyle(.roundedBorder).onSubmit(save).accessibilityLabel("Proje veya seri adı")
                .disabled(store.workInProgress)
            if editor.kind == .series, editor.entityID == nil {
                Picker("Proje", selection: $projectID) {
                    Text("Proje yok").tag(UUID?.none)
                    ForEach(store.workspaceCatalog.projects) { Text($0.name).tag(UUID?.some($0.id)) }
                }.disabled(store.workInProgress)
            }
            if let error { Text(error).font(.caption).foregroundStyle(WorkspaceStyle.recording) }
            HStack {
                Spacer()
                Button("Vazgeç") { dismiss() }.buttonStyle(WorkspaceQuietButtonStyle()).keyboardShortcut(.cancelAction)
                Button("Kaydet", action: save).buttonStyle(WorkspacePrimaryButtonStyle()).keyboardShortcut(.defaultAction)
                    .disabled(store.workInProgress || (try? WorkspaceCatalog.cleanName(name)) == nil)
            }
        }
        .padding(24).frame(minWidth: 380, idealWidth: 460, maxWidth: 620)
        .foregroundStyle(WorkspaceStyle.ink).background(WorkspaceStyle.canvas).tint(WorkspaceStyle.accent)
    }

    private func save() {
        guard !store.workInProgress else { return }
        let id: UUID?
        if let existing = editor.entityID {
            let success = editor.kind == .project ? store.renameProject(id: existing, name: name) : store.renameSeries(id: existing, name: name)
            id = success ? existing : nil
        } else {
            id = editor.kind == .project ? store.createProject(name: name) : store.createSeries(name: name, projectID: projectID)
        }
        if let id { onSaved(id); dismiss() }
        else { error = store.errorMessage ?? "Kaydedilemedi. Tekrar dene." }
    }
}
