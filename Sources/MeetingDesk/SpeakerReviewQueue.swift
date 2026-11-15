import Foundation

struct SpeakerReviewIdentifiedGroup: Identifiable, Equatable {
    var id: String
    var name: String
    var speakerIDs: [String]
}

/// Review is driven by unresolved recording-local voices, not by the number of
/// already known clusters. No identity is inferred from equal display names.
enum SpeakerReviewQueue {
    static func allSpeakerIDs(in meeting: Meeting) -> [String] {
        SpeakerReviewPolicy.speakerIDs(in: meeting)
    }

    static func pendingSpeakerIDs(in meeting: Meeting) -> [String] {
        allSpeakerIDs(in: meeting).filter { identifiedKey(for: $0, in: meeting) == nil }
    }

    /// An explicit meeting-person/profile link and a strong automatic match to
    /// that same profile are one known identity. Ambiguous archived person data
    /// stays separate; this function never repairs or writes archive data.
    static func identifiedKey(for speakerID: String, in meeting: Meeting) -> String? {
        let people = meeting.speakerReviewPeople ?? []
        if let personID = meeting.speakerReviewAssignments?[speakerID] {
            let matches = people.filter { $0.id == personID }
            if matches.count == 1, let person = matches.first {
                if let profileID = person.voiceProfileID,
                   people.filter({ $0.voiceProfileID == profileID }).count == 1 {
                    return "profile:" + profileID.uuidString
                }
                return "person:" + personID.uuidString
            }
        }
        if let suggestion = meeting.speakerSuggestions?[speakerID], suggestion.automatic {
            return "profile:" + suggestion.profileID.uuidString
        }
        return nil
    }

    /// A one-click reuse is available only after this exact current excerpt was
    /// played. The previous person is re-read by ID; names never select identity.
    static func reusablePreviousPerson(in meeting: Meeting, speakerID: String,
                                      previousPersonID: UUID?, sample: SpeakerReviewSample?,
                                      listenedSampleID: String?, audioAvailable: Bool) -> SpeakerReviewSelection? {
        guard audioAvailable, let previousPersonID, let sample,
              allSpeakerIDs(in: meeting).contains(speakerID),
              identifiedKey(for: speakerID, in: meeting) == nil,
              sample.speakerID == speakerID, listenedSampleID == sample.id,
              SpeakerReviewSamples.samples(in: meeting, speakerID: speakerID).contains(sample) else { return nil }
        let people = (meeting.speakerReviewPeople ?? []).filter { $0.id == previousPersonID }
        guard people.count == 1, let person = people.first else { return nil }
        return SpeakerReviewSelection(personID: person.id, voiceProfileID: person.voiceProfileID, name: person.name)
    }

    static func identifiedGroups(in meeting: Meeting) -> [SpeakerReviewIdentifiedGroup] {
        var indices: [String: Int] = [:]
        var groups: [SpeakerReviewIdentifiedGroup] = []
        for speakerID in allSpeakerIDs(in: meeting) {
            guard let key = identifiedKey(for: speakerID, in: meeting) else { continue }
            if let index = indices[key] {
                groups[index].speakerIDs.append(speakerID)
            } else {
                indices[key] = groups.count
                groups.append(SpeakerReviewIdentifiedGroup(id: key,
                    name: SpeakerPresentation.name(for: speakerID, in: meeting), speakerIDs: [speakerID]))
            }
        }
        return groups
    }
}
