import XCTest
@testable import MeetingDesk

final class SpeakerReviewSamplesTests: XCTestCase {
    func testExcerptsAreShortStableAndExcludeOverlappingVoice() {
        var meeting = Meeting(title: "Example", duration: 90)
        meeting.speakerTurns = [
            SpeakerTurn(speakerID: "system:A", source: .system, start: 1, end: 35),
            SpeakerTurn(speakerID: "system:B", source: .system, start: 10, end: 15),
            SpeakerTurn(speakerID: "system:A", source: .system, start: 50, end: 65)
        ]
        let samples = SpeakerReviewSamples.samples(in: meeting, speakerID: "system:A")
        XCTAssertEqual(samples, SpeakerReviewSamples.samples(in: meeting, speakerID: "system:A"))
        XCTAssertFalse(samples.isEmpty)
        XCTAssertLessThanOrEqual(samples.count, 3)
        XCTAssertTrue(samples.allSatisfy { $0.duration <= 8 && $0.duration >= 1.5 && $0.canRemember })
        XCTAssertTrue(samples.allSatisfy { $0.end <= 9.85 || $0.start >= 15.15 })
        XCTAssertEqual(Set(samples.map(\.source)), [.system])
    }

    func testDifferentTrackDoesNotBlockExcerptAndNoAudioFilesAreNeeded() {
        var meeting = Meeting(title: "Example", duration: 20)
        meeting.speakerTurns = [
            SpeakerTurn(speakerID: "microphone:A", source: .microphone, start: 1, end: 12),
            SpeakerTurn(speakerID: "system:B", source: .system, start: 0, end: 20)
        ]
        let samples = SpeakerReviewSamples.samples(in: meeting, speakerID: "microphone:A")
        XCTAssertFalse(samples.isEmpty)
        XCTAssertEqual(samples.first?.source, .microphone)
        XCTAssertNil(meeting.audioFileName)
    }

    func testNoCleanSpeechAndAmbiguousTrackNeverOfferUnsafeExcerpt() {
        var meeting = Meeting(title: "Example", duration: 20)
        meeting.speakerTurns = [
            SpeakerTurn(speakerID: "system:A", source: .system, start: 1, end: 9),
            SpeakerTurn(speakerID: "system:B", source: .system, start: 0, end: 10)
        ]
        XCTAssertTrue(SpeakerReviewSamples.samples(in: meeting, speakerID: "system:A").isEmpty)
        meeting.speakerTurns?.append(SpeakerTurn(speakerID: "system:A", source: .microphone, start: 12, end: 18))
        XCTAssertTrue(SpeakerReviewSamples.samples(in: meeting, speakerID: "system:A").isEmpty)
    }

    func testShortVoiceMayBeNamedButCannotCreateProfile() {
        var meeting = Meeting(title: "Example", duration: 10)
        meeting.speakerTurns = [SpeakerTurn(speakerID: "system:A", source: .system, start: 2, end: 4.5)]
        let sample = SpeakerReviewSamples.samples(in: meeting, speakerID: "system:A").first
        XCTAssertNotNil(sample)
        XCTAssertFalse(sample?.canRemember ?? true)
    }

    func testNearEOFInvalidAndDuplicateTurnsCannotCrashOrMultiplySamples() {
        var meeting = Meeting(title: "Example", duration: 20)
        let voice = SpeakerTurn(speakerID: "system:A", source: .system, start: 1, end: 10)
        meeting.speakerTurns = Array(repeating: voice, count: 20) + [
            SpeakerTurn(speakerID: "system:B", source: .system, start: 20.2, end: 20.24),
            SpeakerTurn(speakerID: "system:C", source: .system, start: .nan, end: 4)
        ]
        let samples = SpeakerReviewSamples.samples(in: meeting, speakerID: "system:A")
        XCTAssertEqual(samples.count, 1)
        XCTAssertTrue(samples.allSatisfy { $0.start >= 0 && $0.end <= 20 })
        meeting.duration = .nan
        XCTAssertTrue(SpeakerReviewSamples.samples(in: meeting, speakerID: "system:A").isEmpty)
    }
}
