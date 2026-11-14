import SwiftUI
import AppKit

private enum DetailTab: String, CaseIterable {
    case overview = "Özet", transcript = "Transkript", personal = "Notlarım"
    var symbol: String {
        switch self { case .overview: return "sparkles"; case .transcript: return "text.alignleft"; case .personal: return "square.and.pencil" }
    }
    var key: KeyEquivalent {
        switch self { case .overview: return "1"; case .transcript: return "2"; case .personal: return "3" }
    }
}

struct RootView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var recorder: AudioRecorder
    @State private var query = ""
    @State private var tab: DetailTab = .overview
    @State private var showImport = false
    @State private var showPeople = false
    @State private var focusID: String?
    @State private var editSegment: String?
    @State private var sharingMeeting: Meeting?
    @State private var editingMeeting: Meeting?
    @State private var reviewingSpeaker: SpeakerReviewRequest?
    @State private var showInspector = true
    @State private var showInspectorSheet = false
    @State private var showQuickOpen = false
    @State private var transcriptQuery = ""
    @State private var pendingActionsOnly = false
    @State private var sectionFocus: String?
    @Namespace private var tabHighlight
    @AppStorage(WorkspaceAppearance.defaultsKey) private var appearanceRaw = WorkspaceAppearance.system.rawValue
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var needsLocalSummarySetup: Bool {
        store.processingMode == .local && store.localSummaryBackend == .qwen &&
            (store.localSummaryServiceStatus == .modelMissing || store.localSummaryServiceStatus == .updateRequired || store.localSummaryNeedsAppUpdate)
    }

    private func summaryActionTitle(for meeting: Meeting) -> String {
        if needsLocalSummarySetup {
            return store.localSummaryNeedsAppUpdate || store.localSummaryServiceStatus == .updateRequired ? "Toplantı’yı güncelle" : "Özet modelini hazırla"
        }
        return meeting.notes == nil ? "Özet oluştur" : "Özeti yenile"
    }

    private func createSummary() {
        if needsLocalSummarySetup { store.showSettings = true }
        else { store.summarize(); tab = .overview }
    }

    var body: some View {
        NavigationSplitView {
            WorkspaceSidebar(store: store, recorder: recorder, query: $query,
                onNew: newMeeting, onImportAudio: { guard !store.workInProgress else { return }; store.importAudio() },
                onImportTranscript: { guard !store.workInProgress else { return }; showImport = true },
                onPeople: { showPeople = true }, onQuickOpen: { showQuickOpen = true })
                .navigationSplitViewColumnWidth(min: 220, ideal: 252, max: 300)
        } detail: {
            GeometryReader { geometry in
                VStack(spacing: 0) {
                    workspaceBar(wide: geometry.size.width >= 880)
                    HStack(spacing: 0) {
                        VStack(spacing: 0) {
                            if let meeting = store.selected { detail(meeting) }
                            else { welcome }
                            statusBar
                        }.frame(maxWidth: .infinity, maxHeight: .infinity)
                        if showInspector && geometry.size.width >= 880, let meeting = store.selected {
                            Rectangle().fill(WorkspaceStyle.border).frame(width: 1)
                            inspector(meeting).frame(width: 242)
                                .transition(.move(edge: .trailing).combined(with: .opacity))
                        }
                    }
                }.background(WorkspaceStyle.canvas)
            }
        }
        .navigationSplitViewStyle(.balanced)
        .tint(WorkspaceStyle.accent)
        .preferredColorScheme((WorkspaceAppearance(rawValue: appearanceRaw) ?? .system).colorScheme)
        .focusedSceneValue(\.workspaceQuickOpen, { showQuickOpen = true })
        .sheet(isPresented: $showQuickOpen) {
            WorkspaceQuickOpenView(meetings: store.meetings, selectedID: store.selectedID,
                canNavigate: !recorder.isRecording && !store.hasPendingRecordingSession && !store.showMicrophoneCheck,
                onSelect: { id in
                    guard !recorder.isRecording, !store.hasPendingRecordingSession, !store.showMicrophoneCheck else { return }
                    store.selectedID = id; showQuickOpen = false
                })
        }
        .sheet(isPresented: $showInspectorSheet) {
            VStack(spacing: 0) {
                HStack { Text("Toplantı ayrıntıları").font(.headline); Spacer(); Button("Bitti") { showInspectorSheet = false } }
                    .padding(22)
                if let meeting = store.selected { inspector(meeting) }
            }.frame(width: 380, height: 640).background(WorkspaceStyle.canvas)
        }
        .sheet(isPresented: $store.showSettings) { WorkspaceSettingsView(store: store) }
        .sheet(isPresented: $showPeople) {
            PeopleView(store: store) { meetingID in
                guard !store.workInProgress else { return }
                store.stopPlayback()
                store.selectedID = meetingID
                tab = .transcript
                showPeople = false
            }
        }
        .sheet(isPresented: $showImport) { ImportTranscriptView(store: store) }
        .sheet(isPresented: $store.showMicrophoneCheck) { MicrophoneCheckView(store: store) }
        .sheet(item: $sharingMeeting) { SharingView(meeting: $0, notion: store.notion) }
        .sheet(item: $reviewingSpeaker) { request in
            SpeakerReviewWizard(store: store, meetingID: request.meetingID, initialSpeakerID: request.initialSpeakerID)
        }
        .sheet(item: $editingMeeting) { meeting in
            NotesEditingView(meeting: meeting) { notes in
                try store.saveEditedNotes(notes, meetingID: meeting.id)
            }
        }
        .alert("İşlem tamamlanamadı", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("Tamam") { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
        .onChange(of: store.selectedID) { _, _ in
            store.stopPlayback(); store.playbackSource = .mixed; focusID = nil; editSegment = nil
            reviewingSpeaker = nil; transcriptQuery = ""; sectionFocus = nil
            if let meeting = store.selected, meeting.audioFileName == nil && meeting.segments.isEmpty && meeting.notes == nil {
                tab = .overview
            }
        }
        .task(id: "\(store.processingMode.rawValue):\(store.localSummaryBackend.rawValue)") {
            if store.processingMode == .local { await store.refreshLocalSummaryModelStatus() }
        }
    }

    private func newMeeting() {
        guard !store.workInProgress else { return }
        _ = store.newMeeting(); tab = .overview
    }

    private func workspaceBar(wide: Bool) -> some View {
        HStack(spacing: 10) {
            Text("Çalışma alanım").foregroundStyle(WorkspaceStyle.muted)
            Image(systemName: "chevron.right").font(.system(size: 9, weight: .bold)).foregroundStyle(WorkspaceStyle.muted)
            Text(store.selected == nil ? "Başlangıç" : "Toplantılar").foregroundStyle(WorkspaceStyle.ink)
            Spacer()
            Label(store.processingMode == .local ? "Bu Mac’te" : "OpenAI modu", systemImage: store.processingMode == .local ? "lock.shield" : "cloud")
                .foregroundStyle(WorkspaceStyle.muted).help(store.processingMode == .local ? "Yerel mod: ses ve transkript bu Mac’te işlenir." : "OpenAI işlemlerinde toplantı içeriği API’ye gönderilir.")
            Button { showQuickOpen = true } label: { Image(systemName: "magnifyingglass").frame(width: 28, height: 28) }
                .buttonStyle(.plain).help("Hızlı aç · ⌘K").accessibilityLabel("Toplantı bul")
            Button {
                if wide { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.2)) { showInspector.toggle() } }
                else { showInspectorSheet = true }
            } label: { Image(systemName: "sidebar.right").frame(width: 28, height: 28) }
                .buttonStyle(.plain).disabled(store.selected == nil)
                .help("Toplantı ayrıntıları ve içerik haritası").accessibilityLabel("Toplantı ayrıntılarını göster")
        }.font(.system(size: 11, weight: .medium)).padding(.horizontal, 26).frame(height: 46)
            .background(WorkspaceStyle.canvas)
            .overlay(alignment: .bottom) { Rectangle().fill(WorkspaceStyle.border).frame(height: 1) }
    }

    @ViewBuilder private var statusBar: some View {
        if !store.statusMessage.isEmpty || store.isBusy {
            HStack(spacing: 9) {
                if store.isBusy { ProgressView().controlSize(.small) }
                else { Image(systemName: "checkmark.circle").foregroundStyle(WorkspaceStyle.accent) }
                Text(store.statusMessage).font(.system(size: 11)).foregroundStyle(WorkspaceStyle.muted).lineLimit(2)
                Spacer(minLength: 8)
                if store.canCancelProcessing { Button("İptal") { store.cancelProcessing() }.font(.caption) }
            }.padding(.horizontal, 24).padding(.vertical, 10).background(WorkspaceStyle.sidebar)
                .overlay(alignment: .top) { Rectangle().fill(WorkspaceStyle.border).frame(height: 1) }
        }
    }

    private func inspector(_ meeting: Meeting) -> some View {
        let presentation = MeetingNotesPresentation(meeting: meeting)
        let participants = WorkspaceParticipants.entries(in: meeting)
        return ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                VStack(alignment: .leading, spacing: 14) {
                    inspectorHeading("BU TOPLANTIDA")
                    HStack(spacing: 0) {
                        inspectorStat("Süre", value: meeting.duration > 0 ? timeLabel(meeting.duration) : "—")
                        Spacer()
                        inspectorStat("Açık görev", value: "\(meeting.notes?.actions.filter { !meeting.completedActions.contains($0.id) }.count ?? 0)")
                    }
                    if !participants.isEmpty {
                        Divider()
                        ForEach(participants) { person in
                            HStack(spacing: 9) {
                                WorkspaceAvatar(name: person.name, size: 27)
                                Text(person.name).font(.system(size: 12, weight: .medium)).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                        }
                        Button { tab = .transcript; reviewingSpeaker = SpeakerReviewRequest(meetingID: meeting.id, initialSpeakerID: nil) } label: {
                            Label("Konuşmacıları düzenle", systemImage: "person.crop.circle.badge.checkmark")
                        }.font(.system(size: 11, weight: .medium)).buttonStyle(.plain).foregroundStyle(WorkspaceStyle.accent)
                            .disabled(store.workInProgress || meeting.speakerRecognitionEngine == nil)
                    }
                }
                if !presentation.sections.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        inspectorHeading("İÇERİK")
                        ForEach(presentation.sections) { section in
                            Button {
                                tab = .overview; sectionFocus = nil
                                Task { @MainActor in sectionFocus = section.id }
                                showInspectorSheet = false
                            } label: {
                                HStack(spacing: 9) {
                                    Rectangle().fill(sectionFocus == section.id ? WorkspaceStyle.accent : WorkspaceStyle.border).frame(width: 2, height: 17)
                                    Text(section.title).lineLimit(2).multilineTextAlignment(.leading)
                                    Spacer(minLength: 0)
                                }.contentShape(Rectangle())
                            }.buttonStyle(.plain).font(.system(size: 12)).foregroundStyle(WorkspaceStyle.muted)
                        }
                    }
                }
                VStack(alignment: .leading, spacing: 12) {
                    inspectorHeading("NOT AYARLARI")
                    Text("Toplantı türü").font(.system(size: 11)).foregroundStyle(WorkspaceStyle.muted)
                    Picker("Toplantı şablonu", selection: Binding(get: { meeting.template }, set: { store.setTemplate($0, for: meeting.id) })) {
                        ForEach(MeetingTemplate.allCases) { Text($0.label).tag($0) }
                    }.labelsHidden().frame(maxWidth: .infinity).disabled(store.workInProgress)
                    Text(meeting.template.description).font(.system(size: 10)).foregroundStyle(WorkspaceStyle.muted).fixedSize(horizontal: false, vertical: true)
                    Text("Özet dili").font(.system(size: 11)).foregroundStyle(WorkspaceStyle.muted)
                    Picker("Özet dili", selection: Binding(get: { meeting.outputLanguage }, set: { store.setOutputLanguage($0, for: meeting.id) })) {
                        Text("Türkçe").tag("Türkçe"); Text("English").tag("English")
                    }.labelsHidden().disabled(store.workInProgress)
                    if store.processingMode == .local {
                        Text("Kayıtta konuşulan dil").font(.system(size: 11)).foregroundStyle(WorkspaceStyle.muted)
                        Picker("Konuşma dili", selection: Binding(get: { store.speechLanguage(for: meeting) }, set: { store.setSpeechLanguage($0, for: meeting.id) })) {
                            Text("Türkçe").tag("Türkçe"); Text("English").tag("English")
                        }.labelsHidden().disabled(store.workInProgress)
                        Text("Konuşma dili otomatik algılanmaz. Özet dili ayrı seçilir.").font(.system(size: 10)).foregroundStyle(WorkspaceStyle.muted)
                    }
                }
                VStack(alignment: .leading, spacing: 9) {
                    Label("Senin arşivin, senin Mac’in.", systemImage: "internaldrive").font(.system(size: 11, weight: .medium))
                    Text("Ses saklama süresini Ayarlar’dan değiştirebilirsin. Transkript ve notlar korunur.").font(.system(size: 10)).foregroundStyle(WorkspaceStyle.muted)
                    Button("Arşivi aç") { store.revealArchive() }.buttonStyle(.plain).font(.system(size: 11)).foregroundStyle(WorkspaceStyle.accent)
                }.padding(14).background(WorkspaceStyle.elevated.opacity(0.55), in: RoundedRectangle(cornerRadius: 12))
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
        }.background(WorkspaceStyle.canvas)
    }

    private func inspectorHeading(_ value: String) -> some View {
        Text(value).font(.system(size: 9, weight: .semibold)).tracking(1.6).foregroundStyle(WorkspaceStyle.muted)
    }
    private func inspectorStat(_ name: String, value: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(value).font(.system(size: 20, weight: .semibold, design: .rounded)).monospacedDigit()
            Text(name).font(.system(size: 10)).foregroundStyle(WorkspaceStyle.muted)
        }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 24) {
            Image(systemName: "waveform.circle").font(.system(size: 58, weight: .light)).foregroundStyle(.tint)
            Text("Toplantıya odaklan.\nNotları sonra aç.").font(.system(size: 34, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            Text("Mac’inin mikrofonunu ve toplantı sesini birlikte kaydet.\nBitince transkripti, kararları ve sonraki adımları düzenle.")
                .font(.body).foregroundStyle(.secondary).lineSpacing(5)
            ViewThatFits(in: .horizontal) {
                HStack { welcomeActions }
                VStack(alignment: .leading, spacing: 10) { welcomeActions }
            }.disabled(store.workInProgress)
            Divider()
            Label("Ses kayıtları ve toplantı arşivi Mac’te saklanır.", systemImage: "internaldrive").font(.caption).foregroundStyle(.secondary)
            Label("Mac’te ücretsiz transkript ve özet · API anahtarı gerekmez", systemImage: "sparkles").font(.caption).foregroundStyle(.secondary)
            Text(store.localSummaryBackend == .qwen ? "Ücretsiz yerel transkript için macOS 26+ gerekir. Qwen özet modeli ilk kullanımda bir kez hazırlanır." : "Ücretsiz yerel transkript için macOS 26+ gerekir. Temel özet, Apple Intelligence açıkken çalışır.").font(.caption).foregroundStyle(.secondary)
        }.padding(55).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    @ViewBuilder private var welcomeActions: some View {
        Button { newMeeting() } label: { Label("Yeni toplantı", systemImage: "plus") }.buttonStyle(WorkspacePrimaryButtonStyle())
        Button("Kayıt içe aktar") { guard !store.workInProgress else { return }; store.importAudio() }.buttonStyle(WorkspaceQuietButtonStyle())
        Button("Transkript yapıştır") { guard !store.workInProgress else { return }; showImport = true }.buttonStyle(WorkspaceQuietButtonStyle())
    }

    private func detail(_ meeting: Meeting) -> some View {
        let participants = WorkspaceParticipants.entries(in: meeting)
        let identified = participants.filter(\.isIdentified).count
        return VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 15) {
                HStack(alignment: .top, spacing: 18) {
                    VStack(alignment: .leading, spacing: 10) {
                        Text("TOPLANTI / \(meeting.createdAt.formatted(.dateTime.day().month(.wide)).uppercased())")
                            .font(.system(size: 9, weight: .semibold)).tracking(1.8).foregroundStyle(WorkspaceStyle.muted)
                        TextField("Toplantı başlığı", text: Binding(get: { store.meetings.first { $0.id == meeting.id }?.title ?? "" }, set: { value in store.update(meeting.id) { $0.title = value } }))
                            .font(.system(size: 28, weight: .semibold)).textFieldStyle(.plain)
                            .foregroundStyle(WorkspaceStyle.ink)
                            .accessibilityLabel("Toplantı başlığı")
                        HStack(spacing: 12) {
                            Label(meeting.createdAt.formatted(date: .abbreviated, time: .shortened), systemImage: "calendar")
                            if meeting.duration > 0 { Label(timeLabel(meeting.duration), systemImage: "clock") }
                            if !participants.isEmpty {
                                Label(identified > 0 ? "\(identified) kişi eşleştirildi" : "\(participants.count) ses grubu", systemImage: "person.2")
                            }
                        }.font(.system(size: 11)).foregroundStyle(WorkspaceStyle.muted)
                    }
                    Spacer(minLength: 0)
                    Button { sharingMeeting = meeting } label: { Label("Paylaş", systemImage: "square.and.arrow.up") }
                        .buttonStyle(WorkspaceQuietButtonStyle())
                        .disabled(store.workInProgress || (meeting.segments.isEmpty && meeting.notes == nil))
                    Menu {
                        Button("Notları düzenle…") { editingMeeting = meeting }.disabled(meeting.notes == nil || store.workInProgress)
                        Button("Önceki nota dön") { store.restorePreviousNotes() }.disabled(!store.hasPreviousNotes || store.workInProgress)
                        Divider()
                        Button("Kayıt içe aktar…") { store.importAudio() }.disabled(store.workInProgress)
                        Button("Transkript yapıştır…") { guard !store.workInProgress else { return }; showImport = true }.disabled(store.workInProgress)
                        Button("Önceki döküme dön") { store.restorePreviousTranscript() }.disabled(!store.hasPreviousTranscript || store.workInProgress)
                        Divider()
                        Button("Yerel arşivi aç") { store.revealArchive() }
                    } label: { Image(systemName: "ellipsis").frame(width: 24, height: 34) }
                        .menuStyle(.borderlessButton).fixedSize().help("Diğer toplantı işlemleri")
                }
                HStack(spacing: 4) {
                    ForEach(DetailTab.allCases, id: \.self) { item in
                        Button {
                            withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.16)) { tab = item }
                        } label: {
                            Label(item.rawValue, systemImage: item.symbol)
                                .font(.system(size: 12, weight: tab == item ? .semibold : .medium))
                                .padding(.horizontal, 13).padding(.vertical, 9)
                                .foregroundStyle(tab == item ? WorkspaceStyle.accent : WorkspaceStyle.muted)
                                .background {
                                    if tab == item {
                                        if reduceMotion { RoundedRectangle(cornerRadius: 9).fill(WorkspaceStyle.elevated) }
                                        else { RoundedRectangle(cornerRadius: 9).fill(WorkspaceStyle.elevated).matchedGeometryEffect(id: "active-tab", in: tabHighlight) }
                                    }
                                }
                        }.buttonStyle(.plain).accessibilityAddTraits(tab == item ? .isSelected : [])
                            .keyboardShortcut(item.key, modifiers: .command)
                    }
                    Spacer(minLength: 6)
                    if !meeting.segments.isEmpty && !recorder.isRecording {
                        Button { createSummary() } label: { Label(summaryActionTitle(for: meeting), systemImage: "sparkles") }
                            .buttonStyle(WorkspacePrimaryButtonStyle()).disabled(store.workInProgress)
                    }
                }
            }.padding(.horizontal, 28).padding(.top, 25).padding(.bottom, 18)
            Rectangle().fill(WorkspaceStyle.border).frame(height: 1)
            if recorder.isRecording {
                recordingBar.padding(.horizontal, 26).padding(.top, 18)
            } else if store.selectedRecoveryURL != nil {
                HStack(spacing: 12) {
                    Label("Tamamlanmamış kayıt bulundu.", systemImage: "arrow.clockwise")
                    Spacer()
                    Button("Kaydı kurtar") { Task { await store.recoverRecording() } }
                        .buttonStyle(WorkspacePrimaryButtonStyle()).disabled(store.workInProgress)
                }.font(.callout).padding(16).background(WorkspaceStyle.elevated, in: RoundedRectangle(cornerRadius: 12)).padding(24)
            }
            Group {
                switch tab {
                case .overview: overview(meeting)
                case .transcript: transcript(meeting)
                case .personal:
                    VStack(alignment: .leading, spacing: 15) {
                        HStack {
                            Label("Aklında kalsın.", systemImage: "square.and.pencil").font(.system(size: 20, weight: .semibold))
                            Spacer()
                            WorkspaceBadge(text: "Yalnız sana ait", symbol: "lock")
                        }
                        Text("Toplantı sırasında ya da sonrasında kendi notlarını ekle. Değişikliklerin otomatik kaydedilir.")
                            .font(.callout).foregroundStyle(WorkspaceStyle.muted)
                        TextEditor(text: Binding(get: { store.meetings.first { $0.id == meeting.id }?.personalNotes ?? "" }, set: { value in store.update(meeting.id) { $0.personalNotes = value } }))
                            .font(.system(size: 14)).scrollContentBackground(.hidden).padding(16)
                            .background(WorkspaceStyle.surface, in: RoundedRectangle(cornerRadius: 14))
                            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(WorkspaceStyle.border))
                            .accessibilityLabel("Kendi notlarım")
                        Text("Bu alan otomatik özete dahil edilmez.").font(.caption).foregroundStyle(WorkspaceStyle.muted)
                    }.padding(28)
                }
            }.frame(maxWidth: .infinity, maxHeight: .infinity)
            if !recorder.isRecording && !store.playbackSources(for: meeting).isEmpty { playbackDock(meeting) }
            if meeting.audioDeletionPending == true && !recorder.isRecording {
                Label("Ses temizliği sonraki kontrolde yeniden denenecek.", systemImage: "clock.arrow.circlepath")
                    .font(.caption).foregroundStyle(WorkspaceStyle.muted).padding(12)
            } else if meeting.audioDeletedAt != nil && meeting.audioFileName == nil && !recorder.isRecording {
                Label("Saklama süresi dolan ses kaldırıldı. Transkript ve notlar korunuyor.", systemImage: "archivebox")
                    .font(.caption).foregroundStyle(WorkspaceStyle.muted).padding(12)
            }
        }
    }

    private func playbackDock(_ meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            HStack(spacing: 12) {
                Button { store.togglePlayback() } label: {
                    Image(systemName: store.isPlaying ? "pause.fill" : "play.fill")
                        .font(.system(size: 13, weight: .semibold)).frame(width: 38, height: 38)
                        .foregroundStyle(WorkspaceStyle.accent).background(WorkspaceStyle.elevated, in: Circle())
                }.buttonStyle(.plain).disabled(store.isBusy).accessibilityLabel(store.isPlaying ? "Sesi duraklat" : "Kaydı dinle")
                Text(timeLabel(store.playbackTime)).font(.system(size: 10).monospacedDigit()).foregroundStyle(WorkspaceStyle.muted)
                Slider(value: Binding(get: { store.playbackTime }, set: { store.seek($0) }), in: 0...max(1, store.playbackDuration > 0 ? store.playbackDuration : meeting.duration))
                    .labelsHidden().disabled(store.isBusy).accessibilityLabel("Kayıtta konum")
                Text(timeLabel(store.playbackDuration > 0 ? store.playbackDuration : meeting.duration)).font(.system(size: 10).monospacedDigit()).foregroundStyle(WorkspaceStyle.muted)
                Menu {
                    Picker("Dinlenecek ses", selection: $store.playbackSource) {
                        ForEach(store.playbackSources(for: meeting)) { Text($0.label).tag($0) }
                    }
                    if let microphone = meeting.microphoneDeviceName {
                        Text("\(microphone) · \(Int(RecorderMix.microphoneGain(meeting.microphoneGain ?? 1)))×")
                    }
                    Text("Ayrı sesler özgün seviyede saklanır.")
                    Text(store.processingMode == .local ? "Konuşma dili: \(store.speechLanguage(for: meeting)). İlk kullanımda ücretsiz dil modeli indirilebilir." : "Ses, transkript oluşturmak için OpenAI’a gönderilir; API kullanım ücreti oluşur.")
                    if let language = meeting.transcribedLanguage { Text("Son döküm dili: \(language)") }
                } label: { Image(systemName: "slider.horizontal.3").frame(width: 24) }
                    .fixedSize().menuStyle(.borderlessButton).disabled(store.isBusy).help("Ses kaynağı ve kayıt ayrıntıları")
                Button(meeting.segments.isEmpty ? "Transkript oluştur" : "Dökümü yenile") { store.transcribe(); tab = .transcript }
                    .buttonStyle(WorkspaceQuietButtonStyle()).disabled(store.workInProgress || !store.playbackSources(for: meeting).contains(.mixed))
            }
        }.padding(.horizontal, 24).padding(.vertical, 14).background(WorkspaceStyle.surface)
            .overlay(alignment: .top) { Rectangle().fill(WorkspaceStyle.border).frame(height: 1) }
    }

    private func recordingSetup(_ meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 20) {
            Image(systemName: "waveform.badge.mic").font(.system(size: 38, weight: .light)).foregroundStyle(WorkspaceStyle.accent)
                .padding(18).background(WorkspaceStyle.elevated, in: RoundedRectangle(cornerRadius: 20))
            Text("Sen konuşmaya odaklan.").font(.system(size: 25, weight: .semibold))
            Text("Mikrofonunu ve toplantı sesini birlikte kaydet.\nNotlar, kararlar ve sonraki adımlar bir araya gelsin.")
                .font(.system(size: 14)).lineSpacing(5).foregroundStyle(WorkspaceStyle.muted)
            VStack(alignment: .leading, spacing: 15) {
                HStack(spacing: 12) {
                    Button { Task { await store.startRecording() } } label: { Label("Kaydı başlat", systemImage: "record.circle") }
                        .buttonStyle(WorkspacePrimaryButtonStyle()).disabled(store.workInProgress)
                    Button { store.showMicrophoneCheck = true } label: { Label("Sesimi kontrol et", systemImage: "mic.badge.questionmark") }
                        .buttonStyle(WorkspaceQuietButtonStyle()).disabled(store.workInProgress)
                }
                Toggle("Bitince transkript ve özeti otomatik hazırla", isOn: $store.automaticLocalProcessing)
                    .font(.system(size: 12)).disabled(store.workInProgress || store.processingMode != .local)
                Text("\(store.selectedMicrophoneName) · \(store.speechLanguage(for: meeting))")
                    .font(.system(size: 10)).foregroundStyle(WorkspaceStyle.muted).lineLimit(2)
                DisclosureGroup("Mikrofon ve dil ayarları") {
                    VStack(alignment: .leading, spacing: 12) {
                MicrophoneControls(store: store)
                Picker("Konuşma dili", selection: Binding(get: { store.speechLanguage(for: meeting) }, set: { store.setSpeechLanguage($0, for: meeting.id) })) {
                    Text("Türkçe").tag("Türkçe"); Text("English").tag("English")
                }.frame(maxWidth: 240).disabled(store.workInProgress)
                    }.padding(.top, 12)
                }.font(.system(size: 12)).disabled(store.workInProgress)
                Text("Mac’te çalan diğer sesler de kayda girebilir. Kulaklık yankıyı azaltır.")
                    .font(.system(size: 10)).foregroundStyle(WorkspaceStyle.muted)
            }.padding(20).frame(maxWidth: .infinity, alignment: .leading)
                .background(WorkspaceStyle.surface, in: RoundedRectangle(cornerRadius: 16))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(WorkspaceStyle.border))
        }.padding(.vertical, 14)
    }

    private var recordingBar: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                WorkspaceBadge(text: recorder.isPaused ? "Duraklatıldı" : "Kayıtta", symbol: recorder.isPaused ? "pause.circle.fill" : "record.circle.fill", color: WorkspaceStyle.recording)
                Text(timeLabel(recorder.elapsed)).font(.system(size: 24, weight: .medium, design: .rounded)).monospacedDigit()
                    .contentTransition(.numericText()).animation(reduceMotion ? nil : .easeOut(duration: 0.2), value: Int(recorder.elapsed))
                Spacer()
                Button {
                    if recorder.isPaused { recorder.resume() } else { recorder.pause() }
                } label: { Image(systemName: recorder.isPaused ? "play.fill" : "pause.fill").frame(width: 18) }
                    .buttonStyle(WorkspaceQuietButtonStyle()).disabled(store.isBusy)
                    .accessibilityLabel(recorder.isPaused ? "Kayda devam et" : "Kaydı duraklat")
                Button { Task { await store.finishRecording() } } label: { Label("Bitir ve sakla", systemImage: "stop.fill") }
                    .buttonStyle(WorkspacePrimaryButtonStyle(tint: WorkspaceStyle.recording)).disabled(store.isBusy)
            }
            HStack {
                AudioLevelRibbon(microphone: recorder.microphoneLevel, system: recorder.systemLevel, paused: recorder.isPaused)
                Spacer()
                Text(store.recordingMeeting?.microphoneDeviceName ?? store.selectedMicrophoneName)
                    .font(.system(size: 10)).foregroundStyle(WorkspaceStyle.muted).lineLimit(1)
            }
            if !recorder.isPaused && recorder.elapsed >= 15 {
                if !recorder.microphoneReceivedSamples {
                    Label("Mikrofondan ses alınmadı. Kaydı bitirip mikrofonu kontrol et.", systemImage: "mic.slash")
                        .font(.caption).foregroundStyle(WorkspaceStyle.recording)
                } else if recorder.microphonePeakDBFS < -42 {
                    Label("Mikrofon sesi çok düşük. Konuşurken uyarı sürüyorsa giriş sesini kontrol et.", systemImage: "mic.badge.exclamationmark")
                        .font(.caption).foregroundStyle(WorkspaceStyle.recording)
                }
            }
        }.padding(18).background(WorkspaceStyle.surface, in: RoundedRectangle(cornerRadius: 16))
            .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(WorkspaceStyle.recording.opacity(0.3)))
    }

    private func overview(_ meeting: Meeting) -> some View {
        let presentation = MeetingNotesPresentation(meeting: meeting)
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 28) {
                    if let notes = meeting.notes {
                        HStack(spacing: 8) {
                            WorkspaceBadge(text: meeting.notesAreReviewed ? "Gözden geçirildi" : "Gözden geçirilmeyi bekliyor",
                                symbol: meeting.notesAreReviewed ? "checkmark.seal" : "eye", color: meeting.notesAreReviewed ? WorkspaceStyle.accent : WorkspaceStyle.muted)
                            Spacer()
                            Button { editingMeeting = meeting } label: { Image(systemName: "square.and.pencil") }
                                .buttonStyle(.plain).disabled(store.workInProgress).help("Notları düzenle").accessibilityLabel("Notları düzenle")
                            Button { store.markNotesReviewed(meeting.id) } label: { Image(systemName: meeting.reviewedAt == nil ? "checkmark.circle" : "checkmark.circle.fill") }
                                .buttonStyle(.plain).disabled(store.workInProgress || meeting.notesNeedRefresh)
                                .help(meeting.reviewedAt == nil ? "Gözden geçirildi olarak işaretle" : "Gözden geçirme işaretini kaldır")
                                .accessibilityLabel(meeting.reviewedAt == nil ? "Gözden geçirildi olarak işaretle" : "Gözden geçirme işaretini kaldır")
                        }
                        if meeting.notesNeedRefresh {
                            Label("Transkript, dil veya şablon değişti. Notları yenileyerek güncel tut; düzeltmelerin korunur.", systemImage: "arrow.clockwise")
                                .font(.system(size: 12)).foregroundStyle(WorkspaceStyle.recording).padding(14)
                                .background(WorkspaceStyle.recording.opacity(0.06), in: RoundedRectangle(cornerRadius: 10))
                        }
                        if let message = presentation.templateChangeMessage {
                            Label(message, systemImage: "rectangle.3.group").font(.system(size: 12)).foregroundStyle(WorkspaceStyle.recording)
                        }
                        ForEach(presentation.sections) { section in
                            VStack(alignment: .leading, spacing: 16) {
                                overviewSection(section, notes: notes, meeting: meeting)
                            }.id(section.id).frame(maxWidth: .infinity, alignment: .leading)
                        }
                        HStack(spacing: 7) {
                            Image(systemName: "sparkles")
                            Text("Otomatik hazırlanan notları ve kaynaklarını gözden geçir.")
                        }.font(.system(size: 10)).foregroundStyle(WorkspaceStyle.muted).padding(.top, 12)
                    } else if meeting.audioFileName == nil && meeting.segments.isEmpty && !recorder.isRecording {
                        recordingSetup(meeting)
                    } else {
                        VStack(alignment: .leading, spacing: 18) {
                            Image(systemName: recorder.isRecording ? "waveform" : "sparkles.rectangle.stack")
                                .font(.system(size: 42, weight: .ultraLight)).foregroundStyle(WorkspaceStyle.accent)
                                .padding(20).background(WorkspaceStyle.elevated, in: RoundedRectangle(cornerRadius: 20))
                            Text(recorder.isRecording ? "Konuşmalar birikiyor." : "Şimdi anlamlı bir nota dönüşsün.")
                                .font(.system(size: 25, weight: .semibold))
                            Text(recorder.isRecording ? "Kayıt devam ederken Notlarım’a istediğin noktaları ekleyebilirsin. Transkript ve özet, kayıt bittikten sonra hazırlanır." : meeting.segments.isEmpty ? "Önce alttaki oynatıcıdan transkripti oluştur. Ardından kısa özet, kararlar ve sonraki adımlar burada görünecek." : "Kısa bir genel bakış, konuşulan konular ve yapılacaklar tek bir yerde. İstersen önce Transkript sekmesinden konuşmacıları düzenle.")
                                .font(.system(size: 14)).lineSpacing(5).foregroundStyle(WorkspaceStyle.muted)
                            if !meeting.segments.isEmpty {
                                Button { createSummary() } label: { Label(summaryActionTitle(for: meeting), systemImage: "sparkles") }
                                    .buttonStyle(WorkspacePrimaryButtonStyle()).disabled(store.workInProgress)
                                Text(store.processingMode == .local ? store.localSummaryBackend.meetingDescription : "Özet hazırlanırken transkript OpenAI’a gönderilir.")
                                    .font(.system(size: 10)).foregroundStyle(WorkspaceStyle.muted)
                            }
                        }.padding(.vertical, 36)
                    }
                }.padding(32).frame(maxWidth: 800, alignment: .leading).frame(maxWidth: .infinity, alignment: .center)
            }
            .onChange(of: sectionFocus) { _, id in
                guard let id else { return }
                withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .top) }
            }
            .onAppear { if let sectionFocus { proxy.scrollTo(sectionFocus, anchor: .top) } }
        }
    }

    @ViewBuilder
    private func overviewSection(_ section: MeetingNotesPresentedSection, notes: MeetingNotes, meeting: Meeting) -> some View {
        switch section.kind {
        case .summary:
            sectionTitle(section.title, icon: "text.alignleft")
            Text(notes.summary).font(.system(size: 15)).lineSpacing(7).textSelection(.enabled)
        case .decisions:
            sectionTitle(section.title, icon: "checkmark.seal")
            ForEach(notes.decisions) { item in itemRow(item.text, evidence: item.evidence, meeting: meeting) }
        case .actions:
            sectionTitle(section.title, icon: "checklist")
            if notes.actions.isEmpty {
                Text("Bu toplantıda kaydedilmiş aksiyon bulunmuyor.").font(.callout).foregroundStyle(.secondary)
            }
            HStack(spacing: 12) {
                Text("\(notes.actions.filter { !meeting.completedActions.contains($0.id) }.count) açık · \(notes.actions.count) toplam")
                    .font(.system(size: 11)).foregroundStyle(WorkspaceStyle.muted)
                Spacer()
                Toggle("Yalnız açık görevler", isOn: $pendingActionsOnly).toggleStyle(.checkbox).font(.system(size: 11))
            }
            if pendingActionsOnly && !notes.actions.isEmpty && notes.actions.allSatisfy({ meeting.completedActions.contains($0.id) }) {
                Label("Tüm görevler tamamlandı.", systemImage: "checkmark.circle.fill").font(.callout).foregroundStyle(WorkspaceStyle.accent)
            }
            ForEach(notes.actions.filter { !pendingActionsOnly || !meeting.completedActions.contains($0.id) }) { action in
                HStack(alignment: .top, spacing: 12) {
                    Toggle("Tamamlandı", isOn: Binding(get: { store.meetings.first { $0.id == meeting.id }?.completedActions.contains(action.id) ?? false }, set: { done in store.update(meeting.id) { if done { $0.completedActions.insert(action.id) } else { $0.completedActions.remove(action.id) } } }))
                        .toggleStyle(.checkbox).labelsHidden().help("Aksiyonu tamamlandı olarak işaretle")
                        .accessibilityLabel("Tamamlandı: \(action.text)")
                    VStack(alignment: .leading, spacing: 8) {
                        Text(action.text).strikethrough(meeting.completedActions.contains(action.id)).textSelection(.enabled)
                        Text("Sorumlu: \(action.owner ?? "Belirtilmedi") · Tarih: \(action.due ?? "Belirtilmedi")").font(.caption).foregroundStyle(.secondary)
                        evidenceButtons(action.evidence, meeting: meeting)
                    }
                    Spacer(minLength: 0)
                }.padding(14).background(WorkspaceStyle.surface, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(WorkspaceStyle.border.opacity(0.65)))
            }
        case .questions:
            sectionTitle(section.title, icon: "questionmark.circle")
            ForEach(notes.questions) { item in itemRow(item.text, evidence: item.evidence, meeting: meeting) }
        case .ideas:
            sectionTitle(section.title, icon: "lightbulb")
            Text("Bu maddeler kesinleşmiş karar ya da atanmış görev değildir.").font(.caption).foregroundStyle(.secondary)
            ForEach(notes.ideas) { item in itemRow(item.text, evidence: item.evidence, meeting: meeting) }
        case .contexts:
            sectionTitle(section.title, icon: "text.bubble")
            if let message = section.emptyMessage {
                Text(message).font(.callout).foregroundStyle(.secondary)
            }
            ForEach(section.topics) { topic in
                VStack(alignment: .leading, spacing: 8) {
                    Text(topic.title).font(.headline)
                    Text(topic.text).font(.system(size: 14)).lineSpacing(5).textSelection(.enabled)
                    evidenceButtons(topic.evidence, meeting: meeting)
                }
            }
        }
    }

    private func transcript(_ meeting: Meeting) -> some View {
        let reviewSpeakerIDs = Set(SpeakerReviewPolicy.speakerIDs(in: meeting))
            .intersection(Set((meeting.speakerTurns ?? []).map(\.speakerID)))
        let displayNames = SpeakerPresentation.names(in: meeting)
        let visibleSegments = meeting.segments.filter {
            transcriptQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ||
            $0.text.localizedStandardContains(transcriptQuery) || (displayNames[$0.speaker] ?? $0.speaker).localizedStandardContains(transcriptQuery)
        }
        return VStack(spacing: 0) {
            if !meeting.segments.isEmpty {
                HStack(spacing: 10) {
                    Image(systemName: "magnifyingglass").foregroundStyle(WorkspaceStyle.muted)
                    TextField("Bu transkriptte ara…", text: $transcriptQuery).textFieldStyle(.plain)
                        .accessibilityLabel("Transkriptte metin veya konuşmacı ara")
                    Text("\(visibleSegments.count) bölüm").font(.system(size: 10)).foregroundStyle(WorkspaceStyle.muted)
                    if !transcriptQuery.isEmpty {
                        Button { transcriptQuery = "" } label: { Image(systemName: "xmark.circle.fill") }
                            .buttonStyle(.plain).accessibilityLabel("Transkript aramasını temizle")
                    }
                }.font(.system(size: 12)).padding(12).background(WorkspaceStyle.surface, in: RoundedRectangle(cornerRadius: 10))
                    .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(WorkspaceStyle.border)).padding(.horizontal, 28).padding(.top, 18)
            }
            ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 20) {
                    if meeting.segments.isEmpty {
                        Text(recorder.isRecording ? "Transkript, kayıt bittikten sonra hazırlanır." : "Henüz transkript yok.").foregroundStyle(.secondary).padding(.vertical, 30)
                    } else {
                        MeetingSpeakerControls(store: store, meeting: meeting) { speakerID in
                            reviewingSpeaker = SpeakerReviewRequest(meetingID: meeting.id, initialSpeakerID: speakerID)
                        }
                        if visibleSegments.isEmpty {
                            Label("Bu aramayla eşleşen konuşma bulunamadı.", systemImage: "text.magnifyingglass")
                                .font(.callout).foregroundStyle(WorkspaceStyle.muted).padding(.vertical, 18)
                        }
                        ForEach(visibleSegments) { segment in
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    WorkspaceAvatar(name: displayNames[segment.speaker] ?? segment.speaker, size: 28)
                                    Text(displayNames[segment.speaker] ?? segment.speaker).font(.callout.weight(.semibold))
                                    Button(timeLabel(segment.start)) { store.seek(segment.start) }.buttonStyle(.plain).foregroundStyle(.tint).font(.caption.monospacedDigit())
                                    Spacer()
                                    if reviewSpeakerIDs.contains(segment.speaker) {
                                        Button("Bu kim?") {
                                            reviewingSpeaker = SpeakerReviewRequest(meetingID: meeting.id, initialSpeakerID: segment.speaker)
                                        }.font(.caption).disabled(store.workInProgress)
                                    }
                                    Button(editSegment == segment.id ? "Bitti" : "Düzelt") { editSegment = editSegment == segment.id ? nil : segment.id }.font(.caption).disabled(store.isBusy)
                                }
                                if editSegment == segment.id {
                                    if meeting.speakerRecognitionEngine != nil {
                                        SpeakerAssignmentPicker(store: store, meeting: meeting, segment: segment)
                                    } else if meeting.transcriptionEngine == ProcessingMode.local.rawValue {
                                        TextField("Bu bölümün konuşmacısı (isteğe bağlı)", text: Binding(get: { store.meetings.first { $0.id == meeting.id }?.segments.first { $0.id == segment.id }?.speaker ?? segment.speaker }, set: { store.nameLocalSpeaker(meetingID: meeting.id, segmentID: segment.id, name: $0) })).textFieldStyle(.roundedBorder).disabled(store.workInProgress)
                                    }
                                    TextEditor(text: Binding(get: { store.meetings.first { $0.id == meeting.id }?.segments.first { $0.id == segment.id }?.text ?? segment.text }, set: { value in store.update(meeting.id) { item in if let index = item.segments.firstIndex(where: { $0.id == segment.id }) { item.segments[index].text = value; item.notesNeedRefresh = item.notes != nil } } }))
                                        .frame(minHeight: 90).font(.body).disabled(store.workInProgress)
                                } else { Text(segment.text).lineSpacing(4).textSelection(.enabled) }
                            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                                .background(focusID == segment.id ? WorkspaceStyle.accent.opacity(0.08) : WorkspaceStyle.surface, in: RoundedRectangle(cornerRadius: 10))
                                .id(segment.id)
                        }
                    }
                }.padding(28).frame(maxWidth: 900, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: focusID) { _, id in if let id { withAnimation(reduceMotion ? nil : .easeInOut(duration: 0.25)) { proxy.scrollTo(id, anchor: .center) } } }
            .onAppear { if let focusID { proxy.scrollTo(focusID, anchor: .center) } }
        }
        }
    }

    private func sectionTitle(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon).font(.system(size: 17, weight: .semibold)).foregroundStyle(WorkspaceStyle.ink)
    }
    private func itemRow(_ text: String, evidence: [String], meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(text).lineSpacing(4).textSelection(.enabled)
            evidenceButtons(evidence, meeting: meeting)
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(WorkspaceStyle.surface, in: RoundedRectangle(cornerRadius: 12))
                    .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(WorkspaceStyle.border.opacity(0.65)))
    }
    private func evidenceButtons(_ ids: [String], meeting: Meeting) -> some View {
        HStack(spacing: 8) {
            if ids.isEmpty {
                Text("Elle eklendi · kaynak bağlantısı yok").font(.system(size: 10)).foregroundStyle(WorkspaceStyle.muted)
            } else {
                Image(systemName: "link").font(.system(size: 9)).foregroundStyle(WorkspaceStyle.muted)
                ForEach(Array(ids.prefix(3)), id: \.self) { id in
                    if let segment = meeting.segments.first(where: { $0.id == id }) {
                        Button(timeLabel(segment.start)) { openSource(segment) }
                            .buttonStyle(.plain).font(.system(size: 10, weight: .medium).monospacedDigit())
                            .foregroundStyle(WorkspaceStyle.accent).padding(.horizontal, 7).padding(.vertical, 3)
                            .background(WorkspaceStyle.accent.opacity(0.07), in: Capsule())
                            .help("Transkriptte kaynağı aç: \(segment.text.prefix(120))")
                    }
                }
                if ids.count > 3 {
                    Menu {
                        ForEach(Array(ids.dropFirst(3)), id: \.self) { id in
                            if let segment = meeting.segments.first(where: { $0.id == id }) {
                                Button("\(timeLabel(segment.start)) · \(segment.text.prefix(70))") { openSource(segment) }
                            }
                        }
                    } label: { Text("+\(ids.count - 3) kaynak").font(.system(size: 10)) }
                        .menuStyle(.borderlessButton).fixedSize()
                }
            }
            if ids.contains(where: { id in !meeting.segments.contains { $0.id == id } }) {
                Image(systemName: "exclamationmark.triangle").foregroundStyle(WorkspaceStyle.recording)
                    .help("Önceki döküme ait kaynak · kontrol et").accessibilityLabel("Önceki döküme ait kaynak; kontrol et")
            }
            Spacer(minLength: 0)
        }
    }

    private func openSource(_ segment: TranscriptSegment) {
        transcriptQuery = ""; focusID = segment.id; tab = .transcript; store.seek(segment.start)
    }

}

