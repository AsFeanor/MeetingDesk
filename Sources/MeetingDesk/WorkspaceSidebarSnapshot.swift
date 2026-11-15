import Foundation

/// Small archive rows are independent of playback clocks and recorder meters.
/// Rebuild only when archive/profile/search inputs change, never while drawing.
struct WorkspaceSidebarSnapshot: Equatable {
    struct Row: Identifiable, Equatable {
        let id: UUID
        let title: String
        let createdAt: Date
        let duration: Double
        let hasNotes: Bool
        let hasTranscript: Bool
        let notesAreReviewed: Bool
        let pendingActionCount: Int
    }
    struct Group: Identifiable, Equatable {
        let id: Int
        let title: String
        let meetings: [Row]
    }
    let groups: [Group]
    let matchCount: Int
    let peopleCount: Int
    static let empty = WorkspaceSidebarSnapshot(groups: [], matchCount: 0, peopleCount: 0)

    static func build(meetings: [Meeting], profiles: [VoiceProfile], query: String, pendingOnly: Bool,
                      now: Date = Date(), calendar: Calendar = .current) -> WorkspaceSidebarSnapshot {
        let rows = meetings.enumerated().compactMap { index, meeting -> (Int, Row)? in
            let pending = meeting.notes?.actions.reduce(0) { $0 + (meeting.completedActions.contains($1.id) ? 0 : 1) } ?? 0
            guard (!pendingOnly || pending > 0), MeetingArchiveSearch.matches(meeting, query: query) else { return nil }
            return (index, Row(id: meeting.id, title: meeting.title, createdAt: meeting.createdAt,
                duration: meeting.duration, hasNotes: meeting.notes != nil, hasTranscript: !meeting.segments.isEmpty,
                notesAreReviewed: meeting.notesAreReviewed, pendingActionCount: pending))
        }.sorted {
            $0.1.createdAt == $1.1.createdAt ? $0.0 < $1.0 : $0.1.createdAt > $1.1.createdAt
        }.map(\.1)
        let yesterday = calendar.date(byAdding: .day, value: -1, to: now) ?? now
        let week = calendar.dateInterval(of: .weekOfYear, for: now)
        let buckets = Dictionary(grouping: rows) { row -> Int in
            if calendar.isDate(row.createdAt, inSameDayAs: now) { return 0 }
            if calendar.isDate(row.createdAt, inSameDayAs: yesterday) { return 1 }
            return week?.contains(row.createdAt) == true ? 2 : 3
        }
        let titles = ["Bugün", "Dün", "Bu hafta", "Önceki toplantılar"]
        let groups = titles.indices.compactMap { index -> Group? in
            guard let rows = buckets[index], !rows.isEmpty else { return nil }
            return Group(id: index, title: titles[index], meetings: rows)
        }
        return WorkspaceSidebarSnapshot(groups: groups, matchCount: rows.count,
            peopleCount: PeopleDirectory.entries(meetings: meetings, profiles: profiles).count)
    }
}
