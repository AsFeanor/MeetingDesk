import Foundation
import SwiftUI

/// Stable recording-local IDs remain in the archive; the UI presents names or
/// human-readable labels without exposing the recognizer's internal identifiers.
enum SpeakerPresentation {
    static func name(for speakerID: String, in meeting: Meeting) -> String {
        if let name = meeting.speakerNames[speakerID]?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty {
            return name
        }
        if meeting.speakerTurns?.contains(where: { $0.speakerID == speakerID }) == true,
           let index = meeting.speakers.firstIndex(of: speakerID) {
            return "Konuşmacı \(index + 1)"
        }
        return speakerID
    }
}

struct SpeakerRecognitionSettingsView: View {
    @ObservedObject var store: AppStore

    private var unavailable: Bool { store.workInProgress || store.preparingSpeakerModels }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Label("Konuşmacılar ve ses profilleri", systemImage: "person.2.wave.2").font(.headline)
            Toggle("Yeni transkriptlerde konuşmacıları ayır ve kayıtlı sesleri tanı", isOn: $store.speakerRecognitionEnabled)
                .disabled(unavailable)
                .accessibilityLabel("Konuşmacı tanımayı etkinleştir")
            Text("Bir kişiyi ilk kez isimlendirip sesini hatırlatabilirsin. Sonraki toplantılarda güçlü eşleşmeler isimlendirilir; belirsiz eşleşmeler onayını bekler.")
                .font(.caption).foregroundStyle(.secondary)
            HStack(spacing: 10) {
                if store.preparingSpeakerModels { ProgressView().controlSize(.small) }
                if store.speakerModelsReady {
                    Label("Ses modelleri hazır", systemImage: "checkmark.circle").font(.callout)
                } else {
                    Button("Ses modellerini indir") { store.prepareSpeakerModels() }
                        .disabled(unavailable)
                        .accessibilityHint("İlk kullanım için gerekli konuşmacı modellerini bu Mac’e indirir")
                }
            }
            Text(store.speakerModelStatus).font(.caption).foregroundStyle(.secondary)
            Text("İlk kullanımda modeller indirilir. Konuşmacı analizi ve ses profilleri bu Mac’te tutulur.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            Text("Hatırlanan kişiler · \(store.voiceProfiles.count)").font(.subheadline.weight(.semibold))
            if store.voiceProfiles.isEmpty {
                Text("Henüz ses profili yok. Bir toplantının transkriptinden “Sesini hatırla” seçeneğini kullan.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(store.voiceProfiles) { profile in
                    VoiceProfileEditingRow(store: store, profile: profile)
                }
            }
            Text("Ses profilleri kayıt saklama süresinden ayrı tutulur. Bir profili buradan silebilirsin; önceki toplantıların konuşmacı adları korunur.")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}

private struct VoiceProfileEditingRow: View {
    @ObservedObject var store: AppStore
    let profile: VoiceProfile
    @State private var name: String
    @State private var showDeleteConfirmation = false

    init(store: AppStore, profile: VoiceProfile) {
        self.store = store
        self.profile = profile
        _name = State(initialValue: profile.name)
    }

    private var cleanName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var unavailable: Bool { store.workInProgress || store.preparingSpeakerModels }

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "person.crop.circle").foregroundStyle(.secondary)
            TextField("Kişinin adı", text: $name).textFieldStyle(.roundedBorder)
                .disabled(unavailable)
                .accessibilityLabel("\(profile.name) ses profilinin adı")
            Button("Kaydet") { store.renameVoiceProfile(id: profile.id, name: cleanName) }
                .disabled(unavailable || cleanName.isEmpty || cleanName == profile.name)
            Button(role: .destructive) { showDeleteConfirmation = true } label: {
                Image(systemName: "trash")
            }
            .disabled(unavailable)
            .accessibilityLabel("\(profile.name) ses profilini sil")
        }
        .onChange(of: profile.name) { _, updated in name = updated }
        .alert("\(profile.name) için ses profili silinsin mi?", isPresented: $showDeleteConfirmation) {
            Button("Vazgeç", role: .cancel) {}
            Button("Ses profilini sil", role: .destructive) { store.deleteVoiceProfile(id: profile.id) }
        } message: {
            Text("Bu kişi sonraki toplantılarda bu profille tanınmaz. Önceki toplantıların konuşmacı adları korunur.")
        }
    }
}

struct MeetingSpeakerControls: View {
    @ObservedObject var store: AppStore
    let meeting: Meeting
    @State private var enrollment: SpeakerEnrollmentRequest?
    @State private var showSpeakerNames = true

