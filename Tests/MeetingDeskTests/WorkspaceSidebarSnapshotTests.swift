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
}
