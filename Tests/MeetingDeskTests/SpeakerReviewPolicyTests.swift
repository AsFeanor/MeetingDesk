import Foundation
import XCTest
@testable import MeetingDesk

final class SpeakerReviewPolicyTests: XCTestCase {
    private func meeting(clusters: Int = 3) -> Meeting {
        var value = Meeting(title: "Sentetik konuşmacı kontrolü")
        value.duration = Double(clusters * 5)
        value.segments = [TranscriptSegment(id: "original-text", speaker: "Toplantı sesi", start: 0, end: value.duration,
            text: "Zamanları ayrı olmayan toplantı metni.", audioSource: .system)]
        value.speakerTurns = (0..<clusters).map { SpeakerTurn(speakerID: "system:\($0)", source: .system, start: Double($0 * 5), end: Double($0 * 5 + 4)) }
        return value
    }

    private func profile(_ name: String = "Onur") -> VoiceProfile {
        VoiceProfile(name: name, modelID: "synthetic-voice-model", samples: [[1, 0]])
    }

    private func notes() -> MeetingNotes {
        MeetingNotes(summary: "Önceki not", decisions: [], actions: [], questions: [], ideas: [], topics: [])
    }

    func testNineDetectedClustersCanBeExplicitlyMappedToFivePeopleWithoutChangingAudioOrTranscriptEvidence() throws {
        let original = meeting(clusters: 9)
        var reviewed = original
        let names = ["Onur", "Altuğ", "Elif", "Deniz", "Beyza"]
        var ids: [UUID] = []
        for index in names.indices {
            reviewed = try SpeakerReviewPolicy.assign(meeting: reviewed, speakerID: "system:\(index)",
                selection: SpeakerReviewSelection(name: names[index]), profiles: [])
            ids.append(try XCTUnwrap(reviewed.speakerReviewAssignments?["system:\(index)"]))
        }
        for index in 5..<9 {
            reviewed = try SpeakerReviewPolicy.assign(meeting: reviewed, speakerID: "system:\(index)",
                selection: SpeakerReviewSelection(personID: ids[index - 5], name: ""), profiles: [])
        }
        XCTAssertEqual(reviewed.speakerReviewPeople?.count, 5)
        XCTAssertEqual(reviewed.speakerReviewAssignments?.count, 9)
        XCTAssertEqual(SpeakerReviewPolicy.confirmedCount(in: reviewed), 9)
        XCTAssertEqual(SpeakerReviewPolicy.speakerIDs(in: reviewed).count, 9)
        XCTAssertEqual(reviewed.speakerNames["system:5"], "Onur")
        XCTAssertEqual(reviewed.speakerNames["system:8"], "Deniz")
        XCTAssertEqual(reviewed.speakerReviewAssignments?["system:0"], reviewed.speakerReviewAssignments?["system:5"])
        XCTAssertEqual(reviewed.segments, original.segments)
        XCTAssertEqual(reviewed.speakerTurns, original.speakerTurns)
        XCTAssertEqual(reviewed.duration, original.duration)
        XCTAssertEqual(reviewed.audioFileName, original.audioFileName)
    }

    func testNewDuplicateNameRequiresExplicitExistingPersonSelection() throws {
        let first = try SpeakerReviewPolicy.assign(meeting: meeting(), speakerID: "system:0", selection: .init(name: " Onur "), profiles: [])
        XCTAssertThrowsError(try SpeakerReviewPolicy.assign(meeting: first, speakerID: "system:1", selection: .init(name: "Onur"), profiles: [])) { error in
            XCTAssertTrue(error.localizedDescription.contains("listeden seçin"))
        }
        let personID = try XCTUnwrap(first.speakerReviewPeople?.first?.id)
        let reused = try SpeakerReviewPolicy.assign(meeting: first, speakerID: "system:1",
            selection: .init(personID: personID, name: "Bu seçim kişiyi yeniden adlandıramaz"), profiles: [])
        XCTAssertEqual(reused.speakerReviewPeople?.count, 1)
        XCTAssertEqual(reused.speakerNames["system:1"], "Onur")
        XCTAssertEqual(reused.speakerReviewAssignments?["system:1"], personID)
        let distinct = try SpeakerReviewPolicy.assign(meeting: first, speakerID: "system:1", selection: .init(name: "Onur Yılmaz"), profiles: [])
        XCTAssertEqual(distinct.speakerReviewPeople?.count, 2)
    }

