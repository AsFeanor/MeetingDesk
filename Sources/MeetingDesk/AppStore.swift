import AppKit
import AVFoundation
import Combine
import UniformTypeIdentifiers

@MainActor
final class AppStore: ObservableObject {
    @Published var meetings: [Meeting] = []
    @Published var selectedID: UUID?
    @Published var errorMessage: String?
    @Published var statusMessage = ""
    @Published var isBusy = false
    @Published var showSettings = false
    @Published var showMicrophoneCheck = false
    @Published var automaticLocalProcessing = UserDefaults.standard.bool(forKey: "meetingdesk.automaticLocalProcessing") {
        didSet { UserDefaults.standard.set(automaticLocalProcessing, forKey: "meetingdesk.automaticLocalProcessing") }
    }
    @Published var meetingDetectionEnabled = UserDefaults.standard.bool(forKey: "meetingdesk.meetingDetectionEnabled") {
        didSet {
            UserDefaults.standard.set(meetingDetectionEnabled, forKey: "meetingdesk.meetingDetectionEnabled")
            guard systemServicesEnabled else { return }
            if meetingDetectionEnabled { meetingDetector.start() } else { meetingDetector.stop() }
        }
    }
    @Published var showRecordingPanel = UserDefaults.standard.object(forKey: "meetingdesk.showRecordingPanel") as? Bool ?? true {
        didSet { UserDefaults.standard.set(showRecordingPanel, forKey: "meetingdesk.showRecordingPanel") }
    }
    @Published var hasKey = false
    @Published var processingMode: ProcessingMode = ProcessingMode(rawValue: UserDefaults.standard.string(forKey: "meetingdesk.processingMode") ?? "") ?? .local {
        didSet { UserDefaults.standard.set(processingMode.rawValue, forKey: "meetingdesk.processingMode") }
    }
    @Published var transcriptionLanguage = UserDefaults.standard.string(forKey: "meetingdesk.transcriptionLanguage") ?? "Türkçe" {
        didSet { UserDefaults.standard.set(transcriptionLanguage, forKey: "meetingdesk.transcriptionLanguage") }
    }
    @Published var playbackTime: Double = 0
    @Published var playbackDuration: Double = 0
    @Published var isPlaying = false
    @Published var playbackSource: PlaybackSource = .mixed {
        didSet { if playbackSource != oldValue { stopPlayback() } }
    }
    @Published var microphoneDeviceID = UserDefaults.standard.string(forKey: "meetingdesk.microphoneDeviceID") ?? "" {
        didSet { UserDefaults.standard.set(microphoneDeviceID, forKey: "meetingdesk.microphoneDeviceID") }
    }
    @Published var microphoneGain: Double = {
        let saved = UserDefaults.standard.double(forKey: "meetingdesk.microphoneGain")
        return saved.isFinite && (1...4).contains(saved) ? saved : 2
    }() {
        didSet { UserDefaults.standard.set(microphoneGain, forKey: "meetingdesk.microphoneGain") }
    }
    @Published private(set) var microphoneDevices: [MicrophoneDevice] = []
    @Published private(set) var defaultMicrophoneName = "Mac’in varsayılan mikrofonu"
    let recorder = AudioRecorder()
    let updates = AppUpdater()
    let notion: NotionConnection
    let meetingDetector = MeetingDetector()
    let systemServicesEnabled: Bool
    private var updateSubscriptions: Set<AnyCancellable> = []
    let library: MeetingLibrary
    private var recordingID: UUID?
    private var player: AVAudioPlayer?
    private var playbackID: UUID?
    private var timer: Timer?
    private var processingTask: Task<Void, Never>?
    private var isFinishingRecording = false

