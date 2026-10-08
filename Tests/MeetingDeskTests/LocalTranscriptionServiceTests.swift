import XCTest
@testable import MeetingDesk

final class LocalTranscriptionServiceTests: XCTestCase {
    func testLanguageSelectionNeverSilentlySubstitutesEnglish() throws {
        XCTAssertEqual(try LocalTranscriptionService.localeIdentifier(for: "Türkçe"), "tr-TR")
        XCTAssertEqual(try LocalTranscriptionService.localeIdentifier(for: "English"), "en-US")
        XCTAssertThrowsError(try LocalTranscriptionService.localeIdentifier(for: "Automatic"))
    }

    func testLongFileTranscriptKeepsLateUtteranceAndUnknownSpeaker() throws {
        var assembler = LocalTranscriptAssembler(duration: 7_200)
        try assembler.append(text: " İlk karar. ", start: 2.5, end: 5.1)
        try assembler.append(text: "One more task at the end.", start: 7_195.4, end: 7_199.6)
        XCTAssertEqual(assembler.segments.map(\.text), ["İlk karar.", "One more task at the end."])
        XCTAssertEqual(assembler.segments.last?.start, 7_195.4)
        XCTAssertEqual(assembler.segments.last?.end, 7_199.6)
        XCTAssertEqual(Set(assembler.segments.map(\.speaker)), ["Konuşma"])
        XCTAssertEqual(assembler.segments.map(\.id), ["local-1", "local-2"])
    }

    func testRepeatedFinalResultDoesNotDuplicateButRepeatedPhraseAtAnotherTimeDoes() throws {
        var assembler = LocalTranscriptAssembler(duration: 30)
        try assembler.append(text: "Agreed.", start: 1, end: 2)
        try assembler.append(text: "Agreed.", start: 1, end: 2)
        try assembler.append(text: "Agreed.", start: 20, end: 21)
        XCTAssertEqual(assembler.segments.count, 2)
        XCTAssertEqual(assembler.segments.last?.start, 20)
    }

    func testInvalidTimestampFailsInsteadOfDroppingUtterance() throws {
        for invalid in [(Double.nan, 2.0), (1.0, Double.infinity), (-1.0, 2.0), (3.0, 1.0), (31.0, 32.0)] {
            var assembler = LocalTranscriptAssembler(duration: 30)
            try assembler.append(text: "Valid.", start: 1, end: 2)
            XCTAssertThrowsError(try assembler.append(text: "Must not be silently lost.", start: invalid.0, end: invalid.1))
            XCTAssertEqual(assembler.segments.count, 1)
        }
    }

    func testIncompleteAudioReadIsRejectedAtAnyMeetingLength() throws {
        XCTAssertThrowsError(try LocalTranscriptAssembler.requireEntireFileRead(lastSampleSeconds: 60, duration: 3_600))
        XCTAssertThrowsError(try LocalTranscriptAssembler.requireEntireFileRead(lastSampleSeconds: .nan, duration: 3_600))
        XCTAssertNoThrow(try LocalTranscriptAssembler.requireEntireFileRead(lastSampleSeconds: 3_599.99995, duration: 3_600))
    }

    func testEmptyUtteranceDoesNotCreateFalseSpeech() throws {
        var assembler = LocalTranscriptAssembler(duration: 10)
        try assembler.append(text: " \n", start: 0, end: 0)
        XCTAssertTrue(assembler.segments.isEmpty)
    }

    func testCancelledRequestStopsBeforeReadingOriginalFile() async throws {
        let task = Task { () throws -> [TranscriptSegment] in
            withUnsafeCurrentTask { $0?.cancel() }
            return try await LocalTranscriptionService().transcribe(audioURL: URL(fileURLWithPath: "/nonexistent-recording.wav"), language: "English")
        }
        do { _ = try await task.value; XCTFail("Cancelled operation must fail") }
        catch { XCTAssertTrue(error is CancellationError) }
    }
}
