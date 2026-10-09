import SwiftUI

struct AudioRetentionSettingsView: View {
    @ObservedObject var store: AppStore
    @State private var selection = 0
    @State private var customDays = "30"
    @State private var pendingPolicy: AudioRetentionPolicy?
    @State private var showConfirmation = false
    @State private var error: String?

    private let presets = [7, 30, 90, 180, 365]
    private let customSelection = -1

    private var draftDays: Int? {
        if selection == 0 { return nil }
        return selection == customSelection ? Int(customDays.trimmingCharacters(in: .whitespacesAndNewlines)) : selection
    }

    private var customDaysAreInvalid: Bool {
        guard selection == customSelection else { return false }
        guard let days = draftDays else { return true }
        return !(1...3650).contains(days)
    }

    private var canApply: Bool {
        !store.workInProgress && !customDaysAreInvalid && draftDays != store.audioRetentionPolicy.days
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Ses kayıtlarını saklama").font(.headline)
            Picker("Saklama süresi", selection: $selection) {
                Text("Otomatik silme kapalı").tag(0)
                ForEach(presets, id: \.self) { days in
                    Text("\(days) gün").tag(days)
                }
                Text("Özel süre…").tag(customSelection)
            }
            .disabled(store.workInProgress)
            if selection == customSelection {
                HStack(spacing: 8) {
                    TextField("Gün sayısı", text: $customDays)
                        .textFieldStyle(.roundedBorder)
                        .frame(width: 100)
                        .accessibilityLabel("Özel saklama süresi, gün")
                    Text("gün").foregroundStyle(.secondary)
                }
                .disabled(store.workInProgress)
                Text("1–3650 gün arasında bir süre seç.")
                    .font(.caption).foregroundStyle(customDaysAreInvalid ? .red : .secondary)
            }
            Text("Ses dosyaları süre dolunca Mac’in Çöp Sepeti’ne taşınır. Transkript ve özetler korunur. Uygulama açıkken kontrol edilir. Diskteki yer Çöp Sepeti boşaltılınca geri kazanılır.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text(currentPolicyLabel).font(.caption).foregroundStyle(.secondary)
                Spacer()
                Button("Uygula", action: applyDraft)
                    .disabled(!canApply)
            }
            if let status = store.audioRetentionStatus, !status.isEmpty {
                Text(status).font(.caption).foregroundStyle(.secondary)
            }
            if let error {
                Text(error).font(.caption).foregroundStyle(.red)
            }
        }
        .onAppear(perform: loadCurrentPolicy)
        .onChange(of: store.audioRetentionPolicy.days) { _, _ in loadCurrentPolicy() }
        .alert("Ses saklama süresi uygulansın mı?", isPresented: $showConfirmation) {
            Button("İptal", role: .cancel) { pendingPolicy = nil }
            Button("Uygula", role: .destructive) {
                guard let policy = pendingPolicy else { return }
                store.setAudioRetentionPolicy(policy)
                pendingPolicy = nil
            }
            .disabled(store.workInProgress)
        } message: {
            if let days = pendingPolicy?.days {
                Text("\(days) günü doldurmuş mevcut ses kayıtları da Çöp Sepeti’ne taşınır. Transkript ve özetler korunur.")
            }
        }
    }

    private var currentPolicyLabel: String {
        if let days = store.audioRetentionPolicy.days { return "Uygulanan süre: \(days) gün" }
        return "Otomatik silme şu anda kapalı."
    }

    private func loadCurrentPolicy() {
        let days = store.audioRetentionPolicy.days
        selection = days.map { presets.contains($0) ? $0 : customSelection } ?? 0
        if let days { customDays = String(days) }
        error = nil
    }

    private func applyDraft() {
        guard canApply else { return }
        do {
            let policy = try AudioRetentionPolicy(days: draftDays)
            error = nil
            if let days = policy.days, store.audioRetentionPolicy.days.map({ days < $0 }) ?? true {
                pendingPolicy = policy
                showConfirmation = true
            } else {
                store.setAudioRetentionPolicy(policy)
            }
        } catch {
            self.error = error.localizedDescription
        }
    }
}
