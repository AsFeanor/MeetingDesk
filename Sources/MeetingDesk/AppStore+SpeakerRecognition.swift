import Foundation

extension AppStore {
    func prepareSpeakerModels() {
        guard !workInProgress else { return }
        preparingSpeakerModels = true
        runProcessing(message: "Konuşmacı modelleri hazırlanıyor… İlk kullanımda internet gerekir.") { [weak self] in
            guard let self else { return }
            defer { self.preparingSpeakerModels = false }
            do {
                try await self.speakerEngine.prepareModels()
                try Task.checkCancellation()
                self.speakerModelsReady = true
                self.speakerSettingsDefaults.set(true, forKey: "meetingdesk.speakerModelsReady")
                self.speakerModelStatus = "Konuşmacı modelleri hazır. Sesler bu Mac’te işlenir."
                self.statusMessage = "Konuşmacı tanımayı açabilir, bir toplantıda kişilerin sesini hatırlatabilirsin."
            } catch {
                self.speakerModelStatus = "Modeller hazırlanamadı: \(error.localizedDescription)"
                throw error
            }
        }
    }

    func identifySpeakers() {
        guard !workInProgress, let meeting = selected, !meeting.segments.isEmpty else { return }
        let id = meeting.id
        runProcessing(message: "Konuşmacılar bu Mac’te ayrılıyor ve kayıtlı ses profilleriyle karşılaştırılıyor…") { [weak self] in
            try await self?.recognizeMeeting(id)
        }
    }

    func recognizeMeeting(_ id: UUID) async throws {
        guard let original = meetings.first(where: { $0.id == id }), !original.segments.isEmpty else { return }
        let tracks = speakerAudioTracks(for: original)
        guard !tracks.isEmpty else { throw MeetingError.message("Konuşmacı tanıma için toplantının ses kaydı gerekiyor.") }
        let profiles = try voiceProfileStore.load()
        var allTurns: [SpeakerTurn] = [], samples: [SpeakerVoiceSample] = []
        for track in tracks {
            try Task.checkCancellation()
            let analysis = try await speakerEngine.analyze(audioURL: track.1, source: track.0)
            allTurns += analysis.turns; samples += analysis.samples
        }
        try Task.checkCancellation()
        guard meetings.first(where: { $0.id == id }) == original else {
            throw MeetingError.message("Toplantı işlenirken değişti. Konuşmacı sonucu kaydedilmedi; yeniden deneyebilirsin.")
        }
        let segments = try SpeakerTranscriptAlignment.assign(original.segments, turns: allTurns)
        let used = Set(segments.map(\.speaker))
        var names: [String: String] = [:], suggestions: [String: SpeakerIdentitySuggestion] = [:]
        let identified = allTurns.sorted { $0.start == $1.start ? $0.speakerID < $1.speakerID : $0.start < $1.start }
            .reduce(into: [String]()) { result, turn in if used.contains(turn.speakerID), !result.contains(turn.speakerID) { result.append(turn.speakerID) } }
        for (index, speaker) in identified.enumerated() {
            names[speaker] = "Konuşmacı \(index + 1)"
            if let sample = samples.first(where: { $0.speakerID == speaker }), let match = VoiceProfileMatcher.match(sample: sample, profiles: profiles) {
                suggestions[speaker] = match
                if match.automatic { names[speaker] = match.name }
            }
        }
        guard !identified.isEmpty else {
            throw MeetingError.message("Bu kayıtta güvenilir konuşmacı aralığı bulunamadı. Mevcut transkript korunuyor.")
        }
        try library.saveTranscriptVersion(original)
        guard update(id, {
            $0.segments = segments; $0.speakerNames = names
            $0.speakerTurns = allTurns; $0.speakerSuggestions = suggestions
            $0.speakerRecognitionEngine = "fluidaudio-0.18.3-campplus-v2"
            $0.speakerRecognitionNotice = original.segments.contains(where: { $0.words == nil })
                ? "Bu dökümde kelime zamanları bulunmayan bölümler var. Daha hassas konuşmacı ayrımı için dökümü yeniden oluşturabilirsin." : nil
            $0.notesNeedRefresh = $0.notes != nil
        }) else { throw MeetingError.message("Konuşmacılar kaydedilemedi. Önceki döküm korundu.") }
        voiceProfiles = profiles
        speakerModelsReady = true
        speakerSettingsDefaults.set(true, forKey: "meetingdesk.speakerModelsReady")
        speakerModelStatus = "Konuşmacı modelleri hazır. Sesler bu Mac’te işlenir."
        statusMessage = "Konuşmacılar ayrıldı. İsimleri kontrol edebilir ve tanıttığın kişinin sesini hatırlatabilirsin."
    }