struct MicrophoneControls: View {
    @ObservedObject var store: AppStore
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker("Mikrofon", selection: $store.microphoneDeviceID) {
                Text("Varsayılan: \(store.defaultMicrophoneName)").tag("")
                ForEach(store.microphoneDevices) { Text($0.name).tag($0.id) }
                if !store.microphoneDeviceID.isEmpty && !store.microphoneDevices.contains(where: { $0.id == store.microphoneDeviceID }) {
                    Text("Seçilen mikrofon bağlı değil").tag(store.microphoneDeviceID)
                }
            }.frame(maxWidth: .infinity)
            HStack(spacing: 12) {
            Picker("Sesimi güçlendir", selection: $store.microphoneGain) {
                Text("1×").tag(1.0)
                Text("2×").tag(2.0)
                Text("3×").tag(3.0)
                Text("4×").tag(4.0)
            }.frame(width: 170)
            Button { store.refreshMicrophones() } label: { Image(systemName: "arrow.clockwise") }.help("Mikrofon listesini yenile")
            }
        }.disabled(store.isBusy || store.recorder.isRecording)
            .onAppear { store.refreshMicrophones() }
    }
}

private struct ImportTranscriptView: View {
    @ObservedObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var title = ""
    @State private var text = ""
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Transkript yapıştır").font(.title2.weight(.semibold))
            TextField("Toplantı başlığı", text: $title).textFieldStyle(.roundedBorder)
            Text("Düz metni koruyarak içe aktarır. Zaman ve isim için: [00:14] Ahmet: Konuşma metni").font(.caption).foregroundStyle(.secondary)
            TextEditor(text: $text).font(.body).frame(minHeight: 260).border(Color.gray.opacity(0.2))
            HStack { Spacer(); Button("İptal") { dismiss() }; Button("İçe aktar") { guard !store.workInProgress else { return }; store.importTranscript(text: text, title: title); dismiss() }.buttonStyle(.borderedProminent).disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.workInProgress) }
        }.padding(28).frame(width: 650)
    }
}

