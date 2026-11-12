import Foundation
import SwiftUI

struct SpeakerReviewRequest: Identifiable {
    let meetingID: UUID
    let initialSpeakerID: String?
    var id: String { meetingID.uuidString + ":" + (initialSpeakerID ?? "all") }
}

/// One voice at a time: listen, select a person, then move on. Recording-local
/// voices stay distinct while several of them may be assigned to the same person.
struct SpeakerReviewWizard: View {
    @ObservedObject var store: AppStore
    let meetingID: UUID
    let initialSpeakerID: String?
    @Environment(\.dismiss) private var dismiss
    @State private var step = 0
    @State private var reviewOrder: [String] = []
    @State private var sampleIndex = 0
    @State private var selectedChoice = "unselected"
    @State private var newName = ""
    @State private var rememberVoice = false
    @State private var listenedSampleID: String?
    @State private var showSummary = false
    @State private var saveAttempted = false

    init(store: AppStore, meetingID: UUID, initialSpeakerID: String? = nil) {
        self.store = store
        self.meetingID = meetingID
        self.initialSpeakerID = initialSpeakerID
    }

    private var meeting: Meeting? { store.meetings.first(where: { $0.id == meetingID }) }
    private var speakerIDs: [String] { reviewOrder.isEmpty ? (meeting.map { SpeakerReviewPolicy.speakerIDs(in: $0) } ?? []) : reviewOrder }
    private var speakerID: String? { speakerIDs.indices.contains(step) ? speakerIDs[step] : nil }
    private var unavailable: Bool { store.workInProgress || store.preparingSpeakerModels }
    private var samples: [SpeakerReviewSample] {
        guard let meeting, let speakerID else { return [] }
        return Array(SpeakerReviewSamples.samples(in: meeting, speakerID: speakerID).prefix(3))
    }
    private var sample: SpeakerReviewSample? { samples.indices.contains(sampleIndex) ? samples[sampleIndex] : samples.first }
    private var playingThisSample: Bool {
        guard let sample else { return false }
        return store.playingSpeakerSampleID == sample.id && store.isPlaying
    }
    private var canPlay: Bool {
        guard let meeting, let sample else { return false }
        let source: PlaybackSource
        switch sample.source {
        case .microphone: source = .microphone
        case .system: source = .system
        case .mixed: source = .mixed
        }
        guard let url = store.library.audioURL(for: meeting, source: source) else { return false }
        return FileManager.default.fileExists(atPath: url.path)
    }
    private var canRemember: Bool {
        sample?.canRemember == true && canPlay && store.speakerModelsReady && listenedSampleID == sample?.id
    }
    private var choices: [ReviewChoice] {
        guard let meeting else { return [] }
        var result: [ReviewChoice] = []
        var seenProfiles: Set<UUID> = []
        for person in meeting.speakerReviewPeople ?? [] {
            if let profileID = person.voiceProfileID, !seenProfiles.insert(profileID).inserted { continue }
            result.append(ReviewChoice(id: "person:" + person.id.uuidString, name: person.name,
                                       personID: person.id, voiceProfileID: person.voiceProfileID))
        }
        for profile in store.voiceProfiles where seenProfiles.insert(profile.id).inserted {
            result.append(ReviewChoice(id: "profile:" + profile.id.uuidString, name: profile.name,
                                       personID: nil, voiceProfileID: profile.id))
        }
        return result
    }
    private var selection: SpeakerReviewSelection? {
        if selectedChoice == "new" {
            let name = newName.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !name.isEmpty, name.count <= 100 else { return nil }
            return SpeakerReviewSelection(personID: nil, voiceProfileID: nil, name: name)
        }
        guard let choice = choices.first(where: { $0.id == selectedChoice }) else { return nil }
        return SpeakerReviewSelection(personID: choice.personID, voiceProfileID: choice.voiceProfileID, name: choice.name)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider().padding(.top, 18)
            if meeting == nil || speakerIDs.isEmpty {
                ContentUnavailableView("Bu toplantıda gözden geçirilecek ses yok", systemImage: "person.wave.2")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if showSummary {
                summary
            } else {
                reviewStep
            }
            Divider()
            footer.padding(.top, 16)
        }
        .padding(26)
        .frame(width: 560, height: 620)
        .interactiveDismissDisabled(unavailable)
        .onAppear {
            store.stopPlayback()
            reviewOrder = meeting.map { SpeakerReviewPolicy.speakerIDs(in: $0) } ?? []
            if let initialSpeakerID, let index = speakerIDs.firstIndex(of: initialSpeakerID) { step = index }
            loadCurrentChoice()
        }
        .onChange(of: step) { _, _ in resetForStep() }
        .onChange(of: selectedChoice) { _, _ in rememberVoice = false }
        .onChange(of: store.selectedID) { _, id in if id != meetingID { dismiss() } }
        .onDisappear { store.stopSpeakerSample() }
    }