    func rememberSpeaker(_ speakerID: String, name: String, profileID: UUID? = nil) {
        guard !workInProgress, let original = selected else { return }
        let id = original.id
        runProcessing(message: "Onayladığın ses profili bu Mac’te hazırlanıyor…") { [weak self] in
            guard let self else { return }
            let turns = SpeakerEnrollmentEvidence.eligibleTurns(in: original, speakerID: speakerID)
            guard let target = turns.first(where: { $0.speakerID == speakerID }),
                  let audio = self.speakerAudioTracks(for: original).first(where: { $0.0 == target.source })?.1 else {
                throw MeetingError.message("Bu kişi için kullanılabilir ses bulunamadı. Ses kaydı ve konuşmacı ayrımı gerekiyor.")
            }
            let sample = try await self.speakerEngine.sample(audioURL: audio, speakerID: speakerID, turns: turns)
            try Task.checkCancellation()
            guard self.meetings.first(where: { $0.id == id }) == original else {
                throw MeetingError.message("Toplantı değiştiği için ses profili kaydedilmedi. Yeniden deneyebilirsin.")
            }
            let current = try self.voiceProfileStore.load()
            let updated = try VoiceProfileEnrollment.remember(name: name, sample: sample, existing: current, profileID: profileID)
            try self.voiceProfileStore.save(updated)
            self.voiceProfiles = updated
            let savedName = try VoiceProfileValidation.name(name)
            guard let savedProfileID = profileID ?? updated.last?.id else { throw VoiceProfileError.unknownProfile }
            guard self.update(id, {
                $0.speakerNames[speakerID] = savedName
                var associations = $0.speakerSuggestions ?? [:]
                associations[speakerID] = SpeakerIdentitySuggestion(profileID: savedProfileID, name: savedName, similarity: 1, automatic: true)
                $0.speakerSuggestions = associations
                $0.notesNeedRefresh = $0.notes != nil
            }) else {
                throw MeetingError.message("Ses profili saklandı, ancak toplantı adı kaydedilemedi. Konuşmacı adını yeniden düzeltebilirsin.")
            }
            self.statusMessage = "\(savedName) için ses profili saklandı. Sonraki toplantılar bu Mac’te karşılaştırılacak."
        }
    }

    func confirmSpeakerMatch(_ speakerID: String, profileID: UUID) {
        guard !workInProgress, let meeting = selected, let profile = voiceProfiles.first(where: { $0.id == profileID }) else { return }
        update(meeting.id) {
            $0.speakerNames[speakerID] = profile.name
            let similarity = $0.speakerSuggestions?[speakerID]?.similarity ?? 0
            var associations = $0.speakerSuggestions ?? [:]
            associations[speakerID] = SpeakerIdentitySuggestion(profileID: profile.id, name: profile.name, similarity: similarity, automatic: true)
            $0.speakerSuggestions = associations
            $0.notesNeedRefresh = $0.notes != nil
        }
    }

    func dismissSpeakerSuggestion(_ speakerID: String) {
        guard !workInProgress, let meeting = selected else { return }
        update(meeting.id) { $0.speakerSuggestions?[speakerID] = nil }
    }

    func assignSpeaker(segmentID: String, speakerID: String) {
        guard !workInProgress, let meeting = selected, meeting.speakers.contains(speakerID) else { return }
        update(meeting.id) {
            if let index = $0.segments.firstIndex(where: { $0.id == segmentID }) {
                $0.segments[index].speaker = speakerID
                $0.notesNeedRefresh = $0.notes != nil
            }
        }
    }

    func renameVoiceProfile(id: UUID, name: String) {
        guard !workInProgress else { return }
        do {
            let name = try VoiceProfileValidation.name(name)
            var profiles = try voiceProfileStore.load()
            guard let index = profiles.firstIndex(where: { $0.id == id }) else { return }
            profiles[index].name = name; profiles[index].updatedAt = Date()
            try voiceProfileStore.save(profiles); voiceProfiles = profiles
        } catch { errorMessage = error.localizedDescription }
    }

    func deleteVoiceProfile(id: UUID) {
        guard !workInProgress else { return }
        do {
            let profiles = try voiceProfileStore.load().filter { $0.id != id }
            try voiceProfileStore.save(profiles); voiceProfiles = profiles
            statusMessage = "Ses profili silindi. Önceki toplantılardaki yazılı isimler korunuyor."
        } catch { errorMessage = error.localizedDescription }
    }

    func speakerAudioTracks(for meeting: Meeting) -> [(SpeakerAudioSource, URL)] {
        if meeting.transcriptSourceSeparated == true,
           let microphone = library.audioURL(for: meeting, source: .microphone), let system = library.audioURL(for: meeting, source: .system),
           FileManager.default.fileExists(atPath: microphone.path), FileManager.default.fileExists(atPath: system.path) {
            return [(.microphone, microphone), (.system, system)]
        }
        guard let audio = library.audioURL(for: meeting), FileManager.default.fileExists(atPath: audio.path) else { return [] }
        // Previously separated transcript timings must never be assigned to a mixed source silently.
        if meeting.transcriptSourceSeparated == true { return [] }
        return [(.mixed, audio)]
    }
}

enum SpeakerEnrollmentEvidence {
    static func eligibleTurns(in meeting: Meeting, speakerID: String) -> [SpeakerTurn] {
        let turns = meeting.speakerTurns ?? []
        let target = turns.filter { $0.speakerID == speakerID }
        var filtered: [SpeakerTurn] = []
        for turn in target {
            // Only intervals still assigned to this speaker are eligible after manual corrections.
            for segment in meeting.segments where segment.speaker == speakerID && SpeakerTranscriptAlignment.source(for: segment) == turn.source {
                let start = max(turn.start, segment.start), end = min(turn.end, segment.end)
                if end > start { filtered.append(SpeakerTurn(speakerID: speakerID, source: turn.source, start: start, end: end)) }
            }
        }
        return turns.filter { $0.speakerID != speakerID } + filtered
    }
}