struct UpdateSettingsView: View {
    @ObservedObject var updater: AppUpdater
    @State private var updateToken = ""
    @State private var error: String?
    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Uygulama güncellemeleri").font(.headline)
                Spacer()
                Text(updater.versionLabel).font(.caption).foregroundStyle(.secondary)
            }
            Text(updater.configurationMessage).font(.callout).foregroundStyle(.secondary)
            Toggle("Yeni sürümleri otomatik kontrol et", isOn: $updater.automaticallyChecksForUpdates)
                .disabled(!updater.isConfigured)
            Text("Güncellemeyi kurmadan önce onayın istenir. Kayıt veya not hazırlama bitene kadar uygulama yeniden başlatılmaz.")
                .font(.caption).foregroundStyle(.secondary)
            if updater.requiresAuthentication {
                SecureField(updater.hasUpdateToken ? "GitHub erişim anahtarını değiştir" : "GitHub erişim anahtarı", text: $updateToken)
                    .textFieldStyle(.roundedBorder)
                Text("Gizli sürümler için yalnız bu depoya erişen, Contents: Read-only yetkili bir GitHub anahtarı kullan. Anahtar Mac’in Anahtar Zinciri’nde saklanır.")
                    .font(.caption).foregroundStyle(.secondary)
                Link("GitHub erişim anahtarı oluştur", destination: URL(string: "https://github.com/settings/personal-access-tokens/new")!)
                HStack {
                    Button("Erişim anahtarını kaydet") {
                        do { try updater.saveUpdateToken(updateToken); updateToken = ""; error = nil }
                        catch { self.error = error.localizedDescription }
                    }.disabled(updateToken.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    if updater.hasUpdateToken {
                        Button("Erişim anahtarını kaldır") {
                            do { try updater.deleteUpdateToken(); error = nil }
                            catch { self.error = error.localizedDescription }
                        }
                    }
                }
            }
            Button("Güncellemeleri kontrol et…") { updater.checkForUpdates() }
                .disabled(!updater.canCheckForUpdates)
            if let error { Text(error).font(.caption).foregroundStyle(.red) }
        }
    }
}
