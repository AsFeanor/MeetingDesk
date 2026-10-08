import SwiftUI

struct NotesEditingView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: MeetingNotes
    @State private var saveError: String?
    private let onSave: (MeetingNotes) throws -> Void
    private let template: MeetingTemplate
    private let english: Bool

    init(meeting: Meeting, onSave: @escaping (MeetingNotes) throws -> Void) {
        _draft = State(initialValue: meeting.notes ?? MeetingNotes(summary: "", decisions: [], actions: [], questions: [], ideas: [], topics: []))
        self.onSave = onSave
        template = MeetingTemplate(rawValue: meeting.notesTemplateRawValue ?? "") ?? .general
        english = meeting.outputLanguage == "English"
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 8) {
                Text("Toplantı notunu düzenle").font(.title2.weight(.semibold))
                Text("Kaydettiğin düzeltmeler özeti yenilediğinde korunur. Kaynak konuşmalar düzenlenmez. Sorumlu ve tarih bilinmiyorsa boş bırak.")
                    .font(.callout).foregroundStyle(.secondary)
            }.padding(24)
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    Text("Not düzeni: \(template.label)").font(.caption).foregroundStyle(.secondary)
                    ForEach(template.sectionOrder, id: \.rawValue) { kind in
                        editorSection(kind)
                    }
                }.padding(24)
            }
            Divider()
            HStack {
                if let saveError { Text(saveError).font(.callout).foregroundStyle(.red).fixedSize(horizontal: false, vertical: true) }
                Spacer()
                Button("Vazgeç") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Kaydet") { save() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
            }.padding(20)
        }.frame(minWidth: 620, idealWidth: 720, minHeight: 580, idealHeight: 760)
    }

    @ViewBuilder
    private func editorSection(_ kind: MeetingNotesSectionKind) -> some View {
        switch kind {
        case .summary:
            VStack(alignment: .leading, spacing: 8) {
                Text(template.summaryTitle(english: english)).font(.headline)
                editor($draft.summary, height: 120).accessibilityLabel(template.summaryTitle(english: english))
            }
        case .decisions: evidenceSection(template.decisionsTitle(english: english), items: $draft.decisions)
        case .actions: actionSection
        case .questions: evidenceSection(template.questionsTitle(english: english), items: $draft.questions)
        case .ideas: evidenceSection(template.ideasTitle(english: english), items: $draft.ideas)
        case .contexts: topicSection
        }
    }

    private func evidenceSection(_ title: String, items: Binding<[EvidenceItem]>) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(title) {
                items.wrappedValue.append(EvidenceItem(id: newID(), text: "", evidence: []))
            }
            if items.wrappedValue.isEmpty { Text("Henüz bir not yok.").font(.caption).foregroundStyle(.secondary) }
            ForEach(items) { item in
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        sourceLabel(item.wrappedValue.evidence)
                        Spacer()
                        removeButton { items.wrappedValue.removeAll { $0.id == item.wrappedValue.id } }
                    }
                    editor(item.text, height: 70).accessibilityLabel(title)
                }.padding(12).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private var actionSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader(template.actionsTitle(english: english)) {
                draft.actions.append(ActionItem(id: newID(), text: "", owner: nil, due: nil, evidence: []))
            }
            if draft.actions.isEmpty { Text("Henüz bir aksiyon yok.").font(.caption).foregroundStyle(.secondary) }
            ForEach($draft.actions) { action in
                VStack(alignment: .leading, spacing: 10) {
                    HStack {
                        sourceLabel(action.wrappedValue.evidence)
                        Spacer()
                        removeButton { draft.actions.removeAll { $0.id == action.wrappedValue.id } }
                    }
                    editor(action.text, height: 70).accessibilityLabel("Aksiyon açıklaması")
                    HStack(alignment: .top, spacing: 16) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Sorumlu").font(.caption).foregroundStyle(.secondary)
                            TextField("Belirtilmedi", text: optionalBinding(action.owner)).textFieldStyle(.roundedBorder)
                        }
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Tarih · söylendiği biçimiyle").font(.caption).foregroundStyle(.secondary)
                            TextField("Belirtilmedi", text: optionalBinding(action.due)).textFieldStyle(.roundedBorder)
                        }
                    }
                }.padding(12).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private var topicSection: some View {
        let groups = MeetingNotesPresentation.sections(notes: draft, template: template, english: english)
            .filter { $0.kind == .contexts }
        return VStack(alignment: .leading, spacing: 24) {
            ForEach(groups) { group in
                VStack(alignment: .leading, spacing: 12) {
                    if group.id == "context-other" {
                        sectionHeader(group.title) { appendManualTopic() }
                    } else {
                        Text(group.title).font(.headline)
                    }
                    if let message = group.emptyMessage {
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    }
                    ForEach(group.topics) { topic in
                        topicEditor(binding(for: topic))
                    }
                }
            }
            if !groups.contains(where: { $0.id == "context-other" }) {
                VStack(alignment: .leading, spacing: 12) {
                    sectionHeader(english ? "Other discussion" : "Diğer konular") { appendManualTopic() }
                    Text("Henüz elle eklenen bir konu yok.").font(.caption).foregroundStyle(.secondary)
                }
            }
        }
    }

    private func appendManualTopic() {
        draft.topics.append(TopicNote(id: newID(), title: "", text: "", evidence: []))
    }

    private func binding(for topic: TopicNote) -> Binding<TopicNote> {
        Binding(get: { draft.topics.first(where: { $0.id == topic.id }) ?? topic }, set: { value in
            if let index = draft.topics.firstIndex(where: { $0.id == topic.id }) { draft.topics[index] = value }
        })
    }

    private func topicEditor(_ topic: Binding<TopicNote>) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                sourceLabel(topic.wrappedValue.evidence)
                Spacer()
                removeButton { draft.topics.removeAll { $0.id == topic.wrappedValue.id } }
            }
            TextField("Konu başlığı", text: topic.title).textFieldStyle(.roundedBorder)
            editor(topic.text, height: 80).accessibilityLabel("Konu açıklaması")
        }.padding(12).background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 10))
    }

    private func sectionHeader(_ title: String, add: @escaping () -> Void) -> some View {
        HStack {
            Text(title).font(.headline)
            Spacer()
            Button(action: add) { Label("Ekle", systemImage: "plus") }.font(.caption)
                .accessibilityLabel("\(title): not ekle")
        }
    }

    private func editor(_ text: Binding<String>, height: CGFloat) -> some View {
        TextEditor(text: text).font(.body).frame(minHeight: height)
            .padding(6).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.secondary.opacity(0.2)))
    }

    private func sourceLabel(_ evidence: [String]) -> some View {
        Label(evidence.isEmpty ? "Elle eklenen not · kaynak bağlantısı yok" : "\(evidence.count) kaynak bağlantısı korunur",
              systemImage: evidence.isEmpty ? "pencil" : "link")
            .font(.caption2).foregroundStyle(.secondary)
    }

    private func removeButton(action: @escaping () -> Void) -> some View {
        Button(action: action) { Image(systemName: "trash") }.buttonStyle(.borderless)
            .help("Notu kaldır").accessibilityLabel("Notu kaldır")
    }

    private func optionalBinding(_ value: Binding<String?>) -> Binding<String> {
        Binding(get: { value.wrappedValue ?? "" }, set: { value.wrappedValue = $0.isEmpty ? nil : $0 })
    }

    private func newID() -> String { "manual-\(UUID().uuidString)" }

    private func save() {
        let requiredText = [draft.summary] + (draft.decisions + draft.questions + draft.ideas).map(\.text)
            + draft.actions.map(\.text) + draft.topics.flatMap { [$0.title, $0.text] }
        guard requiredText.allSatisfy({ !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }) else {
            saveError = "Boş notları doldur veya kaldır; kısa özet ve konu başlığı boş olamaz."
            return
        }
        do {
            try onSave(draft)
            dismiss()
        } catch {
            saveError = error.localizedDescription
        }
    }
}