    var hasPendingRecordingSession: Bool { recordingID != nil }
    var workInProgress: Bool { isBusy || recorder.isRecording || showMicrophoneCheck || hasPendingRecordingSession || notion.isExporting }
    var selected: Meeting? { meetings.first { $0.id == selectedID } }
    var recordingMeeting: Meeting? { meetings.first { $0.id == recordingID } }
    var hasPreviousTranscript: Bool { selected.map { library.hasTranscriptVersion(for: $0.id) } ?? false }
    var hasPreviousNotes: Bool { selected.map { library.hasNotesVersion(for: $0.id) } ?? false }
    var selectedMicrophoneName: String {
        microphoneDeviceID.isEmpty ? defaultMicrophoneName : microphoneDevices.first { $0.id == microphoneDeviceID }?.name ?? "Seçilen mikrofon bağlı değil"
    }
    func refreshMicrophones() {
        microphoneDevices = MicrophoneDevice.available()
        defaultMicrophoneName = AVCaptureDevice.default(for: .audio)?.localizedName ?? "Mac’in varsayılan mikrofonu"
    }
    func playbackSources(for meeting: Meeting) -> [PlaybackSource] {
        PlaybackSource.allCases.filter { library.audioURL(for: meeting, source: $0) != nil }
    }
    func speechLanguage(for meeting: Meeting) -> String { meeting.speechLanguage ?? transcriptionLanguage }
    func setSpeechLanguage(_ language: String, for id: UUID) {
        update(id) { $0.speechLanguage = language }
    }
    func setTemplate(_ template: MeetingTemplate, for id: UUID) {
        guard !workInProgress, let meeting = meetings.first(where: { $0.id == id }), meeting.template != template else { return }
        update(id) { $0.templateRawValue = template.rawValue; $0.notesNeedRefresh = $0.notes != nil }
    }
    func setOutputLanguage(_ language: String, for id: UUID) {
        guard !workInProgress, let meeting = meetings.first(where: { $0.id == id }), meeting.outputLanguage != language else { return }
        update(id) { $0.outputLanguage = language; $0.notesNeedRefresh = $0.notes != nil }
    }
    var selectedRecoveryURL: URL? {
        guard let selected else { return nil }
        let folder = library.directory(for: selected.id)
        let destination = folder.appendingPathComponent("recording.m4a")
        let manifest = folder.appendingPathComponent(".recording-recovery/recovery.json")
        guard FileManager.default.fileExists(atPath: manifest.path) else { return nil }
        if FileManager.default.fileExists(atPath: destination.path) {
            // A crash after the last file move still needs receipt-checked cleanup.
            guard let recovery = try? PCMRecordingSession(recoverDestination: destination),
                  (try? recovery.ownsPublishedFile(destination)) == true else { return nil }
        }
        return destination
    }

    init(root: URL? = nil, initializeSystemServices: Bool = true, notionConnection: NotionConnection? = nil) {
        #if DEBUG
        let previewRoot = (Bundle.main.object(forInfoDictionaryKey: "MeetingDeskPreviewArchive") as? String).map { URL(fileURLWithPath: $0, isDirectory: true) }
        #else
        let previewRoot: URL? = nil
        #endif
        systemServicesEnabled = initializeSystemServices && previewRoot == nil
        notion = notionConnection ?? NotionConnection(loadCredentials: systemServicesEnabled)
        library = MeetingLibrary(root: root ?? previewRoot)
        reload()
        if initializeSystemServices && previewRoot == nil { refreshKey(); refreshMicrophones() }
        Publishers.CombineLatest4(recorder.$isRecording, $isBusy, $showMicrophoneCheck, notion.$isExporting)
            .map { recording, busy, checking, exporting in recording || busy || checking || exporting }
            .removeDuplicates()
            .sink { [weak self] busy in
                guard let self else { return }
                let active = busy || self.hasPendingRecordingSession
                self.updates.setWorkInProgress(active)
                self.meetingDetector.setSuspended(active)
            }
            .store(in: &updateSubscriptions)
        notion.objectWillChange
            .sink { [weak self] _ in self?.objectWillChange.send() }
            .store(in: &updateSubscriptions)
        if systemServicesEnabled && meetingDetectionEnabled { meetingDetector.start() }
        recorder.onFailure = { [weak self] error in
            guard let self else { return }
            self.errorMessage = "Kayıt kesildi: \(error.localizedDescription). Kaydedilmiş bölüm korunuyor."
            Task { await self.finishRecording(interrupted: true) }
        }
        timer = Timer.scheduledTimer(withTimeInterval: 0.2, repeats: true) { [weak self] _ in
            Task { @MainActor in
                guard let self, let player = self.player else { return }
                self.playbackTime = player.currentTime
                self.isPlaying = player.isPlaying
            }
        }
    }

