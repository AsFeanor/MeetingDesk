import Foundation
import XCTest
@testable import MeetingDesk

final class TranscriptConversationTests: XCTestCase {
    private func segment(_ id: String, _ speaker: String, _ start: Double, _ end: Double,
                         _ text: String, source: SpeakerAudioSource = .system) -> TranscriptSegment {
        TranscriptSegment(id: id, speaker: speaker, start: start, end: end, text: text,
                          words: [TranscriptWord(text: text, start: start, end: end)], audioSource: source)
    }

    func testLegacyInterleavedSourcesAreChronologicalWithoutRewritingOrHidingAnchors() {
        let late = segment("mic-late", "microphone:A", 8, 10, "Son söz.", source: .microphone)
        let remote = segment("remote", "system:B", 3, 5, "Aradaki söz.")
        let early = segment("mic-early", "microphone:A", 0, 2, "İlk söz.", source: .microphone)
        let meeting = Meeting(title: "Sentetik", segments: [late, remote, early])
        let original = meeting

        let blocks = TranscriptConversation.blocks(in: meeting)

        XCTAssertEqual(blocks.map(\.start), [0, 3, 8])
        XCTAssertEqual(blocks.flatMap(\.sourceSegmentIDs), ["mic-early", "remote", "mic-late"])
        XCTAssertEqual(blocks.flatMap(\.segments), [early, remote, late])
        XCTAssertEqual(meeting, original)
    }

    func testDifferentVoiceClustersOfOneConfirmedPersonBecomeOneSameSourceCard() {
        let person = SpeakerReviewPerson(name: "Deniz")
        let first = segment("first", "system:A", 0, 1, "İlk konu.")
        let second = segment("second", "system:B", 1.2, 2, "İkinci konu.")
        var meeting = Meeting(title: "Sentetik", segments: [first, second])
        meeting.speakerReviewPeople = [person]
        meeting.speakerReviewAssignments = ["system:A": person.id, "system:B": person.id]

        let blocks = TranscriptConversation.blocks(in: meeting)

        XCTAssertEqual(blocks.count, 1)
        XCTAssertEqual(blocks.first?.id, "first")
        XCTAssertEqual(blocks.first?.speaker, "system:A")
        XCTAssertEqual(blocks.first?.text, "İlk konu. İkinci konu.")
        XCTAssertEqual(blocks.first?.segments, [first, second])
        XCTAssertTrue(blocks.first?.containsID("second") == true)
        XCTAssertFalse(blocks.first?.containsID("unrelated") == true)
    }

    func testEqualNamesNeverMergeDifferentPeopleOrUnconfirmedVoices() {
        for explicitlyAssigned in [false, true] {
            let firstPerson = SpeakerReviewPerson(name: "Deniz"), secondPerson = SpeakerReviewPerson(name: "Deniz")
            var meeting = Meeting(title: "Sentetik", segments: [
                segment("first", "system:A", 0, 1, "Birinci."), segment("second", "system:B", 1, 2, "İkinci.")
            ])
            meeting.speakerNames = ["system:A": "Deniz", "system:B": "Deniz"]
            if explicitlyAssigned {
                meeting.speakerReviewPeople = [firstPerson, secondPerson]
                meeting.speakerReviewAssignments = ["system:A": firstPerson.id, "system:B": secondPerson.id]
            }
            XCTAssertEqual(TranscriptConversation.blocks(in: meeting).count, 2)
        }
    }

    func testSameKnownPersonOnMicrophoneAndSystemStillHasSeparateSourceCards() {
        let person = SpeakerReviewPerson(name: "Ece")
        var meeting = Meeting(title: "Sentetik", segments: [
            segment("mic", "microphone:A", 0, 1, "Aynı cümle.", source: .microphone),
            segment("remote", "system:B", 0, 1, "Aynı cümle.")
        ])
        meeting.speakerReviewPeople = [person]
        meeting.speakerReviewAssignments = ["microphone:A": person.id, "system:B": person.id]

        let blocks = TranscriptConversation.blocks(in: meeting)

        XCTAssertEqual(blocks.count, 2)
        XCTAssertEqual(blocks.map(\.source), [.microphone, .system])
        XCTAssertEqual(blocks.flatMap(\.sourceSegmentIDs), ["mic", "remote"])
        XCTAssertEqual(blocks.map(\.text), ["Aynı cümle.", "Aynı cümle."], "Presentation must not silently deduplicate source speech")
    }

