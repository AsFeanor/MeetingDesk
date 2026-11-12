import Foundation
import XCTest
@testable import MeetingDesk

final class SpeakerTranscriptAlignmentTests: XCTestCase {
    private func turn(_ id: String, _ start: Double, _ end: Double, source: SpeakerAudioSource = .system) -> SpeakerTurn {
        SpeakerTurn(speakerID: id, source: source, start: start, end: end)
    }

    private func segment(_ words: [TranscriptWord]?, text: String = "Merhaba, bugün başlıyoruz.", start: Double = 0, end: Double = 4) -> TranscriptSegment {
        TranscriptSegment(id: "local-system-1", speaker: "Toplantı sesi", start: start, end: end,
                          text: text, words: words, audioSource: .system)
    }

    func testSpeakerBoundarySplitsAtTimedWordsWithoutLosingTextOrTimeline() throws {
        let words = [TranscriptWord(text: "Merhaba, ", start: 0, end: 1),
                     TranscriptWord(text: "bugün ", start: 1, end: 2),
                     TranscriptWord(text: "başlıyoruz.", start: 2, end: 4)]
        let original = segment(words)
        let result = try SpeakerTranscriptAlignment.assign([original], turns: [turn("system:A", 0, 2), turn("system:B", 2, 4)])
        XCTAssertEqual(result.map(\.speaker), ["system:A", "system:B"])
        XCTAssertEqual(result.map(\.text), ["Merhaba, bugün", "başlıyoruz."])
        XCTAssertEqual(result.map(\.text).joined(separator: " "), original.text)
        XCTAssertEqual(result.flatMap { $0.words ?? [] }, words)
        XCTAssertEqual(result.map(\.start), [0, 2])
        XCTAssertEqual(result.map(\.end), [2, 4])
        XCTAssertEqual(Set(result.map(\.id)).count, result.count)
        XCTAssertEqual(result.map(\.audioSource), [.system, .system])
    }

    func testSimultaneousSpeakersRemainUnknownInsteadOfSelectingOneBySortOrder() throws {
        let words = [TranscriptWord(text: "Merhaba, ", start: 0, end: 1),
                     TranscriptWord(text: "bugün başlıyoruz.", start: 1, end: 4)]
        let original = segment(words)
        let result = try SpeakerTranscriptAlignment.assign([original], turns: [turn("system:A", 0, 4), turn("system:B", 0, 4)])
        XCTAssertEqual(result.map(\.speaker), ["Toplantı sesi"])
        XCTAssertEqual(result.first?.text, original.text)
        XCTAssertEqual(result.flatMap { $0.words ?? [] }, words)
    }

    func testMicrophoneAndSystemAtSameTimeDoNotCompeteForIdentity() throws {
        let word = TranscriptWord(text: "Merhaba.", start: 10, end: 12)
        let mic = TranscriptSegment(id: "local-microphone-1", speaker: "Mikrofon", start: 10, end: 12,
                                    text: word.text, words: [word], audioSource: .microphone)
        let remote = TranscriptSegment(id: "local-system-1", speaker: "Toplantı sesi", start: 10, end: 12,
                                       text: word.text, words: [word], audioSource: .system)
        let result = try SpeakerTranscriptAlignment.assign([mic, remote], turns: [turn("microphone:A", 10, 12, source: .microphone), turn("system:B", 10, 12)])
        XCTAssertEqual(result.map(\.speaker), ["microphone:A", "system:B"])
        XCTAssertEqual(result.map(\.start), [10, 10])
        XCTAssertEqual(result.map(\.audioSource), [.microphone, .system])
    }

