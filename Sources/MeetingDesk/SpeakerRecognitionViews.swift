import Foundation
import SwiftUI

/// Stable recording-local IDs remain in the archive; the UI presents names or
/// human-readable labels without exposing the recognizer's internal identifiers.
enum SpeakerPresentation {
    static func name(for speakerID: String, in meeting: Meeting) -> String {
        if let personID = meeting.speakerReviewAssignments?[speakerID],
           let person = meeting.speakerReviewPeople?.first(where: { $0.id == personID }) {
            return person.name
        }
        if let match = meeting.speakerSuggestions?[speakerID], match.automatic {
            return match.name
        }
        if let name = meeting.speakerNames[speakerID]?.trimmingCharacters(in: .whitespacesAndNewlines),
           !isFallbackName(name, speakerID: speakerID) {
            return name
        }
        if let index = SpeakerReviewPolicy.speakerIDs(in: meeting).firstIndex(of: speakerID) {
            return "Ses \(index + 1)"
        }
        return speakerID
    }

    static func names(in meeting: Meeting) -> [String: String] {
        names(in: meeting, orderedSpeakerIDs: SpeakerReviewPolicy.speakerIDs(in: meeting))
    }

    /// Reuse the caller's first-speaking order rather than sorting the complete
    /// transcript once again for every unresolved name.
    static func names(in meeting: Meeting, orderedSpeakerIDs: [String]) -> [String: String] {
        let ranks = Dictionary(uniqueKeysWithValues: orderedSpeakerIDs.enumerated().map { ($0.element, $0.offset + 1) })
        let ids = Set(orderedSpeakerIDs).union(meeting.speakers)
        var firstPeople: [UUID: SpeakerReviewPerson] = [:]
        for person in meeting.speakerReviewPeople ?? [] where firstPeople[person.id] == nil {
            firstPeople[person.id] = person
        }
        var result: [String: String] = [:]
        for id in ids {
            if let personID = meeting.speakerReviewAssignments?[id], let person = firstPeople[personID] {
                result[id] = person.name
            } else if let match = meeting.speakerSuggestions?[id], match.automatic {
                result[id] = match.name
            } else if let name = meeting.speakerNames[id]?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !isFallbackName(name, speakerID: id) {
                result[id] = name
            } else if let rank = ranks[id] {
                result[id] = "Ses \(rank)"
            } else { result[id] = id }
        }
        return result
    }

