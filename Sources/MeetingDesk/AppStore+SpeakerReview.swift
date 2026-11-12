import Foundation

extension AppStore {
    func saveSpeakerReview(meetingID: UUID, speakerID: String, selection: SpeakerReviewSelection,
                           rememberVoice: Bool, sample: SpeakerReviewSample?, onSaved: @escaping () -> Void) {
        guard !workInProgress, let original = meetings.first(where: { $0.id == meetingID }), selectedID == meetingID else { return }
        stopSpeakerSample()
        errorMessage = nil
        runProcessing(message: rememberVoice ? "İsim ve onayladığın ses örneği saklanıyor…" : "İsim toplantıya uygulanıyor…") { [weak self] in
            guard let self else { return }
            let previousProfiles = try self.voiceProfileStore.load()
            var reviewInput = original
            // Old transcripts often include pauses in an utterance's time range.
            // Reuse existing turns for only unresolved, wordless source labels.
            reviewInput.segments = try original.segments.flatMap { segment -> [TranscriptSegment] in
                if segment.words == nil, ["Mikrofon", "Toplantı sesi", "Konuşma"].contains(segment.speaker) {
                    return try SpeakerTranscriptAlignment.assign([segment], turns: original.speakerTurns ?? [])
                }
                return [segment]
            }
            var candidate = try SpeakerReviewPolicy.assign(meeting: reviewInput, speakerID: speakerID,
                                                           selection: selection, profiles: previousProfiles)
            if candidate.segments != original.segments {
                candidate.notesNeedRefresh = candidate.notes != nil || candidate.notesNeedRefresh
                candidate.reviewedAt = nil
            }
            var updatedProfiles: [VoiceProfile]?
            if rememberVoice {
                guard let sample, sample.speakerID == speakerID, sample.canRemember,
                      SpeakerReviewSamples.samples(in: original, speakerID: speakerID).contains(sample),
                      let personID = candidate.speakerReviewAssignments?[speakerID],
                      let personIndex = candidate.speakerReviewPeople?.firstIndex(where: { $0.id == personID }) else {
                    throw MeetingError.message("Bu sesi hatırlamak için daha uzun ve temiz bir örnek seçip dinleyin.")
                }
                let source: PlaybackSource
                switch sample.source { case .microphone: source = .microphone; case .system: source = .system; case .mixed: source = .mixed }
                guard let url = self.library.audioURL(for: original, source: source), FileManager.default.fileExists(atPath: url.path) else {
                    throw MeetingError.message("Dinlediğin örneğin ses kaydı bulunamadı. İstersen sesi hatırlamadan yalnız isim verebilirsin.")
                }
                let voice = try await self.speakerEngine.sampleExcerpt(audioURL: url, sample: sample)
                try Task.checkCancellation()
                let person = candidate.speakerReviewPeople![personIndex]
                let existingProfileID = previousProfiles.first(where: { $0.id == person.voiceProfileID })?.id
                let profiles = try VoiceProfileEnrollment.remember(name: person.name, sample: voice,
                                                                   existing: previousProfiles, profileID: existingProfileID)
                guard let profileID = existingProfileID ?? profiles.last?.id else { throw VoiceProfileError.unknownProfile }
                candidate.speakerReviewPeople?[personIndex].voiceProfileID = profileID
                updatedProfiles = profiles
            }
            try Task.checkCancellation()
            guard self.meetings.first(where: { $0.id == meetingID }) == original, self.selectedID == meetingID else {
                throw MeetingError.message("Toplantı değiştiği için seçim kaydedilmedi. Önceki bilgiler korundu.")
            }
            if updatedProfiles != nil, try self.voiceProfileStore.load() != previousProfiles {
                throw MeetingError.message("Ses profilleri işlem sırasında değişti. Önceki bilgiler korundu; yeniden deneyebilirsin.")
            }
            try self.library.saveTranscriptVersion(original)
            if let profiles = updatedProfiles { try self.voiceProfileStore.save(profiles) }
            guard self.update(meetingID, { $0 = candidate }) else {
                if updatedProfiles != nil {
                    do { try self.voiceProfileStore.save(previousProfiles) }
                    catch {
                        self.voiceProfiles = (try? self.voiceProfileStore.load()) ?? previousProfiles
                        throw MeetingError.message("İsim kaydedilemedi; ses profili saklanmış olabilir. Ayarlar’daki ses profillerini kontrol edin.")
                    }
                }
                throw MeetingError.message("İsim kaydedilemedi. Önceki toplantı ve ses profilleri korundu.")
            }
            if let profiles = updatedProfiles {
                self.voiceProfiles = profiles
                self.speakerRecognitionEnabled = true
            }
            self.statusMessage = rememberVoice ? "İsim ve seçtiğin ses örneği kaydedildi." : "İsim bu toplantıya uygulandı."
            onSaved()
        }
    }
}
