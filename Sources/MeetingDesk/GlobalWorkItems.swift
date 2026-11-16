import Foundation

enum WorkItemStatus: String, CaseIterable, Identifiable {
    case open, completed, all
    var id: String { rawValue }
    var label: String {
        switch self { case .open: return "Açık"; case .completed: return "Tamamlanan"; case .all: return "Tümü" }
    }
}

enum WorkItemMembershipFilter: Hashable {
    case all, unassigned, id(UUID)
    func includes(_ value: UUID?) -> Bool {
        switch self { case .all: return true; case .unassigned: return value == nil; case .id(let id): return value == id }
    }
}

enum WorkItemMeetingDateFilter: String, CaseIterable, Identifiable {
    case all, last7Days, last30Days
    var id: String { rawValue }
    var label: String {
        switch self { case .all: return "Tüm tarihler"; case .last7Days: return "Son 7 gün"; case .last30Days: return "Son 30 gün" }
    }

    /// Trailing, inclusive elapsed-day windows refer only to the source meeting timestamp.
    /// Free-form action due strings are never interpreted as dates.
    func includes(_ date: Date, now: Date) -> Bool {
        let days: Double
        switch self { case .all: return true; case .last7Days: days = 7; case .last30Days: days = 30 }
        guard date.timeIntervalSinceReferenceDate.isFinite, now.timeIntervalSinceReferenceDate.isFinite else { return false }
        return date <= now && date >= now.addingTimeInterval(-days * 86_400)
    }
}

struct GlobalWorkItemsFilter: Equatable {
    var search = ""
    // nil is every owner; an empty string explicitly selects unspecified owners.
    var owner: String?
    var project: WorkItemMembershipFilter = .all
    var series: WorkItemMembershipFilter = .all
    var status: WorkItemStatus = .open
    var meetingDate: WorkItemMeetingDateFilter = .all
}

struct WorkItemSource: Identifiable, Equatable {
    let id: String
    let time: Double
}

struct GlobalWorkItem: Identifiable, Equatable {
    let meetingID: UUID
    let meetingTitle: String
    let meetingDate: Date
    let projectID: UUID?
    let seriesID: UUID?
    let projectName: String?
    let seriesName: String?
    let action: ActionItem
    let isCompleted: Bool
    let notesNeedRefresh: Bool
    let sources: [WorkItemSource]
    var id: String { meetingID.uuidString + ":" + action.id }
    var owner: String { action.owner?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
    var due: String { action.due?.trimmingCharacters(in: .whitespacesAndNewlines) ?? "" }
}

struct GlobalWorkItemsSnapshot: Equatable {
    var rows: [GlobalWorkItem] = []
    var owners: [String] = []
    var totalCount = 0
    var ambiguousCount = 0
}

enum GlobalWorkItems {
    static func snapshot(meetings: [Meeting], catalog: WorkspaceCatalog, filter: GlobalWorkItemsFilter = .init(), now: Date = Date()) -> GlobalWorkItemsSnapshot {
        let meetingGroups = Dictionary(grouping: meetings, by: \.id)
        let projects = Dictionary(grouping: catalog.projects, by: \.id).compactMapValues { $0.count == 1 ? $0[0].name : nil }
        let series = Dictionary(grouping: catalog.series, by: \.id).compactMapValues { $0.count == 1 ? $0[0].name : nil }
        var all: [GlobalWorkItem] = []
        var ambiguous = meetingGroups.values.filter { $0.count != 1 }.reduce(0) { $0 + $1.reduce(0) { $0 + ($1.notes?.actions.count ?? 0) } }
        for meeting in meetingGroups.values.compactMap({ $0.count == 1 ? $0[0] : nil }).sorted(by: meetingOrder) {
            let actions = meeting.notes?.actions ?? []
            let counts = Dictionary(grouping: actions, by: \.id).mapValues(\.count)
            let segments = Dictionary(grouping: meeting.segments, by: \.id)
            for action in actions {
                guard counts[action.id] == 1, !action.id.isEmpty else { ambiguous += 1; continue }
                var seen: Set<String> = []
                let sources = action.evidence.compactMap { id -> WorkItemSource? in
                    guard seen.insert(id).inserted, let matches = segments[id], matches.count == 1,
                          let segment = matches.first, segment.start.isFinite, segment.start >= 0 else { return nil }
                    return WorkItemSource(id: id, time: segment.start)
                }
                all.append(GlobalWorkItem(meetingID: meeting.id, meetingTitle: meeting.title, meetingDate: meeting.createdAt,
                    projectID: meeting.projectID, seriesID: meeting.seriesID,
                    projectName: meeting.projectID.map { projects[$0] ?? "Kullanılamayan proje" },
                    seriesName: meeting.seriesID.map { series[$0] ?? "Kullanılamayan seri" }, action: action,
                    isCompleted: meeting.completedActions.contains(action.id), notesNeedRefresh: meeting.notesNeedRefresh, sources: sources))
            }
        }
        let query = folded(filter.search.trimmingCharacters(in: .whitespacesAndNewlines))
        let rows = all.filter { row in
            guard filter.project.includes(row.projectID), filter.series.includes(row.seriesID),
                  filter.owner.map({ $0 == row.owner }) ?? true,
                  filter.meetingDate.includes(row.meetingDate, now: now) else { return false }
            switch filter.status {
            case .open: if row.isCompleted { return false }
            case .completed: if !row.isCompleted { return false }
            case .all: break
            }
            guard !query.isEmpty else { return true }
            return [row.action.text, row.owner, row.due, row.meetingTitle, row.projectName ?? "", row.seriesName ?? ""]
                .contains { folded($0).contains(query) }
        }
        return GlobalWorkItemsSnapshot(rows: rows, owners: Set(all.map(\.owner).filter { !$0.isEmpty }).sorted {
            $0.localizedStandardCompare($1) == .orderedAscending
        }, totalCount: all.count, ambiguousCount: ambiguous)
    }

