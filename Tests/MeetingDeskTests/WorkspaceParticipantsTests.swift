import Foundation
import XCTest
@testable import MeetingDesk

final class WorkspaceParticipantsTests: XCTestCase {
    private func meeting(_ speakerIDs: [String]) -> Meeting {
        var meeting = Meeting(title: "Sentetik katılımcılar")
        meeting.segments = speakerIDs.enumerated().map { index, speaker in
            TranscriptSegment(id: "segment-\(index)", speaker: speaker,
                start: Double(index * 5), end: Double(index * 5 + 4), text: "Örnek konuşma.")
        }
        return meeting
    }

    func testSeveralVoiceClustersAssignedToOnePersonProduceOneParticipant() throws {
        let person = SpeakerReviewPerson(name: "Deniz")
        var value = meeting(["system:C", "system:A", "system:B"])
        value.speakerReviewPeople = [person]
        value.speakerReviewAssignments = ["system:A": person.id, "system:B": person.id, "system:C": person.id]
        let original = value

        let entries = WorkspaceParticipants.entries(in: value)

        XCTAssertEqual(entries.count, 1)
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.id, "person:\(person.id.uuidString)")
        XCTAssertEqual(entry.name, "Deniz")
        XCTAssertTrue(entry.isIdentified)
        XCTAssertEqual(entry.speakerIDs, ["system:C", "system:A", "system:B"], "Keep first-speaking order, not alphabetical cluster order")
        XCTAssertEqual(value, original)
    }

    func testEqualDisplayNamesDoNotMergeTwoExplicitDifferentPeople() {
        let first = SpeakerReviewPerson(name: "Deniz"), second = SpeakerReviewPerson(name: "Deniz")
        var value = meeting(["system:A", "system:B"])
        value.speakerReviewPeople = [first, second]
        value.speakerReviewAssignments = ["system:A": first.id, "system:B": second.id]

        let entries = WorkspaceParticipants.entries(in: value)

        XCTAssertEqual(entries.count, 2)
        XCTAssertEqual(Set(entries.map(\.id)).count, 2)
        XCTAssertEqual(entries.map(\.name), ["Deniz", "Deniz"])
        XCTAssertTrue(entries.allSatisfy(\.isIdentified))
        XCTAssertEqual(entries.map(\.speakerIDs), [["system:A"], ["system:B"]])
    }

    func testUnusedPersonAndUnusedSuggestionDoNotInventAttendance() {
        let present = SpeakerReviewPerson(name: "Ece"), unused = SpeakerReviewPerson(name: "Deniz")
        var value = meeting(["system:A"])
        value.speakerReviewPeople = [present, unused]
        value.speakerReviewAssignments = ["system:A": present.id, "missing-cluster": unused.id]
        value.speakerSuggestions = ["unused-auto-cluster": .init(profileID: UUID(), name: "Başka kişi", similarity: 0.99, automatic: true)]

        let entries = WorkspaceParticipants.entries(in: value)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.name, "Ece")
        XCTAssertEqual(entries.first?.speakerIDs, ["system:A"])
    }

    func testStrongAutomaticProfileAssociationsGroupClustersWithoutUsingNames() throws {
        let profileID = UUID()
        var value = meeting(["system:B", "system:A", "system:C"])
        value.speakerSuggestions = [
            "system:A": .init(profileID: profileID, name: "Güncellenen ad", similarity: 0.95, automatic: true),
            "system:B": .init(profileID: profileID, name: "Ece", similarity: 0.93, automatic: true),
            "system:C": .init(profileID: UUID(), name: "Ece", similarity: 0.94, automatic: true)
        ]

        let entries = WorkspaceParticipants.entries(in: value)

        XCTAssertEqual(entries.count, 2)
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entry.id, "profile:\(profileID.uuidString)")
        XCTAssertEqual(entry.name, "Ece")
        XCTAssertTrue(entry.isIdentified)
        XCTAssertEqual(entry.speakerIDs, ["system:B", "system:A"])
        XCTAssertEqual(entries.last?.speakerIDs, ["system:C"], "Same name with a different profile remains distinct")
    }

}
