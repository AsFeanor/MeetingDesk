import Foundation
import XCTest
@testable import MeetingDesk

final class CarryoverActionsTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 2_000_000)
    private func meeting(_ title: String, daysAgo: Double, actions: [ActionItem] = []) -> Meeting {
        var value = Meeting(title: title, createdAt: now.addingTimeInterval(-daysAgo * 86_400))
        value.notes = MeetingNotes(summary: "Örnek özet", decisions: [], actions: actions, questions: [], ideas: [], topics: [])
        return value
    }
    private func action(_ id: String = "a", text: String = "Sonucu kontrol et", owner: String? = nil) -> ActionItem {
        ActionItem(id: id, text: text, owner: owner, due: nil, evidence: ["source-1"])
    }

    func testTitleMatchIsOnlyASuggestionUntilTheUserLinksTheMeeting() throws {
        let current = meeting("  PM   Catchup\n", daysAgo: 0)
        let previous = meeting("pm catchup", daysAgo: 1, actions: [action()])
        let unrelated = meeting("Başka proje", daysAgo: 0.5, actions: [action("other")])
        let archive = [current, unrelated, previous]

        XCTAssertEqual(CarryoverActions.suggestedPreviousMeeting(for: current, in: archive, now: now)?.id, previous.id)
        let reminder = CarryoverActions.reminder(for: current, previousMeetingID: nil, in: archive, now: now)
        XCTAssertNil(reminder.source)
        XCTAssertTrue(reminder.tasks.isEmpty)
        XCTAssertNil(reminder.issue)
        XCTAssertFalse(CarryoverActions.containsPendingTask(sourceMeetingID: previous.id, actionID: "a", for: current,
            previousMeetingID: nil, in: archive, now: now))
    }

    func testGenericOrDifferentTitlesNeverCreateAnAutomaticSuggestion() {
        let generic = meeting("Yeni toplantı", daysAgo: 0)
        let genericPrevious = meeting("YENİ TOPLANTI", daysAgo: 1, actions: [action()])
        XCTAssertNil(CarryoverActions.suggestedPreviousMeeting(for: generic, in: [generic, genericPrevious], now: now))
        let dated = meeting("PM Catchup 15 Kasım", daysAgo: 0)
        let previous = meeting("PM Catchup 14 Kasım", daysAgo: 1, actions: [action()])
        XCTAssertNil(CarryoverActions.suggestedPreviousMeeting(for: dated, in: [dated, previous], now: now))
        let distinctTurkish = meeting("iş", daysAgo: 0)
        let distinctPrevious = meeting("is", daysAgo: 1, actions: [action()])
        XCTAssertNil(CarryoverActions.suggestedPreviousMeeting(for: distinctTurkish, in: [distinctTurkish, distinctPrevious], now: now))
    }

    func testEligibilityExcludesSelfFutureEqualDateInvalidDatesAndAmbiguousArchiveIDs() {
        let current = meeting("Görüşme", daysAgo: -3)
        let previous = meeting("Geçmiş", daysAgo: 1)
        let future = meeting("Henüz gerçekleşmedi", daysAgo: -1)
        var sameTime = meeting("Aynı an", daysAgo: 0); sameTime.createdAt = current.createdAt
        var invalid = meeting("Geçersiz", daysAgo: 2); invalid.createdAt = Date(timeIntervalSince1970: .nan)
        let duplicate = meeting("Belirsiz", daysAgo: 4)
        var duplicateCopy = duplicate; duplicateCopy.title = "Aynı kimlikle başka kopya"
        let eligible = CarryoverActions.eligiblePreviousMeetings(for: current,
            in: [current, previous, future, sameTime, invalid, duplicate, duplicateCopy], now: now)
        XCTAssertEqual(eligible.map(\.id), [previous.id])
    }

    func testOnlyOriginalStillOpenTasksAreShownAndOwnerlessWorkIsKept() throws {
        let current = meeting("Yeni görüşme", daysAgo: 0, actions: [action("current", text: "Yeni iş")])
        var previous = meeting("Önceki", daysAgo: 1, actions: [action("done"), action("pending", owner: nil)])
        previous.completedActions = ["done"]
        let originalCurrent = current, originalPrevious = previous
        let reminder = CarryoverActions.reminder(for: current, previousMeetingID: previous.id, in: [current, previous], now: now)
        let task = try XCTUnwrap(reminder.tasks.first)
        XCTAssertEqual(reminder.tasks.count, 1)
        XCTAssertEqual(task.sourceMeetingID, previous.id)
        XCTAssertEqual(task.action.id, "pending")
        XCTAssertNil(task.action.owner)
        XCTAssertEqual(task.action.evidence, ["source-1"])
        XCTAssertEqual(current, originalCurrent)
        XCTAssertEqual(previous, originalPrevious)
    }

    func testSavedChainKeepsOlderOriginalTasksDistinctEvenWhenTheirActionIDsMatch() {
        let current = meeting("Ekip", daysAgo: 0)
        let previous = meeting("Ekip", daysAgo: 1, actions: [action("same", text: "Birinci iş")])
        let older = meeting("Ekip", daysAgo: 2, actions: [action("same", text: "İkinci iş")])
        let reminder = CarryoverActions.reminder(for: current, previousMeetingID: previous.id,
            in: [current, previous, older], previousLinks: [previous.id: older.id], now: now)
        XCTAssertEqual(reminder.linkedMeetingIDs, [previous.id, older.id])
        XCTAssertEqual(reminder.tasks.map(\.sourceMeetingID), [previous.id, older.id])
        XCTAssertEqual(Set(reminder.tasks.map(\.id)).count, 2)
        XCTAssertNil(reminder.issue)
        var completedPrevious = previous
        completedPrevious.completedActions.insert("same")
        let refreshed = CarryoverActions.reminder(for: current, previousMeetingID: previous.id,
            in: [current, completedPrevious, older], previousLinks: [previous.id: older.id], now: now)
        XCTAssertEqual(refreshed.tasks.map(\.sourceMeetingID), [older.id])
        XCTAssertTrue(current.completedActions.isEmpty)
    }

    func testInvalidExplicitLinkDoesNotFallBackToAnotherSuggestedMeeting() {
        let current = meeting("Ekip", daysAgo: 0)
        let previous = meeting("Ekip", daysAgo: 1, actions: [action()])
        let future = meeting("Ekip", daysAgo: -1, actions: [action()])
        let archive = [current, previous, future]
        for invalidID in [current.id, future.id, UUID()] {
            let reminder = CarryoverActions.reminder(for: current, previousMeetingID: invalidID, in: archive, now: now)
            XCTAssertNil(reminder.source)
            XCTAssertTrue(reminder.tasks.isEmpty)
            XCTAssertEqual(reminder.issue, .unavailableSource)
        }
    }

    func testBrokenHistoryRetainsValidWorkWithoutFollowingCyclesMissingOrNewerLinks() {
        let current = meeting("Ekip", daysAgo: 0)
        let previous = meeting("Ekip", daysAgo: 1, actions: [action("previous")])
        let older = meeting("Ekip", daysAgo: 2, actions: [action("older")])
        for badLink in [current.id, previous.id, UUID()] {
            let reminder = CarryoverActions.reminder(for: current, previousMeetingID: previous.id,
                in: [current, previous, older], previousLinks: [previous.id: older.id, older.id: badLink], now: now)
            XCTAssertEqual(reminder.tasks.map(\.action.id), ["previous", "older"])
            XCTAssertEqual(reminder.linkedMeetingIDs, [previous.id, older.id])
            XCTAssertEqual(reminder.issue, .brokenHistory)
        }
    }

    func testNoArbitraryHistoryLimitDropsStillOpenTasks() {
        let current = meeting("Ekip", daysAgo: 0)
        let history = (1...80).map { meeting("Ekip", daysAgo: Double($0), actions: [action("task-\($0)")]) }
        let links = Dictionary(uniqueKeysWithValues: zip(history, history.dropFirst()).map { ($0.id, $1.id) })
        let reminder = CarryoverActions.reminder(for: current, previousMeetingID: history[0].id,
            in: history + [current], previousLinks: links, now: now)
        XCTAssertEqual(reminder.tasks.count, 80)
        XCTAssertEqual(reminder.linkedMeetingIDs.count, 80)
        XCTAssertNil(reminder.issue)
    }

    func testStaleCompletionIsRejectedAfterSourceCompletionNotesOrLinkChange() {
        let current = meeting("Ekip", daysAgo: 0)
        var previous = meeting("Ekip", daysAgo: 1, actions: [action("pending")])
        func contains(_ source: Meeting, link: UUID?) -> Bool {
            CarryoverActions.containsPendingTask(sourceMeetingID: previous.id, actionID: "pending", for: current,
                previousMeetingID: link, in: [current, source], now: now)
        }
        XCTAssertTrue(contains(previous, link: previous.id))
        XCTAssertFalse(contains(previous, link: nil))
        previous.completedActions.insert("pending")
        XCTAssertFalse(contains(previous, link: previous.id))
        previous.completedActions = []
        previous.notes?.actions = []
        XCTAssertFalse(contains(previous, link: previous.id))
    }
}