    private var unavailable: Bool { store.workInProgress || store.preparingSpeakerModels }
    private var hasAudio: Bool { !store.playbackSources(for: meeting).isEmpty }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Label("Konuşmacılar", systemImage: "person.2.wave.2").font(.headline)
                Spacer()
                Button { store.identifySpeakers() } label: {
                    Label(meeting.speakerRecognitionEngine == nil ? "Konuşmacıları tanı" : "Yeniden tanı", systemImage: "waveform")
                }
                .disabled(unavailable || !hasAudio || !store.speakerModelsReady)
                .accessibilityHint("Bu toplantının konuşmacılarını ayırır ve kayıtlı ses profilleriyle karşılaştırır")
            }
            if !hasAudio {
                Text("Ses kaydı saklanmadığı için bu toplantıda ses analizi yapılamaz. Konuşmacı adlarını yine düzeltebilirsin.")
                    .font(.caption).foregroundStyle(.secondary)
            } else if !store.speakerModelsReady {
                HStack(spacing: 10) {
                    if store.preparingSpeakerModels { ProgressView().controlSize(.small) }
                    Text("Konuşmacı tanıma için ses modellerini bir kez indir.").font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                    Button("Modelleri indir") { store.prepareSpeakerModels() }.disabled(unavailable)
                }
            }
            if store.speakerModelsReady && !store.speakerRecognitionEnabled {
                Text("Yeni transkriptlerde otomatik tanıma kapalı. Ayarlar → Konuşmacılar ve ses profilleri bölümünden açabilirsin.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if meeting.speakerRecognitionEngine != nil {
                Label("Konuşmacılar seslerine göre ayrıldı. İsimleri kontrol edip düzeltebilirsin.", systemImage: "person.crop.circle.badge.checkmark")
                    .font(.caption).foregroundStyle(.secondary)
            }
            if let notice = meeting.speakerRecognitionNotice, !notice.isEmpty {
                Label(notice, systemImage: "exclamationmark.bubble")
                    .font(.caption).foregroundStyle(.secondary)
            }
            DisclosureGroup("İsimler ve hatırlanan sesler", isExpanded: $showSpeakerNames) {
                VStack(alignment: .leading, spacing: 16) {
                    ForEach(meeting.speakers, id: \.self) { speakerID in
                        speakerRow(speakerID)
                    }
                    Text("Burada isim düzeltmek ses profilini değiştirmez. Ses profilini yalnız “Sesini hatırla” ile onayladığında kaydederiz.")
                        .font(.caption).foregroundStyle(.secondary)
                }.padding(.top, 12)
            }
        }
        .sheet(item: $enrollment) { request in
            SpeakerEnrollmentView(store: store, request: request)
        }
    }

    private func speakerRow(_ speakerID: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Text("Konuşmacı \((meeting.speakers.firstIndex(of: speakerID) ?? 0) + 1)")
                    .font(.caption).foregroundStyle(.secondary).frame(width: 105, alignment: .leading)
                TextField("İsim", text: Binding(get: {
                    store.meetings.first(where: { $0.id == meeting.id })?.speakerNames[speakerID] ?? ""
                }, set: { name in
                    guard !unavailable else { return }
                    store.update(meeting.id) {
                        $0.speakerNames[speakerID] = name
                        $0.speakerSuggestions?.removeValue(forKey: speakerID)
                        $0.notesNeedRefresh = $0.notes != nil
                    }
                }))
                .textFieldStyle(.roundedBorder)
                .accessibilityLabel("\(SpeakerPresentation.name(for: speakerID, in: meeting)) için konuşmacı adı")
                .disabled(unavailable)
            }
            if let suggestion = meeting.speakerSuggestions?[speakerID],
               store.voiceProfiles.contains(where: { $0.id == suggestion.profileID }) {
                if suggestion.automatic {
                    Label("Kayıtlı ses profiliyle eşleşti", systemImage: "checkmark.circle")
                        .font(.caption).foregroundStyle(.secondary)
                } else {
                    HStack(spacing: 10) {
                        Text("Bu kişi \(suggestion.name) mi?").font(.callout)
                        Button("Evet") { store.confirmSpeakerMatch(speakerID, profileID: suggestion.profileID) }
                            .accessibilityLabel("\(SpeakerPresentation.name(for: speakerID, in: meeting)) için \(suggestion.name) eşleşmesini onayla")
                        Button("Değil") { store.dismissSpeakerSuggestion(speakerID) }
                            .accessibilityLabel("\(SpeakerPresentation.name(for: speakerID, in: meeting)) için \(suggestion.name) eşleşmesini reddet")
                    }.disabled(unavailable)
                }
            }
            if canRemember(speakerID) {
                Button {
                    let match = meeting.speakerSuggestions?[speakerID]
                    let knownProfileID = match?.automatic == true && store.voiceProfiles.contains(where: { $0.id == match?.profileID }) ? match?.profileID : nil
                    enrollment = SpeakerEnrollmentRequest(meetingID: meeting.id, speakerID: speakerID,
                                                          name: meeting.speakerNames[speakerID] ?? "", profileID: knownProfileID)
                } label: {
                    Label("Sesini hatırla", systemImage: "person.crop.circle.badge.plus")
                }
                .font(.caption)
                .disabled(unavailable || !store.speakerModelsReady)
                .accessibilityLabel("\(SpeakerPresentation.name(for: speakerID, in: meeting)) sesini hatırla")
            }
        }
    }

    private func canRemember(_ speakerID: String) -> Bool {
        guard let turns = meeting.speakerTurns else { return false }
        return turns.contains { turn in
            guard turn.speakerID == speakerID else { return false }
            let source: PlaybackSource
            switch turn.source {
            case .microphone: source = .microphone
            case .system: source = .system
            case .mixed: source = .mixed
            }
            guard let url = store.library.audioURL(for: meeting, source: source) else { return false }
            return FileManager.default.fileExists(atPath: url.path)
        }
    }
}

