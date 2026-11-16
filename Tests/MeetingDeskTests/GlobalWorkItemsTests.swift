import XCTest
@testable import MeetingDesk

final class GlobalWorkItemsTests: XCTestCase {
    private func meeting(_ title: String, date: Double, actions: [ActionItem]) -> Meeting {
        var meeting = Meeting(title: title)
        meeting.createdAt = Date(timeIntervalSinceReferenceDate: date)
        meeting.notes = MeetingNotes(summary: "Özet", decisions: [], actions: actions, questions: [], ideas: [], topics: [])
        return meeting
    }

    func testSameTextAndActionIDsStayDistinctAcrossMeetingsAndUnknownMetadataIsKept() throws {
        let action = ActionItem(id: "a", text: "Kontrol et", owner: nil, due: nil, evidence: [])
        let first = meeting("İlk", date: 1, actions: [action]), second = meeting("Son", date: 2, actions: [action])
        let snapshot = GlobalWorkItems.snapshot(meetings: [first, second], catalog: .init())
        XCTAssertEqual(snapshot.rows.count, 2)
        XCTAssertEqual(Set(snapshot.rows.map(\.id)).count, 2)
        XCTAssertEqual(snapshot.rows.map(\.meetingID), [second.id, first.id])
        XCTAssertTrue(try XCTUnwrap(snapshot.rows.first).owner.isEmpty)
        XCTAssertTrue(try XCTUnwrap(snapshot.rows.first).due.isEmpty)
    }

    func testProjectSeriesOwnerStatusAndTurkishSearchUseExplicitMembership() {
        let first = MeetingProject(name: "Ürün"), second = MeetingProject(name: "Ürün")
        let series = MeetingSeries(name: "Haftalık", projectID: first.id)
        let catalog = WorkspaceCatalog(projects: [first, second], series: [series])
        var assigned = meeting("Planlama", date: 1, actions: [.init(id: "a", text: "İŞ PLANI", owner: "Elif", due: "gelecek cuma", evidence: [])])
        assigned.projectID = first.id; assigned.seriesID = series.id; assigned.completedActions = ["a"]
        let unknown = meeting("Sahipsiz", date: 2, actions: [.init(id: "b", text: "Kontrol", owner: nil, due: nil, evidence: [])])
        var filter = GlobalWorkItemsFilter(); filter.status = .all
        filter.project = .id(second.id)
        XCTAssertTrue(GlobalWorkItems.snapshot(meetings: [assigned, unknown], catalog: catalog, filter: filter).rows.isEmpty)
        filter.project = .id(first.id); filter.series = .id(series.id); filter.owner = "Elif"; filter.status = .completed; filter.search = "iş planı"
        XCTAssertEqual(GlobalWorkItems.snapshot(meetings: [assigned, unknown], catalog: catalog, filter: filter).rows.map(\.meetingID), [assigned.id])
        filter = .init(); filter.owner = ""; filter.project = .unassigned
        XCTAssertEqual(GlobalWorkItems.snapshot(meetings: [assigned, unknown], catalog: catalog, filter: filter).rows.map(\.meetingID), [unknown.id])
    }

    func testRawDueDatesNeverDetermineOrderAndSourcesOnlyReferenceUniqueSegments() throws {
        var old = meeting("Eski", date: 1, actions: [.init(id: "a", text: "A", due: "yarın", evidence: ["valid", "missing", "valid", "duplicate"])])
        old.segments = [.init(id: "valid", speaker: "A", start: 12, end: 14, text: "Kaynak"),
            .init(id: "duplicate", speaker: "A", start: 0, end: 1, text: "Bir"), .init(id: "duplicate", speaker: "A", start: 2, end: 3, text: "İki")]
        let recent = meeting("Yeni", date: 2, actions: [.init(id: "b", text: "B", due: "2030-01-01", evidence: [])])
        let rows = GlobalWorkItems.snapshot(meetings: [old, recent], catalog: .init()).rows
        XCTAssertEqual(rows.map(\.meetingID), [recent.id, old.id])
        XCTAssertEqual(rows.map(\.due), ["2030-01-01", "yarın"])
        XCTAssertEqual(try XCTUnwrap(rows.last).sources, [.init(id: "valid", time: 12)])
    }

