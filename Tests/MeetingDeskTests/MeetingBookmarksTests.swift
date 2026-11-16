import XCTest
@testable import MeetingDesk

final class MeetingBookmarksTests: XCTestCase {
    func testTimesAndNotesAreValidatedWithoutMovingBookmarks() throws {
        let value = try MeetingBookmarkPolicy.make(time: 12.75, limit: 40, note: "  Ask later  ")
        XCTAssertEqual(value.time, 12.75)
        XCTAssertEqual(value.note, "Ask later")
        for time in [-1.0, .nan, .infinity, 40.1] {
            XCTAssertThrowsError(try MeetingBookmarkPolicy.make(time: time, limit: 40))
        }
        XCTAssertThrowsError(try MeetingBookmarkPolicy.make(time: 0, limit: .infinity))
        XCTAssertThrowsError(try MeetingBookmarkPolicy.make(time: 0, limit: 10, note: String(repeating: "x", count: 1001)))
        XCTAssertEqual(try MeetingBookmarkPolicy.make(time: 0, limit: 0).time, 0)
    }
    func testLegacyArchiveDecodesWithoutNewFieldsAndBookmarkRoundTrips() throws {
        var meeting = Meeting(title: "Synthetic archive")
        let encoded = try JSONEncoder().encode(meeting)
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        for key in ["bookmarks", "projectID", "seriesID"] { json.removeValue(forKey: key) }
        let restored = try JSONDecoder().decode(Meeting.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertNil(restored.bookmarks); XCTAssertNil(restored.projectID); XCTAssertNil(restored.seriesID)
        meeting.bookmarks = [MeetingBookmark(time: 14, note: "Important")]
        meeting.projectID = UUID(); meeting.seriesID = UUID()
        XCTAssertEqual(try JSONDecoder().decode(Meeting.self, from: JSONEncoder().encode(meeting)), meeting)
    }
    func testReadingOrderRejectsAmbiguousIDsAndSourceDoesNotJumpAcrossGaps() {
        var meeting = Meeting(title: "Synthetic source")
        meeting.duration = 50
        meeting.segments = [
            .init(id: "first", speaker: "a", start: 2, end: 4, text: "First"),
            .init(id: "last", speaker: "b", start: 30, end: 35, text: "Last")
        ]
        let first = MeetingBookmark(time: 3), late = MeetingBookmark(time: 32)
        let duplicate = MeetingBookmark(time: 4)
        meeting.bookmarks = [late, duplicate, first, duplicate, .init(time: .nan)]
        XCTAssertEqual(MeetingBookmarkPolicy.ordered(in: meeting).map(\.id), [first.id, late.id])
        XCTAssertEqual(MeetingBookmarkPolicy.source(for: first, in: meeting)?.id, "first")
        XCTAssertNil(MeetingBookmarkPolicy.source(for: .init(time: 20), in: meeting))
        meeting.segments.append(meeting.segments[0])
        XCTAssertNil(MeetingBookmarkPolicy.source(for: first, in: meeting))
    }
    @MainActor func testStorePersistsEditsAndDeletesOnlyMarkerMetadata() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(root: root, initializeSystemServices: false)
        var value = store.newMeeting(); value.duration = 60
        value.segments = [.init(id: "s", speaker: "a", start: 0, end: 50, text: "Synthetic transcript")]
        value.notes = .init(summary: "Summary", decisions: [], actions: [], questions: [], ideas: [], topics: [])
        value.reviewedAt = Date(); value.projectID = UUID(); value.seriesID = UUID()
        XCTAssertTrue(store.update(value.id) { $0 = value })
        let original = try XCTUnwrap(store.selected)
        let id = try XCTUnwrap(store.addBookmark(at: 24, note: "Review", in: value.id))
        XCTAssertEqual(try store.library.load().meetings.first?.bookmarks?.first?.id, id)
        XCTAssertTrue(store.editBookmark(id, note: "New note", in: value.id))
        XCTAssertEqual(store.selected?.bookmarks?.first?.note, "New note")
        XCTAssertEqual(store.selected?.segments, original.segments)
        XCTAssertEqual(store.selected?.notes, original.notes)
        XCTAssertEqual(store.selected?.reviewedAt, original.reviewedAt)
        XCTAssertEqual(store.selected?.projectID, original.projectID)
        XCTAssertTrue(store.deleteBookmark(id, in: value.id))
        XCTAssertEqual(store.selected?.bookmarks, [])
        XCTAssertEqual(try store.library.load().meetings.first?.bookmarks, [])
    }
    @MainActor func testBusyWrongMeetingAndFailedSaveCannotAddOrEditBookmarks() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(root: root, initializeSystemServices: false)
        let meeting = store.newMeeting()
        XCTAssertTrue(store.update(meeting.id) { $0.duration = 30 })
        XCTAssertFalse(store.canMarkImportantMoment)
        XCTAssertNil(store.markImportantMoment())
        XCTAssertNil(store.addBookmark(at: 31, in: meeting.id))
        XCTAssertNil(store.addBookmark(at: 5, in: UUID()))
        let id = try XCTUnwrap(store.addBookmark(at: 5, in: meeting.id))
        store.isBusy = true
        XCTAssertNil(store.addBookmark(at: 6, in: meeting.id))
        XCTAssertFalse(store.editBookmark(id, note: "Wrong", in: meeting.id))
        XCTAssertFalse(store.deleteBookmark(id, in: meeting.id))
        store.isBusy = false
        let before = store.selected
        let folder = store.library.directory(for: meeting.id)
        try FileManager.default.removeItem(at: folder)
        try Data().write(to: folder)
        XCTAssertNil(store.addBookmark(at: 6, in: meeting.id))
        XCTAssertEqual(store.selected, before)
    }
}
