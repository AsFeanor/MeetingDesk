import Foundation

enum SpeakerReviewPolicy {
    /// Detected voices also appear when legacy transcription has no word timing.
    /// Source labels are deliberately not counted as additional people.
    static func speakerIDs(in meeting: Meeting) -> [String] {
        var entries: [(id: String, start: Double, ordinal: Int)] = []
        for turn in meeting.speakerTurns ?? [] {
            guard validSpeakerID(turn.speakerID), turn.start.isFinite, turn.end.isFinite,
                  turn.start >= 0, turn.end > turn.start else { continue }
            entries.append((turn.speakerID, turn.start, entries.count))
        }
        for segment in meeting.segments {
            guard validSpeakerID(segment.speaker), segment.start.isFinite, segment.end.isFinite,
                  segment.start >= 0, segment.end >= segment.start,
                  !segment.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { continue }
            entries.append((segment.speaker, segment.start, entries.count))
        }
        entries.sort {
            if $0.start != $1.start { return $0.start < $1.start }
            return $0.ordinal < $1.ordinal
        }
        var seen = Set<String>()
        return entries.compactMap { seen.insert($0.id).inserted ? $0.id : nil }
    }

    /// This changes labels and explicit person associations only. It never changes
    /// transcript content, model turns, saved voice vectors, or the number of model clusters.
    static func assign(meeting: Meeting, speakerID: String, selection: SpeakerReviewSelection, profiles: [VoiceProfile]) throws -> Meeting {
        guard speakerIDs(in: meeting).contains(speakerID) else { throw SpeakerReviewError.unknownSpeaker }
        var people = meeting.speakerReviewPeople ?? []
        var assignments = meeting.speakerReviewAssignments ?? [:]
        try validate(people: people, assignments: assignments)

        let personIndex: Int
        var previousName: String?
        if let personID = selection.personID {
            guard let index = people.firstIndex(where: { $0.id == personID }) else { throw SpeakerReviewError.unknownPerson }
            if let selectedProfile = selection.voiceProfileID, selectedProfile != people[index].voiceProfileID {
                throw SpeakerReviewError.conflictingSelection
            }
            personIndex = index
            previousName = people[index].name
            // A deleted global profile does not erase this meeting's person or historical name.
            if let profileID = people[index].voiceProfileID, let profile = try profile(with: profileID, in: profiles, required: false) {
                people[index].name = try VoiceProfileValidation.name(profile.name)
            }
        } else if let profileID = selection.voiceProfileID {
            guard let profile = try profile(with: profileID, in: profiles, required: true) else {
                throw SpeakerReviewError.unknownVoiceProfile
            }
            let name = try VoiceProfileValidation.name(profile.name)
            if let index = people.firstIndex(where: { $0.voiceProfileID == profileID }) {
                personIndex = index
                previousName = people[index].name
                people[index].name = name
            } else {
                people.append(SpeakerReviewPerson(name: name, voiceProfileID: profileID))
                personIndex = people.count - 1
            }
        } else {
            let name = try VoiceProfileValidation.name(selection.name)
            guard !people.contains(where: { $0.name == name }) else { throw SpeakerReviewError.duplicateName(name) }
            people.append(SpeakerReviewPerson(name: name))
            personIndex = people.count - 1
        }

        let person = people[personIndex]
        assignments[speakerID] = person.id
        var result = meeting
        var changedLabels = false
        // Refresh already linked labels only when the selected global profile's
        // authoritative name changed. Other people and custom legacy names stay intact.
        let renamedPerson = previousName.map { $0 != person.name } ?? false
        let targets = renamedPerson ? assignments.filter { $0.value == person.id }.map(\.key) : [speakerID]
        var associations = result.speakerSuggestions ?? [:]
        for target in targets {
            if result.speakerName(target) != person.name { changedLabels = true }
            result.speakerNames[target] = person.name
            if var suggestion = associations[target],
               let profileID = person.voiceProfileID, suggestion.profileID == profileID,
               try profile(with: profileID, in: profiles, required: false) != nil {
                suggestion.name = person.name
                suggestion.automatic = true
                associations[target] = suggestion
            } else {
                associations.removeValue(forKey: target)
            }
        }
        result.speakerSuggestions = associations.isEmpty ? nil : associations
        result.speakerReviewPeople = people
        result.speakerReviewAssignments = assignments
        if changedLabels {
            result.notesNeedRefresh = result.notes != nil || result.notesNeedRefresh
            result.reviewedAt = nil
        }
        return result
    }

    static func confirmedCount(in meeting: Meeting) -> Int {
        let people = Set((meeting.speakerReviewPeople ?? []).map(\.id))
        let assignments = meeting.speakerReviewAssignments ?? [:]
        return speakerIDs(in: meeting).filter { assignments[$0].map(people.contains) ?? false }.count
    }

    private static func validSpeakerID(_ value: String) -> Bool {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value == clean, !clean.isEmpty, clean.count <= 256,
              !clean.unicodeScalars.contains(where: { CharacterSet.controlCharacters.contains($0) }) else { return false }
        return !["Mikrofon", "Toplantı sesi", "Konuşma"].contains(clean)
    }

    private static func profile(with id: UUID, in profiles: [VoiceProfile], required: Bool) throws -> VoiceProfile? {
        let matches = profiles.filter { $0.id == id }
        guard matches.count <= 1 else { throw SpeakerReviewError.invalidReviewData }
        guard let profile = matches.first else {
            if required { throw SpeakerReviewError.unknownVoiceProfile }
            return nil
        }
        return profile
    }

    private static func validate(people: [SpeakerReviewPerson], assignments: [String: UUID]) throws {
        let ids = Set(people.map(\.id))
        let profileIDs = people.compactMap(\.voiceProfileID)
        guard ids.count == people.count, Set(profileIDs).count == profileIDs.count,
              people.allSatisfy({ (try? VoiceProfileValidation.name($0.name)) == $0.name }),
              assignments.values.allSatisfy(ids.contains) else { throw SpeakerReviewError.invalidReviewData }
    }
}
