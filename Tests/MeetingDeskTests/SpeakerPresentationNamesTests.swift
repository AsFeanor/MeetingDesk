import XCTest
@testable import MeetingDesk

final class SpeakerPresentationNamesTests: XCTestCase {
    func testBatchedNamesPreserveSingleNamePrecedenceFallbackOrderAndLegacyLabels() {
        let person = SpeakerReviewPerson(name: "  Manuel ad  ")
        var value = Meeting(title: "Sentetik adlar")
        let speakers: [String] = ["system:C", "system:B", "system:A", "system:D", "system:E", "Mikrofon"]
        for (index, speaker) in speakers.enumerated() {
            let start = Double(index) * 5.0
            let segment = TranscriptSegment(id: "s\(index)", speaker: speaker, start: start, end: start + 4.0, text: "Konuşma")
            value.segments.append(segment)
        }
        value.speakerReviewPeople = [person, SpeakerReviewPerson(id: person.id, name: "İkinci bozuk kayıt")]
        value.speakerReviewAssignments = ["system:C": person.id]
        value.speakerSuggestions = [
            "system:C": .init(profileID: UUID(), name: "Manuel yerine geçmez", similarity: 1, automatic: true),
            "system:B": .init(profileID: UUID(), name: "Otomatik", similarity: 1, automatic: true),
            "system:E": .init(profileID: UUID(), name: "Onaysız", similarity: 0.6, automatic: false)
        ]
        value.speakerNames = ["system:A": "   Özel ad   ", "system:D": "Konuşmacı 99", "system:E": "Ses 5"]
        value.speakerTurns = [.init(speakerID: "system:turn", source: .system, start: 0.5, end: 2)]
        let order = SpeakerReviewPolicy.speakerIDs(in: value)
        let batch = SpeakerPresentation.names(in: value, orderedSpeakerIDs: order)
        for id in Set(order).union(value.speakers) {
            XCTAssertEqual(batch[id], SpeakerPresentation.name(for: id, in: value), id)
        }
        XCTAssertEqual(batch, SpeakerPresentation.names(in: value))
        XCTAssertEqual(batch["system:C"], person.name)
        XCTAssertEqual(batch["system:B"], "Otomatik")
        XCTAssertEqual(batch["system:A"], "Özel ad")
        XCTAssertEqual(batch["Mikrofon"], "Mikrofon")
    }
}
