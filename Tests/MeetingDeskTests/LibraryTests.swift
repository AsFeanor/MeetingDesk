import XCTest
@testable import MeetingDesk

final class LibraryTests: XCTestCase {
    func testExistingArchiveWithoutEngineMetadataRemainsReadable() throws {
        let encoder = JSONEncoder()
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: encoder.encode(Meeting(title: "Önceki sürüm"))) as? [String: Any])
        object.removeValue(forKey: "transcriptionEngine")
        object.removeValue(forKey: "notesEngine")
        object.removeValue(forKey: "microphoneDeviceID")
        object.removeValue(forKey: "microphoneDeviceName")
        object.removeValue(forKey: "microphoneGain")
        let reopened = try JSONDecoder().decode(Meeting.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertEqual(reopened.title, "Önceki sürüm")
        XCTAssertNil(reopened.transcriptionEngine)
        XCTAssertNil(reopened.notesEngine)
        XCTAssertNil(reopened.microphoneGain)
    }
    func testSeparatePlaybackSourcesAreOnlyAvailableWhenSavedAndCannotEscapeArchive() throws {
        let library = MeetingLibrary(root: try temporary())
        var meeting = Meeting(title: "Ses dengesi")
        meeting.audioFileName = "recording.m4a"
        meeting.microphoneDeviceID = "BuiltInMicrophoneDevice"
        meeting.microphoneDeviceName = "MacBook Pro Mikrofonu"
        meeting.microphoneGain = 2
        try library.save(meeting)
        XCTAssertNil(library.audioURL(for: meeting, source: .microphone))
        let microphone = library.directory(for: meeting.id).appendingPathComponent("recording-microphone.m4a")
        try Data([1, 2]).write(to: microphone)
        XCTAssertEqual(library.audioURL(for: meeting, source: .microphone), microphone)
        XCTAssertNil(library.audioURL(for: meeting, source: .system))
        XCTAssertEqual(try library.load().meetings.first?.microphoneDeviceName, "MacBook Pro Mikrofonu")
        XCTAssertEqual(try library.load().meetings.first?.microphoneGain, 2)
        meeting.audioFileName = "../../outside.m4a"
        XCTAssertNil(library.audioURL(for: meeting, source: .microphone))
    }
    func testTranscriptVersionKeepsPreviousLanguageAndNotesWithoutChangingAudio() throws {
        let library = MeetingLibrary(root: try temporary())
        var original = Meeting(title: "Türkçe toplantı")
        original.audioFileName = "recording.m4a"
        original.segments = [TranscriptSegment(id: "local-1", speaker: "A", start: 0, end: 10, text: "Wrong English recognition")]
        original.notes = MeetingNotes(summary: "Old notes", decisions: [], actions: [], questions: [], ideas: [], topics: [])
        original.speechLanguage = "English"
        original.transcribedLanguage = "English"
        try library.save(original)
        let audio = try XCTUnwrap(library.audioURL(for: original))
        let audioBytes = Data([1, 2, 3, 4])
        try audioBytes.write(to: audio)
        try library.saveTranscriptVersion(original)
        var corrected = original
        corrected.speechLanguage = "Türkçe"
        corrected.transcribedLanguage = "Türkçe"
        corrected.segments[0].text = "Doğru Türkçe döküm"
        corrected.notesNeedRefresh = true
        try library.save(corrected)
        XCTAssertEqual(try library.latestTranscriptVersion(for: original.id), original)
        XCTAssertEqual(try library.load().meetings, [corrected])
        XCTAssertTrue(library.hasTranscriptVersion(for: original.id))
        XCTAssertEqual(try Data(contentsOf: audio), audioBytes)
    }
    private func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MeetingDesk-LibraryTests-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }
    func testNotesEditsAndActionCompletionSurviveReopen() throws {
        let root = try temporary()
        let library = MeetingLibrary(root: root)
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
        var meeting = Meeting(title: "Gerçek toplantı")
        meeting.segments = [TranscriptSegment(id: "s1", speaker: "A", start: 12, end: 17, text: "Değişikliği yapacağım.")]
        meeting.speakerNames = ["A": "Elif"]
        meeting.notes = MeetingNotes(summary: "Özet", decisions: [], actions: [ActionItem(id: "a1", text: "Değişikliği yap", owner: "Elif", due: nil, evidence: ["s1"])], questions: [], ideas: [], topics: [])
        meeting.completedActions = ["a1"]
        meeting.personalNotes = "Kendi notum"
        meeting.notesNeedRefresh = true
        try library.save(meeting)
        let reopened = try MeetingLibrary(root: root).load()
        XCTAssertEqual(reopened.meetings, [meeting])
        let permissions = try FileManager.default.attributesOfItem(atPath: library.directory(for: meeting.id).appendingPathComponent("meeting.json").path)[.posixPermissions] as? NSNumber
        XCTAssertEqual(permissions?.intValue, 0o600)
    }
    func testCorruptRecordIsPreservedAndDoesNotHideOtherMeetings() throws {
        let library = MeetingLibrary(root: try temporary())
        let meeting = Meeting(title: "Korunmuş kayıt")
        try library.save(meeting)
        let broken = library.directory(for: UUID())
        try FileManager.default.createDirectory(at: broken, withIntermediateDirectories: true)
        try Data("incomplete json".utf8).write(to: broken.appendingPathComponent("meeting.json"))
        let loaded = try library.load()
        XCTAssertEqual(loaded.meetings.count, 1)
        XCTAssertEqual(loaded.unreadable, 1)
        XCTAssertTrue(FileManager.default.fileExists(atPath: broken.appendingPathComponent("meeting.json").path))
    }
    func testExportRetainsSourcesUnknownDueAndStaleNotice() {
        var meeting = Meeting(title: "Kaynaklı çıktı")
        meeting.segments = [TranscriptSegment(id: "s1", speaker: "A", start: 1567, end: 1580, text: "Karar verdik.")]
        meeting.notes = MeetingNotes(summary: "Özet", decisions: [EvidenceItem(id: "d1", text: "Karar", evidence: ["s1"])], actions: [ActionItem(id: "a1", text: "Takip", owner: nil, due: nil, evidence: ["s1"])], questions: [], ideas: [], topics: [])
        meeting.completedActions = ["a1"]
        meeting.notesNeedRefresh = true
        let output = MeetingExport.markdown(meeting)
        XCTAssertTrue(output.contains("[26:07](#s1)"))
        XCTAssertTrue(output.contains("<a id=\"s1\"></a>"))
        XCTAssertTrue(output.contains("Sorumlu: Belirtilmedi · Tarih: Belirtilmedi"))
        XCTAssertTrue(output.contains("- [x] Takip"))
        XCTAssertTrue(output.contains("eski sürüme dayanıyor"))
    }
    func testImportPreservesMixedLanguageAndHourTimestamps() {
        let text = "[00:14] Ahmet: Hello, can you hear me?\nTürkçe bir açıklama.\n[01:02:03] Elif: Evet, duyuyoruz."
        let result = TranscriptParser.parse(text)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].speaker, "Ahmet")
        XCTAssertTrue(result[0].text.contains("Türkçe bir açıklama."))
        XCTAssertEqual(result[0].start, 14)
        XCTAssertEqual(result[1].start, 3723)
        XCTAssertEqual(result[0].end, 3723)
    }
    func testPlainTranscriptIsNotDiscardedAndEmptyInputIsRejected() {
        let text = "Bu metnin zaman damgası yok.\nHello again."
        XCTAssertEqual(TranscriptParser.parse(text).first?.text, text)
        XCTAssertTrue(TranscriptParser.parse("\n  \n").isEmpty)
    }
    func testAudioPathsCannotEscapeTheMeetingDirectory() throws {
        let library = MeetingLibrary(root: try temporary())
        var meeting = Meeting(title: "Test")
        meeting.audioFileName = "../../secret.m4a"
        XCTAssertNil(library.audioURL(for: meeting))
        meeting.audioFileName = "recording.m4a"
        XCTAssertEqual(library.audioURL(for: meeting)?.deletingLastPathComponent(), library.directory(for: meeting.id))
    }
}