    func reload() {
        do {
            let loaded = try library.load()
            meetings = loaded.meetings
            selectedID = meetings.first?.id
            if loaded.unreadable > 0 { errorMessage = "\(loaded.unreadable) toplantı dosyası okunamadı. Dosyalar arşivde korunuyor." }
        } catch { errorMessage = error.localizedDescription }
    }

    func refreshKey() { hasKey = ((try? APIKeychain.load()) ?? "").isEmpty == false }

    @discardableResult func newMeeting() -> Meeting {
        stopPlayback()
        let meeting = Meeting(title: "Yeni toplantı", speechLanguage: transcriptionLanguage)
        meetings.insert(meeting, at: 0)
        selectedID = meeting.id
        persist(meeting)
        return meeting
    }

    @discardableResult func update(_ id: UUID, _ change: (inout Meeting) -> Void) -> Bool {
        guard let index = meetings.firstIndex(where: { $0.id == id }) else { return false }
        var candidate = meetings[index]
        change(&candidate)
        if candidate.segments != meetings[index].segments || candidate.speakerNames != meetings[index].speakerNames ||
            candidate.notes != meetings[index].notes || candidate.notesNeedRefresh || candidate.templateRawValue != meetings[index].templateRawValue {
            candidate.reviewedAt = nil
        }
        do {
            try library.save(candidate)
            meetings[index] = candidate
            return true
        } catch {
            errorMessage = "Kaydedilemedi: \(error.localizedDescription)"
            return false
        }
    }

    func nameLocalSpeaker(meetingID: UUID, segmentID: String, name: String) {
        let clean = name.trimmingCharacters(in: .whitespacesAndNewlines)
        update(meetingID) { meeting in
            guard let index = meeting.segments.firstIndex(where: { $0.id == segmentID }) else { return }
            meeting.segments[index].speaker = clean.isEmpty ? "Konuşma" : clean
            if !clean.isEmpty, clean != "Konuşma" { meeting.speakerNames[clean] = clean }
            meeting.notesNeedRefresh = meeting.notes != nil
        }
    }

    private func persist(_ meeting: Meeting) {
        do { try library.save(meeting) }
        catch { errorMessage = "Kaydedilemedi: \(error.localizedDescription)" }
    }

    func startRecording() async {
        guard !workInProgress else { return }
        stopPlayback()
        meetingDetector.dismissCurrentMeeting()
        let meeting = selected.flatMap { $0.audioFileName == nil && $0.segments.isEmpty ? $0 : nil } ?? newMeeting()
        selectedID = meeting.id
        recordingID = meeting.id
        isBusy = true
        statusMessage = "Ses kaydı hazırlanıyor…"
        do {
            refreshMicrophones()
            let deviceID = microphoneDeviceID.isEmpty ? AVCaptureDevice.default(for: .audio)?.uniqueID : microphoneDeviceID
            let deviceName = selectedMicrophoneName
            let gain = microphoneGain
            // Persist the destination before capture so an interrupted session stays discoverable.
            guard update(meeting.id, {
                $0.audioFileName = "recording.m4a"; $0.source = "Mac kaydı"
                $0.microphoneDeviceID = deviceID; $0.microphoneDeviceName = deviceName; $0.microphoneGain = gain
            }) else { throw MeetingError.message("Toplantı kaydedilemediği için ses kaydı başlatılmadı.") }
            let url = library.directory(for: meeting.id).appendingPathComponent("recording.m4a")
            try await recorder.start(url: url, microphoneDeviceID: deviceID, microphoneGain: gain)
            statusMessage = "Kayıt Mac’te saklanıyor"
        } catch {
            update(meeting.id) {
                $0.audioFileName = nil; $0.microphoneDeviceID = nil; $0.microphoneDeviceName = nil; $0.microphoneGain = nil
            }
            recordingID = nil
            errorMessage = error.localizedDescription
            statusMessage = ""
        }
        isBusy = false
    }

