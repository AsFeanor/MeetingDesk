import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SharingView: View {
    let meeting: Meeting
    @Environment(\.dismiss) private var dismiss
    @State private var options = MeetingShareOptions()
    @State private var errorMessage: String?
    @State private var statusMessage = ""

    private var document: MeetingShareDocument { MeetingExport.document(meeting, options: options) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Paylaş ve dışa aktar").font(.title2.weight(.semibold))
                    Text(meeting.title).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button("Kapat") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            Picker("Paylaşılacak içerik", selection: $options.scope) {
                ForEach(MeetingShareScope.allCases) { scope in Text(scope.rawValue).tag(scope) }
            }.pickerStyle(.segmented)
            Text(options.scope.explanation).font(.caption).foregroundStyle(.secondary)
            Toggle("Kendi notlarımı dahil et", isOn: $options.includePersonalNotes)
                .toggleStyle(.checkbox)
            Text(options.includePersonalNotes ? "Kendi notların da aşağıdaki çıktıya eklendi." : "Kendi notların paylaşımın dışında tutulur.")
                .font(.caption).foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Önizleme").font(.callout.weight(.medium))
                    Spacer()
                    Label("Mac’te hazırlanır", systemImage: "lock").font(.caption).foregroundStyle(.secondary)
                }
                ScrollView {
                    Text(verbatim: document.plainText)
                        .font(.system(size: 13)).lineSpacing(4)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(18)
                }
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                .overlay(RoundedRectangle(cornerRadius: 10).stroke(Color(nsColor: .separatorColor).opacity(0.5)))
                .accessibilityLabel("Seçili paylaşım içeriği")
            }
            if !statusMessage.isEmpty {
                Text(statusMessage).font(.caption).foregroundStyle(.secondary).accessibilityAddTraits(.updatesFrequently)
            }
            HStack(spacing: 12) {
                Button { copy(document) } label: { Label("Metni kopyala", systemImage: "doc.on.doc") }
                Spacer()
                Button("Markdown kaydet…") { save(document, format: .markdown) }
                Button("PDF kaydet…") { save(document, format: .pdf) }.buttonStyle(.borderedProminent)
            }
        }
        .padding(24)
        .frame(minWidth: 690, idealWidth: 760, minHeight: 630, idealHeight: 720)
        .onChange(of: options) { _, _ in statusMessage = "" }
        .alert("Paylaşım hazırlanamadı", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("Tamam") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private func copy(_ selection: MeetingShareDocument) {
        NSPasteboard.general.clearContents()
        guard NSPasteboard.general.setString(selection.plainText, forType: .string) else {
            errorMessage = "Metin panoya kopyalanamadı. Yeniden deneyebilirsin."
            return
        }
        statusMessage = "Önizlemedeki metin kopyalandı."
    }

    private enum ExportFormat: Equatable { case markdown, pdf }
    private func save(_ selection: MeetingShareDocument, format: ExportFormat) {
        let panel = NSSavePanel()
        let fileExtension = format == .pdf ? "pdf" : "md"
        panel.allowedContentTypes = format == .pdf ? [.pdf] : [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = filename + "." + fileExtension
        panel.title = format == .pdf ? "PDF kaydet" : "Markdown kaydet"
        panel.canCreateDirectories = true
        guard panel.runModal() == .OK, let destination = panel.url else { return }
        do {
            if format == .pdf {
                try MeetingPDFExport.data(document: selection, title: meeting.title).write(to: destination, options: .atomic)
            } else {
                try selection.markdown.write(to: destination, atomically: true, encoding: .utf8)
            }
            statusMessage = "Seçili içerik \(fileExtension.uppercased()) olarak kaydedildi."
        } catch {
            errorMessage = "Dosya kaydedilemedi: \(error.localizedDescription)"
        }
    }

    private var filename: String {
        let invalid = CharacterSet(charactersIn: "/:\\").union(.controlCharacters)
        let clean = meeting.title.components(separatedBy: invalid).joined(separator: "-")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return clean.isEmpty ? "Toplantı" : String(clean.prefix(120))
    }
}
