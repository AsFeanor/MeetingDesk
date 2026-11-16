import Foundation

extension AppStore {
    @discardableResult
    func saveGlossaryEntry(_ entry: GlossaryEntry) -> Bool {
        guard !workInProgress else { return false }
        guard glossaryEntries.filter({ $0.id == entry.id }).count <= 1 else {
            errorMessage = GlossaryError.duplicateID.localizedDescription; return false
        }
        var candidate = glossaryEntries
        if let index = candidate.firstIndex(where: { $0.id == entry.id }) { candidate[index] = entry }
        else { candidate.append(entry) }
        return persistGlossaryEntries(candidate)
    }

    @discardableResult
    func deleteGlossaryEntry(id: UUID) -> Bool {
        guard !workInProgress, glossaryEntries.filter({ $0.id == id }).count == 1 else { return false }
        return persistGlossaryEntries(glossaryEntries.filter { $0.id != id })
    }

    @discardableResult
    func applyGlossarySuggestion(_ suggestion: GlossarySuggestion, meetingID: UUID) -> Bool {
        guard !workInProgress, selectedID == meetingID,
              meetings.filter({ $0.id == meetingID }).count == 1,
              let original = meetings.first(where: { $0.id == meetingID }) else { return false }
        do {
            let candidate = try TranscriptGlossary.applying(suggestion, to: original, entries: glossaryEntries)
            // History is written first; either failure leaves the current transcript unchanged.
            try library.saveTranscriptVersion(original)
            guard update(meetingID, { $0 = candidate }) else { return false }
            errorMessage = nil
            statusMessage = "Seçtiğin yazım düzeltildi. Önceki transkript sürümü saklandı."
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func persistGlossaryEntries(_ candidate: [GlossaryEntry]) -> Bool {
        do {
            let localStore = GlossaryStore(root: library.root)
            guard try localStore.load() == glossaryEntries else {
                throw MeetingError.message("Sözlük başka bir işlemde değişti. Önceki kayıtlar korundu; uygulamayı yeniden açıp tekrar deneyin.")
            }
            try localStore.save(candidate)
            glossaryEntries = candidate
            errorMessage = nil
            statusMessage = "Kişisel sözlük bu Mac’te kaydedildi."
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }
}
