import SwiftUI

struct GlossaryView: View {
    @ObservedObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var editing: GlossaryEntry?
    @State private var deleting: GlossaryEntry?
    @State private var query = ""

    private var filtered: [GlossaryEntry] {
        let key = GlossaryValidation.key(query.trimmingCharacters(in: .whitespacesAndNewlines))
        return store.glossaryEntries.filter { entry in
            key.isEmpty || ([entry.canonical] + entry.variants).contains { GlossaryValidation.key($0).contains(key) }
        }.sorted { $0.canonical.localizedStandardCompare($1.canonical) == .orderedAscending }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 5) {
                    Label("Kişisel sözlük", systemImage: "character.book.closed").font(.title2.weight(.semibold))
                    Text("İsim, ürün ve terimlerin doğru yazımlarını bu Mac’te sakla. Transkriptte her öneriyi ayrı ayrı onaylarsın.")
                        .font(.callout).foregroundStyle(.secondary)
                }
                Spacer()
                Button("Terim ekle", systemImage: "plus") { editing = GlossaryEntry(canonical: "", variants: []) }
                    .disabled(store.workInProgress)
            }
            TextField("Doğru veya duyulan yazımı ara", text: $query).textFieldStyle(.roundedBorder)
            if store.glossaryEntries.isEmpty {
                VStack(spacing: 10) {
                    Image(systemName: "character.book.closed").font(.system(size: 36)).foregroundStyle(.secondary)
                    Text("Henüz terim eklenmedi").font(.headline)
                    Text("Örneğin doğru yazım “Lifesycle”, duyulan yazım “life cycle” olabilir.")
                        .font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
                    Button("İlk terimi ekle") { editing = GlossaryEntry(canonical: "", variants: []) }.disabled(store.workInProgress)
                }.frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if filtered.isEmpty {
                Text("Bu yazımla eşleşen terim yok.").foregroundStyle(.secondary).frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 10) {
                        ForEach(filtered) { entry in
                            HStack(alignment: .top, spacing: 12) {
                                VStack(alignment: .leading, spacing: 5) {
                                    Text(entry.canonical).font(.headline).textSelection(.enabled)
                                    Text("Duyulan yazımlar: \(entry.variants.joined(separator: " · "))")
                                        .font(.callout).foregroundStyle(.secondary).textSelection(.enabled)
                                }
                                Spacer()
                                Button("Düzenle") { editing = entry }.disabled(store.workInProgress)
                                Button("Sil", role: .destructive) { deleting = entry }.disabled(store.workInProgress)
                            }
                            .padding(14).frame(maxWidth: .infinity, alignment: .leading)
                            .background(WorkspaceStyle.surface, in: RoundedRectangle(cornerRadius: 10))
                        }
                    }
                }
            }
            if let error = store.errorMessage { Text(error).font(.caption).foregroundStyle(.red) }
            HStack { Text("\(store.glossaryEntries.count) terim").font(.caption).foregroundStyle(.secondary); Spacer(); Button("Kapat") { dismiss() }.keyboardShortcut(.cancelAction) }
        }
        .padding(26).frame(minWidth: 580, idealWidth: 680, maxWidth: 920, minHeight: 480, idealHeight: 620, maxHeight: 860)
        .background(WorkspaceStyle.canvas).foregroundStyle(WorkspaceStyle.ink).tint(WorkspaceStyle.accent)
        .sheet(item: $editing) { entry in
            GlossaryEntryEditor(store: store, original: entry)
        }
        .confirmationDialog("“\(deleting?.canonical ?? "")” sözlükten silinsin mi?", isPresented: Binding(
            get: { deleting != nil }, set: { if !$0 { deleting = nil } }), titleVisibility: .visible) {
                Button("Terimi sil", role: .destructive) {
                    if let entry = deleting { _ = store.deleteGlossaryEntry(id: entry.id) }
                    deleting = nil
                }
                Button("Vazgeç", role: .cancel) { deleting = nil }
            } message: { Text("Daha önce onayladığın transkript düzeltmeleri korunur.") }
    }
}

private struct GlossaryEntryEditor: View {
    @ObservedObject var store: AppStore
    let original: GlossaryEntry
    @Environment(\.dismiss) private var dismiss
    @State private var canonical: String
    @State private var variants: String
    @State private var validationError: String?

    init(store: AppStore, original: GlossaryEntry) {
        self.store = store; self.original = original
        _canonical = State(initialValue: original.canonical)
        _variants = State(initialValue: original.variants.joined(separator: "\n"))
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(original.canonical.isEmpty ? "Terim ekle" : "Terimi düzenle").font(.title2.weight(.semibold))
            Text("Doğru yazım").font(.headline)
            TextField("Örneğin Lifesycle", text: $canonical).textFieldStyle(.roundedBorder)
                .accessibilityLabel("Terimin doğru yazımı")
            Text("Duyulan farklı yazımlar").font(.headline)
            Text("Her satıra bir yazım gir. Öneriler yalnız tam kelime veya tam ifade eşleşmelerinde görünür.")
                .font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $variants).font(.body).frame(height: 130).padding(6)
                .overlay(RoundedRectangle(cornerRadius: 6).stroke(.quaternary))
                .accessibilityLabel("Duyulan yazımlar; her satırda bir yazım")
            if let validationError { Text(validationError).font(.caption).foregroundStyle(.red) }
            HStack {
                Spacer()
                Button("Vazgeç") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Kaydet", action: save).keyboardShortcut(.defaultAction).disabled(store.workInProgress)
            }
        }.padding(24).frame(minWidth: 380, idealWidth: 490, maxWidth: 620)
            .background(WorkspaceStyle.canvas).foregroundStyle(WorkspaceStyle.ink).tint(WorkspaceStyle.accent).disabled(store.workInProgress)
    }

    private func save() {
        let entry = GlossaryEntry(id: original.id, canonical: canonical.trimmingCharacters(in: .whitespacesAndNewlines),
            variants: variants.components(separatedBy: .newlines)
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })
        do {
            let others = store.glossaryEntries.filter { $0.id != original.id }
            try GlossaryValidation.entries(others + [entry])
            if store.saveGlossaryEntry(entry) { dismiss() }
            else { validationError = store.errorMessage ?? "Terim kaydedilemedi." }
        } catch { validationError = error.localizedDescription }
    }
}