    @discardableResult func finishRecording(interrupted: Bool = false, allowAutomaticProcessing: Bool = true) async -> Bool {
        guard let id = recordingID, !isFinishingRecording else { return false }
        isFinishingRecording = true
        isBusy = true
        statusMessage = "Ses kaydı kaydediliyor…"
        var saved = false
        do {
            let duration = try await recorder.stop()
            saved = update(id) { $0.duration = duration }
            statusMessage = saved ? "Kayıt hazır. Transkripti oluşturabilir veya yalnız mikrofonu dinleyebilirsin." : "Ses kaydı korundu; toplantı bilgileri kaydedilemedi."
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "Kayıt tamamlanamadı; kurtarma dosyaları toplantı klasöründe korunuyor."
        }
        recordingID = nil
        isFinishingRecording = false
        if AutomaticProcessingPolicy.shouldRun(enabled: automaticLocalProcessing && allowAutomaticProcessing,
                                               mode: processingMode, saved: saved, interrupted: interrupted) {
            runProcessing(message: "Kayıt hazır. Transkript ve özet Mac’te hazırlanıyor…") { [weak self] in
                guard let self else { return }
                try await MeetingWorkflowRunner.run(meetingID: id, transcribe: { id in
                    self.statusMessage = "Transkript Mac’te hazırlanıyor…"
                    try await self.transcribeMeeting(id, mode: .local)
                }, summarize: { id in
                    self.statusMessage = "Toplantı notları Mac’te hazırlanıyor…"
                    try await self.summarizeMeeting(id, mode: .local)
                })
                self.statusMessage = "Transkript ve toplantı notu hazır. Kaynakları kontrol edip paylaşabilirsin."
            }
        } else { isBusy = false }
        return saved
    }

    func transcribe() {
        guard let meeting = selected, meeting.audioFileName != nil, !workInProgress else { return }
        let mode = processingMode
        runProcessing(message: mode == .local ? "Transkript Mac’te hazırlanıyor. İlk kullanımda dil modeli indirilebilir…" : "Konuşmacılar ve transkript hazırlanıyor…") { [weak self] in
            try await self?.transcribeMeeting(meeting.id, mode: mode)
        }
    }

    private func transcribeMeeting(_ id: UUID, mode: ProcessingMode) async throws {
        guard let meeting = meetings.first(where: { $0.id == id }), let audioURL = library.audioURL(for: meeting) else {
            throw MeetingError.message("Toplantının ses kaydı bulunamadı.")
        }
        let language = speechLanguage(for: meeting)
        let segments: [TranscriptSegment]
        var separated = false
        var notice: String?
        if mode == .local {
            let result = try await ChannelTranscriptionService().transcribe(mixedURL: audioURL,
                microphoneURL: library.audioURL(for: meeting, source: .microphone),
                systemURL: library.audioURL(for: meeting, source: .system), language: language, microphoneGain: meeting.microphoneGain ?? 1)
            segments = result.segments; separated = result.sourceSeparated; notice = result.notice
        } else {
            guard let service = selectedOpenAIService() else { throw MeetingError.message("OpenAI modu için API anahtarı gerekiyor.") }
            segments = try await service.transcribe(audioURL: audioURL)
        }
        try Task.checkCancellation()
        if let current = meetings.first(where: { $0.id == id }), !current.segments.isEmpty { try library.saveTranscriptVersion(current) }
        guard update(id, {
            $0.segments = segments; $0.notesNeedRefresh = $0.notes != nil
            $0.transcriptionEngine = mode.rawValue
            $0.transcribedLanguage = mode == .local ? language : nil
            $0.speechLanguage = language; $0.speakerNames = [:]
            $0.transcriptSourceSeparated = separated
        }) else { throw MeetingError.message("Transkript kaydedilemedi. Önceki döküm ve ses kaydı korunuyor.") }
        statusMessage = notice ?? (mode == .local ? "Yerel transkript hazır. Mikrofon ve toplantı sesi kaynak etiketleri kişi kimliği değildir." : "Transkript hazır. Konuşmacı adlarını kontrol edebilirsin.")
    }

