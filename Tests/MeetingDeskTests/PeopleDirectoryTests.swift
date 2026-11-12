import Foundation
import XCTest
@testable import MeetingDesk

final class PeopleDirectoryTests: XCTestCase {
    private func profile(_ name: String = "Onur", updated: TimeInterval = 100, samples: Int = 1) -> VoiceProfile {
        VoiceProfile(name: name, modelID: "synthetic-model", samples: Array(repeating: [1, 0], count: samples),
            createdAt: Date(timeIntervalSince1970: 50), updatedAt: Date(timeIntervalSince1970: updated))
    }

    private func meeting(_ people: [SpeakerReviewPerson], at timestamp: TimeInterval = 200) -> Meeting {
        var value = Meeting(title: "Sentetik kişi listesi", createdAt: Date(timeIntervalSince1970: timestamp))
        value.speakerReviewPeople = people
        return value
    }

    func testUnusedSavedProfilesAreListedWithTheirCurrentNameAndExampleCount() throws {
        let voice = profile(updated: 300, samples: 4)
        let entry = try XCTUnwrap(PeopleDirectory.entries(meetings: [], profiles: [voice]).first)
        XCTAssertEqual(entry.id, "profile:\(voice.id.uuidString)")
        XCTAssertEqual(entry.name, voice.name)
        XCTAssertEqual(entry.profileID, voice.id)
        XCTAssertEqual(entry.sampleCount, 4)
        XCTAssertTrue(entry.meetingIDs.isEmpty)
        XCTAssertNil(entry.lastSeen, "A saved voice sample alone is not a meeting")
    }

    func testMeetingOnlyPeopleAreVisibleWithoutClaimingSavedVoice() throws {
        let person = SpeakerReviewPerson(name: "Elif")
        let original = meeting([person])
        let entry = try XCTUnwrap(PeopleDirectory.entries(meetings: [original], profiles: []).first)
        XCTAssertEqual(entry.id, "meeting:\(original.id.uuidString):person:\(person.id.uuidString)")
        XCTAssertEqual(entry.name, person.name)
        XCTAssertNil(entry.profileID)
        XCTAssertEqual(entry.sampleCount, 0)
        XCTAssertEqual(entry.meetingIDs, [original.id])
        XCTAssertEqual(entry.lastSeen, original.createdAt)
    }

    func testSameNamedUnrelatedPeopleAndProfilesRemainSeparate() {
        let first = SpeakerReviewPerson(name: "Deniz"), second = SpeakerReviewPerson(name: "Deniz")
        let one = meeting([first]), two = meeting([second])
        let global = profile("Deniz")
        let entries = PeopleDirectory.entries(meetings: [one, two], profiles: [global])
        XCTAssertEqual(entries.count, 3)
        XCTAssertEqual(Set(entries.map(\.id)).count, 3)
        XCTAssertEqual(entries.filter { $0.profileID != nil }.count, 1)
        XCTAssertEqual(entries.filter { $0.profileID == nil }.flatMap(\.meetingIDs).count, 2)
    }

    func testLocalPersonIDsAreScopedToTheirMeetingWithoutInferringCrossMeetingIdentity() {
        let copiedPerson = SpeakerReviewPerson(name: "Deniz")
        let first = meeting([copiedPerson]), second = meeting([copiedPerson])
        let entries = PeopleDirectory.entries(meetings: [first, second], profiles: [])
        XCTAssertEqual(entries.count, 2)
        XCTAssertNotEqual(entries[0].id, entries[1].id)
    }

