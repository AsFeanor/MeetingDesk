import Foundation
import XCTest
@testable import MeetingDesk

final class SpeakerReviewQueueTests: XCTestCase {
    private func meeting(_ speakers: [String]) -> Meeting {
        var value = Meeting(title: "Sentetik ses gözden geçirme")
        value.segments = speakers.enumerated().map { index, speaker in
            TranscriptSegment(id: "s\(index)", speaker: speaker, start: Double(index * 10),
                end: Double(index * 10 + 8), text: "Örnek konuşma.")
        }
        return value
    }

    func testAlreadyConfirmedClustersAreNotAskedAgainButUnknownVoicesRemainSeparate() {
        let person = SpeakerReviewPerson(name: "Ece")
        var value = meeting(["system:A", "microphone:A", "system:B", "system:C"])
        value.speakerReviewPeople = [person]
        value.speakerReviewAssignments = ["system:A": person.id, "microphone:A": person.id]
        // Equal legacy labels are not sufficient identity proof for unknown voices.
        value.speakerNames = ["system:B": "Deniz", "system:C": "Deniz"]
        let original = value

        XCTAssertEqual(SpeakerReviewQueue.pendingSpeakerIDs(in: value), ["system:B", "system:C"])
        XCTAssertEqual(SpeakerReviewQueue.identifiedGroups(in: value).count, 1)
        XCTAssertEqual(SpeakerReviewQueue.identifiedGroups(in: value).first?.speakerIDs, ["system:A", "microphone:A"])
        XCTAssertEqual(value, original)
    }

    func testStrongAutomaticMatchesDoNotBecomeRepeatedQuestionsWhileWeakSuggestionsDo() {
        let profile = UUID()
        var value = meeting(["system:A", "system:B", "system:C"])
        value.speakerSuggestions = [
            "system:A": .init(profileID: profile, name: "Ece", similarity: 0.99, automatic: true),
            "system:B": .init(profileID: profile, name: "Ece", similarity: 0.98, automatic: true),
            "system:C": .init(profileID: profile, name: "Ece", similarity: 0.82, automatic: false)
        ]

        XCTAssertEqual(SpeakerReviewQueue.pendingSpeakerIDs(in: value), ["system:C"])
        let known = SpeakerReviewQueue.identifiedGroups(in: value)
        XCTAssertEqual(known.count, 1)
        XCTAssertEqual(known.first?.speakerIDs, ["system:A", "system:B"])
    }

    func testExplicitProfileAndStrongAutomaticMatchRepresentOnePerson() {
        let profile = UUID()
        let person = SpeakerReviewPerson(name: "Ece", voiceProfileID: profile)
        var value = meeting(["microphone:A", "system:B"])
        value.speakerReviewPeople = [person]
        value.speakerReviewAssignments = ["microphone:A": person.id]
        value.speakerSuggestions = ["system:B": .init(profileID: profile, name: "Ece", similarity: 0.99, automatic: true)]

        XCTAssertTrue(SpeakerReviewQueue.pendingSpeakerIDs(in: value).isEmpty)
        XCTAssertEqual(SpeakerReviewQueue.identifiedGroups(in: value).count, 1)
        XCTAssertEqual(SpeakerReviewQueue.identifiedGroups(in: value).first?.speakerIDs, ["microphone:A", "system:B"])
    }

    func testEqualNamesWithDifferentPeopleOrProfilesNeverMerge() {
        let first = SpeakerReviewPerson(name: "Deniz"), second = SpeakerReviewPerson(name: "Deniz")
        var value = meeting(["system:A", "system:B", "system:C", "system:D"])
        value.speakerReviewPeople = [first, second]
        value.speakerReviewAssignments = ["system:A": first.id, "system:B": second.id]
        value.speakerSuggestions = [
            "system:C": .init(profileID: UUID(), name: "Deniz", similarity: 0.99, automatic: true),
            "system:D": .init(profileID: UUID(), name: "Deniz", similarity: 0.99, automatic: true)
        ]

        let groups = SpeakerReviewQueue.identifiedGroups(in: value)
        XCTAssertEqual(groups.count, 4)
        XCTAssertEqual(Set(groups.map(\.id)).count, 4)
    }