    private var header: some View {
        HStack(alignment: .top) {
            VStack(alignment: .leading, spacing: 5) {
                Text(showSummary ? "Seçtiğin kişiler" : "Bu kim?").font(.title2.weight(.semibold))
                if let meeting { Text(meeting.title).font(.caption).foregroundStyle(.secondary).lineLimit(1) }
                Text(showSummary ? "İsimler bu toplantıya uygulandı." : "Kısa örneği dinle, sonra kişiyi seç.")
                    .font(.callout).foregroundStyle(.secondary)
            }
            Spacer()
            if !showSummary && !speakerIDs.isEmpty {
                Text("Ses \(step + 1) / \(speakerIDs.count)").font(.callout.monospacedDigit()).foregroundStyle(.secondary)
            }
            Button { dismiss() } label: { Image(systemName: "xmark") }
                .buttonStyle(.plain).foregroundStyle(.secondary).padding(.leading, 10)
                .disabled(unavailable).keyboardShortcut(.cancelAction)
                .accessibilityLabel("Konuşmacı düzenlemeyi kapat")
        }
    }

    private var reviewStep: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                samplePlayer
                VStack(alignment: .leading, spacing: 10) {
                    Picker("Bu kişi", selection: $selectedChoice) {
                        Text("Kişi seç").tag("unselected")
                        ForEach(choices) { choice in
                            Text(choice.name).tag(choice.id)
                        }
                        Divider()
                        Text("Yeni kişi…").tag("new")
                    }
                    .controlSize(.large).disabled(unavailable)
                    .accessibilityLabel("Dinlediğin sesin ait olduğu kişi")
                    if selectedChoice == "new" {
                        TextField("Yeni kişinin adı", text: $newName).textFieldStyle(.roundedBorder)
                            .controlSize(.large).disabled(unavailable)
                            .accessibilityLabel("Yeni kişinin adı")
                    }
                    if let meeting, let speakerID, let suggestion = meeting.speakerSuggestions?[speakerID],
                       !suggestion.automatic, let choice = choices.first(where: { $0.voiceProfileID == suggestion.profileID }) {
                        Button("Önerilen kişiyi seç: \(choice.name)") { selectedChoice = choice.id }
                            .font(.caption).disabled(unavailable)
                    }
                    Text("Aynı kişi başka örneklerde de çıkabilir; listeden aynı ismi seç.")
                        .font(.caption).foregroundStyle(.secondary)
                }
                VStack(alignment: .leading, spacing: 7) {
                    Toggle("Dinlediğim bu sesi sonraki toplantılarda tanı", isOn: $rememberVoice)
                        .toggleStyle(.checkbox).disabled(unavailable || !canRemember)
                    if !store.speakerRecognitionEnabled {
                        Text("Onayladığında yeni transkriptlerde otomatik tanıma da açılır.")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    if !store.speakerModelsReady {
                        Text("Sesi hatırlamak için modelleri Ayarlar’dan hazırla.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if sample?.canRemember != true {
                        Text("Bu örneğe isim verebilirsin; sesini hatırlamak için daha uzun, temiz bir örnek gerekir.")
                            .font(.caption).foregroundStyle(.secondary)
                    } else if listenedSampleID != sample?.id {
                        Text("Bu seçeneği açmadan önce örneği dinle.").font(.caption).foregroundStyle(.secondary)
                    }
                }
                if saveAttempted, let error = store.errorMessage {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }
                if unavailable {
                    HStack(spacing: 9) {
                        ProgressView().controlSize(.small)
                        Text(store.statusMessage).font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var samplePlayer: some View {
        VStack(spacing: 12) {
            Button {
                guard let sample else { return }
                if playingThisSample { store.stopSpeakerSample() }
                else {
                    store.playSpeakerSample(sample, meetingID: meetingID)
                    if store.playingSpeakerSampleID == sample.id && store.isPlaying { listenedSampleID = sample.id }
                }
            } label: {
                HStack(spacing: 13) {
                    Image(systemName: playingThisSample ? "stop.circle.fill" : "play.circle.fill")
                        .font(.system(size: 48, weight: .regular))
                    VStack(alignment: .leading, spacing: 4) {
                        Text(playingThisSample ? "Örneği durdur" : "Örneği dinle").font(.headline)
                        if let sample {
                            Text("\(timeLabel(sample.duration)) · \(timeLabel(sample.start)) konumundan")
                                .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        }
                    }
                    Spacer()
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(16)
                .background(Color.accentColor.opacity(0.08), in: RoundedRectangle(cornerRadius: 12))
            }
            .buttonStyle(.plain).foregroundStyle(.tint)
            .disabled(unavailable || !canPlay)
            .accessibilityLabel(playingThisSample ? "Kısa ses örneğini durdur" : "Kısa ses örneğini dinle")
            HStack {
                if samples.count > 1 {
                    Text("Örnek \(sampleIndex + 1) / \(samples.count)").font(.caption).foregroundStyle(.secondary)
                    Spacer()
                    Button("Başka örnek") {
                        store.stopSpeakerSample()
                        sampleIndex = (sampleIndex + 1) % samples.count
                        rememberVoice = false
                        listenedSampleID = nil
                    }.disabled(unavailable)
                }
            }
            if !canPlay {
                Text(samples.isEmpty ? "Bu ses için kısa örnek bulunamadı. Şimdilik geçip başka sese bakabilirsin." : "Bu örneğin ses kaydı artık bulunamıyor. Yine de kişi seçebilirsin.")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var summary: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let meeting {
                    let people = reviewSummary(in: meeting)
                    let unnamed = speakerIDs.filter { meeting.speakerReviewAssignments?[$0] == nil }.count
                    Text("\(people.count) kişi seçildi").font(.title3.weight(.semibold))
                    ForEach(people) { person in
                        HStack(spacing: 12) {
                            Image(systemName: "person.crop.circle.fill").font(.title2).foregroundStyle(.tint)
                            VStack(alignment: .leading, spacing: 3) {
                                Text(person.name).font(.headline)
                                Text("\(person.voiceCount) ses bu kişiye bağlandı").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Gözden geçir") {
                                guard let index = speakerIDs.firstIndex(where: { meeting.speakerReviewAssignments?[$0] == person.id }) else { return }
                                showSummary = false
                                step = index
                                resetForStep()
                            }.font(.caption).disabled(unavailable)
                        }
                        .padding(12)
                        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 9))
                    }
                    if unnamed > 0 {
                        Text("\(unnamed) sesin adı henüz seçilmedi. Daha sonra devam edebilirsin.")
                            .font(.callout).foregroundStyle(.secondary)
                    }
                    Text("Seçimleri transkriptte görebilirsin. İstersen sesleri yeniden gözden geçir.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }.padding(.vertical, 22).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if showSummary {
                Button("Sesleri gözden geçir") { showSummary = false; step = 0; resetForStep() }.disabled(unavailable)
                Spacer()
                Button("Bitti") { dismiss() }.buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction).disabled(unavailable)
            } else if speakerIDs.isEmpty || meeting == nil {
                Spacer()
                Button("Kapat") { dismiss() }.keyboardShortcut(.cancelAction)
            } else {
                Button("Önceki") { step = max(0, step - 1) }.disabled(unavailable || step == 0)
                Spacer()
                Button("Şimdilik geç") { nextStep() }.disabled(unavailable)
                Button("Kaydet ve devam et") { saveCurrent() }
                    .buttonStyle(.borderedProminent).keyboardShortcut(.defaultAction)
                    .disabled(unavailable || selection == nil)
            }
        }
    }

    private func loadCurrentChoice() {
        guard let meeting, let speakerID else { selectedChoice = "unselected"; return }
        if let personID = meeting.speakerReviewAssignments?[speakerID],
           let person = meeting.speakerReviewPeople?.first(where: { $0.id == personID }),
           let choice = choices.first(where: { $0.personID == person.id || (person.voiceProfileID != nil && $0.voiceProfileID == person.voiceProfileID) }) {
            selectedChoice = choice.id
        } else if let match = meeting.speakerSuggestions?[speakerID], match.automatic,
                  let choice = choices.first(where: { $0.voiceProfileID == match.profileID }) {
            selectedChoice = choice.id
        } else {
            selectedChoice = choices.isEmpty ? "new" : "unselected"
        }
        newName = ""
    }

    private func resetForStep() {
        store.stopSpeakerSample()
        sampleIndex = 0
        rememberVoice = false
        listenedSampleID = nil
        saveAttempted = false
        loadCurrentChoice()
    }

    private func nextStep() {
        store.stopSpeakerSample()
        if step + 1 < speakerIDs.count { step += 1 }
        else { showSummary = true }
    }

    private func saveCurrent() {
        guard !unavailable, let speakerID, let selection else { return }
        store.stopSpeakerSample()
        store.errorMessage = nil
        saveAttempted = true
        store.saveSpeakerReview(meetingID: meetingID, speakerID: speakerID, selection: selection,
                                rememberVoice: rememberVoice && canRemember, sample: sample) {
            saveAttempted = false
            nextStep()
        }
    }

    private func reviewSummary(in meeting: Meeting) -> [ReviewSummaryPerson] {
        (meeting.speakerReviewPeople ?? []).compactMap { person in
            let count = speakerIDs.filter { meeting.speakerReviewAssignments?[$0] == person.id }.count
            return count > 0 ? ReviewSummaryPerson(id: person.id, name: person.name, voiceCount: count) : nil
        }
    }
}

private struct ReviewChoice: Identifiable {
    let id: String
    let name: String
    let personID: UUID?
    let voiceProfileID: UUID?
}

private struct ReviewSummaryPerson: Identifiable {
    let id: UUID
    let name: String
    let voiceCount: Int
}