    func testGlobalProfileSelectionReusesMeetingPersonAndRefreshesOnlyThatPersonsLinkedLabels() throws {
        let voice = profile("Onur Başterzi")
        let person = SpeakerReviewPerson(name: "Onur", voiceProfileID: voice.id)
        var original = meeting()
        original.speakerReviewPeople = [person]
        original.speakerReviewAssignments = ["system:0": person.id]
        original.speakerNames = ["system:0": "Onur", "legacy-speaker": "Eski isim korunur"]
        original.notes = notes(); original.reviewedAt = Date()
        let profilesBefore = [voice]
        let result = try SpeakerReviewPolicy.assign(meeting: original, speakerID: "system:1",
            selection: .init(voiceProfileID: voice.id, name: "Yanlış giriş dikkate alınmaz"), profiles: profilesBefore)
        XCTAssertEqual(result.speakerReviewPeople, [SpeakerReviewPerson(id: person.id, name: voice.name, voiceProfileID: voice.id)])
        XCTAssertEqual(result.speakerReviewAssignments?["system:1"], person.id)
        XCTAssertEqual(result.speakerNames["system:0"], voice.name)
        XCTAssertEqual(result.speakerNames["system:1"], voice.name)
        XCTAssertEqual(result.speakerNames["legacy-speaker"], "Eski isim korunur")
        XCTAssertTrue(result.notesNeedRefresh)
        XCTAssertNil(result.reviewedAt)
        XCTAssertEqual(result.segments, original.segments)
        XCTAssertEqual(profilesBefore, [voice], "Selecting a known person cannot train or change any voice vectors")
    }

    func testExplicitProfileIdentityNeverMergesPeopleMerelyBecauseNamesMatch() throws {
        let firstProfile = profile(), secondProfile = profile()
        var result = try SpeakerReviewPolicy.assign(meeting: meeting(), speakerID: "system:0", selection: .init(voiceProfileID: firstProfile.id, name: ""), profiles: [firstProfile, secondProfile])
        result = try SpeakerReviewPolicy.assign(meeting: result, speakerID: "system:1", selection: .init(voiceProfileID: secondProfile.id, name: ""), profiles: [firstProfile, secondProfile])
        XCTAssertEqual(result.speakerReviewPeople?.count, 2)
        XCTAssertNotEqual(result.speakerReviewAssignments?["system:0"], result.speakerReviewAssignments?["system:1"])
        XCTAssertEqual(Set(result.speakerReviewPeople?.compactMap(\.voiceProfileID) ?? []), [firstProfile.id, secondProfile.id])
    }

    func testMatchingPendingProfileCanBeConfirmedWithoutChangingScoreOrTraining() throws {
        let voice = profile()
        var original = meeting()
        original.speakerSuggestions = ["system:0": .init(profileID: voice.id, name: "Eski ad", similarity: 0.71, automatic: false)]
        let result = try SpeakerReviewPolicy.assign(meeting: original, speakerID: "system:0", selection: .init(voiceProfileID: voice.id, name: ""), profiles: [voice])
        XCTAssertEqual(result.speakerSuggestions?["system:0"]?.profileID, voice.id)
        XCTAssertEqual(result.speakerSuggestions?["system:0"]?.name, voice.name)
        XCTAssertEqual(result.speakerSuggestions?["system:0"]?.similarity, 0.71)
        XCTAssertEqual(result.speakerSuggestions?["system:0"]?.automatic, true)
        XCTAssertEqual(voice.samples, [[1, 0]])
    }

