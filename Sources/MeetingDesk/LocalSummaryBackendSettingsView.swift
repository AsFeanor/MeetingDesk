import SwiftUI

struct LocalSummaryBackendSettingsView: View {
    @ObservedObject var store: AppStore
    private var unavailable: Bool { store.workInProgress || store.preparingLocalSummaryModel }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Özet modeli").font(.headline)
            Picker("Özet modeli", selection: $store.localSummaryBackend) {
                ForEach(LocalSummaryBackend.allCases) { backend in Text(backend.label).tag(backend) }
            }.disabled(unavailable)
            if store.localSummaryBackend == .qwen {
                Text("Toplantının tamamını birlikte değerlendirerek kısa bir özet, kararlar ve yapılacaklar oluşturur.")
                    .font(.callout).foregroundStyle(.secondary)
                Text("İlk model indirmesi yaklaşık 6,6 GB. Hazırlandıktan sonra özet bu Mac’te çevrimdışı oluşturulur; API anahtarı ve kredi gerekmez.")
                    .font(.caption).foregroundStyle(.secondary)
                Text(store.localSummaryModelStatus).font(.caption).foregroundStyle(.secondary)
                if store.preparingLocalSummaryModel {
                    HStack(spacing: 10) {
                        if let progress = store.localSummaryModelProgress { ProgressView(value: progress).frame(maxWidth: 200) }
                        else { ProgressView().controlSize(.small) }
                        Text("Özet modeli hazırlanıyor…").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("İptal") { store.cancelProcessing() }.font(.caption)
                    }
                } else if store.localSummaryModelReady {
                    Label("Qwen özet modeli hazır", systemImage: "checkmark.circle").font(.caption)
                } else if store.localSummaryNeedsAppUpdate || store.localSummaryServiceStatus == .updateRequired {
                    Text("Özet altyapısını yenilemek için Toplantı’yı güncelle.")
                        .font(.caption).foregroundStyle(.secondary)
                    Button("Toplantı güncellemelerini kontrol et…") { store.updates.checkForUpdates() }
                        .disabled(unavailable || !store.updates.canCheckForUpdates)
                } else {
                    Button(store.localSummaryServiceStatus == .modelMissing ? "Modeli indir" : "Modeli hazırla") {
                        store.prepareLocalSummaryModel()
                    }.disabled(unavailable)
                }
            } else {
                Text(LocalSummaryService.availabilityDescription()).font(.caption).foregroundStyle(.secondary)
                Text("Temel seçenek Apple Intelligence kullanır. Uzun toplantıları bölümler halinde değerlendirir; değişen kararları kaynak metinden kontrol et.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .task(id: store.localSummaryBackend) { await store.refreshLocalSummaryModelStatus() }
    }
}
