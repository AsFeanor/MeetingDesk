import Foundation
import XCTest
@testable import MeetingDesk

final class WorkspaceSidebarSnapshotTests: XCTestCase {
    private var calendar: Calendar {
        var value = Calendar(identifier: .gregorian)
        value.timeZone = TimeZone(secondsFromGMT: 0)!
        value.firstWeekday = 2
        return value
    }
    private var now: Date { date(2026, 11, 15, 12) }
    private func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 9) -> Date {
        calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour))!
    }
    private func notes(actions: [ActionItem] = []) -> MeetingNotes {
        MeetingNotes(summary: "Özet", decisions: [], actions: actions, questions: [], ideas: [], topics: [])
    }
    private func build(_ meetings: [Meeting], profiles: [VoiceProfile] = [], query: String = "", pending: Bool = false) -> WorkspaceSidebarSnapshot {
        WorkspaceSidebarSnapshot.build(meetings: meetings, profiles: profiles, query: query,
            pendingOnly: pending, now: now, calendar: calendar)
    }

    func testDateBucketsPreserveDescendingDateAndStableEqualDateOrder() {
        let today = Meeting(title: "Bugün", createdAt: date(2026, 11, 15))
        let sameDay = Meeting(title: "Aynı zaman", createdAt: today.createdAt)
        let yesterday = Meeting(title: "Dün", createdAt: date(2026, 11, 14))
        let week = Meeting(title: "Bu hafta", createdAt: date(2026, 11, 10))
        let old = Meeting(title: "Önceki", createdAt: date(2026, 10, 30))
        let snapshot = build([old, today, yesterday, week, sameDay])
        XCTAssertEqual(snapshot.groups.map(\.title), ["Bugün", "Dün", "Bu hafta", "Önceki toplantılar"])
        XCTAssertEqual(snapshot.groups.flatMap(\.meetings).map(\.id), [today.id, sameDay.id, yesterday.id, week.id, old.id])
        XCTAssertEqual(snapshot.matchCount, 5)
    }

    func testSearchUsesTranscriptAndPersonalNotesWhilePendingFilterExcludesCompletedActions() {
        let action = ActionItem(id: "a", text: "Takip", owner: nil, due: nil, evidence: [])
        var active = Meeting(title: "Alakasız başlık", createdAt: now)
        active.personalNotes = "BÜTÇE değerlendirmesi"
        active.segments = [TranscriptSegment(id: "s", speaker: "system:A", start: 0, end: 2, text: "Müşteri ihtiyaçları")]
        active.notes = notes(actions: [action])
        var completed = active
        completed.id = UUID()
        completed.completedActions = [action.id]
        let snapshot = build([active, completed], query: "butce müşteri", pending: true)
        XCTAssertEqual(snapshot.matchCount, 1)
        XCTAssertEqual(snapshot.groups.flatMap(\.meetings).map(\.id), [active.id])
        XCTAssertEqual(snapshot.groups.first?.meetings.first?.pendingActionCount, 1)
        XCTAssertEqual(build([completed], query: "butce müşteri").groups.first?.meetings.first?.pendingActionCount, 0)
    }

    func testRowsRetainDisplayMetadataAndRefreshAfterActualArchiveChanges() throws {
        var meeting = Meeting(title: "İlk başlık", createdAt: now)
        meeting.duration = 85
        meeting.segments = [TranscriptSegment(id: "s", speaker: "system:A", start: 0, end: 3, text: "İçerik")]
        meeting.notes = notes()
        meeting.reviewedAt = now
        let before = build([meeting])
        let row = try XCTUnwrap(before.groups.first?.meetings.first)
        XCTAssertTrue(row.hasNotes)
        XCTAssertTrue(row.hasTranscript)
        XCTAssertTrue(row.notesAreReviewed)
        XCTAssertEqual(row.duration, 85)
        XCTAssertEqual(row.createdAtLabel, meeting.createdAt.formatted(.dateTime.day().month(.abbreviated)))
        meeting.title = "Düzenlenmiş başlık"
        meeting.notesNeedRefresh = true
        let after = build([meeting])
        XCTAssertNotEqual(before, after)
        XCTAssertEqual(after.groups.first?.meetings.first?.title, "Düzenlenmiş başlık")
        XCTAssertEqual(after.groups.first?.meetings.first?.notesAreReviewed, false)
    }

    func testPeopleCountIsWholeArchiveNotOnlyMatchingMeetingsAndDoesNotMutateSources() {
        var visible = Meeting(title: "Aranan toplantı", createdAt: now)
        visible.speakerReviewPeople = [SpeakerReviewPerson(name: "Yerel kişi")]
        let profile = VoiceProfile(name: "Kaydedilmiş kişi", modelID: "synthetic", samples: [[1, 0]], createdAt: now, updatedAt: now)
        var hidden = Meeting(title: "Diğer toplantı", createdAt: date(2026, 11, 1))
        hidden.speakerReviewPeople = [SpeakerReviewPerson(name: profile.name, voiceProfileID: profile.id)]
        let source = [visible, hidden]
        let snapshot = build(source, profiles: [profile], query: "Aranan")
        XCTAssertEqual(snapshot.matchCount, 1)
        XCTAssertEqual(snapshot.peopleCount, 2)
        XCTAssertEqual(build(source, profiles: [profile], query: "Sonuç yok").peopleCount, 2)
        XCTAssertEqual(source, [visible, hidden])
        XCTAssertEqual(profile.samples, [[1, 0]])
    }

    func testFlatItemsKeepHeadingsAndMeetingsInExistingDisplayOrder() {
        let today = Meeting(title: "Bugün", createdAt: date(2026, 11, 15))
        let sameDate = Meeting(title: "Aynı tarih", createdAt: today.createdAt)
        let yesterday = Meeting(title: "Dün", createdAt: date(2026, 11, 14))
        let week = Meeting(title: "Bu hafta", createdAt: date(2026, 11, 10))
        let old = Meeting(title: "Önceki", createdAt: date(2026, 10, 30))
        let snapshot = build([old, today, yesterday, week, sameDate])

        XCTAssertEqual(snapshot.items.map(\.id), [
            .heading(0), .meeting(today.id), .meeting(sameDate.id),
            .heading(1), .meeting(yesterday.id), .heading(2), .meeting(week.id),
            .heading(3), .meeting(old.id)
        ])
        XCTAssertEqual(snapshot.items.compactMap { item -> String? in
            guard case .heading(_, let title) = item else { return nil }
            return title
        }, snapshot.groups.map(\.title))
        XCTAssertEqual(snapshot.items.compactMap { item -> WorkspaceSidebarSnapshot.Row? in
            guard case .meeting(let row) = item else { return nil }
            return row
        }, snapshot.groups.flatMap(\.meetings))
    }

    func testHistoricalBucketExposesEveryMeetingAsAnIndependentItem() {
        let old = (0..<240).map { index in
            Meeting(title: "Eski toplantı \(index)", createdAt: date(2026, 10, 1).addingTimeInterval(Double(index)))
        }
        let snapshot = build(old)

        XCTAssertEqual(snapshot.groups.count, 1)
        XCTAssertEqual(snapshot.groups.first?.id, 3)
        XCTAssertEqual(snapshot.items.count, old.count + 1)
        XCTAssertEqual(snapshot.items.first?.id, .heading(3))
        XCTAssertEqual(snapshot.items.dropFirst().map(\.id), old.reversed().map { .meeting($0.id) })
        XCTAssertEqual(Set(snapshot.items.map(\.id)).count, snapshot.items.count)
    }

    func testFilteredItemsKeepStableMeetingIdentityAndOmitEmptyHeadings() {
        let action = ActionItem(id: "a", text: "Takip", owner: nil, due: nil, evidence: [])
        var matching = Meeting(title: "Aranan", createdAt: date(2026, 10, 1))
        matching.notes = notes(actions: [action])
        let other = Meeting(title: "Diğer", createdAt: now)
        let original = build([other, matching])
        let filtered = build([other, matching], query: "Aranan", pending: true)

        XCTAssertEqual(filtered.items.map(\.id), [.heading(3), .meeting(matching.id)])
        XCTAssertEqual(filtered.items.last?.id, original.items.last?.id)
        matching.title = "Aranan, düzenlendi"
        let renamed = build([other, matching], query: "Aranan", pending: true)
        XCTAssertEqual(renamed.items.map(\.id), filtered.items.map(\.id))
        XCTAssertNotEqual(renamed.items, filtered.items)
        matching.completedActions.insert(action.id)
        XCTAssertTrue(build([other, matching], query: "Aranan", pending: true).items.isEmpty)
        XCTAssertTrue(WorkspaceSidebarSnapshot.empty.items.isEmpty)
    }
}
