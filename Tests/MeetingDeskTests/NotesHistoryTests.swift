import XCTest
@testable import MeetingDesk

final class NotesHistoryTests: XCTestCase {
    func testNoteHistoryKeepsEarlierNotesSeparateFromTranscriptAndRecording() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MeetingDesk-NotesHistoryTests-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let library = MeetingLibrary(root: root)
        var original = Meeting(title: "Not geçmişi")
        original.audioFileName = "recording.m4a"
        original.segments = [TranscriptSegment(id: "s1", speaker: "A", start: 5, end: 10, text: "Özgün kaynak metin")]
        original.personalNotes = "Kişisel notu koru"
        original.notes = MeetingNotes(summary: "Önceki özet", decisions: [], actions: [], questions: [], ideas: [], topics: [])
        original.notesEngine = ProcessingMode.local.rawValue
        original.templateRawValue = "weeklyReview"
        original.outputLanguage = "English"
        original.reviewedAt = Date(timeIntervalSince1970: 1_000)
        try library.save(original)
        let audio = try XCTUnwrap(library.audioURL(for: original))
        let audioBytes = Data([0, 1, 2, 3])
        try audioBytes.write(to: audio)
        XCTAssertFalse(library.hasNotesVersion(for: original.id))
        try library.saveNotesVersion(original)
        var updated = original
        updated.notes?.summary = "Sonraki özet"
        updated.completedActions = ["new-action"]
        updated.reviewedAt = nil
        try library.save(updated)
        let previous = try XCTUnwrap(library.latestNotesVersion(for: original.id))
        XCTAssertEqual(previous.meetingID, original.id)
        XCTAssertEqual(previous.notes, original.notes)
        XCTAssertEqual(previous.completedActions, original.completedActions)
        XCTAssertEqual(previous.notesEngine, original.notesEngine)
        XCTAssertEqual(previous.reviewedAt, original.reviewedAt)
        XCTAssertEqual(previous.templateRawValue, original.templateRawValue)
        XCTAssertEqual(previous.outputLanguage, original.outputLanguage)
        XCTAssertTrue(previous.matchesTranscript(of: updated))
        var changedText = updated
        changedText.segments[0].text = "Aynı kimlikle değiştirilmiş kaynak metin"
        XCTAssertFalse(previous.matchesTranscript(of: changedText))
        var changedSpeaker = updated
        changedSpeaker.speakerNames["A"] = "Yeni kişi"
        XCTAssertFalse(previous.matchesTranscript(of: changedSpeaker))
        XCTAssertTrue(library.hasNotesVersion(for: original.id))
        XCTAssertFalse(library.hasTranscriptVersion(for: original.id))
        XCTAssertEqual(try library.load().meetings, [updated])
        XCTAssertEqual(try Data(contentsOf: audio), audioBytes)
        let files = try FileManager.default.contentsOfDirectory(at: library.directory(for: original.id).appendingPathComponent(".notes-history"), includingPropertiesForKeys: nil)
        let file = try XCTUnwrap(files.first)
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
        XCTAssertNil(object["segments"])
        XCTAssertNil(object["audioFileName"])
        XCTAssertNil(object["personalNotes"])
        XCTAssertNotNil(object["transcriptFingerprint"])
        let permissions = try FileManager.default.attributesOfItem(atPath: file.path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }

    func testMismatchedMeetingNoteHistoryIsRejected() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MeetingDesk-NotesHistoryMismatchTests-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        let library = MeetingLibrary(root: root)
        let meeting = Meeting(title: "Doğru toplantı")
        try library.saveNotesVersion(meeting)
        let folder = library.directory(for: meeting.id).appendingPathComponent(".notes-history")
        let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil).first)
        var wrong = MeetingNotesVersion(meeting: meeting)
        wrong.meetingID = UUID()
        try JSONEncoder().encode(wrong).write(to: file)
        XCTAssertThrowsError(try library.latestNotesVersion(for: meeting.id))
        XCTAssertNil(try library.latestNotesVersion(for: UUID()))
    }
}