private struct SpeakerEnrollmentRequest: Identifiable {
    let meetingID: UUID
    let speakerID: String
    let name: String
    let profileID: UUID?
    var id: String { meetingID.uuidString + ":" + speakerID }
}

private struct SpeakerEnrollmentView: View {
    @ObservedObject var store: AppStore
    let request: SpeakerEnrollmentRequest
    @Environment(\.dismiss) private var dismiss
    @State private var name: String
    @State private var profileID: UUID?
    @State private var agreesToRemember = false

    init(store: AppStore, request: SpeakerEnrollmentRequest) {
        self.store = store
        self.request = request
        _name = State(initialValue: request.name)
        _profileID = State(initialValue: request.profileID)
    }

    private var cleanName: String { name.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var unavailable: Bool { store.workInProgress || store.preparingSpeakerModels }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Label("Bu sesi hatırla", systemImage: "person.crop.circle.badge.plus").font(.title2.weight(.semibold))
            Text("Bu kişinin sesini ismiyle eşleştirip sonraki toplantılarda tanımak için bu Mac’te saklayacağız.")
                .foregroundStyle(.secondary)
            Picker("Kişi", selection: $profileID) {
                Text("Yeni kişi").tag(Optional<UUID>.none)
                ForEach(store.voiceProfiles) { profile in
                    Text(profile.name).tag(Optional(profile.id))
                }
            }
            .disabled(unavailable)
            .accessibilityLabel("Ses profilinin ait olduğu kişi")
            if profileID == nil {
                TextField("Kişinin adı", text: $name).textFieldStyle(.roundedBorder)
                    .disabled(unavailable)
                    .accessibilityLabel("Hatırlanacak kişinin adı")
            }
            Text("Yalnız bu kişinin tek başına konuştuğu temiz bölümler kullanılır. Çok kısa veya karışık seslerden profil oluşturulmaz.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle(profileID == nil ? "Bu kişinin ses profilini bu Mac’te sakla" : "Bu konuşmadan seçtiğim kişinin ses profiline örnek ekle", isOn: $agreesToRemember)
                .disabled(unavailable)
            Text("İstersen Ayarlar → Konuşmacılar ve ses profilleri bölümünden silebilirsin. İsmi veya konuşmacıyı düzeltmek tek başına yeni bir ses örneği kaydetmez.")
                .font(.caption).foregroundStyle(.secondary)
            if !store.speakerRecognitionEnabled {
                Text("Yeni transkriptlerde otomatik tanıma şu anda kapalı. Ayarlar’dan açabilir veya toplantıda “Konuşmacıları tanı” seçeneğini kullanabilirsin.")
                    .font(.caption).foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("Vazgeç") { dismiss() }.keyboardShortcut(.cancelAction)
                Button(profileID == nil ? "Sesini hatırla" : "Örneği ekle") {
                    guard store.selectedID == request.meetingID else { dismiss(); return }
                    let selectedName = profileID.flatMap { id in store.voiceProfiles.first(where: { $0.id == id })?.name } ?? cleanName
                    store.rememberSpeaker(request.speakerID, name: selectedName, profileID: profileID)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .keyboardShortcut(.defaultAction)
                .disabled(unavailable || !agreesToRemember || (profileID == nil && cleanName.isEmpty))
            }
        }
        .padding(28)
        .frame(width: 500)
        .onChange(of: profileID) { _, _ in agreesToRemember = false }
    }
}

struct SpeakerAssignmentPicker: View {
    @ObservedObject var store: AppStore
    let meeting: Meeting
    let segment: TranscriptSegment

    var body: some View {
        Picker("Bu bölümün konuşmacısı", selection: Binding(get: {
            store.meetings.first(where: { $0.id == meeting.id })?.segments.first(where: { $0.id == segment.id })?.speaker ?? segment.speaker
        }, set: { speakerID in
            guard store.selectedID == meeting.id else { return }
            store.assignSpeaker(segmentID: segment.id, speakerID: speakerID)
        })) {
            ForEach(meeting.speakers, id: \.self) { speakerID in
                Text(SpeakerPresentation.name(for: speakerID, in: meeting)).tag(speakerID)
            }
        }
        .disabled(store.workInProgress || store.preparingSpeakerModels)
        .accessibilityLabel("Bu bölümün konuşmacısını düzelt")
    }
}
