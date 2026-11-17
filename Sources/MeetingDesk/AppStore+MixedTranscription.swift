import Foundation

extension AppStore {
    func refreshMixedModelStatus() async {
        let ready = await whisperModels.isReady()
        guard !Task.isCancelled, !preparingMixedModel else { return }
        mixedModelReady = ready
        mixedModelStatus = ready ? "Karma dil modeli hazır" : "Türkçe ve İngilizce için bir kez yaklaşık 1,6 GB indirilir."
    }

    func prepareMixedModel() {
        guard !workInProgress else { return }
        guard WhisperRuntimeLocation.isBundled else {
            errorMessage = "Karma dil bileşeni bu uygulama paketinde yok. Toplantı’yı güncelleyip yeniden dene."
            return
        }
        let preparationID = UUID()
        mixedModelPreparationID = preparationID
        preparingMixedModel = true; mixedModelProgress = 0
        runProcessing(message: "Karma dil modeli indiriliyor…", preserveErrorInStatus: true) { [weak self] in
            guard let self else { return }
            defer { self.preparingMixedModel = false; self.mixedModelProgress = nil; self.mixedModelPreparationID = nil }
            do {
                try await self.whisperModels.prepare { [weak self] fraction in
                    Task { @MainActor [weak self] in
                        guard let self, self.preparingMixedModel, self.mixedModelPreparationID == preparationID else { return }
                        self.mixedModelProgress = min(1, max(0, fraction))
                    }
                }
                self.mixedModelReady = true; self.mixedModelStatus = "Karma dil modeli hazır"
                self.statusMessage = "Karma dil modeli hazır. Konuşma dilini Türkçe + English seçerek kullanabilirsin."
            } catch {
                self.mixedModelReady = false; self.mixedModelStatus = error.localizedDescription
                throw error
            }
        }
    }

    func transcribeLocalMeeting(_ meeting: Meeting, audioURL: URL, language: String) async throws
        -> (ChannelTranscriptionResult, TranscriptASRProvenance?) {
        let microphone = library.audioURL(for: meeting, source: .microphone)
        let system = library.audioURL(for: meeting, source: .system)
        guard try LocalASRBackend.route(language: language) == .mlxWhisper else {
            let result = try await ChannelTranscriptionService().transcribe(mixedURL: audioURL,
                microphoneURL: microphone, systemURL: system, language: language, microphoneGain: meeting.microphoneGain ?? 1)
            return (result, nil)
        }
        let sources = [audioURL, microphone, system].compactMap { $0 }
        let identities = try sources.map(MixedSourceIdentity.init)
        let model = try await whisperModels.verifiedDirectory()
        let configuration = VerifiedWhisperConfiguration(modelDirectory: model,
            modelIdentifier: WhisperModelPin.identifier, modelRevision: WhisperModelPin.revision,
            implementationVersion: WhisperModelPin.implementation, decodingStrategyID: WhisperModelPin.strategy,
            acceptedLanguageModes: [.turkishEnglish])
        let launch = try await Task.detached(priority: .utility) { try WhisperRuntimeLocation.launch() }.value
        try Task.checkCancellation()
        let session = try WhisperTranscriptionAdapter.ownedSession(configuration: configuration, launch: launch)
        do {
            let channels = ChannelTranscriptionService(validateLanguage: { try LocalASRBackend.mlxWhisper.validate(language: $0) },
                transcribeAudio: { url, language, allowNoSpeech in
                    try await session.transcribe(audioURL: url, language: language, allowNoSpeech: allowNoSpeech)
                })
            let result = try await channels.transcribe(mixedURL: audioURL, microphoneURL: microphone,
                systemURL: system, language: language, microphoneGain: meeting.microphoneGain ?? 1)
            let provenance = try await session.provenance(language: language, mergedSegments: result.segments)
            try await session.finishAndClose()
            try Task.checkCancellation()
            guard identities == (try sources.map(MixedSourceIdentity.init)),
                  let current = meetings.first(where: { $0.id == meeting.id }),
                  speechLanguage(for: current) == language, current.microphoneGain == meeting.microphoneGain else {
                throw MeetingError.message("Ses kaydı veya dil ayarı işlem sırasında değişti. Yeni döküm kaydedilmedi; önceki kayıt korunuyor.")
            }
            return (result, provenance)
        } catch { await session.cancelAndClose(); throw error }
    }
}

private struct MixedSourceIdentity: Equatable {
    let size: UInt64
    let modified: Date
    let inode: UInt64
    init(_ url: URL) throws {
        let a = try FileManager.default.attributesOfItem(atPath: url.path)
        guard a[.type] as? FileAttributeType == .typeRegular,
              let size = a[.size] as? NSNumber, let modified = a[.modificationDate] as? Date,
              let inode = a[.systemFileNumber] as? NSNumber else { throw WhisperAdapterFailure.invalidPCM }
        self.size = size.uint64Value; self.modified = modified; self.inode = inode.uint64Value
    }
}
