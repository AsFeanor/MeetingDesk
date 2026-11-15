import XCTest
@testable import MeetingDesk

final class CarryoverStoreTests: XCTestCase {
    @MainActor private func fixture() throws -> (AppStore, Meeting, Meeting) {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("carryover-store-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let domain = "carryover-store-\(UUID())"
        let defaults = try XCTUnwrap(UserDefaults(suiteName: domain))
        addTeardownBlock { defaults.removePersistentDomain(forName: domain) }
        let store = AppStore(root: root, initializeSystemServices: false, audioRetentionDefaults: defaults)
        var source = store.newMeeting(); source.createdAt = Date().addingTimeInterval(-86_400)
        source.notes = .init(summary: "Önceki", decisions: [], actions: [
            .init(id: "todo", text: "Kontrolü yap", evidence: [])
        ], questions: [], ideas: [], topics: [])
        XCTAssertTrue(store.update(source.id) { $0 = source })
        let current = store.newMeeting()
        return (store, source, current)
    }
    @MainActor func testCompletingReminderUpdatesOriginalTaskWithoutCopyingIntoCurrentMeeting() throws {
        let (store, source, current) = try fixture()
        store.setPreviousMeeting(source.id, for: current.id)
        store.completeCarryoverAction(sourceMeetingID: source.id, actionID: "todo", in: current.id)
        let saved = try store.library.load().meetings
        XCTAssertTrue(try XCTUnwrap(saved.first { $0.id == source.id }).completedActions.contains("todo"))
        let currentSaved = try XCTUnwrap(saved.first { $0.id == current.id })
        XCTAssertNil(currentSaved.notes)
        XCTAssertEqual(currentSaved.previousMeetingID, source.id)
        XCTAssertTrue(currentSaved.completedActions.isEmpty)
    }
    @MainActor func testStaleReminderCannotCompleteWorkAfterLinkChanges() throws {
        let (store, source, current) = try fixture()
        store.setPreviousMeeting(source.id, for: current.id)
        store.setPreviousMeeting(nil, for: current.id)
        store.completeCarryoverAction(sourceMeetingID: source.id, actionID: "todo", in: current.id)
        XCTAssertTrue(try XCTUnwrap(store.meetings.first { $0.id == source.id }).completedActions.isEmpty)
    }
    @MainActor func testBusyAndWrongSelectionCannotChangeLinksOrCompleteOriginalWork() throws {
        let (store, source, current) = try fixture()
        store.isBusy = true
        store.setPreviousMeeting(source.id, for: current.id)
        XCTAssertNil(store.selected?.previousMeetingID)
        store.isBusy = false
        store.setPreviousMeeting(source.id, for: current.id)
        store.selectedID = source.id
        store.completeCarryoverAction(sourceMeetingID: source.id, actionID: "todo", in: current.id)
        XCTAssertTrue(try XCTUnwrap(store.meetings.first { $0.id == source.id }).completedActions.isEmpty)
    }
    @MainActor func testTranscriptHistoryRestoreKeepsCurrentPreviousMeetingLink() throws {
        let (store, source, current) = try fixture()
        try store.library.saveTranscriptVersion(current)
        store.setPreviousMeeting(source.id, for: current.id)
        store.restorePreviousTranscript()
        XCTAssertEqual(store.selected?.previousMeetingID, source.id)
        XCTAssertEqual(try store.library.load().meetings.first { $0.id == current.id }?.previousMeetingID, source.id)
    }
}