    func testSharedGlobalProfileDeduplicatesAcrossMeetingsAndUsesAuthoritativeCurrentName() throws {
        let voice = profile("Onur Örnek", updated: 150)
        let first = meeting([SpeakerReviewPerson(name: "Eski Onur", voiceProfileID: voice.id)], at: 200)
        let second = meeting([SpeakerReviewPerson(name: "Diğer tarihsel ad", voiceProfileID: voice.id)], at: 400)
        let entries = PeopleDirectory.entries(meetings: [first, second], profiles: [voice])
        let entry = try XCTUnwrap(entries.first)
        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entry.name, voice.name)
        XCTAssertEqual(entry.meetingIDs, [second.id, first.id])
        XCTAssertEqual(entry.lastSeen, second.createdAt)
        XCTAssertEqual(entry.profileID, voice.id)
    }

    func testProfileUpdateDoesNotChangeTheLastAssociatedMeetingDate() throws {
        let voice = profile(updated: 900)
        let value = meeting([SpeakerReviewPerson(name: "Onur", voiceProfileID: voice.id)], at: 400)
        XCTAssertEqual(try XCTUnwrap(PeopleDirectory.entries(meetings: [value], profiles: [voice]).first).lastSeen, value.createdAt)
    }

    func testDeletedProfileKeepsStableIdentityButNoRememberedVoiceClaim() throws {
        let voice = profile("Current name")
        let first = meeting([SpeakerReviewPerson(name: "Eski ad", voiceProfileID: voice.id)], at: 200)
        let second = meeting([SpeakerReviewPerson(name: "Son tarihsel ad", voiceProfileID: voice.id)], at: 400)
        let remembered = try XCTUnwrap(PeopleDirectory.entries(meetings: [first, second], profiles: [voice]).first)
        let historical = try XCTUnwrap(PeopleDirectory.entries(meetings: [second, first], profiles: []).first)
        XCTAssertEqual(historical.id, remembered.id)
        XCTAssertEqual(historical.name, "Son tarihsel ad")
        XCTAssertNil(historical.profileID)
        XCTAssertEqual(historical.sampleCount, 0)
        XCTAssertEqual(historical.meetingIDs, [second.id, first.id])
        XCTAssertEqual(historical.lastSeen, second.createdAt)
    }

    func testConfirmedOlderAssociationsAddMeetingHistoryButPendingAndUnusedAssociationsDoNot() throws {
        let voice = profile()
        var confirmed = meeting([], at: 200)
        confirmed.segments = [TranscriptSegment(id: "s1", speaker: "system:A", start: 0, end: 5, text: "Sentetik konuşma.")]
        confirmed.speakerSuggestions = ["system:A": .init(profileID: voice.id, name: voice.name, similarity: 0.9, automatic: true)]
        var pending = meeting([], at: 900)
        pending.segments = confirmed.segments
        pending.speakerSuggestions = ["system:A": .init(profileID: voice.id, name: voice.name, similarity: 0.7, automatic: false)]
        var unused = meeting([], at: 1_000)
        unused.segments = confirmed.segments
        unused.speakerSuggestions = ["missing-speaker": .init(profileID: voice.id, name: voice.name, similarity: 0.9, automatic: true)]
        let entry = try XCTUnwrap(PeopleDirectory.entries(meetings: [confirmed, pending, unused], profiles: [voice]).first)
        XCTAssertEqual(entry.meetingIDs, [confirmed.id])
        XCTAssertEqual(entry.lastSeen, confirmed.createdAt)
        let forgotten = try XCTUnwrap(PeopleDirectory.entries(meetings: [confirmed, pending, unused], profiles: []).first)
        XCTAssertEqual(forgotten.id, entry.id)
        XCTAssertEqual(forgotten.name, voice.name)
        XCTAssertNil(forgotten.profileID)
        XCTAssertEqual(forgotten.sampleCount, 0)
        XCTAssertEqual(forgotten.meetingIDs, [confirmed.id])
        XCTAssertEqual(forgotten.lastSeen, confirmed.createdAt)
    }

    func testConfirmedTurnOnlyClusterCanLinkWordlessLegacyMeeting() throws {
        let voice = profile()
        var original = meeting([], at: 500)
        original.segments = [TranscriptSegment(id: "old", speaker: "Toplantı sesi", start: 0, end: 30, text: "Kelime zamanı olmayan döküm.")]
        original.speakerTurns = [SpeakerTurn(speakerID: "system:A", source: .system, start: 1, end: 5)]
        original.speakerSuggestions = ["system:A": .init(profileID: voice.id, name: voice.name, similarity: 1, automatic: true)]
        XCTAssertEqual(try XCTUnwrap(PeopleDirectory.entries(meetings: [original], profiles: [voice]).first).meetingIDs, [original.id])
    }

    func testRepeatedClustersAndSnapshotsDoNotInflateMeetingCount() throws {
        let voice = profile()
        var original = meeting([SpeakerReviewPerson(name: voice.name, voiceProfileID: voice.id)])
        original.segments = [TranscriptSegment(id: "s1", speaker: "system:A", start: 0, end: 4, text: "Sentetik."),
                             TranscriptSegment(id: "s2", speaker: "system:B", start: 4, end: 8, text: "Sentetik.")]
        original.speakerSuggestions = ["system:A": .init(profileID: voice.id, name: voice.name, similarity: 1, automatic: true),
                                       "system:B": .init(profileID: voice.id, name: voice.name, similarity: 1, automatic: true)]
        XCTAssertEqual(try XCTUnwrap(PeopleDirectory.entries(meetings: [original, original], profiles: [voice]).first).meetingIDs, [original.id])
    }

    func testOrderAndHistoricalNameTieBreakAreIndependentOfInputOrder() {
        let sharedDeletedID = UUID()
        let first = meeting([SpeakerReviewPerson(name: "Birinci tarihsel ad", voiceProfileID: sharedDeletedID)], at: 300)
        let second = meeting([SpeakerReviewPerson(name: "İkinci tarihsel ad", voiceProfileID: sharedDeletedID)], at: 300)
        let local = meeting([SpeakerReviewPerson(name: "Altuğ")], at: 100)
        let profiles = [profile("Zeynep"), profile("Elif")]
        XCTAssertEqual(PeopleDirectory.entries(meetings: [first, second, local], profiles: profiles),
                       PeopleDirectory.entries(meetings: [local, second, first], profiles: Array(profiles.reversed())))
    }

    func testDirectoryComputationDoesNotMutateHistoricalNamesOrVoiceSamples() {
        let voice = profile("Yeni isim", samples: 3)
        let original = meeting([SpeakerReviewPerson(name: "Tarihsel isim", voiceProfileID: voice.id)])
        let meetings = [original], profiles = [voice]
        _ = PeopleDirectory.entries(meetings: meetings, profiles: profiles)
        XCTAssertEqual(meetings, [original])
        XCTAssertEqual(meetings[0].speakerReviewPeople?.first?.name, "Tarihsel isim")
        XCTAssertEqual(profiles, [voice])
    }
}