    func testMeetingDateFilterUsesInclusiveSourceTimestampWindowsWithInjectedClock() {
        let now = Date(timeIntervalSinceReferenceDate: 2_000_000_000)
        let day = 86_400.0
        func fixture(_ title: String, age: Double) -> Meeting {
            meeting(title, date: now.timeIntervalSinceReferenceDate - age,
                actions: [.init(id: "a", text: title, due: "yarın veya 2030-01-01", evidence: [])])
        }
        let today = fixture("Şimdi", age: 0)
        let atSeven = fixture("Yedi gün sınırı", age: 7 * day)
        let beforeSeven = fixture("Yedi gün dışı", age: 7 * day + 1)
        let atThirty = fixture("Otuz gün sınırı", age: 30 * day)
        let beforeThirty = fixture("Otuz gün dışı", age: 30 * day + 1)
        let future = fixture("Gelecek", age: -1)
        let all = [beforeSeven, today, beforeThirty, atSeven, future, atThirty]
        var filter = GlobalWorkItemsFilter()
        XCTAssertEqual(GlobalWorkItems.snapshot(meetings: all, catalog: .init(), filter: filter, now: now).rows.count, 6)
        filter.meetingDate = .last7Days
        XCTAssertEqual(GlobalWorkItems.snapshot(meetings: all, catalog: .init(), filter: filter, now: now).rows.map(\.meetingID), [today.id, atSeven.id])
        filter.meetingDate = .last30Days
        XCTAssertEqual(GlobalWorkItems.snapshot(meetings: all, catalog: .init(), filter: filter, now: now).rows.map(\.meetingID), [today.id, atSeven.id, beforeSeven.id, atThirty.id])
        XCTAssertEqual(GlobalWorkItems.snapshot(meetings: [atSeven], catalog: .init(), filter: .init(meetingDate: .last7Days), now: now.addingTimeInterval(1)).rows.count, 0)
    }

    func testMeetingDateFilterCombinesWithOwnerProjectSeriesStatusAndSearch() {
        let now = Date(timeIntervalSinceReferenceDate: 2_000_000_000)
        let project = MeetingProject(name: "Ürün")
        let series = MeetingSeries(name: "Haftalık", projectID: project.id)
        let catalog = WorkspaceCatalog(projects: [project], series: [series])
        var matching = meeting("Planlama", date: now.timeIntervalSinceReferenceDate - 100,
            actions: [.init(id: "a", text: "İş planı", owner: "Elif", due: "geçen yıl", evidence: [])])
        matching.projectID = project.id; matching.seriesID = series.id; matching.completedActions = ["a"]
        var older = matching; older.id = UUID(); older.createdAt = now.addingTimeInterval(-31 * 86_400)
        var filter = GlobalWorkItemsFilter()
        filter.owner = "Elif"; filter.project = .id(project.id); filter.series = .id(series.id)
        filter.status = .completed; filter.search = "iş planı"; filter.meetingDate = .last30Days
        XCTAssertEqual(GlobalWorkItems.snapshot(meetings: [older, matching], catalog: catalog, filter: filter, now: now).rows.map(\.meetingID), [matching.id])
        filter.status = .open
        XCTAssertTrue(GlobalWorkItems.snapshot(meetings: [older, matching], catalog: catalog, filter: filter, now: now).rows.isEmpty)
    }

    func testDateFilterInvalidatesCacheButClockAloneDoesNot() {
        let now = Date(timeIntervalSinceReferenceDate: 2_000_000_000)
        let item = meeting("Eski", date: now.addingTimeInterval(-8 * 86_400).timeIntervalSinceReferenceDate,
            actions: [.init(id: "a", text: "Kontrol", evidence: [])])
        var filter = GlobalWorkItemsFilter(), cache = GlobalWorkItemsCache()
        XCTAssertTrue(cache.refresh(meetings: [item], catalog: .init(), filter: filter, now: now))
        XCTAssertEqual(cache.snapshot.rows.count, 1)
        filter.meetingDate = .last7Days
        XCTAssertTrue(cache.refresh(meetings: [item], catalog: .init(), filter: filter, now: now))
        XCTAssertTrue(cache.snapshot.rows.isEmpty)
        XCTAssertFalse(cache.refresh(meetings: [item], catalog: .init(), filter: filter, now: now.addingTimeInterval(60)))
        XCTAssertEqual(cache.buildCount, 2)
    }

    func testAmbiguousActionAndMeetingIDsAreNotOfferedForCompletion() throws {
        let action = ActionItem(id: "a", text: "Kontrol", evidence: [])
        let duplicateActions = meeting("Tek", date: 1, actions: [action, action])
        let duplicateMeeting = meeting("Çift", date: 2, actions: [action])
        let snapshot = GlobalWorkItems.snapshot(meetings: [duplicateActions, duplicateMeeting, duplicateMeeting], catalog: .init())
        XCTAssertTrue(snapshot.rows.isEmpty); XCTAssertEqual(snapshot.ambiguousCount, 4)
        let row = try XCTUnwrap(GlobalWorkItems.snapshot(meetings: [duplicateMeeting], catalog: .init()).rows.first)
        XCTAssertFalse(GlobalWorkItems.isCurrent(row, in: [duplicateMeeting, duplicateMeeting]))
    }