    func restorePreviousTranscript() {
        guard let meeting = selected, !workInProgress else { return }
        do {
            guard let previous = try library.latestTranscriptVersion(for: meeting.id) else { return }
            try library.saveTranscriptVersion(meeting)
            guard update(meeting.id, {
                $0.segments = previous.segments
                $0.speakerNames = previous.speakerNames
                $0.transcriptionEngine = previous.transcriptionEngine
                $0.transcribedLanguage = previous.transcribedLanguage
                $0.notes = previous.notes
                $0.notesEngine = previous.notesEngine
                $0.notesTemplateRawValue = previous.notesTemplateRawValue
                $0.notesNeedRefresh = previous.notesNeedRefresh || previous.notesTemplate != meeting.template || previous.outputLanguage != meeting.outputLanguage
                $0.completedActions = previous.completedActions
                $0.notesManualEdits = previous.notesManualEdits
                $0.reviewedAt = $0.notesNeedRefresh ? nil : previous.reviewedAt
                $0.transcriptSourceSeparated = previous.transcriptSourceSeparated
            }) else { throw MeetingError.message("Önceki döküm kaydedilemedi; mevcut döküm korundu.") }
            statusMessage = "Önceki döküm geri getirildi. Ses kaydı ve kişisel notlar korundu."
        } catch { errorMessage = error.localizedDescription }
    }

    func recoverRecording() async {
        guard let meeting = selected, let destination = selectedRecoveryURL, !workInProgress else { return }
        isBusy = true
        statusMessage = "Kesilen kayıt kurtarılıyor…"
        defer { isBusy = false }
        do {
            let duration = try await AudioRecorder.recover(url: destination)
            guard update(meeting.id, { $0.audioFileName = "recording.m4a"; $0.duration = duration; $0.source = "Mac kaydı" }) else {
                throw MeetingError.message("Ses dosyası kurtarıldı, ancak toplantı bilgileri kaydedilemedi. Ses kaydı korundu.")
            }
            statusMessage = "Kayıt kurtarıldı. Transkripti oluşturabilirsin."
        } catch { errorMessage = error.localizedDescription; statusMessage = "Kurtarma tamamlanamadı; ham kayıt korunuyor." }
    }

    func summarize() {
        guard let meeting = selected, !meeting.segments.isEmpty, !workInProgress else { return }
        let mode = processingMode
        runProcessing(message: mode == .local ? "Toplantı notları Mac’te hazırlanıyor…" : "Kararlar, aksiyonlar ve açık sorular hazırlanıyor…") { [weak self] in
            try await self?.summarizeMeeting(meeting.id, mode: mode)
        }
    }

    private func summarizeMeeting(_ id: UUID, mode: ProcessingMode) async throws {
        guard let meeting = meetings.first(where: { $0.id == id }), !meeting.segments.isEmpty else {
            throw MeetingError.message("Özet için önce transkript oluştur.")
        }
        let notes: MeetingNotes
        if mode == .local { notes = try await LocalSummaryService().summarize(meeting: meeting) }
        else {
            guard let service = selectedOpenAIService() else { throw MeetingError.message("OpenAI modu için API anahtarı gerekiyor.") }
            notes = try await service.summarize(meeting: meeting)
        }
        try Task.checkCancellation()
        try commitGeneratedNotes(notes, sourceMeeting: meeting, engine: mode.rawValue)
        statusMessage = "Toplantı notu hazır. Düzeltmeler ve tamamlanan görevler korundu; kaynakları kontrol edebilirsin."
    }