    func testPickingAnotherPersonClearsConflictingSuggestionRatherThanInventingMatchEvidence() throws {
        let first = profile("Onur"), second = profile("Elif")
        var original = meeting()
        original.speakerSuggestions = ["system:0": .init(profileID: first.id, name: first.name, similarity: 0.73, automatic: false)]
        let result = try SpeakerReviewPolicy.assign(meeting: original, speakerID: "system:0", selection: .init(voiceProfileID: second.id, name: ""), profiles: [first, second])
        XCTAssertNil(result.speakerSuggestions?["system:0"])
        XCTAssertEqual(result.speakerNames["system:0"], "Elif")
        XCTAssertEqual(result.speakerReviewPeople?.first?.voiceProfileID, second.id)
    }

    func testNewNameDoesNotBecomeGlobalIdentityEvenWhenItMatchesStoredProfileName() throws {
        let voice = profile()
        var original = meeting()
        original.speakerSuggestions = ["system:0": .init(profileID: voice.id, name: voice.name, similarity: 0.72, automatic: false)]
        let result = try SpeakerReviewPolicy.assign(meeting: original, speakerID: "system:0", selection: .init(name: voice.name), profiles: [voice])
        XCTAssertNil(result.speakerReviewPeople?.first?.voiceProfileID)
        XCTAssertNil(result.speakerSuggestions?["system:0"])
        XCTAssertEqual(result.speakerNames["system:0"], voice.name)
    }

    func testDeletedGlobalProfileDoesNotEraseOrBlockExistingMeetingPerson() throws {
        let person = SpeakerReviewPerson(name: "Onur", voiceProfileID: UUID())
        var original = meeting()
        original.speakerReviewPeople = [person]
        original.speakerReviewAssignments = ["system:0": person.id]
        original.speakerNames = ["system:0": person.name]
        original.speakerSuggestions = ["system:1": .init(profileID: person.voiceProfileID!, name: person.name, similarity: 0.9, automatic: true)]
        let result = try SpeakerReviewPolicy.assign(meeting: original, speakerID: "system:1", selection: .init(personID: person.id, name: ""), profiles: [])
        XCTAssertEqual(result.speakerReviewPeople, [person])
        XCTAssertEqual(result.speakerReviewAssignments?["system:1"], person.id)
        XCTAssertEqual(result.speakerNames["system:0"], person.name)
        XCTAssertEqual(result.speakerNames["system:1"], person.name)
        XCTAssertNil(result.speakerSuggestions?["system:1"])
    }

    func testUnknownAndConflictingSelectionsFailWithoutChangingOriginalMeeting() throws {
        var original = meeting()
        let voice = profile()
        let person = SpeakerReviewPerson(name: "Onur", voiceProfileID: voice.id)
        original.speakerReviewPeople = [person]
        let snapshot = original
        XCTAssertThrowsError(try SpeakerReviewPolicy.assign(meeting: original, speakerID: "missing-speaker", selection: .init(name: "Elif"), profiles: [voice]))
        XCTAssertThrowsError(try SpeakerReviewPolicy.assign(meeting: original, speakerID: "system:0", selection: .init(personID: UUID(), name: ""), profiles: [voice]))
        XCTAssertThrowsError(try SpeakerReviewPolicy.assign(meeting: original, speakerID: "system:0", selection: .init(voiceProfileID: UUID(), name: ""), profiles: [voice]))
        XCTAssertThrowsError(try SpeakerReviewPolicy.assign(meeting: original, speakerID: "system:0", selection: .init(personID: person.id, voiceProfileID: UUID(), name: ""), profiles: [voice]))
        XCTAssertEqual(original, snapshot)
    }

    func testNewNamesUseExistingNameValidation() throws {
        for name in ["", " \n", "Onur\nBaşterzi", String(repeating: "a", count: 101)] {
            XCTAssertThrowsError(try SpeakerReviewPolicy.assign(meeting: meeting(), speakerID: "system:0", selection: .init(name: name), profiles: []))
        }
    }

