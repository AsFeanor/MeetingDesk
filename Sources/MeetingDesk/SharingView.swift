import SwiftUI
import AppKit
import UniformTypeIdentifiers

struct SharingView: View {
    let meeting: Meeting
    @ObservedObject var notion: NotionConnection
    @Environment(\.dismiss) private var dismiss
    @State private var options = MeetingShareOptions()
    @State private var errorMessage: String?
    @State private var statusMessage = ""
    @State private var showNotionConnection = false
    @State private var notionExportRequested = false
    @State private var exportedNotionURL: URL?

    private var exporting: Bool { notion.isExporting || notionExportRequested }

    private var document: MeetingShareDocument { MeetingExport.document(meeting, options: options) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .top) {
                VStack(alignment: .leading, spacing: 6) {
                    Text("Paylaş ve dışa aktar").font(.title2.weight(.semibold))
                    Text(meeting.title).font(.callout).foregroundStyle(.secondary).lineLimit(2)
                }
                Spacer()
                Button("Kapat") { dismiss() }.keyboardShortcut(.cancelAction).disabled(exporting)
            }
            Picker("Paylaşılacak içerik", selection: $options.scope) {
                ForEach(MeetingShareScope.allCases) { scope in Text(scope.rawValue).tag(scope) }
            }.pickerStyle(.segmented).disabled(exporting)
            Text(options.scope.explanation).font(.caption).foregroundStyle(.secondary)
            Toggle("Kendi notlarımı dahil et", isOn: $options.includePersonalNotes)
                .toggleStyle(.checkbox).disabled(exporting)
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
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Button {
                        if notion.isConfigured { exportToNotion(document) }
                        else { showNotionConnection = true }
                    } label: {
                        Label(exportedNotionURL == nil ? "Notion’a aktar" : "Notion’da yeni kopya oluştur", systemImage: "square.and.arrow.up")
                    }.disabled(exporting || notion.exportMayHaveSucceeded)
                    Button("Notion bağlantısı…") { showNotionConnection = true }.disabled(exporting)
                    Spacer()
                    if let url = exportedNotionURL { Link("Notion’da aç", destination: url) }
                }
                Text("Önizlemedeki seçili metin hedef Notion sayfasının altına gönderilir. Ses kaydı gönderilmez.")
                    .font(.caption).foregroundStyle(.secondary)
                if notion.isConfigured, let pageID = try? NotionPageIdentifier.parse(notion.parentPageInput) {
                    Link("Hedef Notion sayfası", destination: NotionPageIdentifier.pageURL(pageID)).font(.caption)
                }
                if exporting {
                    HStack(spacing: 8) { ProgressView().controlSize(.small); Text(notion.statusMessage).font(.caption) }
                }
                if notion.exportMayHaveSucceeded && !exporting {
                    Text(notion.statusMessage).font(.caption).foregroundStyle(.secondary)
                    HStack {
                        if let url = notion.incompleteExportURL { Link("Oluşan sayfayı kontrol et", destination: url) }
                        Button("Kontrol ettim; yeni kopya oluşturabilirim") { notion.acknowledgeIncompleteExport() }
                            .font(.caption)
                    }
                }
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
        .interactiveDismissDisabled(exporting)
        .onChange(of: options) { _, _ in statusMessage = ""; exportedNotionURL = nil }
        .sheet(isPresented: $showNotionConnection) {
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text("Notion bağlantısı").font(.title2.weight(.semibold))
                    Spacer()
                    Button("Kapat") { showNotionConnection = false }.keyboardShortcut(.cancelAction)
                }
                ScrollView { NotionConnectionView(connection: notion) }
            }.padding(24).frame(width: 590).frame(maxHeight: 680)
        }
        .alert("Paylaşım hazırlanamadı", isPresented: Binding(get: { errorMessage != nil }, set: { if !$0 { errorMessage = nil } })) {
            Button("Tamam") { errorMessage = nil }
        } message: { Text(errorMessage ?? "") }
    }

    private func exportToNotion(_ selection: MeetingShareDocument) {
        guard !exporting, notion.canExport else { return }
        notionExportRequested = true
        statusMessage = ""
        Task { @MainActor in
            defer { notionExportRequested = false }
            do {
                let receipt = try await notion.export(document: selection, title: meeting.title)
                exportedNotionURL = receipt.url
                statusMessage = "Seçili içerik Notion’a aktarıldı."
            } catch { errorMessage = error.localizedDescription }
        }
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
