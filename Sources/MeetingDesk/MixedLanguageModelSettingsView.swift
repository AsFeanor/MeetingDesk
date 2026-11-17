import SwiftUI

struct MixedLanguageModelSettingsView: View {
    @ObservedObject var store: AppStore
    var body: some View {
        VStack(alignment: .leading, spacing: 9) {
            Divider()
            HStack {
                Label("Karma dil modeli", systemImage: "waveform")
                    .font(.system(size: 12, weight: .semibold))
                Spacer()
                Button(store.mixedModelReady ? "Kontrol et" : "Modeli hazırla") { store.prepareMixedModel() }
                    .disabled(store.workInProgress || !WhisperRuntimeLocation.isBundled)
            }
            Text(WhisperRuntimeLocation.isBundled ? store.mixedModelStatus : "Karma dil bileşenini kullanmak için Toplantı’yı güncelle.")
                .font(.caption).foregroundStyle(WorkspaceStyle.muted).fixedSize(horizontal: false, vertical: true)
            if store.preparingMixedModel {
                ProgressView(value: store.mixedModelProgress ?? 0)
                Text("İndirme tamamlanınca bu Mac’te çevrimdışı kullanılabilir.")
                    .font(.caption).foregroundStyle(WorkspaceStyle.muted)
            }
        }
    }
}
