import SwiftUI

struct NotesEditingView: View {
    @Environment(\.dismiss) private var dismiss
    @State private var draft: MeetingNotes
    @State private var saveError: String?
    private let onSave: (MeetingNotes) throws -> Void

    init(meeting: Meeting, onSave: @escaping (MeetingNotes) throws -> Void) {
        _draft = State(initialValue: meeting.notes ?? MeetingNotes(summary: "", decisions: [], actions: [], questions: [], ideas: [], topics: []))
        self.onSave = onSave
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
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Kısa özet").font(.headline)
                        editor($draft.summary, height: 120).accessibilityLabel("Kısa özet")
                    }
                    evidenceSection("Kararlar", items: $draft.decisions)
                    actionSection
                    evidenceSection("Açık sorular", items: $draft.questions)
                    evidenceSection("Fikirler ve seçenekler", items: $draft.ideas)
                    topicSection
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
            sectionHeader("Aksiyonlar") {
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
        VStack(alignment: .leading, spacing: 12) {
            sectionHeader("Konular") {
                draft.topics.append(TopicNote(id: newID(), title: "", text: "", evidence: []))
            }
            if draft.topics.isEmpty { Text("Henüz bir konu yok.").font(.caption).foregroundStyle(.secondary) }
            ForEach($draft.topics) { topic in
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
        }
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
