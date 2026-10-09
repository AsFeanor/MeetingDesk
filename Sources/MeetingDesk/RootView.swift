import SwiftUI
import AppKit

private enum DetailTab: String, CaseIterable { case overview = "Toplantı notu", transcript = "Transkript", personal = "Kendi notlarım" }

struct RootView: View {
    @ObservedObject var store: AppStore
    @ObservedObject var recorder: AudioRecorder
    @State private var query = ""
    @State private var tab: DetailTab = .overview
    @State private var showImport = false
    @State private var focusID: String?
    @State private var editSegment: String?
    @State private var sharingMeeting: Meeting?
    @State private var editingMeeting: Meeting?

    private var filtered: [Meeting] {
        store.meetings.filter { MeetingArchiveSearch.matches($0, query: query) }
    }

    var body: some View {
        NavigationSplitView {
            VStack(alignment: .leading, spacing: 16) {
                HStack {
                    Image(systemName: "waveform").font(.title2).foregroundStyle(.tint)
                    Text("Toplantı").font(.title2.weight(.semibold))
                    Spacer()
                }.padding(.top, 8)
                Text("Konuşulanları kaybetme.").font(.caption).foregroundStyle(.secondary)
                Button { _ = store.newMeeting(); tab = .overview } label: { Label("Yeni toplantı", systemImage: "plus") }
                    .buttonStyle(.borderedProminent).controlSize(.large)
                    .disabled(store.workInProgress)
                TextField("Arşivde ara", text: $query).textFieldStyle(.roundedBorder)
                    .help("Başlık, transkript, kararlar, görevler, kişi adları ve kendi notlarında ara")
                if !query.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    HStack {
                        Text("\(filtered.count) toplantı bulundu").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Temizle") { query = "" }.font(.caption).buttonStyle(.plain)
                    }
                }
                List(selection: $store.selectedID) {
                    ForEach(filtered) { meeting in
                        VStack(alignment: .leading, spacing: 5) {
                            Text(meeting.title).font(.body.weight(.medium)).lineLimit(2)
                            Text(meeting.createdAt.formatted(date: .abbreviated, time: .shortened)).font(.caption).foregroundStyle(.secondary)
                            if meeting.duration > 0 { Text(timeLabel(meeting.duration)).font(.caption2.monospacedDigit()).foregroundStyle(.secondary) }
                        }.padding(.vertical, 5).tag(meeting.id)
                    }
                }.listStyle(.sidebar).padding(.horizontal, -12)
                    .disabled(recorder.isRecording || store.hasPendingRecordingSession || store.showMicrophoneCheck)
                if filtered.isEmpty && !store.meetings.isEmpty {
                    Text("Aramana uygun toplantı yok.").font(.caption).foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
                HStack(spacing: 16) {
                    Button { store.showSettings = true } label: { Label("Ayarlar", systemImage: "gearshape") }
                    Button { store.revealArchive() } label: { Image(systemName: "folder") }.help("Yerel arşivi aç")
                }.buttonStyle(.plain).foregroundStyle(.secondary).font(.caption)
            }.padding(18).navigationSplitViewColumnWidth(min: 215, ideal: 250, max: 310)
        } detail: {
            VStack(spacing: 0) {
                if let meeting = store.selected { detail(meeting) }
                else { welcome }
                if !store.statusMessage.isEmpty || store.isBusy {
                    HStack(spacing: 10) {
                        if store.isBusy { ProgressView().controlSize(.small) }
                        Text(store.statusMessage).font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        if store.canCancelProcessing {
                            Button("İptal") { store.cancelProcessing() }.font(.caption)
                        }
                    }.padding(14).background(Color(nsColor: .controlBackgroundColor))
                }
            }
        }
        .sheet(isPresented: $store.showSettings) { SettingsView(store: store) }
        .sheet(isPresented: $showImport) { ImportTranscriptView(store: store) }
        .sheet(isPresented: $store.showMicrophoneCheck) { MicrophoneCheckView(store: store) }
        .sheet(item: $sharingMeeting) { SharingView(meeting: $0, notion: store.notion) }
        .sheet(item: $editingMeeting) { meeting in
            NotesEditingView(meeting: meeting) { notes in
                try store.saveEditedNotes(notes, meetingID: meeting.id)
            }
        }
        .alert("İşlem tamamlanamadı", isPresented: Binding(get: { store.errorMessage != nil }, set: { if !$0 { store.errorMessage = nil } })) {
            Button("Tamam") { store.errorMessage = nil }
        } message: { Text(store.errorMessage ?? "") }
        .onChange(of: store.selectedID) { _, _ in store.stopPlayback(); store.playbackSource = .mixed; focusID = nil; editSegment = nil }
    }

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 24) {
            Image(systemName: "waveform.circle").font(.system(size: 58, weight: .light)).foregroundStyle(.tint)
            Text("Toplantıya odaklan.\nNotları sonra aç.").font(.system(size: 34, weight: .semibold)).fixedSize(horizontal: false, vertical: true)
            Text("Mac’inin mikrofonunu ve toplantı sesini birlikte kaydet.\nBitince transkripti, kararları ve sonraki adımları düzenle.")
                .font(.body).foregroundStyle(.secondary).lineSpacing(5)
            HStack {
                Button { _ = store.newMeeting() } label: { Label("Yeni toplantı", systemImage: "plus") }.buttonStyle(.borderedProminent).controlSize(.large)
                Button("Kayıt içe aktar") { store.importAudio() }.controlSize(.large)
                Button("Transkript yapıştır") { showImport = true }.controlSize(.large)
            }
            Divider()
            Label("Ses kayıtları ve toplantı arşivi Mac’te saklanır.", systemImage: "internaldrive").font(.caption).foregroundStyle(.secondary)
            Label("Mac’te ücretsiz transkript ve özet · API anahtarı gerekmez", systemImage: "sparkles").font(.caption).foregroundStyle(.secondary)
            Text("Yerel mod için macOS 26+ gerekir. Özet, Apple Intelligence açıkken çalışır.").font(.caption).foregroundStyle(.secondary)
        }.padding(55).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
    }

    private func detail(_ meeting: Meeting) -> some View {
        VStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 14) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 8) {
                        TextField("Toplantı başlığı", text: Binding(get: { store.meetings.first { $0.id == meeting.id }?.title ?? "" }, set: { value in store.update(meeting.id) { $0.title = value } }))
                            .font(.title.weight(.semibold)).textFieldStyle(.plain)
                        Text("\(meeting.createdAt.formatted(date: .long, time: .shortened)) · \(meeting.source)\(meeting.duration > 0 ? " · " + timeLabel(meeting.duration) : "")")
                            .font(.caption).foregroundStyle(.secondary)
                    }
                    Spacer()
                    Button { sharingMeeting = meeting } label: { Label("Paylaş", systemImage: "square.and.arrow.up") }
                        .disabled(store.workInProgress || (meeting.segments.isEmpty && meeting.notes == nil))
                    Menu {
                        Button("Paylaş…") { sharingMeeting = meeting }.disabled(store.workInProgress)
                        Button("Notları düzenle…") { editingMeeting = meeting }.disabled(meeting.notes == nil || store.workInProgress)
                        Button("Önceki nota dön") { store.restorePreviousNotes() }.disabled(!store.hasPreviousNotes || store.workInProgress)
                        Button("Kayıt içe aktar…") { store.importAudio() }.disabled(store.workInProgress)
                        Button("Transkript yapıştır…") { showImport = true }.disabled(store.workInProgress)
                        Button("Önceki döküme dön") { store.restorePreviousTranscript() }.disabled(!store.hasPreviousTranscript || recorder.isRecording || store.isBusy)
                        Button("Yerel arşivi aç") { store.revealArchive() }
                    } label: { Image(systemName: "ellipsis.circle").font(.title2) }.menuStyle(.borderlessButton).fixedSize()
                }
                if store.processingMode == .local && (meeting.audioFileName != nil || meeting.segments.isEmpty) {
                    HStack(spacing: 12) {
                        Text("Konuşma dili").font(.callout.weight(.medium))
                        Picker("Konuşma dili", selection: Binding(get: { store.speechLanguage(for: meeting) }, set: { store.setSpeechLanguage($0, for: meeting.id) })) {
                            Text("Türkçe").tag("Türkçe")
                            Text("English").tag("English")
                        }.labelsHidden().frame(width: 135).disabled(store.workInProgress)
                        Text("Kayıtta konuşulan dili seç. Özet dili ayrı seçilir.").font(.caption).foregroundStyle(.secondary)
                        Spacer()
                    }
                }
                HStack(spacing: 12) {
                    Picker("Toplantı şablonu", selection: Binding(get: { meeting.template }, set: { template in
                        store.setTemplate(template, for: meeting.id)
                    })) {
                        ForEach(MeetingTemplate.allCases) { Text($0.label).tag($0) }
                    }.frame(width: 270).disabled(store.workInProgress)
                    Text(meeting.template.description).font(.caption).foregroundStyle(.secondary)
                    Spacer(minLength: 0)
                }
                if recorder.isRecording { recordingBar }
                else if store.selectedRecoveryURL != nil {
                    HStack(spacing: 14) {
                        Label("Bu toplantıda tamamlanmamış bir kayıt var.", systemImage: "arrow.clockwise")
                        Spacer()
                        Button("Kaydı kurtar") { Task { await store.recoverRecording() } }.buttonStyle(.borderedProminent).disabled(store.isBusy)
                    }.font(.callout).padding(14).background(Color.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 12))
                }
                else if meeting.audioFileName == nil && meeting.segments.isEmpty {
                    VStack(alignment: .leading, spacing: 12) {
                        MicrophoneControls(store: store)
                        HStack(spacing: 16) {
                            Button { Task { await store.startRecording() } } label: { Label("Kaydı başlat", systemImage: "record.circle") }
                                .buttonStyle(.borderedProminent).disabled(store.isBusy)
                            Button { store.showMicrophoneCheck = true } label: { Label("Sesimi kontrol et", systemImage: "mic.badge.questionmark") }
                                .disabled(store.workInProgress)
                            Text("Mikrofon + toplantı sesi").font(.caption).foregroundStyle(.secondary)
                        }
                        Toggle("Kaydı bitirince transkript ve özeti Mac’te hazırla", isOn: $store.automaticLocalProcessing)
                            .font(.caption).disabled(store.workInProgress || store.processingMode != .local)
                        if store.processingMode != .local { Text("Otomatik hazırlama yalnız ücretsiz yerel modda çalışır.").font(.caption2).foregroundStyle(.secondary) }
                    }
                } else if !store.playbackSources(for: meeting).isEmpty {
                    if let microphone = meeting.microphoneDeviceName {
                        Text("Kayıt mikrofonu: \(microphone) · Güçlendirme: \(Int(RecorderMix.microphoneGain(meeting.microphoneGain ?? 1)))×").font(.caption2).foregroundStyle(.secondary)
                    }
                    if store.playbackSources(for: meeting).count > 1 {
                        HStack {
                            Picker("Dinle", selection: $store.playbackSource) {
                                ForEach(store.playbackSources(for: meeting)) { Text($0.label).tag($0) }
                            }.frame(width: 260).disabled(store.isBusy)
                            Text("Ayrı sesler özgün seviyede saklanır; mikrofon güçlendirmesi birleşik kayıttadır.").font(.caption2).foregroundStyle(.secondary)
                        }
                    }
                    HStack(spacing: 12) {
                        Button { store.togglePlayback() } label: { Image(systemName: store.isPlaying ? "pause.fill" : "play.fill") }
                            .buttonStyle(.bordered).disabled(store.isBusy)
                        Text(timeLabel(store.playbackTime)).font(.caption.monospacedDigit())
                        Slider(value: Binding(get: { store.playbackTime }, set: { store.seek($0) }), in: 0...max(1, store.playbackDuration > 0 ? store.playbackDuration : meeting.duration))
                            .disabled(store.isBusy)
                        Text(timeLabel(store.playbackDuration > 0 ? store.playbackDuration : meeting.duration)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        Button(meeting.segments.isEmpty ? "Transkript oluştur" : "Dökümü yeniden oluştur") { store.transcribe(); tab = .transcript }
                                .buttonStyle(.borderedProminent).disabled(store.isBusy || !store.playbackSources(for: meeting).contains(.mixed))
                    }
                    if store.processingMode == .local {
                        Text("Ücretsiz yerel transkript · Konuşma dili: \(store.speechLanguage(for: meeting)). Dil otomatik algılanmaz. İlk kullanımda Apple’ın dil modeli indirilebilir.").font(.caption2).foregroundStyle(.secondary)
                        if !meeting.segments.isEmpty {
                            Text(meeting.transcribedLanguage.map { "Son dökümde kullanılan dil: \($0). Yeniden oluştururken önceki döküm saklanır." } ?? "Bu eski dökümde kullanılan dil kaydedilmemiş. Dil yanlışsa Türkçe seçip dökümü yeniden oluştur.").font(.caption2).foregroundStyle(.secondary)
                        }
                    } else {
                        Text("Ses kaydı OpenAI’a gönderilir; API kullanım ücreti hesabına yansır. Yeniden oluştururken önceki döküm saklanır.").font(.caption2).foregroundStyle(.secondary)
                    }
                }
                if meeting.audioDeletionPending == true && !recorder.isRecording {
                    Label("Ses temizliği henüz tamamlanmadı; kalan dosyalar sonraki kontrolde yeniden denenecek.", systemImage: "clock.arrow.circlepath")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if meeting.audioDeletedAt != nil && meeting.audioFileName == nil && !recorder.isRecording {
                    Label("Ses kaydı saklama süresi dolduğu için kaldırıldı. Transkript ve özetler korunur.", systemImage: "archivebox")
                        .font(.caption).foregroundStyle(.secondary)
                }
                if meeting.audioFileName == nil && meeting.audioDeletedAt == nil && meeting.segments.isEmpty && !recorder.isRecording {
                    Text("Mac’te çalan diğer uygulamaların sesi de kayda girebilir. Kulaklık, mikrofon yankısını azaltır.").font(.caption2).foregroundStyle(.secondary)
                }
                HStack {
                    Picker("Görünüm", selection: $tab) { ForEach(DetailTab.allCases, id: \.self) { Text($0.rawValue).tag($0) } }
                        .pickerStyle(.segmented).frame(maxWidth: 480)
                    Spacer()
                    if !meeting.segments.isEmpty && !recorder.isRecording {
                        Button(meeting.notes == nil ? "Özet oluştur" : "Özeti yenile") { store.summarize(); tab = .overview }
                            .disabled(store.isBusy)
                    }
                }
                if !meeting.segments.isEmpty && meeting.notes == nil && !recorder.isRecording {
                    Text(store.processingMode == .local ? "Ücretsiz yerel özet · Apple Intelligence kullanır; transkript Mac’te işlenir." : "Özet oluştururken transkript OpenAI’a gönderilir. Kaynak metin korunur.").font(.caption2).foregroundStyle(.secondary)
                }
            }.padding(24)
            Divider()
            switch tab {
            case .overview: overview(meeting)
            case .transcript: transcript(meeting)
            case .personal:
                VStack(alignment: .leading, spacing: 12) {
                    Text("Toplantı sırasında ya da sonrasında kendi notlarını ekle.").font(.callout).foregroundStyle(.secondary)
                    TextEditor(text: Binding(get: { store.meetings.first { $0.id == meeting.id }?.personalNotes ?? "" }, set: { value in store.update(meeting.id) { $0.personalNotes = value } }))
                        .font(.body).padding(10).background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
                    Text("Bu alan yerel saklanır; otomatik özet için gönderilmez.").font(.caption).foregroundStyle(.secondary)
                }.padding(24)
            }
        }
    }

    private var recordingBar: some View {
        VStack(alignment: .leading, spacing: 10) {
          HStack(spacing: 15) {
            Circle().fill(recorder.isPaused ? Color.orange : Color.red).frame(width: 9, height: 9)
            Text(recorder.isPaused ? "Duraklatıldı" : "Kaydediliyor").font(.callout.weight(.medium))
            Text(timeLabel(recorder.elapsed)).font(.body.monospacedDigit())
            Spacer()
            meter("Mikrofon", value: recorder.microphoneLevel)
            meter("Toplantı", value: recorder.systemLevel)
            Button(recorder.isPaused ? "Devam et" : "Duraklat") { if recorder.isPaused { recorder.resume() } else { recorder.pause() } }.disabled(store.isBusy)
            Button("Bitir ve sakla") { Task { await store.finishRecording() } }.buttonStyle(.borderedProminent).disabled(store.isBusy)
          }
          Text("\(store.recordingMeeting?.microphoneDeviceName ?? store.selectedMicrophoneName) · Mikrofon güçlendirmesi: \(Int(store.recordingMeeting?.microphoneGain ?? store.microphoneGain))×").font(.caption2).foregroundStyle(.secondary)
          if !recorder.isPaused && recorder.elapsed >= 15 {
              if !recorder.microphoneReceivedSamples {
                  Label("Henüz mikrofondan ses alınmadı. Kaydı bitirip seçili mikrofonu kontrol et.", systemImage: "mic.slash").font(.caption).foregroundStyle(.orange)
              } else if recorder.microphonePeakDBFS < -42 {
                  Label("Şimdiye kadar mikrofon sesi çok düşük. Konuşurken bu uyarı kalıyorsa mikrofonu veya giriş sesini kontrol et.", systemImage: "mic.badge.exclamationmark").font(.caption).foregroundStyle(.orange)
              }
          }
        }.padding(14).background(Color.red.opacity(0.045), in: RoundedRectangle(cornerRadius: 12))
    }

    private func meter(_ name: String, value: Double) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(name).font(.caption2).foregroundStyle(.secondary)
            ProgressView(value: max(0, min(1, value))).frame(width: 64)
        }.accessibilityLabel("\(name) ses seviyesi")
    }

    private func overview(_ meeting: Meeting) -> some View {
        let presentation = MeetingNotesPresentation(meeting: meeting)
        return ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                if !meeting.segments.isEmpty {
                    HStack(spacing: 10) {
                        Text("Özet dili").font(.caption).foregroundStyle(.secondary)
                        Picker("Özet dili", selection: Binding(get: { meeting.outputLanguage }, set: { language in store.setOutputLanguage(language, for: meeting.id) })) {
                            Text("Türkçe").tag("Türkçe"); Text("English").tag("English")
                        }.labelsHidden().frame(width: 130)
                        Spacer()
                    }.disabled(store.workInProgress)
                }
                if let notes = meeting.notes {
                    HStack {
                        if meeting.reviewedAt != nil {
                            Label("Kontrol edildi", systemImage: "checkmark.seal.fill").foregroundStyle(.tint)
                        } else { Label("Kontrol bekliyor", systemImage: "eye").foregroundStyle(.secondary) }
                        Spacer()
                        Button("Notları düzenle") { editingMeeting = meeting }.disabled(store.workInProgress)
                        Button(meeting.reviewedAt == nil ? "Kontrol edildi olarak işaretle" : "İşareti kaldır") { store.markNotesReviewed(meeting.id) }
                            .disabled(store.workInProgress || meeting.notesNeedRefresh)
                    }.font(.caption)
                    if meeting.notesNeedRefresh { Label("Transkript, özet dili veya şablon değişti. Özeti yenileyip kaynakları kontrol et; düzeltmelerin korunur.", systemImage: "arrow.clockwise").font(.callout).foregroundStyle(.orange) }
                    Text("Not düzeni: \(presentation.template.label)").font(.caption).foregroundStyle(.secondary)
                    if let message = presentation.templateChangeMessage {
                        Label(message, systemImage: "rectangle.3.group").font(.callout).foregroundStyle(.orange)
                    }
                    ForEach(presentation.sections) { section in
                        overviewSection(section, notes: notes, meeting: meeting)
                    }
                    Divider()
                    Text("Otomatik not, toplantıda söylenenleri aktarır. Konuşmacıları ve kararların kaynaklarını kontrol et.").font(.caption).foregroundStyle(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 16) {
                        Image(systemName: "doc.text").font(.largeTitle).foregroundStyle(.secondary)
                        Text("Toplantı notu burada oluşacak.").font(.title2.weight(.medium))
                        Text(recorder.isRecording ? "Kayıt sürerken ‘Kendi notlarım’ alanına istediğin noktaları ekleyebilirsin." : meeting.segments.isEmpty ? "Önce kaydı bitirip transkripti oluştur. Ardından kararları ve sonraki adımları çıkaralım." : "Özeti oluşturmadan önce konuşmacı adlarını düzeltebilirsin. Söylenmeyen sorumlu ve tarih alanları boş bırakılır.")
                            .foregroundStyle(.secondary).lineSpacing(4)
                        if !meeting.segments.isEmpty {
                            Button("Özet oluştur") { store.summarize() }.buttonStyle(.borderedProminent).disabled(store.isBusy)
                        }
                    }.padding(.vertical, 40)
                }
            }.padding(28).frame(maxWidth: 900, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    @ViewBuilder
    private func overviewSection(_ section: MeetingNotesPresentedSection, notes: MeetingNotes, meeting: Meeting) -> some View {
        switch section.kind {
        case .summary:
            sectionTitle(section.title, icon: "text.alignleft")
            Text(notes.summary).font(.body).lineSpacing(5).textSelection(.enabled)
        case .decisions:
            sectionTitle(section.title, icon: "checkmark.seal")
            ForEach(notes.decisions) { item in itemRow(item.text, evidence: item.evidence, meeting: meeting) }
        case .actions:
            sectionTitle(section.title, icon: "checklist")
            if notes.actions.isEmpty {
                Text("Bu toplantıda kaydedilmiş aksiyon bulunmuyor.").font(.callout).foregroundStyle(.secondary)
            }
            ForEach(notes.actions) { action in
                HStack(alignment: .top, spacing: 12) {
                    Toggle("Tamamlandı", isOn: Binding(get: { store.meetings.first { $0.id == meeting.id }?.completedActions.contains(action.id) ?? false }, set: { done in store.update(meeting.id) { if done { $0.completedActions.insert(action.id) } else { $0.completedActions.remove(action.id) } } }))
                        .toggleStyle(.checkbox).labelsHidden().help("Aksiyonu tamamlandı olarak işaretle")
                    VStack(alignment: .leading, spacing: 8) {
                        Text(action.text).strikethrough(meeting.completedActions.contains(action.id)).textSelection(.enabled)
                        Text("Sorumlu: \(action.owner ?? "Belirtilmedi") · Tarih: \(action.due ?? "Belirtilmedi")").font(.caption).foregroundStyle(.secondary)
                        evidenceButtons(action.evidence, meeting: meeting)
                    }
                    Spacer(minLength: 0)
                }.padding(14).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
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
                    Text(topic.text).textSelection(.enabled)
                    evidenceButtons(topic.evidence, meeting: meeting)
                }
            }
        }
    }

    private func transcript(_ meeting: Meeting) -> some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    if meeting.segments.isEmpty {
                        Text(recorder.isRecording ? "Transkript, kayıt bittikten sonra hazırlanır." : "Henüz transkript yok.").foregroundStyle(.secondary).padding(.vertical, 30)
                    } else {
                        if meeting.transcriptionEngine == ProcessingMode.local.rawValue {
                            Label(meeting.transcriptSourceSeparated == true ? "Mikrofon ve toplantı sesi ayrı çözüldü. Kaynak etiketleri kişi kimliği belirtmez; kulaklık yankıyı azaltır." : "Birleşik kayıt çözüldü. Yerel mod kişileri otomatik tanımaz; konuşmacı adlarını düzeltebilirsin.", systemImage: "person.crop.circle.badge.questionmark")
                                .font(.caption).foregroundStyle(.secondary)
                        }
                        if meeting.transcriptionEngine != ProcessingMode.local.rawValue { DisclosureGroup("Konuşmacı adlarını düzelt") {
                            VStack(spacing: 10) {
                                ForEach(meeting.speakers, id: \.self) { speaker in
                                    HStack {
                                        Text(speaker).font(.caption).foregroundStyle(.secondary).frame(width: 135, alignment: .leading)
                                        TextField("İsim", text: Binding(get: { store.meetings.first { $0.id == meeting.id }?.speakerNames[speaker] ?? speaker }, set: { name in store.update(meeting.id) { $0.speakerNames[speaker] = name; $0.notesNeedRefresh = $0.notes != nil } })).textFieldStyle(.roundedBorder)
                                    }
                                }
                                Text("Etiketler gerçek isimleri otomatik doğrulamaz. Bölüm etiketi varsa, aynı ses farklı bölümlerde ayrı görünebilir.").font(.caption).foregroundStyle(.secondary).frame(maxWidth: .infinity, alignment: .leading)
                            }.padding(.top, 12)
                        }.disabled(store.isBusy) }
                        ForEach(meeting.segments) { segment in
                            VStack(alignment: .leading, spacing: 10) {
                                HStack {
                                    Text(meeting.speakerName(segment.speaker)).font(.callout.weight(.semibold))
                                    Button(timeLabel(segment.start)) { store.seek(segment.start) }.buttonStyle(.plain).foregroundStyle(.tint).font(.caption.monospacedDigit())
                                    Spacer()
                                    Button(editSegment == segment.id ? "Bitti" : "Düzelt") { editSegment = editSegment == segment.id ? nil : segment.id }.font(.caption).disabled(store.isBusy)
                                }
                                if editSegment == segment.id {
                                    if meeting.transcriptionEngine == ProcessingMode.local.rawValue {
                                        TextField("Bu bölümün konuşmacısı (isteğe bağlı)", text: Binding(get: { store.meetings.first { $0.id == meeting.id }?.segments.first { $0.id == segment.id }?.speaker ?? segment.speaker }, set: { store.nameLocalSpeaker(meetingID: meeting.id, segmentID: segment.id, name: $0) })).textFieldStyle(.roundedBorder).disabled(store.workInProgress)
                                    }
                                    TextEditor(text: Binding(get: { store.meetings.first { $0.id == meeting.id }?.segments.first { $0.id == segment.id }?.text ?? segment.text }, set: { value in store.update(meeting.id) { item in if let index = item.segments.firstIndex(where: { $0.id == segment.id }) { item.segments[index].text = value; item.notesNeedRefresh = item.notes != nil } } }))
                                        .frame(minHeight: 90).font(.body).disabled(store.workInProgress)
                                } else { Text(segment.text).lineSpacing(4).textSelection(.enabled) }
                            }.padding(16).frame(maxWidth: .infinity, alignment: .leading)
                                .background(focusID == segment.id ? Color.accentColor.opacity(0.08) : Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
                                .id(segment.id)
                        }
                    }
                }.padding(28).frame(maxWidth: 900, alignment: .leading).frame(maxWidth: .infinity, alignment: .leading)
            }
            .onChange(of: focusID) { _, id in if let id { withAnimation { proxy.scrollTo(id, anchor: .center) } } }
            .onAppear { if let focusID { proxy.scrollTo(focusID, anchor: .center) } }
        }
    }

    private func sectionTitle(_ title: String, icon: String) -> some View {
        Label(title, systemImage: icon).font(.title3.weight(.semibold))
    }
    private func itemRow(_ text: String, evidence: [String], meeting: Meeting) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text(text).lineSpacing(4).textSelection(.enabled)
            evidenceButtons(evidence, meeting: meeting)
        }.padding(14).frame(maxWidth: .infinity, alignment: .leading).background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 10))
    }
    private func evidenceButtons(_ ids: [String], meeting: Meeting) -> some View {
        HStack(spacing: 10) {
            Text(ids.isEmpty ? "Elle eklendi · kaynak bağlantısı yok" : "Kaynak").font(.caption2).foregroundStyle(.secondary)
            if ids.contains(where: { id in !meeting.segments.contains { $0.id == id } }) {
                Text("Önceki döküme ait kaynak · kontrol et").font(.caption2).foregroundStyle(.orange)
            }
            ForEach(ids, id: \.self) { id in
                if let segment = meeting.segments.first(where: { $0.id == id }) {
                    Button(timeLabel(segment.start)) { focusID = id; tab = .transcript; store.seek(segment.start) }
                        .buttonStyle(.plain).font(.caption.monospacedDigit()).foregroundStyle(.tint)
                }
            }
        }
    }
}

