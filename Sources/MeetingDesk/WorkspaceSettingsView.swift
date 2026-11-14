import SwiftUI

struct WorkspaceSettingsView: View {
    @ObservedObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @AppStorage(WorkspaceAppearance.defaultsKey) private var appearanceRaw = WorkspaceAppearance.system.rawValue
    @State private var category: SettingsCategory = .general
    @State private var key = ""
    @State private var keyError: String?
    @State private var keySaved = false
    @State private var transcriptionStatus = "Dil desteği kontrol ediliyor…"

    init(store: AppStore) {
        self.store = store
        let needsModel = store.processingMode == .local &&
            (store.localSummaryServiceStatus == .modelMissing || store.localSummaryNeedsAppUpdate)
        _category = State(initialValue: needsModel ? .summary : .general)
    }

    var body: some View {
        HStack(spacing: 0) {
            navigation
            Rectangle().fill(WorkspaceStyle.border).frame(width: 1)
            VStack(alignment: .leading, spacing: 0) {
                header
                Rectangle().fill(WorkspaceStyle.border).frame(height: 1)
                ScrollView {
                    VStack(alignment: .leading, spacing: 23) { categoryContent }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(28)
                }
                Rectangle().fill(WorkspaceStyle.border).frame(height: 1)
                HStack {
                    Text("Tercihler otomatik kaydedilir; bağlantı anahtarları ayrıca kaydedilir.")
                        .font(.system(size: 10)).foregroundStyle(WorkspaceStyle.muted)
                    Spacer(minLength: 10)
                    Button("Kapat") { dismiss() }.buttonStyle(WorkspaceQuietButtonStyle()).keyboardShortcut(.cancelAction)
                }.padding(.horizontal, 24).padding(.vertical, 15)
            }.background(WorkspaceStyle.canvas)
        }
        .frame(width: 780, height: 660)
        .foregroundStyle(WorkspaceStyle.ink)
        .tint(WorkspaceStyle.accent)
        .preferredColorScheme((WorkspaceAppearance(rawValue: appearanceRaw) ?? .system).colorScheme)
        .onChange(of: store.processingMode) { _, _ in key = ""; keyError = nil; keySaved = false }
        .task(id: store.transcriptionLanguage) {
            let status = await LocalTranscriptionService.availabilityDescription(language: store.transcriptionLanguage)
            guard !Task.isCancelled else { return }
            transcriptionStatus = status
        }
    }

