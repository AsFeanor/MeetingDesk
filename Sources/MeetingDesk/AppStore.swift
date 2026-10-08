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
    private var updateSubscriptions: Set<AnyCancellable> = []
    let library: MeetingLibrary
    private var recordingID: UUID?
    private var player: AVAudioPlayer?
    private var playbackID: UUID?
    private var timer: Timer?
    private var processingTask: Task<Void, Never>?

    var hasPendingRecordingSession: Bool { recordingID != nil }
    var selected: Meeting? { meetings.first { $0.id == selectedID } }
    var recordingMeeting: Meeting? { meetings.first { $0.id == recordingID } }
    var hasPreviousTranscript: Bool { selected.map { library.hasTranscriptVersion(for: $0.id) } ?? false }
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

    init(root: URL? = nil) {
        library = MeetingLibrary(root: root)
        reload()
        refreshKey()
        refreshMicrophones()
        Publishers.CombineLatest(recorder.$isRecording, $isBusy)
            .map { recording, busy in recording || busy }
            .removeDuplicates()
            .sink { [weak self] busy in
                guard let self else { return }
                self.updates.setWorkInProgress(busy || self.hasPendingRecordingSession)
            }
            .store(in: &updateSubscriptions)
        recorder.onFailure = { [weak self] error in
            guard let self else { return }
            self.errorMessage = "Kayıt kesildi: \(error.localizedDescription). Kaydedilmiş bölüm korunuyor."
            Task { await self.finishRecording() }
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

    func update(_ id: UUID, _ change: (inout Meeting) -> Void) {
        guard let index = meetings.firstIndex(where: { $0.id == id }) else { return }
        change(&meetings[index])
        persist(meetings[index])
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
        guard !recorder.isRecording, !isBusy else { return }
        stopPlayback()
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
            update(meeting.id) {
                $0.audioFileName = "recording.m4a"; $0.source = "Mac kaydı"
                $0.microphoneDeviceID = deviceID; $0.microphoneDeviceName = deviceName; $0.microphoneGain = gain
            }
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

    func finishRecording() async {
        guard let id = recordingID else { return }
        isBusy = true
        statusMessage = "Ses kaydı kaydediliyor…"
        do {
            let duration = try await recorder.stop()
            update(id) { $0.duration = duration }
            statusMessage = "Kayıt hazır. İstersen yalnız mikrofonu dinleyip ardından transkripti oluşturabilirsin."
        } catch {
            errorMessage = error.localizedDescription
            statusMessage = "Kayıt tamamlanamadı; kurtarma dosyaları toplantı klasöründe korunuyor."
        }
        recordingID = nil
        isBusy = false
    }

    func transcribe() {
        guard let meeting = selected, let audioURL = library.audioURL(for: meeting), !isBusy, !recorder.isRecording else { return }
        let mode = processingMode
        let language = speechLanguage(for: meeting)
        let service = mode == .openAI ? selectedOpenAIService() : nil
        guard mode != .openAI || service != nil else { return }
        runProcessing(message: mode == .local ? "Transkript Mac’te hazırlanıyor. İlk kullanımda dil modeli indirilebilir…" : "Konuşmacılar ve transkript hazırlanıyor…") { [weak self] in
            let segments: [TranscriptSegment]
            if mode == .local { segments = try await LocalTranscriptionService().transcribe(audioURL: audioURL, language: language) }
            else { segments = try await service!.transcribe(audioURL: audioURL) }
            try Task.checkCancellation()
            guard let self else { return }
            if !meeting.segments.isEmpty { try self.library.saveTranscriptVersion(meeting) }
            self.update(meeting.id) {
                $0.segments = segments; $0.notesNeedRefresh = $0.notes != nil
                $0.transcriptionEngine = mode.rawValue
                $0.transcribedLanguage = mode == .local ? language : nil
                $0.speechLanguage = language
                $0.speakerNames = [:]
            }
            self.statusMessage = mode == .local ? "Yerel transkript hazır. Bu mod konuşmacıları otomatik ayırmaz." : "Transkript hazır. Konuşmacı adlarını kontrol edip özeti oluşturabilirsin."
        }
    }

    func restorePreviousTranscript() {
        guard let meeting = selected, !isBusy, !recorder.isRecording else { return }
        do {
            guard let previous = try library.latestTranscriptVersion(for: meeting.id) else { return }
            try library.saveTranscriptVersion(meeting)
            update(meeting.id) {
                $0.segments = previous.segments
                $0.speakerNames = previous.speakerNames
                $0.transcriptionEngine = previous.transcriptionEngine
                $0.transcribedLanguage = previous.transcribedLanguage
                $0.notes = previous.notes
                $0.notesEngine = previous.notesEngine
                $0.notesNeedRefresh = previous.notesNeedRefresh
                $0.completedActions = previous.completedActions
            }
            statusMessage = "Önceki döküm geri getirildi. Ses kaydı ve kişisel notlar korundu."
        } catch { errorMessage = error.localizedDescription }
    }

    func recoverRecording() async {
        guard let meeting = selected, let destination = selectedRecoveryURL, !isBusy, !recorder.isRecording else { return }
        isBusy = true
        statusMessage = "Kesilen kayıt kurtarılıyor…"
        defer { isBusy = false }
        do {
            let duration = try await AudioRecorder.recover(url: destination)
            update(meeting.id) { $0.audioFileName = "recording.m4a"; $0.duration = duration; $0.source = "Mac kaydı" }
            statusMessage = "Kayıt kurtarıldı. Transkripti oluşturabilirsin."
        } catch { errorMessage = error.localizedDescription; statusMessage = "Kurtarma tamamlanamadı; ham kayıt korunuyor." }
    }

    func summarize() {
        guard let meeting = selected, !meeting.segments.isEmpty, !isBusy, !recorder.isRecording else { return }
        let mode = processingMode
        let service = mode == .openAI ? selectedOpenAIService() : nil
        guard mode != .openAI || service != nil else { return }
        runProcessing(message: mode == .local ? "Toplantı notları Mac’te hazırlanıyor…" : "Kararlar, aksiyonlar ve açık sorular hazırlanıyor…") { [weak self] in
            let notes: MeetingNotes
            if mode == .local { notes = try await LocalSummaryService().summarize(meeting: meeting) }
            else { notes = try await service!.summarize(meeting: meeting) }
            try Task.checkCancellation()
            guard let self else { return }
            self.update(meeting.id) { $0.notes = notes; $0.notesNeedRefresh = false; $0.completedActions = []; $0.notesEngine = mode.rawValue }
            self.statusMessage = "Toplantı notu hazır. Kaynakları ve görevleri kontrol edebilirsin."
        }
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
        guard !isBusy, !recorder.isRecording else { return }
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

    func exportSelected() {
        guard let meeting = selected else { return }
        let panel = NSSavePanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "md") ?? .plainText]
        panel.nameFieldStringValue = meeting.title.replacingOccurrences(of: "/", with: "-") + ".md"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do { try MeetingExport.markdown(meeting).write(to: url, atomically: true, encoding: .utf8) }
        catch { errorMessage = error.localizedDescription }
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
