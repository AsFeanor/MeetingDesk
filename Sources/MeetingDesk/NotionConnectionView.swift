import SwiftUI

struct NotionConnectionView: View {
    @ObservedObject var connection: NotionConnection
    @State private var token = ""
    @State private var parentPage = ""
    @State private var errorMessage: String?
    @State private var saved = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Notion’a aktar", systemImage: "square.and.arrow.up").font(.headline)
                Spacer()
                if connection.isConfigured {
                    Label("Bağlantı kaydedildi", systemImage: "checkmark.circle")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
            Text("Toplantı notlarını ve seçtiğin transkripti Notion’da yeni bir alt sayfa olarak açabilirsin. Her aktarımın içeriğini Paylaş ekranında seçersin.")
                .font(.callout).foregroundStyle(.secondary)
            if !connection.isConfigured {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Bir kez bağla").font(.subheadline.weight(.medium))
                    Text("1. Notion’da bir iç entegrasyon oluştur; içerik okuma ve ekleme izni ver.\n2. Hedef sayfada ••• → Bağlantılar → Bağlantı ekle ile entegrasyonunu seç.\n3. Entegrasyon anahtarını ve hedef sayfanın bağlantısını aşağıya kaydet.")
                        .font(.caption).foregroundStyle(.secondary).lineSpacing(4)
                    Link("Notion bağlantısı oluştur", destination: URL(string: "https://www.notion.so/profile/integrations")!)
                }
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Hedef Notion sayfası").font(.caption.weight(.medium))
                TextField("Hedef sayfanın bağlantısını yapıştır", text: $parentPage)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Hedef Notion sayfası bağlantısı")
            }
            VStack(alignment: .leading, spacing: 6) {
                Text("Notion bağlantı anahtarı").font(.caption.weight(.medium))
                SecureField(connection.hasToken ? "Mevcut anahtarı korumak için boş bırak" : "Entegrasyon anahtarını yapıştır", text: $token)
                    .textFieldStyle(.roundedBorder)
                    .accessibilityLabel("Notion bağlantı anahtarı")
                Text("Anahtar yalnız bu Mac’in Anahtar Zinciri’nde saklanır. Ses kaydı Notion’a yüklenmez; seçtiğin metin düğmeye bastığında gönderilir.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Button("Bağlantıyı kaydet") {
                    do {
                        try connection.saveConnection(token: token, parentPage: parentPage)
                        token = ""
                        parentPage = NotionPageIdentifier.pageURL(try NotionPageIdentifier.parse(connection.parentPageInput)).absoluteString
                        errorMessage = nil
                        saved = true
                    } catch { errorMessage = error.localizedDescription; saved = false }
                }.buttonStyle(.borderedProminent)
                    .disabled(parentPage.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || (!connection.hasToken && token.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty))
                if connection.hasToken {
                    Button("Bağlantıyı kaldır") {
                        do {
                            try connection.disconnect()
                            token = ""; parentPage = ""; errorMessage = nil; saved = false
                        } catch { errorMessage = error.localizedDescription }
                    }
                }
            }
            if let errorMessage { Text(errorMessage).font(.caption).foregroundStyle(.red) }
            else if saved { Text("Bağlantı kaydedildi. Paylaş ekranından Notion’a aktarabilirsin.").font(.caption).foregroundStyle(.secondary) }
            if connection.exportMayHaveSucceeded {
                Text(connection.statusMessage).font(.caption).foregroundStyle(.secondary)
                if let url = connection.incompleteExportURL { Link("Önceki aktarımı Notion’da kontrol et", destination: url) }
            }
        }
        .disabled(connection.isExporting)
        .onAppear {
            if let pageID = try? NotionPageIdentifier.parse(connection.parentPageInput) {
                parentPage = NotionPageIdentifier.pageURL(pageID).absoluteString
            } else { parentPage = connection.parentPageInput }
        }
    }
}
