import XCTest
@testable import MeetingDesk

final class EvidenceAudioPreviewTests: XCTestCase {
    private func meeting() -> Meeting {
        var result = Meeting(title: "Örnek ses kaynağı")
        result.duration = 100
        result.segments = [
            .init(id: "mic", speaker: "speaker1", start: 10, end: 11, text: "İlk kaynak", audioSource: .microphone),
            .init(id: "sys", speaker: "speaker2", start: 25, end: 50, text: "Uzun kaynak", audioSource: .system),
            .init(id: "end", speaker: "speaker2", start: 99, end: 100, text: "Son kaynak", audioSource: .system)
        ]
        return result
    }
    func testExcerptUsesEvidenceChannelAndBoundedContextInsteadOfCurrentPlayerChoice() throws {
        let value = meeting()
        let mic = try XCTUnwrap(EvidenceAudioPreview.excerpts(in: value, evidence: ["mic"]).first)
        XCTAssertEqual(mic.source, .microphone)
        XCTAssertEqual(mic.playbackSource, .microphone)
        XCTAssertEqual(mic.start, 9.65, accuracy: 0.0001)
        XCTAssertEqual(mic.duration, 3, accuracy: 0.0001)
        let system = try XCTUnwrap(EvidenceAudioPreview.excerpts(in: value, evidence: ["sys"]).first)
        XCTAssertEqual(system.playbackSource, .system)
        XCTAssertEqual(system.duration, 12, accuracy: 0.0001)
    }
    func testWindowsStayInsideMeetingAndKeepEveryDistinctValidEvidence() throws {
        let value = meeting()
        let result = EvidenceAudioPreview.excerpts(in: value, evidence: ["end", "mic", "sys", "mic"])
        XCTAssertEqual(result.map(\.segmentID), ["mic", "sys", "end"])
        XCTAssertEqual(result.last?.end, 100)
        XCTAssertTrue(result.allSatisfy { $0.start >= 0 && $0.end <= 100 && $0.duration <= 12 })
    }
    func testStaleAmbiguousAndInvalidEvidenceCannotPlayAnotherSegment() {
        var value = meeting()
        value.segments.append(value.segments[0])
        value.segments.append(.init(id: "bad", speaker: "speaker", start: .nan, end: 10, text: "Geçersiz"))
        XCTAssertTrue(EvidenceAudioPreview.excerpts(in: value, evidence: ["missing", "mic", "bad"]).isEmpty)
    }
    func testLegacySourceTagsRemainLocalAndOriginalTranscriptIsUnchanged() throws {
        var value = meeting()
        value.segments = [.init(id: "local-system-4-voice-2", speaker: "voice", start: 0, end: 1, text: "Kaynak")]
        let original = value
        let result = try XCTUnwrap(EvidenceAudioPreview.excerpts(in: value, evidence: [value.segments[0].id]).first)
        XCTAssertEqual(result.source, .system)
        XCTAssertEqual(result.start, 0)
        XCTAssertEqual(value, original)
    }
    func testUnavailableDurationAndOutOfRangeSourcesAreRejected() {
        var value = meeting(); value.duration = .infinity
        XCTAssertTrue(EvidenceAudioPreview.excerpts(in: value, evidence: ["mic"]).isEmpty)
        value = meeting(); value.segments[0].end = 150
        XCTAssertTrue(EvidenceAudioPreview.excerpts(in: value, evidence: ["mic"]).isEmpty)
    }
}