    func testStalePersonAssignmentDoesNotHideVoiceFromReview() {
        var value = meeting(["system:A", "system:B"])
        value.speakerReviewAssignments = ["system:A": UUID()]

        XCTAssertEqual(SpeakerReviewQueue.pendingSpeakerIDs(in: value), ["system:A", "system:B"])
        XCTAssertTrue(SpeakerReviewQueue.identifiedGroups(in: value).isEmpty)
    }
    private func excerptMeeting() throws -> (Meeting, SpeakerReviewPerson, SpeakerReviewSample) {
        let previous = SpeakerReviewPerson(name: "Ece")
        var value = meeting(["system:known", "system:current"])
        value.duration = 30
        value.speakerReviewPeople = [previous]
        value.speakerReviewAssignments = ["system:known": previous.id]
        value.speakerTurns = [
            .init(speakerID: "system:known", source: .system, start: 0, end: 8),
            .init(speakerID: "system:current", source: .system, start: 10, end: 20)
        ]
        let sample = try XCTUnwrap(SpeakerReviewSamples.samples(in: value, speakerID: "system:current").first)
        return (value, previous, sample)
    }

    func testQuickReuseRequiresExactCurrentExcerptToHavePlayedAndExistingAudio() throws {
        let (value, previous, sample) = try excerptMeeting()
        func eligible(_ played: String?, audio: Bool = true) -> SpeakerReviewSelection? {
            SpeakerReviewQueue.reusablePreviousPerson(in: value, speakerID: "system:current",
                previousPersonID: previous.id, sample: sample, listenedSampleID: played, audioAvailable: audio)
        }
        XCTAssertNil(eligible(nil))
        XCTAssertNil(eligible("another-sample"))
        XCTAssertNil(eligible(sample.id, audio: false))
        let accepted = try XCTUnwrap(eligible(sample.id))
        XCTAssertEqual(accepted.personID, previous.id)
        XCTAssertEqual(accepted.name, "Ece")
    }

    func testQuickReuseDoesNotTrustSampleFromAnotherVoiceOrAlteredRange() throws {
        let (value, previous, sample) = try excerptMeeting()
        var wrongVoice = sample
        wrongVoice.speakerID = "system:known"
        var wrongRange = sample
        wrongRange.end += 1
        for candidate in [wrongVoice, wrongRange] {
            XCTAssertNil(SpeakerReviewQueue.reusablePreviousPerson(in: value, speakerID: "system:current",
                previousPersonID: previous.id, sample: candidate, listenedSampleID: candidate.id, audioAvailable: true))
        }
    }

    func testQuickReuseRevalidatesPersonByIDAndUsesCurrentProfileLink() throws {
        var (value, previous, sample) = try excerptMeeting()
        let sameNameDifferentPerson = SpeakerReviewPerson(name: previous.name)
        value.speakerReviewPeople?.append(sameNameDifferentPerson)
        let updatedProfile = UUID()
        value.speakerReviewPeople?[0].voiceProfileID = updatedProfile
        let accepted = try XCTUnwrap(SpeakerReviewQueue.reusablePreviousPerson(in: value, speakerID: "system:current",
            previousPersonID: previous.id, sample: sample, listenedSampleID: sample.id, audioAvailable: true))
        XCTAssertEqual(accepted.personID, previous.id)
        XCTAssertNotEqual(accepted.personID, sameNameDifferentPerson.id)
        XCTAssertEqual(accepted.voiceProfileID, updatedProfile)
        value.speakerReviewPeople?.removeAll(where: { $0.id == previous.id })
        XCTAssertNil(SpeakerReviewQueue.reusablePreviousPerson(in: value, speakerID: "system:current",
            previousPersonID: previous.id, sample: sample, listenedSampleID: sample.id, audioAvailable: true))
    }

    func testQuickReuseNeverProposesOverwritingAnAlreadyIdentifiedVoice() throws {
        var (value, previous, sample) = try excerptMeeting()
        let other = SpeakerReviewPerson(name: "Deniz")
        value.speakerReviewPeople?.append(other)
        value.speakerReviewAssignments?["system:current"] = other.id
        XCTAssertNil(SpeakerReviewQueue.reusablePreviousPerson(in: value, speakerID: "system:current",
            previousPersonID: previous.id, sample: sample, listenedSampleID: sample.id, audioAvailable: true))
    }

}
