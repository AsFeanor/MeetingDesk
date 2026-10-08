import XCTest
@testable import MeetingDesk

final class AppStorePersistenceTests: XCTestCase {
    private func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MeetingDesk-StoreTests-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    func testFailedSaveDoesNotReplaceVisibleMeetingOrReportSuccess() async throws {
        let root = try temporary()
        try await MainActor.run {
            let store = AppStore(root: root, initializeSystemServices: false)
            let meeting = store.newMeeting()
            let file = store.library.directory(for: meeting.id).appendingPathComponent("meeting.json")
            try FileManager.default.removeItem(at: file)
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
            XCTAssertFalse(store.update(meeting.id) { $0.title = "Kaybolmaması gereken değişiklik" })
            XCTAssertEqual(store.selected?.title, meeting.title)
            XCTAssertNotNil(store.errorMessage)
        }
    }

    func testReviewAndEditHistoryPersistWithoutChangingSourceOrPersonalNotes() async throws {
        let root = try temporary()
        try await MainActor.run {
            let store = AppStore(root: root, initializeSystemServices: false)
            var meeting = store.newMeeting()
            meeting.segments = [TranscriptSegment(id: "s1", speaker: "A", start: 0, end: 2, text: "Taslağı Elif hazırlayacak")]
            meeting.notes = MeetingNotes(summary: "İlk özet", decisions: [], actions: [], questions: [], ideas: [], topics: [])
            meeting.personalNotes = "Özel not"
            XCTAssertTrue(store.update(meeting.id) { $0 = meeting })
            store.markNotesReviewed(meeting.id)
            XCTAssertNotNil(store.selected?.reviewedAt)
            var edited = try XCTUnwrap(meeting.notes)
            edited.summary = "Düzeltilmiş özet"
            try store.saveEditedNotes(edited, meetingID: meeting.id)
            XCTAssertNil(store.selected?.reviewedAt)
            XCTAssertEqual(store.selected?.notes?.summary, edited.summary)
            XCTAssertEqual(store.selected?.notesManualEdits?.summary, edited.summary)
            store.restorePreviousNotes()
            XCTAssertEqual(store.selected?.notes?.summary, "İlk özet")
            XCTAssertEqual(store.selected?.segments, meeting.segments)
            XCTAssertEqual(store.selected?.personalNotes, "Özel not")
            XCTAssertEqual(try store.library.load().meetings.first?.notes?.summary, "İlk özet")
        }
    }

    func testRestoringNotesFromDifferentTranscriptMarksThemStale() async throws {
        let root = try temporary()
        try await MainActor.run {
            let store = AppStore(root: root, initializeSystemServices: false)
            var meeting = store.newMeeting()
            meeting.segments = [TranscriptSegment(id: "s1", speaker: "A", start: 0, end: 2, text: "Önceki konuşma")]
            meeting.notes = MeetingNotes(summary: "Önceki özet", decisions: [], actions: [], questions: [], ideas: [], topics: [])
            XCTAssertTrue(store.update(meeting.id) { $0 = meeting })
            try store.library.saveNotesVersion(meeting)
            XCTAssertTrue(store.update(meeting.id) { $0.segments[0].text = "Kaynak metin değişti" })
            store.restorePreviousNotes()
            XCTAssertTrue(try XCTUnwrap(store.selected).notesNeedRefresh)
            XCTAssertNil(store.selected?.reviewedAt)
            XCTAssertEqual(store.selected?.segments[0].text, "Kaynak metin değişti")
            store.markNotesReviewed(meeting.id)
            XCTAssertNil(store.selected?.reviewedAt)
        }
    }

    func testMicrophoneSheetBlocksOtherWorkAndRecordingFinishCannotFakeSuccess() async throws {
        let root = try temporary()
        let store = await MainActor.run { AppStore(root: root, initializeSystemServices: false) }
        await MainActor.run {
            XCTAssertFalse(store.workInProgress)
            store.showMicrophoneCheck = true
            XCTAssertTrue(store.workInProgress)
            store.showMicrophoneCheck = false
        }
        let saved = await store.finishRecording(allowAutomaticProcessing: false)
        XCTAssertFalse(saved)
    }
}
