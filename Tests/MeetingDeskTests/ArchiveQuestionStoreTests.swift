import XCTest
@testable import MeetingDesk

final class ArchiveQuestionStoreTests: XCTestCase {
    @MainActor func testNoEvidenceDoesNotRequireBundledRuntimeAndKeepsArchiveUnchanged() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(root: root, initializeSystemServices: false)
        let meeting = store.newMeeting()
        let before = try Data(contentsOf: store.library.directory(for: meeting.id).appendingPathComponent("meeting.json"))
        let result = try await store.archiveAnswer(question: "İhracat raporu için ne kararlaştırıldı?", meetingIDs: [meeting.id])
        XCTAssertTrue(result.abstained)
        XCTAssertTrue(result.context.sources.isEmpty)
        XCTAssertFalse(store.isBusy)
        XCTAssertFalse(store.workInProgress)
        XCTAssertEqual(try Data(contentsOf: store.library.directory(for: meeting.id).appendingPathComponent("meeting.json")), before)
    }
    @MainActor func testQuestionCannotClearOrReplaceAnotherRunningOperation() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(root: root, initializeSystemServices: false)
        store.isBusy = true; store.statusMessage = "Another operation"
        do {
            _ = try await store.archiveAnswer(question: "What was agreed?", meetingIDs: nil)
            XCTFail("Busy gate must reject the request")
        } catch { }
        XCTAssertTrue(store.isBusy)
        XCTAssertEqual(store.statusMessage, "Another operation")
    }
    @MainActor func testAlreadyCancelledQuestionReleasesItsOwnWorkGate() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(root: root, initializeSystemServices: false)
        let task = Task { @MainActor in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await store.archiveAnswer(question: "What was agreed?", meetingIDs: nil)
        }
        do { _ = try await task.value; XCTFail("Cancellation must propagate") }
        catch is CancellationError { }
        catch { XCTFail("Expected cancellation, received \(error)") }
        XCTAssertFalse(store.isBusy)
        XCTAssertFalse(store.workInProgress)
    }
}