    func testSourceLabelledFormattingFragmentsReadNaturallyAndKeepEveryOriginalCharacterAndID() {
        let segments = [segment("one", "Toplantı sesi", 0, 1, "Bunu"),
                        segment("comma", "Toplantı sesi", 1, 1, ", "),
                        segment("two", "Toplantı sesi", 1.1, 2, "öyle "),
                        segment("three", "Toplantı sesi", 2, 3, "yapalım.")]
        let meeting = Meeting(title: "Sentetik", segments: segments)

        let block = TranscriptConversation.blocks(in: meeting).first

        XCTAssertEqual(block?.text, "Bunu, öyle yapalım.")
        XCTAssertEqual(block?.segments, segments)
        XCTAssertEqual(block?.sourceSegmentIDs, segments.map(\.id))
        for value in segments { XCTAssertTrue(block?.text.contains(value.text) == true) }
        XCTAssertEqual(TranscriptConversation.joinedText(["\nBaşlık ", "devam\n"]), "\nBaşlık devam\n")
        XCTAssertEqual(TranscriptConversation.joinedText(["(", "örnek", ")"]), "(örnek)")
    }

    func testPauseLimitAndThirtySecondMergeLimitSplitCardsWithoutLosingContent() {
        let close = [segment("one", "system:A", 0, 1, "İlk."),
                     segment("two", "system:A", 2.5, 3, "İkinci."),
                     segment("three", "system:A", 4.500_001, 5, "Üçüncü.")]
        XCTAssertEqual(TranscriptConversation.blocks(in: Meeting(title: "Sentetik", segments: close)).map(\.sourceSegmentIDs), [["one", "two"], ["three"]])
        let extended = [segment("one", "system:A", 0, 15, "İlk."),
                        segment("two", "system:A", 15, 30, "İkinci."),
                        segment("three", "system:A", 30, 31, "Üçüncü.")]
        let bounded = TranscriptConversation.blocks(in: Meeting(title: "Sentetik", segments: extended))
        XCTAssertEqual(bounded.map(\.sourceSegmentIDs), [["one", "two"], ["three"]])
        XCTAssertTrue(bounded.allSatisfy { $0.end - $0.start <= 30 })
        XCTAssertEqual(bounded.flatMap(\.segments), extended)
    }

    func testOverlappingSameVoiceUsesUnionEndAndAnExistingLongUtteranceIsNeverSplitOrDropped() {
        let overlapping = [segment("one", "system:A", 0, 10, "Uzun."),
                           segment("two", "system:A", 2, 3, "Ara."),
                           segment("three", "system:A", 11, 12, "Devam.")]
        let block = TranscriptConversation.blocks(in: Meeting(title: "Sentetik", segments: overlapping)).first
        XCTAssertEqual(block?.sourceSegmentIDs, ["one", "two", "three"])
        XCTAssertEqual(block?.start, 0)
        XCTAssertEqual(block?.end, 12)
        let long = segment("legacy-long", "system:A", 0, 50, "Eski uzun bölüm.")
        let next = segment("next", "system:A", 50, 51, "Sonra.")
        let preserved = TranscriptConversation.blocks(in: Meeting(title: "Sentetik", segments: [long, next]))
        XCTAssertEqual(preserved.map(\.segments), [[long], [next]], "The cap limits new joins; it must not discard or invent subsegments inside old utterances")
    }

    func testInvalidTimelineSegmentsRemainIsolatedAndAllSavedIDsRemainPresent() {
        let valid = segment("valid", "system:A", 0, 1, "Geçerli.")
        let invalid = segment("invalid", "system:A", 2, 1, "Zamanı bozuk.")
        let later = segment("later", "system:A", 3, 4, "Sonraki.")
        let blocks = TranscriptConversation.blocks(in: Meeting(title: "Sentetik", segments: [valid, invalid, later]))
        XCTAssertEqual(blocks.map(\.sourceSegmentIDs), [["valid"], ["invalid"], ["later"]])
        XCTAssertEqual(blocks.flatMap(\.segments), [valid, invalid, later])
    }
    func testCentralOrderedSegmentsRetainsStableSimultaneousOrderAndAllSavedFields() {
        let late = segment("late", "microphone:A", 8, 10, "Sonraki.", source: .microphone)
        let first = segment("first", "system:A", 0, 2, "Aynı an, ilk.")
        let simultaneous = segment("simultaneous", "microphone:B", 0, 1, "Aynı an, ikinci.", source: .microphone)
        let saved = [late, first, simultaneous]

        let ordered = TranscriptConversation.orderedSegments(saved)

        XCTAssertEqual(ordered, [first, simultaneous, late])
        XCTAssertEqual(saved, [late, first, simultaneous], "Projection does not rewrite the saved array")
        XCTAssertEqual(ordered.flatMap { $0.words ?? [] }, [first, simultaneous, late].flatMap { $0.words ?? [] })
    }

}