private struct MicrophoneControls: View {
    @ObservedObject var store: AppStore
    var body: some View {
        HStack(spacing: 16) {
            Picker("Mikrofon", selection: $store.microphoneDeviceID) {
                Text("Varsayılan: \(store.defaultMicrophoneName)").tag("")
                ForEach(store.microphoneDevices) { Text($0.name).tag($0.id) }
                if !store.microphoneDeviceID.isEmpty && !store.microphoneDevices.contains(where: { $0.id == store.microphoneDeviceID }) {
                    Text("Seçilen mikrofon bağlı değil").tag(store.microphoneDeviceID)
                }
            }.frame(maxWidth: 330)
            Picker("Sesimi güçlendir", selection: $store.microphoneGain) {
                Text("1×").tag(1.0)
                Text("2×").tag(2.0)
                Text("3×").tag(3.0)
                Text("4×").tag(4.0)
            }.frame(width: 170)
            Button { store.refreshMicrophones() } label: { Image(systemName: "arrow.clockwise") }.help("Mikrofon listesini yenile")
        }.disabled(store.isBusy || store.recorder.isRecording)
            .onAppear { store.refreshMicrophones() }
    }
}

private struct SettingsView: View {
    @ObservedObject var store: AppStore
    @Environment(\.dismiss) private var dismiss
    @State private var key = ""
    @State private var error: String?
    @State private var transcriptionStatus = "Dil desteği kontrol ediliyor…"
    @State private var summaryStatus = ""
    var body: some View {
      ScrollView {
        VStack(alignment: .leading, spacing: 20) {
            Text("Ayarlar").font(.title2.weight(.semibold))
            MicrophoneControls(store: store)
            Button {
                dismiss()
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 350_000_000)
                    if !store.workInProgress { store.showMicrophoneCheck = true }
                }
            } label: { Label("10 saniyelik ses denemesi", systemImage: "mic") }
                .disabled(store.workInProgress)
            Text("Güçlendirme yalnız mikrofon sesine uygulanır. 2× ile başla; sesin hâlâ düşükse sonraki kayıtta 3× veya 4× seç. Kayıt sırasında mikrofon göstergesi konuşurken hareket etmeli.").font(.caption).foregroundStyle(.secondary)
            Divider()
            Picker("Transkript ve özet", selection: $store.processingMode) {
                ForEach(ProcessingMode.allCases) { Text($0.label).tag($0) }
            }.pickerStyle(.segmented).disabled(store.isBusy)
            if store.processingMode == .local {
                Label("API anahtarı ve kredi gerekmez.", systemImage: "checkmark.circle").font(.headline)
                Picker("Yeni toplantılar için konuşma dili", selection: $store.transcriptionLanguage) {
                    Text("Türkçe").tag("Türkçe")
                    Text("English").tag("English")
                }.disabled(store.isBusy)
                Text("Her toplantıda konuşma dilini kayıt ekranından değiştirebilirsin. Bu seçim özet dilini değiştirmez; dil otomatik algılanmaz.").font(.caption).foregroundStyle(.secondary)
                Text("Ses ve transkript Mac’te işlenir. İlk kullanımda Apple’ın ücretsiz dil modeli indirilebilir; sonraki kullanımlarda aynı model kullanılır.").font(.callout).foregroundStyle(.secondary).lineSpacing(4)
                VStack(alignment: .leading, spacing: 8) {
                    Text(transcriptionStatus)
                    Text(summaryStatus)
                }.font(.caption).foregroundStyle(.secondary)
                Text("Bu mod konuşmacıları otomatik ayırmaz. Uzun toplantıların özeti bölümler halinde hazırlanır; sonraki bölümde değişen kararları kaynak metinden kontrol et.").font(.caption).foregroundStyle(.secondary)
            } else {
                Text("OpenAI API anahtarı").font(.headline)
                SecureField(store.hasKey ? "Yeni anahtar girerek değiştirebilirsin" : "API anahtarını gir", text: $key).textFieldStyle(.roundedBorder)
                Text(store.hasKey ? "Bir anahtar Anahtar Zinciri’nde saklanıyor." : "Anahtar macOS Anahtar Zinciri’nde saklanır. Toplantı dosyalarına yazılmaz.").font(.caption).foregroundStyle(.secondary)
                Text("‘Transkript oluştur’ sesi; ‘Özet oluştur’ transkripti OpenAI’a gönderir. API ücreti OpenAI hesabından tahsil edilir.").font(.callout).foregroundStyle(.secondary).lineSpacing(4)
                Link("API anahtarı sayfasını aç", destination: URL(string: "https://platform.openai.com/api-keys")!)
            }
            Divider()
            Toggle("Kaydı bitirince transkript ve özeti Mac’te hazırla", isOn: $store.automaticLocalProcessing)
                .disabled(store.workInProgress || store.processingMode != .local)
            Text("Yalnız Mac’te ücretsiz modunda çalışır. Özet hazırlanamazsa oluşturulmuş transkript saklanır; işlemi iptal edebilirsin.").font(.caption).foregroundStyle(.secondary)
            Divider()
            Text("Toplantı hatırlatıcısı").font(.headline)
            Toggle("Toplantıda olabileceğimi algıla ve kaydı hatırlat", isOn: $store.meetingDetectionEnabled)
            Text("Zoom, Teams, Webex, FaceTime ve Slack’in mikrofon kullanımı kontrol edilir. Tarayıcıda mikrofon kullanımıyla birlikte görünür bir toplantı penceresi gerekir; mevcut ekran iznin yoksa bu kontrol yapılmaz. Ses dinlenmez veya kaydedilmez. Mikrofon kapalı görüşmeler algılanmayabilir.")
                .font(.caption).foregroundStyle(.secondary)
            Text("Hatırlatıcı kaydı kendiliğinden başlatmaz. ‘Kayda başla’ düğmesine bastığında normal kayıt izinleri ve seçili mikrofon kullanılır.")
                .font(.caption).foregroundStyle(.secondary)
            Toggle("Kayıt sırasında küçük kontrol kartını göster", isOn: $store.showRecordingPanel)
            Text("Karttan süreyi ve ses göstergelerini izleyebilir, duraklatabilir veya bitirip saklayabilirsin. Kartı gizlersen kayıt sürer; menü çubuğundan tekrar açabilirsin.")
                .font(.caption).foregroundStyle(.secondary)
            Divider()
            AudioRetentionSettingsView(store: store)
            Divider()
            NotionConnectionView(connection: store.notion)
            Divider()
            Text("Kayıt için macOS mikrofon ve ekran/sistem sesi kayıt izni ister. Uygulama ekran görüntüsü veya video saklamaz.").font(.callout).foregroundStyle(.secondary)
            Button("Yerel toplantı arşivini aç") { store.revealArchive() }
            Divider()
            UpdateSettingsView(updater: store.updates)
            if let error { Text(error).foregroundStyle(.red).font(.caption) }
            HStack {
                if store.hasKey { Button("Anahtarı kaldır") { do { try APIKeychain.delete(); store.refreshKey() } catch { self.error = error.localizedDescription } }.disabled(store.isBusy) }
                Spacer()
                Button("Kapat") { dismiss() }
                if store.processingMode == .openAI { Button("Anahtarı kaydet") {
                    do { try APIKeychain.save(key.trimmingCharacters(in: .whitespacesAndNewlines)); store.refreshKey(); dismiss() }
                    catch { self.error = error.localizedDescription }
                }.buttonStyle(.borderedProminent).disabled(key.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || store.isBusy) }
            }
        }.padding(30)
      }.frame(width: 600).frame(maxHeight: 720)
        .task(id: store.transcriptionLanguage) {
            summaryStatus = LocalSummaryService.availabilityDescription()
            transcriptionStatus = await LocalTranscriptionService.availabilityDescription(language: store.transcriptionLanguage)
        }
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
            HStack { Spacer(); Button("İptal") { dismiss() }; Button("İçe aktar") { store.importTranscript(text: text, title: title); dismiss() }.buttonStyle(.borderedProminent).disabled(text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty) }
        }.padding(28).frame(width: 650)
    }
}

private struct UpdateSettingsView: View {
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