    private static func isFallbackName(_ name: String, speakerID: String) -> Bool {
        name.isEmpty || name == speakerID || ["Mikrofon", "Toplantı sesi", "Konuşma"].contains(name)
            || name.range(of: "^(Konuşmacı|Ses) [0-9]+$", options: .regularExpression) != nil
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
            Text("Hatırlanan sesler · \(store.voiceProfiles.count)").font(.subheadline.weight(.semibold))
            if store.voiceProfiles.isEmpty {
                Text("Henüz sesi hatırlanan kişi yok. İsim verdiğin herkesi sol menüdeki Kişiler bölümünde görebilirsin.")
                    .font(.caption).foregroundStyle(.secondary)
            } else {
                ForEach(store.voiceProfiles) { profile in
                    VoiceProfileEditingRow(store: store, profile: profile)
                }
            }
            Text("Ses profilleri kayıt saklama süresinden ayrı tutulur. Bir profili buradan silebilirsin; önceki toplantıların konuşmacı adları korunur. Tüm isimler sol menüdeki Kişiler bölümünde görünür.")
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
    @State private var showReanalysisConfirmation = false
    let meeting: Meeting
    var onReview: (String?) -> Void

    private var unavailable: Bool { store.workInProgress || store.preparingSpeakerModels }
    @State private var hasAudio = false
    @State private var hasVoices = false
    @State private var namedPeopleCount = 0
    @State private var unnamedCount = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 14) {
                VStack(alignment: .leading, spacing: 4) {
                    Label("Konuşmacılar", systemImage: "person.2.wave.2").font(.headline)
                    if hasVoices {
                        Text(namedPeopleCount == 0 ? "\(unnamedCount) kısa örneği dinleyip isimleri kontrol et." : (unnamedCount == 0 ? "\(namedPeopleCount) kişi eşleşti · tekrar seçim gerekmiyor" : "\(namedPeopleCount) kişi eşleşti · \(unnamedCount) örnek kaldı"))
                            .font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text("Kısa örnekleri dinleyip kimin konuştuğunu seç.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                Spacer(minLength: 8)
                if hasVoices {
                    Button(unnamedCount > 0 ? "Kalan sesleri seç" : "Konuşmacıları düzenle") { onReview(nil) }
                        .buttonStyle(.borderedProminent).disabled(unavailable)
                        .accessibilityHint("Ses örneklerini tek tek dinleyip kişi seçme ekranını açar")
                    Menu {
                        Button("Sesleri yeniden ayır") {
                            if meeting.speakerReviewAssignments?.isEmpty == false { showReanalysisConfirmation = true }
                            else { store.identifySpeakers() }
                        }
                            .disabled(unavailable || !hasAudio || !store.speakerModelsReady)
                        if let notice = meeting.speakerRecognitionNotice, !notice.isEmpty {
                            Text(notice)
                        }
                    } label: { Image(systemName: "ellipsis.circle") }
                        .menuStyle(.borderlessButton).fixedSize()
                        .accessibilityLabel("Konuşmacı seçenekleri")
                } else if hasAudio {
                    if store.preparingSpeakerModels {
                        ProgressView().controlSize(.small)
                    } else if !store.speakerModelsReady {
                        Button("Ses modellerini indir") { store.prepareSpeakerModels() }.disabled(unavailable)
                    } else {
                        Button("Konuşmacıları bul") { store.identifySpeakers() }
                            .buttonStyle(.borderedProminent).disabled(unavailable)
                    }
                }
            }
            if !hasAudio && !hasVoices {
                Text("Ses kaydı bulunmadığı için örnek dinlenemiyor.").font(.caption).foregroundStyle(.secondary)
            }
        }
        // These counts sort the transcript; playback clocks must not rebuild them.
        .onChange(of: meeting, initial: true) { _, value in
            hasAudio = !store.playbackSources(for: value).isEmpty
            hasVoices = !(value.speakerTurns ?? []).isEmpty && !SpeakerReviewPolicy.speakerIDs(in: value).isEmpty
            namedPeopleCount = SpeakerReviewQueue.identifiedGroups(in: value).count
            unnamedCount = SpeakerReviewQueue.pendingSpeakerIDs(in: value).count
        }
        .confirmationDialog("Sesleri yeniden ayır?", isPresented: $showReanalysisConfirmation, titleVisibility: .visible) {
            Button("Yeniden ayır", role: .destructive) { store.identifySpeakers() }
            Button("Vazgeç", role: .cancel) {}
        } message: {
            Text("Bu toplantıdaki kişi seçimleri yeniden yapılır. Önceki dökümü geri getirebilirsin.")
        }
    }
}

struct SpeakerAssignmentPicker: View {
    @ObservedObject var store: AppStore
    let meeting: Meeting
    let segment: TranscriptSegment

    private func identityKey(_ speakerID: String) -> String {
        if let personID = meeting.speakerReviewAssignments?[speakerID],
           meeting.speakerReviewPeople?.contains(where: { $0.id == personID }) == true {
            return "person:" + personID.uuidString
        }
        if let match = meeting.speakerSuggestions?[speakerID], match.automatic {
            if let person = meeting.speakerReviewPeople?.first(where: { $0.voiceProfileID == match.profileID }) {
                return "person:" + person.id.uuidString
            }
            return "profile:" + match.profileID.uuidString
        }
        return "voice:" + speakerID
    }

    private var choices: [String] {
        var seen: Set<String> = []
        return meeting.speakers.filter { seen.insert(identityKey($0)).inserted }
    }

    private func canonicalSpeaker(_ speakerID: String) -> String {
        choices.first(where: { identityKey($0) == identityKey(speakerID) }) ?? speakerID
    }

    var body: some View {
        Picker("Bu bölümün konuşmacısı", selection: Binding(get: {
            let current = store.meetings.first(where: { $0.id == meeting.id })?.segments.first(where: { $0.id == segment.id })?.speaker ?? segment.speaker
            return canonicalSpeaker(current)
        }, set: { speakerID in
            guard store.selectedID == meeting.id else { return }
            store.assignSpeaker(segmentID: segment.id, speakerID: speakerID)
        })) {
            ForEach(choices, id: \.self) { speakerID in
                Text(SpeakerPresentation.name(for: speakerID, in: meeting)).tag(speakerID)
            }
        }
        .disabled(store.workInProgress || store.preparingSpeakerModels)
        .accessibilityLabel("Bu bölümün konuşmacısını düzelt")
    }
}