    func testCacheOnlyRebuildsForMeetingCatalogOrFilterChanges() throws {
        var cache = GlobalWorkItemsCache()
        var item = meeting("Toplantı", date: 1, actions: [.init(id: "a", text: "Kontrol", evidence: [])])
        let project = MeetingProject(name: "İlk ad")
        item.projectID = project.id
        var catalog = WorkspaceCatalog(projects: [project])
        var filter = GlobalWorkItemsFilter()
        XCTAssertTrue(cache.refresh(meetings: [item], catalog: catalog, filter: filter))
        XCTAssertFalse(cache.refresh(meetings: [item], catalog: catalog, filter: filter))
        XCTAssertEqual(cache.buildCount, 1)
        catalog.projects[0].name = "Yeni ad"
        XCTAssertTrue(cache.refresh(meetings: [item], catalog: catalog, filter: filter))
        XCTAssertEqual(cache.snapshot.rows.first?.projectName, "Yeni ad")
        filter.search = "yeni ad"
        XCTAssertTrue(cache.refresh(meetings: [item], catalog: catalog, filter: filter))
        item.completedActions = ["a"]
        XCTAssertTrue(cache.refresh(meetings: [item], catalog: catalog, filter: filter))
        XCTAssertTrue(cache.snapshot.rows.isEmpty)
        XCTAssertEqual(cache.buildCount, 4)
    }

    @MainActor func testCompletionPersistsToOriginalMeetingAndRejectsStaleRows() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MeetingDesk-GlobalWork-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(root: root, initializeSystemServices: false)
        let source = store.newMeeting()
        XCTAssertTrue(store.update(source.id) {
            $0.notes = MeetingNotes(summary: "Özet", decisions: [], actions: [.init(id: "a", text: "Kontrol", owner: "Elif", evidence: [])], questions: [], ideas: [], topics: [])
        })
        let selected = store.newMeeting()
        let row = try XCTUnwrap(GlobalWorkItems.snapshot(meetings: store.meetings, catalog: store.workspaceCatalog).rows.first)
        store.isBusy = true
        XCTAssertFalse(store.setGlobalWorkItemCompletion(row, isCompleted: true))
        store.isBusy = false
        XCTAssertTrue(store.setGlobalWorkItemCompletion(row, isCompleted: true))
        XCTAssertEqual(store.selectedID, selected.id)
        XCTAssertEqual(try store.library.load().meetings.first { $0.id == source.id }?.completedActions, ["a"])
        XCTAssertNil(store.selected?.notes)
        XCTAssertFalse(store.setGlobalWorkItemCompletion(row, isCompleted: false))
        var filter = GlobalWorkItemsFilter(); filter.status = .completed
        let completed = try XCTUnwrap(GlobalWorkItems.snapshot(meetings: store.meetings, catalog: store.workspaceCatalog, filter: filter).rows.first)
        let project = try XCTUnwrap(store.createProject(name: "Yeni proje"))
        XCTAssertTrue(store.assignMeeting(source.id, projectID: project, seriesID: nil))
        XCTAssertFalse(store.setGlobalWorkItemCompletion(completed, isCompleted: false))
        let current = try XCTUnwrap(GlobalWorkItems.snapshot(meetings: store.meetings, catalog: store.workspaceCatalog, filter: filter).rows.first)
        XCTAssertTrue(store.update(source.id) { $0.notes?.actions[0].text = "İçerik değişti" })
        XCTAssertFalse(store.setGlobalWorkItemCompletion(current, isCompleted: false))
    }

    @MainActor func testFailedOriginalMeetingSaveDoesNotCheckOffTask() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MeetingDesk-GlobalWorkFailure-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(root: root, initializeSystemServices: false)
        let source = store.newMeeting()
        XCTAssertTrue(store.update(source.id) { $0.notes = MeetingNotes(summary: "Özet", decisions: [], actions: [.init(id: "a", text: "İş", evidence: [])], questions: [], ideas: [], topics: []) })
        let row = try XCTUnwrap(GlobalWorkItems.snapshot(meetings: store.meetings, catalog: .init()).rows.first)
        let file = store.library.directory(for: source.id).appendingPathComponent("meeting.json")
        try FileManager.default.removeItem(at: file); try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
        XCTAssertFalse(store.setGlobalWorkItemCompletion(row, isCompleted: true))
        XCTAssertTrue(try XCTUnwrap(store.meetings.first { $0.id == source.id }).completedActions.isEmpty)
    }
}