    /// Commit only against the input that was actually summarized. UI disabling
    /// alone cannot protect an asynchronous result from source/config changes.
    func commitGeneratedNotes(_ notes: MeetingNotes, sourceMeeting: Meeting, engine: String) throws {
        guard let current = meetings.first(where: { $0.id == sourceMeeting.id }) else {
            throw MeetingError.message("Özetin toplantısı bulunamadı; önceki notlar korundu.")
        }
        guard current.template == sourceMeeting.template,
              current.outputLanguage == sourceMeeting.outputLanguage,
              current.segments == sourceMeeting.segments,
              current.speakerNames == sourceMeeting.speakerNames,
              current.title == sourceMeeting.title else {
            throw MeetingError.message("Özet hazırlanırken transkript, başlık, özet dili veya şablon değişti. Eski ayarlara göre hazırlanan özet kaydedilmedi; yeniden oluşturabilirsin.")
        }
        if current.notes != nil { try library.saveNotesVersion(current) }
        var reconciled = NotesRevisionPolicy.reconcileGenerated(notes, into: current, engine: engine)
        reconciled.notesTemplateRawValue = sourceMeeting.template.rawValue
        guard update(current.id, { $0 = reconciled }) else {
            throw MeetingError.message("Toplantı notları kaydedilemedi. Önceki notlar korunuyor.")
        }
    }

    func saveEditedNotes(_ notes: MeetingNotes, meetingID: UUID) throws {
        guard !workInProgress, let meeting = meetings.first(where: { $0.id == meetingID }) else {
            throw MeetingError.message("Devam eden işlem bitince notları düzenleyebilirsin.")
        }
        if meeting.notes != nil { try library.saveNotesVersion(meeting) }
        let edited = NotesRevisionPolicy.applyEdits(to: meeting, editedNotes: notes)
        guard update(meetingID, { $0 = edited }) else { throw MeetingError.message("Notlar kaydedilemedi. Düzeltmelerini tekrar kaydetmeyi dene.") }
        statusMessage = "Düzeltmeler kaydedildi. Özeti yenilerken korunacak."
    }

    func markNotesReviewed(_ id: UUID) {
        guard !workInProgress else { return }
        update(id) { meeting in
            if meeting.reviewedAt == nil { meeting = NotesRevisionPolicy.markReviewed(meeting) }
            else { meeting.reviewedAt = nil }
        }
    }

    func restorePreviousNotes() {
        guard let meeting = selected, !workInProgress else { return }
        do {
            guard let previous = try library.latestNotesVersion(for: meeting.id) else { return }
            try library.saveNotesVersion(meeting)
            guard update(meeting.id, {
                $0.notes = previous.notes; $0.completedActions = previous.completedActions
                $0.notesNeedRefresh = previous.notesNeedRefresh || !previous.matchesTranscript(of: meeting); $0.notesEngine = previous.notesEngine
                $0.notesManualEdits = previous.notesManualEdits; $0.reviewedAt = previous.matchesTranscript(of: meeting) ? previous.reviewedAt : nil
                $0.templateRawValue = previous.templateRawValue; $0.notesTemplateRawValue = previous.notesTemplateRawValue; $0.outputLanguage = previous.outputLanguage ?? $0.outputLanguage
            }) else { throw MeetingError.message("Önceki not sürümü kaydedilemedi; mevcut notlar korundu.") }
            statusMessage = "Önceki toplantı notu geri getirildi. Transkript ve ses kaydı korundu."
        } catch { errorMessage = error.localizedDescription }
    }