    static func isCurrent(_ row: GlobalWorkItem, in meetings: [Meeting]) -> Bool {
        let matches = meetings.filter { $0.id == row.meetingID }
        guard matches.count == 1, let meeting = matches.first,
              meeting.projectID == row.projectID, meeting.seriesID == row.seriesID,
              meeting.completedActions.contains(row.action.id) == row.isCompleted else { return false }
        let actions = meeting.notes?.actions.filter { $0.id == row.action.id } ?? []
        return !row.action.id.isEmpty && actions.count == 1 && actions.first == row.action
    }

    private static func folded(_ value: String) -> String {
        value.lowercased(with: Locale(identifier: "tr_TR")).folding(options: [.diacriticInsensitive], locale: Locale(identifier: "tr_TR"))
    }

    static func meetingOrder(_ lhs: Meeting, _ rhs: Meeting) -> Bool {
        let left = lhs.createdAt.timeIntervalSinceReferenceDate
        let right = rhs.createdAt.timeIntervalSinceReferenceDate
        if left.isFinite != right.isFinite { return left.isFinite }
        if left.isFinite, left != right { return left > right }
        return lhs.id.uuidString < rhs.id.uuidString
    }
}

/// Playback, metering and unrelated AppStore publications cannot rebuild this projection.
struct GlobalWorkItemsCache {
    private var meetings: [Meeting]?
    private var catalog: WorkspaceCatalog?
    private var filter: GlobalWorkItemsFilter?
    private(set) var snapshot = GlobalWorkItemsSnapshot()
    private(set) var buildCount = 0

    @discardableResult mutating func refresh(meetings: [Meeting], catalog: WorkspaceCatalog, filter: GlobalWorkItemsFilter, now: Date = Date()) -> Bool {
        guard self.meetings != meetings || self.catalog != catalog || self.filter != filter else { return false }
        self.meetings = meetings; self.catalog = catalog; self.filter = filter
        snapshot = GlobalWorkItems.snapshot(meetings: meetings, catalog: catalog, filter: filter, now: now)
        buildCount += 1
        return true
    }
}
