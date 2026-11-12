import Foundation

struct PeopleDirectoryEntry: Identifiable, Equatable, Sendable {
    var id: String
    var name: String
    /// Present only while the saved global voice profile still exists.
    var profileID: UUID?
    var meetingIDs: [UUID]
    var lastSeen: Date?
    var sampleCount: Int
}

/// A read-only view of explicit identity records. Names never establish identity.
enum PeopleDirectory {
    static func entries(meetings: [Meeting], profiles: [VoiceProfile]) -> [PeopleDirectoryEntry] {
        // Normally the profile store guarantees unique IDs. Keeping this reducer
        // deterministic also avoids trapping while a caller refreshes its snapshot.
        var currentProfiles: [UUID: VoiceProfile] = [:]
        for profile in profiles.sorted(by: profileOrder) where currentProfiles[profile.id] == nil {
            currentProfiles[profile.id] = profile
        }
        var rows: [String: Row] = [:]
        for profile in currentProfiles.values {
            rows[profileKey(profile.id)] = Row(name: displayName(profile.name), profileID: profile.id,
                sampleCount: profile.samples.count, lastSeen: nil)
        }
        for meeting in meetings {
            for person in meeting.speakerReviewPeople ?? [] {
                let key = person.voiceProfileID.map(profileKey) ?? personKey(meeting: meeting.id, person: person.id)
                let hasCurrentProfile = person.voiceProfileID.flatMap { currentProfiles[$0] } != nil
                var row = rows[key] ?? Row(name: displayName(person.name), profileID: nil, sampleCount: 0, lastSeen: nil)
                row.include(meeting: meeting)
                if !hasCurrentProfile {
                    row.considerHistoricalName(displayName(person.name), at: meeting.createdAt,
                        tie: "\(meeting.id.uuidString):\(person.id.uuidString):\(displayName(person.name))")
                }
                rows[key] = row
            }
            // Older meetings may predate guided review. Strong or explicitly
            // confirmed links count; unconfirmed name suggestions do not.
            let used = Set(meeting.segments.map(\.speaker) + (meeting.speakerTurns ?? []).map(\.speakerID))
            for (speakerID, association) in meeting.speakerSuggestions ?? [:]
                where association.automatic && used.contains(speakerID) {
                let key = profileKey(association.profileID)
                var row = rows[key] ?? Row(name: displayName(association.name), profileID: nil, sampleCount: 0, lastSeen: nil)
                row.include(meeting: meeting)
                if currentProfiles[association.profileID] == nil {
                    row.considerHistoricalName(displayName(association.name), at: meeting.createdAt,
                        tie: "\(meeting.id.uuidString):speaker:\(speakerID):\(displayName(association.name))")
                }
                rows[key] = row
            }
        }
        return rows.map { id, row in
            PeopleDirectoryEntry(id: id, name: row.name, profileID: row.profileID,
                meetingIDs: row.meetingIDs.sorted { first, second in
                    let a = row.meetingDates[first]?.timeIntervalSinceReferenceDate ?? -.infinity
                    let b = row.meetingDates[second]?.timeIntervalSinceReferenceDate ?? -.infinity
                    return a == b ? first.uuidString < second.uuidString : a > b
                }, lastSeen: row.lastSeen, sampleCount: row.sampleCount)
        }.sorted {
            let first = sortName($0.name), second = sortName($1.name)
            return first == second ? $0.id < $1.id : first < second
        }
    }

    private struct Row {
        var name: String
        var profileID: UUID?
        var sampleCount: Int
        var lastSeen: Date?
        var meetingIDs: Set<UUID> = []
        var meetingDates: [UUID: Date] = [:]
        var historicalNameDate: Date?
        var historicalNameTie: String?

        mutating func include(meeting: Meeting) {
            meetingIDs.insert(meeting.id)
            if let date = PeopleDirectory.finite(meeting.createdAt) {
                if meetingDates[meeting.id].map({ $0 < date }) ?? true { meetingDates[meeting.id] = date }
                if lastSeen.map({ $0 < date }) ?? true { lastSeen = date }
            }
        }

        mutating func considerHistoricalName(_ candidate: String, at date: Date, tie: String) {
            let date = PeopleDirectory.finite(date)
            let timestamp = date?.timeIntervalSinceReferenceDate ?? -.infinity
            let previous = historicalNameDate?.timeIntervalSinceReferenceDate ?? -.infinity
            guard historicalNameTie == nil || timestamp > previous || (timestamp == previous && tie < historicalNameTie!) else { return }
            name = candidate
            historicalNameDate = date
            historicalNameTie = tie
        }
    }

    private static func finite(_ date: Date) -> Date? {
        date.timeIntervalSinceReferenceDate.isFinite ? date : nil
    }

    private static func displayName(_ value: String) -> String {
        let name = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return name.isEmpty ? "İsimsiz kişi" : name
    }

    private static func sortName(_ value: String) -> String {
        value.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: Locale(identifier: "tr_TR"))
            .precomposedStringWithCanonicalMapping
    }

    private static func profileKey(_ id: UUID) -> String { "profile:\(id.uuidString)" }
    private static func personKey(meeting: UUID, person: UUID) -> String { "meeting:\(meeting.uuidString):person:\(person.uuidString)" }

    private static func profileOrder(_ first: VoiceProfile, _ second: VoiceProfile) -> Bool {
        let a = finite(first.updatedAt)?.timeIntervalSinceReferenceDate ?? -.infinity
        let b = finite(second.updatedAt)?.timeIntervalSinceReferenceDate ?? -.infinity
        if a != b { return a > b }
        if first.name != second.name { return first.name < second.name }
        if first.samples.count != second.samples.count { return first.samples.count > second.samples.count }
        return first.id.uuidString < second.id.uuidString
    }
}