    private func selectedOpenAIService() -> OpenAIService? {
        do {
            guard let key = try APIKeychain.load(), !key.isEmpty else { showSettings = true; return nil }
            return OpenAIService(apiKey: key)
        } catch { errorMessage = error.localizedDescription }
        return nil
    }

    private func runProcessing(message: String, operation: @escaping () async throws -> Void) {
        isBusy = true
        statusMessage = message
        processingTask = Task {
            defer { isBusy = false; processingTask = nil }
            do { try await operation() }
            catch {
                if Task.isCancelled { statusMessage = "İşlem iptal edildi. Yerel kayıt korunuyor." }
                else { errorMessage = error.localizedDescription; statusMessage = "İşlem tamamlanamadı. Yeniden deneyebilirsin." }
            }
        }
    }

    func cancelProcessing() { processingTask?.cancel() }
    var canCancelProcessing: Bool { processingTask != nil }

    func importAudio() {
        guard !workInProgress else { return }
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.audio, .movie]
        panel.allowsMultipleSelection = false
        panel.message = "Mevcut toplantı kaydını seç"
        guard panel.runModal() == .OK, let source = panel.url else { return }
        var meeting = newMeeting()
        meeting.title = source.deletingPathExtension().lastPathComponent
        meeting.source = "İçe aktarılan kayıt"
        meeting.audioFileName = "recording." + (source.pathExtension.isEmpty ? "m4a" : source.pathExtension.lowercased())
        do {
            let destination = library.audioURL(for: meeting)!
            try FileManager.default.copyItem(at: source, to: destination)
            try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: destination.path)
            update(meeting.id) { $0 = meeting }
            Task {
                do {
                    let duration = try await AVURLAsset(url: destination).load(.duration).seconds
                    if duration.isFinite { self.update(meeting.id) { $0.duration = duration } }
                } catch { self.errorMessage = "Kayıt süresi okunamadı: \(error.localizedDescription)" }
            }
        } catch { errorMessage = "Kayıt içe aktarılamadı: \(error.localizedDescription)" }
    }

    func importTranscript(text: String, title: String) {
        let segments = TranscriptParser.parse(text)
        guard !segments.isEmpty else { return }
        var meeting = newMeeting()
        meeting.title = title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "İçe aktarılan transkript" : title
        meeting.segments = segments
        meeting.duration = segments.last?.end ?? 0
        meeting.source = "İçe aktarılan metin"
        update(meeting.id) { $0 = meeting }
        statusMessage = "Transkript içe aktarıldı. Ses kaydı olmadığı için zaman bağlantıları metni açar."
    }

    func revealArchive() { NSWorkspace.shared.open(library.root) }

    func togglePlayback() {
        guard let meeting = selected, let url = library.audioURL(for: meeting, source: playbackSource), !recorder.isRecording else { return }
        do {
            if playbackID != meeting.id {
                stopPlayback()
                player = try AVAudioPlayer(contentsOf: url)
                playbackID = meeting.id
                playbackDuration = player?.duration ?? 0
            }
            if player?.isPlaying == true { player?.pause() }
            else { player?.prepareToPlay(); player?.play() }
            isPlaying = player?.isPlaying ?? false
        } catch { errorMessage = "Ses kaydı açılamadı: \(error.localizedDescription)" }
    }

    func seek(_ time: Double) {
        guard let meeting = selected, let url = library.audioURL(for: meeting, source: playbackSource), !recorder.isRecording else { return }
        do {
            if playbackID != meeting.id {
                stopPlayback()
                player = try AVAudioPlayer(contentsOf: url)
                playbackID = meeting.id
                playbackDuration = player?.duration ?? 0
            }
            player?.currentTime = min(max(0, time), playbackDuration)
            playbackTime = player?.currentTime ?? 0
        } catch { errorMessage = error.localizedDescription }
    }

    func stopPlayback() {
        player?.stop(); player = nil; playbackID = nil
        playbackTime = 0; playbackDuration = 0; isPlaying = false
    }
}