    private var navigation: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 9) {
                Image(systemName: "slider.horizontal.3").foregroundStyle(WorkspaceStyle.accent)
                Text("Ayarlar").font(.system(size: 17, weight: .semibold))
            }.padding(.horizontal, 22).padding(.top, 29).padding(.bottom, 30)
            VStack(spacing: 5) {
                ForEach(SettingsCategory.allCases) { item in
                    Button { category = item } label: {
                        HStack(spacing: 10) {
                            Image(systemName: item.symbol).font(.system(size: 13)).frame(width: 20)
                            Text(item.title).font(.system(size: 12, weight: category == item ? .semibold : .regular))
                            Spacer(minLength: 0)
                        }.padding(.horizontal, 12).padding(.vertical, 11)
                            .foregroundStyle(category == item ? WorkspaceStyle.accent : WorkspaceStyle.ink)
                            .background(category == item ? WorkspaceStyle.accent.opacity(0.10) : .clear, in: RoundedRectangle(cornerRadius: 9))
                            .contentShape(RoundedRectangle(cornerRadius: 9))
                    }.buttonStyle(.plain).accessibilityAddTraits(category == item ? .isSelected : [])
                }
            }.padding(.horizontal, 10)
            Spacer()
            Label("Toplantı", systemImage: "waveform").font(.system(size: 11, weight: .medium))
                .foregroundStyle(WorkspaceStyle.muted).padding(.horizontal, 22).padding(.bottom, 24)
        }.frame(width: 170).background(WorkspaceStyle.sidebar)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 7) {
            Text(category.title).font(.system(size: 24, weight: .semibold))
            Text(category.subtitle).font(.system(size: 12)).foregroundStyle(WorkspaceStyle.muted).lineSpacing(3)
        }.frame(maxWidth: .infinity, alignment: .leading).padding(.horizontal, 28).padding(.vertical, 25)
    }

    @ViewBuilder
    private var categoryContent: some View {
        switch category {
        case .general: general
        case .recording: recording
        case .summary:
            if store.processingMode == .local {
                settingsCard { LocalSummaryBackendSettingsView(store: store) }
            } else {
                settingsCard {
                    Label("OpenAI modu açık", systemImage: "network").font(.headline)
                    note("Özet, kaydettiğin API anahtarıyla hazırlanır. Yerel özet modelini kullanmak için Genel bölümünden Mac’te ücretsiz modunu seç.")
                    Button("Genel ayarları aç") { category = .general }.buttonStyle(WorkspaceQuietButtonStyle())
                }
            }
        case .speakers:
            settingsCard { SpeakerRecognitionSettingsView(store: store) }
        case .retention:
            settingsCard { AudioRetentionSettingsView(store: store) }
            settingsCard {
                Label("Toplantı arşivi", systemImage: "folder").font(.headline)
                note("Transkriptlerin ve toplantı notların, ses saklama süresinden bağımsız olarak arşivde kalır.")
                Button("Yerel toplantı arşivini aç") { store.revealArchive() }.buttonStyle(WorkspaceQuietButtonStyle())
            }
        case .notion:
            settingsCard { NotionConnectionView(connection: store.notion) }
        case .updates:
            settingsCard { UpdateSettingsView(updater: store.updates) }
        }
    }

    private var general: some View {
        VStack(alignment: .leading, spacing: 22) {
            settingsCard {
                Text("Görünüm").font(.headline)
                Picker("Görünüm", selection: $appearanceRaw) {
                    ForEach(WorkspaceAppearance.allCases) { appearance in
                        Label(appearance.label, systemImage: appearance.symbol).tag(appearance.rawValue)
                    }
                }.pickerStyle(.segmented).labelsHidden()
                note("Sistem seçeneği Mac’inin açık veya koyu görünümüne uyar.")
            }
            settingsCard {
                Text("İşleme yöntemi").font(.headline)
                Picker("Transkript ve özet", selection: $store.processingMode) {
                    ForEach(ProcessingMode.allCases) { Text($0.label).tag($0) }
                }.pickerStyle(.segmented).disabled(store.workInProgress)
                if store.processingMode == .local {
                    Label("API anahtarı ve kredi gerekmez", systemImage: "lock.shield").font(.system(size: 12, weight: .medium)).foregroundStyle(WorkspaceStyle.accent)
                    note("Ses ve transkript bu Mac’te işlenir. İlk kullanımda gerekli modeller indirilir; sonraki işlemlerde yeniden indirilmez.")
                } else {
                    apiKeySettings
                }
            }
            settingsCard {
                Text("Konuşma dili").font(.headline)
                Picker("Yeni toplantılar için konuşma dili", selection: $store.transcriptionLanguage) {
                    Text("Türkçe").tag("Türkçe")
                    Text("English").tag("English")
                }.disabled(store.workInProgress)
                note("Yeni toplantıların varsayılanıdır. Her toplantıda ayrıca değiştirebilirsin. Özet dili ayrı seçilir; konuşma dili otomatik algılanmaz.")
                if store.processingMode == .local {
                    Text(transcriptionStatus).font(.caption).foregroundStyle(WorkspaceStyle.muted)
                }
            }
        }
    }

    private var apiKeySettings: some View {
        VStack(alignment: .leading, spacing: 11) {
            Text("OpenAI API anahtarı").font(.system(size: 12, weight: .semibold))
            SecureField(store.hasKey ? "Mevcut anahtarı değiştirmek için yeni anahtar gir" : "API anahtarını gir", text: $key)
                .textFieldStyle(.roundedBorder)
                .onChange(of: key) { _, value in keyError = nil; if !value.isEmpty { keySaved = false } }
            note(store.hasKey ? "Bir anahtar Mac’in Anahtar Zinciri’nde saklanıyor." : "Anahtar Mac’in Anahtar Zinciri’nde saklanır; toplantı dosyalarına yazılmaz.")
            note("‘Transkript oluştur’ sesi; ‘Özet oluştur’ transkripti OpenAI’a gönderir. API ücreti OpenAI hesabından tahsil edilir.")
            Link("API anahtarı sayfasını aç", destination: URL(string: "https://platform.openai.com/api-keys")!).font(.caption)
            HStack {
                Button("Anahtarı kaydet") { saveAPIKey() }
                    .buttonStyle(WorkspacePrimaryButtonStyle())
                    .disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.workInProgress)
                if store.hasKey {
                    Button("Anahtarı kaldır", role: .destructive) { removeAPIKey() }.disabled(store.workInProgress)
                }
            }
            if let keyError { Label(keyError, systemImage: "exclamationmark.circle").font(.caption).foregroundStyle(.red) }
            if keySaved { Label("Anahtar kaydedildi", systemImage: "checkmark.circle").font(.caption).foregroundStyle(WorkspaceStyle.accent) }
        }
    }

    private var recording: some View {
        VStack(alignment: .leading, spacing: 22) {
            settingsCard {
                Text("Mikrofon ve ses seviyesi").font(.headline)
                MicrophoneControls(store: store)
                Button { openMicrophoneCheck() } label: { Label("10 saniyelik ses denemesi", systemImage: "mic") }
                    .buttonStyle(WorkspaceQuietButtonStyle()).disabled(store.workInProgress)
                note("Güçlendirme yalnız mikrofon sesine uygulanır. 2× ile başla; sesin hâlâ düşükse sonraki kayıtta 3× veya 4× seç. Konuşurken mikrofon göstergesi hareket etmeli.")
            }
            settingsCard {
                Text("Kayıt bittikten sonra").font(.headline)
                Toggle("Transkript ve özeti Mac’te hazırla", isOn: $store.automaticLocalProcessing)
                    .disabled(store.workInProgress || store.processingMode != .local)
                note("Yalnız Mac’te ücretsiz modunda çalışır. Özet hazırlanamazsa oluşturulmuş transkript saklanır; işlemi iptal edebilirsin.")
            }
            settingsCard {
                Text("Toplantı hatırlatıcısı").font(.headline)
                Toggle("Toplantıda olabileceğimi algıla ve kaydı hatırlat", isOn: $store.meetingDetectionEnabled)
                note("Zoom, Teams, Webex, FaceTime ve Slack’in mikrofon kullanımı kontrol edilir. Tarayıcıda mikrofon kullanımıyla birlikte görünür bir toplantı penceresi gerekir; mevcut ekran iznin yoksa bu kontrol yapılmaz. Ses dinlenmez veya kaydedilmez. Mikrofon kapalı görüşmeler algılanmayabilir.")
                note("Hatırlatıcı kaydı kendiliğinden başlatmaz. Kayda başla düğmesine bastığında normal kayıt izinleri ve seçili mikrofon kullanılır.")
                Divider()
                Toggle("Kayıt sırasında küçük kontrol kartını göster", isOn: $store.showRecordingPanel)
                note("Karttan süreyi ve ses göstergelerini izleyebilir, duraklatabilir veya bitirip saklayabilirsin. Kartı gizlersen kayıt sürer; menü çubuğundan tekrar açabilirsin.")
            }
            note("Kayıt için macOS mikrofon ve ekran/sistem sesi kayıt izni ister. Uygulama ekran görüntüsü veya video saklamaz.")
        }
    }

    private func settingsCard<Content: View>(@ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 13, content: content)
            .frame(maxWidth: .infinity, alignment: .leading).padding(19)
            .background(WorkspaceStyle.surface, in: RoundedRectangle(cornerRadius: 13))
            .overlay(RoundedRectangle(cornerRadius: 13).strokeBorder(WorkspaceStyle.border.opacity(0.75), lineWidth: 1))
    }
    private func note(_ text: String) -> some View {
        Text(text).font(.system(size: 11.5)).foregroundStyle(WorkspaceStyle.muted).lineSpacing(4).fixedSize(horizontal: false, vertical: true)
    }
    private func saveAPIKey() {
        guard store.processingMode == .openAI, !store.workInProgress else { return }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        do { try APIKeychain.save(trimmed); store.refreshKey(); key = ""; keyError = nil; keySaved = true }
        catch { keyError = error.localizedDescription; keySaved = false }
    }
    private func removeAPIKey() {
        guard store.processingMode == .openAI, !store.workInProgress else { return }
        do { try APIKeychain.delete(); store.refreshKey(); key = ""; keyError = nil; keySaved = false }
        catch { keyError = error.localizedDescription }
    }
    private func openMicrophoneCheck() {
        guard !store.workInProgress else { return }
        dismiss()
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 350_000_000)
            guard !store.workInProgress else { return }
            store.showMicrophoneCheck = true
        }
    }

    private enum SettingsCategory: String, CaseIterable, Identifiable {
        case general, recording, summary, speakers, retention, notion, updates
        var id: String { rawValue }
        var title: String {
            switch self {
            case .general: return "Genel"
            case .recording: return "Kayıt"
            case .summary: return "Özet modeli"
            case .speakers: return "Konuşmacılar"
            case .retention: return "Saklama"
            case .notion: return "Notion"
            case .updates: return "Güncellemeler"
            }
        }
        var symbol: String {
            switch self {
            case .general: return "slider.horizontal.3"
            case .recording: return "mic"
            case .summary: return "sparkles"
            case .speakers: return "person.2"
            case .retention: return "archivebox"
            case .notion: return "square.and.arrow.up"
            case .updates: return "arrow.down.circle"
            }
        }
        var subtitle: String {
            switch self {
            case .general: return "Görünümü ve toplantılarını nasıl işleyeceğini seç."
            case .recording: return "Sesini hazırla, kayıt akışını kendine göre ayarla."
            case .summary: return "Toplantı notlarını hazırlayan yerel modeli yönet."
            case .speakers: return "Konuşmacı ayrımı ve hatırlanan ses profilleri."
            case .retention: return "Ses kayıtlarının ne kadar süre tutulacağını belirle."
            case .notion: return "Toplantı notlarını istediğin Notion sayfasına aktar."
            case .updates: return "Yeni sürümleri ve uygulama güncellemelerini yönet."
            }
        }
    }
}