    func testLegacyUtteranceIsNotSplitUsingGuessedWordPositions() throws {
        let original = segment(nil)
        let result = try SpeakerTranscriptAlignment.assign([original], turns: [turn("system:A", 0, 2), turn("system:B", 2, 4)])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].text, original.text)
        XCTAssertEqual(result[0].start, original.start)
        XCTAssertEqual(result[0].end, original.end)
        XCTAssertEqual(result[0].speaker, "Toplantı sesi")
        let confident = try SpeakerTranscriptAlignment.assign([original], turns: [turn("system:A", 0, 4)])
        XCTAssertEqual(confident[0].speaker, "system:A")
    }

    func testPartialWordTextCannotDropUntimedWords() throws {
        let original = segment([TranscriptWord(text: "Merhaba,", start: 0, end: 1)])
        let result = try SpeakerTranscriptAlignment.assign([original], turns: [turn("system:A", 0, 1), turn("system:B", 1, 4)])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].text, original.text)
        XCTAssertEqual(result[0].id, original.id)
    }

    func testNonMonotonicWordTimesFallBackInsteadOfReorderingTranscriptTime() throws {
        let original = segment([TranscriptWord(text: "A", start: 1, end: 2), TranscriptWord(text: "B", start: 0, end: 1)], text: "AB", end: 2)
        let result = try SpeakerTranscriptAlignment.assign([original], turns: [turn("system:A", 0, 1), turn("system:B", 1, 2)])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].text, "AB")
        XCTAssertEqual(result[0].start, 0)
        XCTAssertEqual(result[0].end, 2)
    }

    func testNearBoundaryWordTimesCannotProduceNegativeDurationSegments() throws {
        let original = segment([TranscriptWord(text: "A", start: 0.95, end: 0.96), TranscriptWord(text: "B", start: 1.1, end: 2)], text: "AB", start: 1, end: 2)
        let result = try SpeakerTranscriptAlignment.assign([original], turns: [turn("system:A", 0.95, 0.96), turn("system:B", 1.1, 2)])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].text, "AB")
        XCTAssertTrue(result.allSatisfy { $0.start >= original.start && $0.end >= $0.start && $0.end <= original.end })
    }

    func testDuplicatePredictedTurnsCannotInflateLegacySpeakerCoverage() throws {
        let original = segment(nil)
        let result = try SpeakerTranscriptAlignment.assign([original], turns: Array(repeating: turn("system:A", 0, 1), count: 10))
        XCTAssertEqual(result[0].speaker, "Toplantı sesi")
    }

    func testChannelMergePreservesTimedWordsAndSourceProvenance() throws {
        let micWords = [TranscriptWord(text: "Benim ", start: 5, end: 6), TranscriptWord(text: "sözüm.", start: 6, end: 7)]
        let systemWords = [TranscriptWord(text: "Karşı taraf.", start: 2, end: 4)]
        let result = try ChannelTranscriptionService.merge(
            microphone: [TranscriptSegment(id: "s1", speaker: "Konuşma", start: 5, end: 7, text: "Benim sözüm.", words: micWords)],
            system: [TranscriptSegment(id: "s1", speaker: "Konuşma", start: 2, end: 4, text: "Karşı taraf.", words: systemWords)])
        XCTAssertEqual(result.map(\.audioSource), [.system, .microphone])
        XCTAssertEqual(result[0].words, systemWords)
        XCTAssertEqual(result[1].words, micWords)
        XCTAssertEqual(result.map(\.start), [2, 5])
    }

    func testOldMeetingJSONStillDecodesWithoutNewVoiceFields() throws {
        let meeting = Meeting(title: "Eski toplantı", segments: [segment(nil)])
        var json = try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(meeting)) as? [String: Any])
        for key in ["speakerTurns", "speakerSuggestions", "speakerRecognitionEngine", "speakerRecognitionNotice"] { json.removeValue(forKey: key) }
        var segments = try XCTUnwrap(json["segments"] as? [[String: Any]])
        segments[0].removeValue(forKey: "words")
        segments[0].removeValue(forKey: "audioSource")
        json["segments"] = segments
        let restored = try JSONDecoder().decode(Meeting.self, from: JSONSerialization.data(withJSONObject: json))
        XCTAssertEqual(restored.id, meeting.id)
        XCTAssertEqual(restored.segments[0].text, meeting.segments[0].text)
        XCTAssertNil(restored.speakerTurns)
        XCTAssertNil(restored.speakerSuggestions)
        XCTAssertNil(restored.segments[0].words)
        XCTAssertNil(restored.segments[0].audioSource)
    }
}
