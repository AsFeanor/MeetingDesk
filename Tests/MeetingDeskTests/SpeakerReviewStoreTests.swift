import XCTest
@testable import MeetingDesk

@MainActor
final class SpeakerReviewStoreTests: XCTestCase {
    func testManualReviewRepairsPauseOnlyLegacyLabelsAndNeverTrainsVoice() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let defaults = UserDefaults(suiteName: UUID().uuidString)!
        let store = AppStore(root: root, initializeSystemServices: false, audioRetentionDefaults: defaults)
        var meeting = fixture()
        meeting.notes = MeetingNotes(summary: "Previous notes", decisions: [], actions: [], questions: [], ideas: [], topics: [])
        try store.library.save(meeting)
        store.meetings = [meeting]; store.selectedID = meeting.id
        let saved = expectation(description: "review committed")
        store.saveSpeakerReview(meetingID: meeting.id, speakerID: "system:A", selection: SpeakerReviewSelection(name: "Onur"),
                                rememberVoice: false, sample: nil) { saved.fulfill() }
        await fulfillment(of: [saved], timeout: 3)
        let updated = try XCTUnwrap(store.selected)
        XCTAssertEqual(updated.segments.map(\.id), meeting.segments.map(\.id))
        XCTAssertEqual(updated.segments.map(\.text), meeting.segments.map(\.text))
        XCTAssertEqual(updated.segments.map(\.start), meeting.segments.map(\.start))
        XCTAssertEqual(updated.segments.first?.speaker, "system:A")
        XCTAssertEqual(updated.speakerName("system:A"), "Onur")
        XCTAssertTrue(updated.notesNeedRefresh)
        XCTAssertEqual(updated.speakerTurns, meeting.speakerTurns)
        XCTAssertTrue(store.library.hasTranscriptVersion(for: meeting.id))
        XCTAssertTrue(try store.voiceProfileStore.load().isEmpty)
        XCTAssertFalse(store.speakerRecognitionEnabled, "Label-only or failed enrollment must not enable future recognition")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".speaker-models").path))
    }

    func testAnotherClusterCanUseSameConfirmedPersonWithoutDuplicateProfile() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(root: root, initializeSystemServices: false, audioRetentionDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        let meeting = fixture()
        try store.library.save(meeting); store.meetings = [meeting]; store.selectedID = meeting.id
        let first = expectation(description: "first voice")
        store.saveSpeakerReview(meetingID: meeting.id, speakerID: "system:A", selection: SpeakerReviewSelection(name: "Onur"),
                                rememberVoice: false, sample: nil) { first.fulfill() }
        await fulfillment(of: [first], timeout: 3)
        let personID = try XCTUnwrap(store.selected?.speakerReviewPeople?.first?.id)
        let second = expectation(description: "same person second voice")
        store.saveSpeakerReview(meetingID: meeting.id, speakerID: "system:B",
                                selection: SpeakerReviewSelection(personID: personID, name: "Ignored"),
                                rememberVoice: false, sample: nil) { second.fulfill() }
        await fulfillment(of: [second], timeout: 3)
        XCTAssertEqual(store.selected?.speakerReviewPeople?.count, 1)
        XCTAssertEqual(store.selected?.speakerReviewAssignments?["system:A"], personID)
        XCTAssertEqual(store.selected?.speakerReviewAssignments?["system:B"], personID)
        XCTAssertEqual(store.selected?.speakerName("system:B"), "Onur")
        XCTAssertTrue(try store.voiceProfileStore.load().isEmpty)
        XCTAssertFalse(store.speakerRecognitionEnabled, "Label-only or failed enrollment must not enable future recognition")
    }

    func testRememberWithoutApprovedExcerptFailsBeforeModelOrProfileWrites() async throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(root: root, initializeSystemServices: false, audioRetentionDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        let meeting = fixture()
        try store.library.save(meeting); store.meetings = [meeting]; store.selectedID = meeting.id
        var saved = false
        store.saveSpeakerReview(meetingID: meeting.id, speakerID: "system:A", selection: SpeakerReviewSelection(name: "Onur"),
                                rememberVoice: true, sample: nil) { saved = true }
        for _ in 0..<100 {
            if !store.isBusy { break }
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertFalse(store.isBusy)
        XCTAssertFalse(saved)
        XCTAssertEqual(store.selected, meeting)
        XCTAssertNotNil(store.errorMessage)
        XCTAssertTrue(try store.voiceProfileStore.load().isEmpty)
        XCTAssertFalse(store.speakerRecognitionEnabled, "Label-only or failed enrollment must not enable future recognition")
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".speaker-models").path))
    }

    private func fixture() -> Meeting {
        var meeting = Meeting(title: "Example", duration: 20, segments: [
            TranscriptSegment(id: "local-system-1", speaker: "Toplantı sesi", start: 0, end: 4, text: "A task."),
            TranscriptSegment(id: "local-system-2", speaker: "system:B", start: 10, end: 14, text: "Another task.", audioSource: .system)
        ])
        meeting.speakerTurns = [SpeakerTurn(speakerID: "system:A", source: .system, start: 1, end: 3),
                                SpeakerTurn(speakerID: "system:B", source: .system, start: 10, end: 14)]
        return meeting
    }
}
