import Foundation

struct CarryoverTask: Identifiable, Equatable {
    let sourceMeetingID: UUID
    let sourceMeetingTitle: String
    let sourceMeetingDate: Date
    let action: ActionItem

    var id: String { sourceMeetingID.uuidString + ":" + action.id }
}

struct CarryoverReminder: Equatable {
    enum Issue: Equatable { case unavailableSource, brokenHistory }
    let source: Meeting?
    let linkedMeetingIDs: [UUID]
    let tasks: [CarryoverTask]
    let issue: Issue?
}

/// Shows original pending work through explicitly saved links. It never changes
/// meetings, copies tasks, or infers that two meetings belong together from people.
enum CarryoverActions {
    static func eligiblePreviousMeetings(for meeting: Meeting, in meetings: [Meeting], now: Date = Date()) -> [Meeting] {
        guard finite(meeting.createdAt), finite(now) else { return [] }
        return uniqueMeetings(meetings).values.filter {
            $0.id != meeting.id && finite($0.createdAt) && $0.createdAt < meeting.createdAt && $0.createdAt <= now
        }.sorted {
            if $0.createdAt != $1.createdAt { return $0.createdAt > $1.createdAt }
            return $0.id.uuidString < $1.id.uuidString
        }
    }

    /// An exact, case/whitespace-normalized title is only a suggestion. The user
    /// must accept it before any original task is surfaced or can be completed.
    static func suggestedPreviousMeeting(for meeting: Meeting, in meetings: [Meeting], now: Date = Date()) -> Meeting? {
        guard let title = recurringTitle(meeting.title) else { return nil }
        return eligiblePreviousMeetings(for: meeting, in: meetings, now: now)
            .first { recurringTitle($0.title) == title }
    }

    static func reminder(for meeting: Meeting, previousMeetingID: UUID?, in meetings: [Meeting],
                         previousLinks: [UUID: UUID] = [:], now: Date = Date()) -> CarryoverReminder {
        guard let previousMeetingID else {
            return CarryoverReminder(source: nil, linkedMeetingIDs: [], tasks: [], issue: nil)
        }
        let byID = uniqueMeetings(meetings)
        guard finite(now), finite(meeting.createdAt), let first = byID[previousMeetingID],
              isEarlier(first, than: meeting, now: now) else {
            return CarryoverReminder(source: nil, linkedMeetingIDs: [], tasks: [], issue: .unavailableSource)
        }
        var cursor = first
        var visited: Set<UUID> = [meeting.id]
        var linked: [UUID] = []
        var tasks: [CarryoverTask] = []
        var issue: CarryoverReminder.Issue?
        while visited.insert(cursor.id).inserted {
            linked.append(cursor.id)
            for action in cursor.notes?.actions ?? [] where !cursor.completedActions.contains(action.id) {
                tasks.append(CarryoverTask(sourceMeetingID: cursor.id, sourceMeetingTitle: cursor.title,
                    sourceMeetingDate: cursor.createdAt, action: action))
            }
            guard let nextID = previousLinks[cursor.id] else { break }
            guard !visited.contains(nextID), let next = byID[nextID], isEarlier(next, than: cursor, now: now) else {
                issue = .brokenHistory
                break
            }
            cursor = next
        }
        return CarryoverReminder(source: first, linkedMeetingIDs: linked, tasks: tasks, issue: issue)
    }

    /// Call immediately before saving completion, so a stale row cannot complete
    /// work after its link, source, notes or completion state changed.
    static func containsPendingTask(sourceMeetingID: UUID, actionID: String, for meeting: Meeting,
                                    previousMeetingID: UUID?, in meetings: [Meeting],
                                    previousLinks: [UUID: UUID] = [:], now: Date = Date()) -> Bool {
        reminder(for: meeting, previousMeetingID: previousMeetingID, in: meetings,
                 previousLinks: previousLinks, now: now).tasks.contains {
            $0.sourceMeetingID == sourceMeetingID && $0.action.id == actionID
        }
    }

    private static func isEarlier(_ candidate: Meeting, than meeting: Meeting, now: Date) -> Bool {
        candidate.id != meeting.id && finite(candidate.createdAt) && finite(meeting.createdAt) &&
            candidate.createdAt < meeting.createdAt && candidate.createdAt <= now
    }

    private static func finite(_ date: Date) -> Bool { date.timeIntervalSinceReferenceDate.isFinite }

    private static func uniqueMeetings(_ meetings: [Meeting]) -> [UUID: Meeting] {
        Dictionary(grouping: meetings, by: \.id).compactMapValues { $0.count == 1 ? $0[0] : nil }
    }

    private static func recurringTitle(_ raw: String) -> String? {
        let title = raw.precomposedStringWithCanonicalMapping
            .split(whereSeparator: \.isWhitespace).joined(separator: " ")
            .lowercased(with: Locale(identifier: "tr_TR"))
        let generic: Set<String> = ["", "toplantı", "yeni toplantı", "isimsiz toplantı", "meeting", "new meeting", "untitled meeting"]
        return generic.contains(title) ? nil : title
    }
}