    func testSpeakerQueueIsChronologicalAndIncludesTurnOnlyClustersButNotSourceLabels() {
        var value = meeting(clusters: 0)
        value.speakerTurns = [SpeakerTurn(speakerID: "system:later", source: .system, start: 20, end: 24),
                              SpeakerTurn(speakerID: "microphone:first", source: .microphone, start: 2, end: 5),
                              SpeakerTurn(speakerID: "system:later", source: .system, start: 25, end: 30),
                              SpeakerTurn(speakerID: "bad", source: .system, start: .nan, end: 4),
                              SpeakerTurn(speakerID: "", source: .system, start: 0, end: 5)]
        value.segments = [TranscriptSegment(id: "a", speaker: "Toplantı sesi", start: 0, end: 30, text: "Kaynak etiketi"),
                          TranscriptSegment(id: "b", speaker: "legacy-voice", start: 10, end: 12, text: "Eski konuşmacı"),
                          TranscriptSegment(id: "c", speaker: "Mikrofon", start: 0, end: 5, text: "Kaynak etiketi"),
                          TranscriptSegment(id: "d", speaker: "Konuşma", start: 0, end: 5, text: "Kaynak etiketi")]
        XCTAssertEqual(SpeakerReviewPolicy.speakerIDs(in: value), ["microphone:first", "legacy-voice", "system:later"])
        XCTAssertEqual(SpeakerReviewPolicy.confirmedCount(in: value), 0)
        XCTAssertThrowsError(try SpeakerReviewPolicy.assign(meeting: value, speakerID: "Toplantı sesi", selection: .init(name: "Onur"), profiles: []))
    }

    func testInvalidExistingPersonAssignmentsAreNotSilentlyRepaired() throws {
        var value = meeting()
        value.speakerReviewAssignments = ["system:0": UUID()]
        XCTAssertThrowsError(try SpeakerReviewPolicy.assign(meeting: value, speakerID: "system:1", selection: .init(name: "Onur"), profiles: []))
    }

    func testUnchangedLabelDoesNotInvalidateReviewedNotesButNewLabelDoes() throws {
        let person = SpeakerReviewPerson(name: "Onur")
        var original = meeting()
        original.speakerReviewPeople = [person]
        original.speakerNames = ["system:0": person.name, "legacy": "Başka eski ad"]
        original.notes = notes()
        let reviewed = Date(timeIntervalSince1970: 1_700_000_000)
        original.reviewedAt = reviewed
        let same = try SpeakerReviewPolicy.assign(meeting: original, speakerID: "system:0", selection: .init(personID: person.id, name: ""), profiles: [])
        XCTAssertFalse(same.notesNeedRefresh)
        XCTAssertEqual(same.reviewedAt, reviewed)
        XCTAssertEqual(same.speakerNames["legacy"], "Başka eski ad")
        let changed = try SpeakerReviewPolicy.assign(meeting: original, speakerID: "system:1", selection: .init(personID: person.id, name: ""), profiles: [])
        XCTAssertTrue(changed.notesNeedRefresh)
        XCTAssertNil(changed.reviewedAt)
        XCTAssertEqual(changed.notes, original.notes)
    }

    func testOptionalReviewFieldsRoundTripAndOlderArchivesDecodeWithoutThem() throws {
        let reviewed = try SpeakerReviewPolicy.assign(meeting: meeting(), speakerID: "system:0", selection: .init(name: "Onur"), profiles: [])
        let data = try JSONEncoder().encode(reviewed)
        XCTAssertEqual(try JSONDecoder().decode(Meeting.self, from: data), reviewed)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        object.removeValue(forKey: "speakerReviewPeople")
        object.removeValue(forKey: "speakerReviewAssignments")
        let old = try JSONDecoder().decode(Meeting.self, from: JSONSerialization.data(withJSONObject: object))
        XCTAssertNil(old.speakerReviewPeople)
        XCTAssertNil(old.speakerReviewAssignments)
        XCTAssertEqual(old.segments, reviewed.segments)
        XCTAssertEqual(old.speakerNames, reviewed.speakerNames)
    }
}
