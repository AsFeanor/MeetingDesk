import Foundation

struct WorkspaceParticipant: Identifiable, Equatable {
    var id: String
    var name: String
    var speakerIDs: [String]
    var isIdentified: Bool
}

/// The inspector presents confirmed people rather than model voice clusters.
/// A shared display name alone never establishes that two voices are one person.
enum WorkspaceParticipants {
    static func entries(in meeting: Meeting) -> [WorkspaceParticipant] {
        var seen = Set<String>()
        let speakerIDs = (SpeakerReviewPolicy.speakerIDs(in: meeting) + meeting.speakers)
            .filter { seen.insert($0).inserted }
        let people = Dictionary(grouping: meeting.speakerReviewPeople ?? [], by: \.id)
        var entries: [WorkspaceParticipant] = []
        var indices: [String: Int] = [:]

        for speakerID in speakerIDs {
            let identity: String
            let isIdentified: Bool
            if let personID = meeting.speakerReviewAssignments?[speakerID],
               let matches = people[personID], matches.count == 1 {
                identity = "person:\(personID.uuidString)"
                isIdentified = true
            } else if let suggestion = meeting.speakerSuggestions?[speakerID], suggestion.automatic {
                identity = "profile:\(suggestion.profileID.uuidString)"
                isIdentified = true
            } else {
                identity = "speaker:\(speakerID)"
                isIdentified = false
            }
            if let index = indices[identity] {
                entries[index].speakerIDs.append(speakerID)
            } else {
                indices[identity] = entries.count
                entries.append(WorkspaceParticipant(id: identity,
                    name: SpeakerPresentation.name(for: speakerID, in: meeting), speakerIDs: [speakerID], isIdentified: isIdentified))
            }
        }
        return entries
    }
}
