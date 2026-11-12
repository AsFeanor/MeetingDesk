import Foundation
import XCTest
@testable import MeetingDesk

final class SpeakerRecognitionStoreTests: XCTestCase {
    private func temporary() throws -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MeetingDesk-SpeakerStoreTests-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    private func defaults() -> UserDefaults {
        let suite = "MeetingDesk-SpeakerStoreTests-\(UUID())"
        addTeardownBlock { UserDefaults.standard.removePersistentDomain(forName: suite) }
        return UserDefaults(suiteName: suite)!
    }

    private func profile() -> VoiceProfile { VoiceProfile(name: "Onur", modelID: "test-model", samples: [[1, 0]]) }

    func testProfileDeletionPreservesPreviousNamesAndTranscript() async throws {
        let root = try temporary(), settings = defaults(), person = profile()
        try await MainActor.run {
            let store = AppStore(root: root, initializeSystemServices: false, audioRetentionDefaults: settings)
            try store.voiceProfileStore.save([person]); store.voiceProfiles = [person]
            let meeting = store.newMeeting()
            XCTAssertTrue(store.update(meeting.id) {
                $0.segments = [TranscriptSegment(id: "s1", speaker: "system:A", start: 0, end: 5, text: "Ben hazırlayacağım.", audioSource: .system)]
                $0.speakerNames = ["system:A": person.name]
            })
            let before = try XCTUnwrap(store.selected)
            store.deleteVoiceProfile(id: person.id)
            XCTAssertEqual(try store.voiceProfileStore.load(), [])
            XCTAssertTrue(store.voiceProfiles.isEmpty)
            XCTAssertEqual(store.selected?.speakerNames, before.speakerNames)
            XCTAssertEqual(store.selected?.segments, before.segments)
            XCTAssertEqual(try store.library.load().meetings.first?.speakerName("system:A"), "Onur")
        }
    }

    func testConfirmAndDismissSuggestionNeverEnrollOrModifyStoredVoiceSamples() async throws {
        let root = try temporary(), settings = defaults(), person = profile()
        try await MainActor.run {
            let store = AppStore(root: root, initializeSystemServices: false, audioRetentionDefaults: settings)
            try store.voiceProfileStore.save([person]); store.voiceProfiles = [person]
            let meeting = store.newMeeting()
            let suggestion = SpeakerIdentitySuggestion(profileID: person.id, name: person.name, similarity: 0.7, automatic: false)
            XCTAssertTrue(store.update(meeting.id) {
                $0.segments = [TranscriptSegment(id: "s1", speaker: "system:A", start: 0, end: 4, text: "Bir iş."),
                               TranscriptSegment(id: "s2", speaker: "system:B", start: 4, end: 8, text: "Diğer iş.")]
                $0.speakerNames = ["system:A": "Konuşmacı 1", "system:B": "Konuşmacı 2"]
                $0.speakerSuggestions = ["system:A": suggestion, "system:B": suggestion]
                $0.notes = MeetingNotes(summary: "Not", decisions: [], actions: [], questions: [], ideas: [], topics: [])
            })
            let originalProfileBytes = try Data(contentsOf: store.voiceProfileStore.fileURL)
            store.confirmSpeakerMatch("system:A", profileID: person.id)
            XCTAssertEqual(store.selected?.speakerName("system:A"), person.name)
            XCTAssertEqual(store.selected?.speakerSuggestions?["system:A"]?.profileID, person.id)
            XCTAssertEqual(store.selected?.speakerSuggestions?["system:A"]?.automatic, true)
            XCTAssertEqual(store.selected?.speakerSuggestions?["system:A"]?.similarity, suggestion.similarity)
            XCTAssertTrue(store.selected?.notesNeedRefresh == true)
            store.dismissSpeakerSuggestion("system:B")
            XCTAssertNil(store.selected?.speakerSuggestions?["system:B"])
            XCTAssertEqual(store.selected?.speakerName("system:B"), "Konuşmacı 2")
            XCTAssertEqual(store.voiceProfiles, [person])
            XCTAssertEqual(try Data(contentsOf: store.voiceProfileStore.fileURL), originalProfileBytes)
        }
    }

    func testCorruptProfilesCannotBeOverwrittenByRenameOrDelete() async throws {
        let root = try temporary(), settings = defaults(), person = profile()
        try await MainActor.run {
            let store = AppStore(root: root, initializeSystemServices: false, audioRetentionDefaults: settings)
            try store.voiceProfileStore.save([person]); store.voiceProfiles = [person]
            let corrupt = Data("{incomplete profile database".utf8)
            try corrupt.write(to: store.voiceProfileStore.fileURL)
            store.renameVoiceProfile(id: person.id, name: "Yeni isim")
            XCTAssertNotNil(store.errorMessage)
            XCTAssertEqual(store.voiceProfiles, [person])
            XCTAssertEqual(try Data(contentsOf: store.voiceProfileStore.fileURL), corrupt)
            store.deleteVoiceProfile(id: person.id)
            XCTAssertEqual(store.voiceProfiles, [person])
            XCTAssertEqual(try Data(contentsOf: store.voiceProfileStore.fileURL), corrupt)
        }
    }

    func testManualCorrectionExcludesWronglyAssignedSpanFromEnrollment() async throws {
        let root = try temporary(), settings = defaults()
        try await MainActor.run {
            let store = AppStore(root: root, initializeSystemServices: false, audioRetentionDefaults: settings)
            let meeting = store.newMeeting()
            let turns = [SpeakerTurn(speakerID: "system:A", source: .system, start: 0, end: 10),
                         SpeakerTurn(speakerID: "system:B", source: .system, start: 10, end: 15)]
            XCTAssertTrue(store.update(meeting.id) {
                $0.segments = [TranscriptSegment(id: "a1", speaker: "system:A", start: 0, end: 5, text: "Doğru kişi.", audioSource: .system),
                               TranscriptSegment(id: "a2", speaker: "system:A", start: 5, end: 10, text: "Yanlış kişi.", audioSource: .system),
                               TranscriptSegment(id: "b1", speaker: "system:B", start: 10, end: 15, text: "Diğer kişi.", audioSource: .system)]
                $0.speakerTurns = turns
            })
            store.assignSpeaker(segmentID: "a2", speakerID: "system:B")
            let corrected = try XCTUnwrap(store.selected)
            let evidence = SpeakerEnrollmentEvidence.eligibleTurns(in: corrected, speakerID: "system:A")
            let target = evidence.filter { $0.speakerID == "system:A" }
            XCTAssertEqual(target, [SpeakerTurn(speakerID: "system:A", source: .system, start: 0, end: 5)])
            XCTAssertTrue(evidence.contains(turns[1]), "Other speakers must remain blockers during clean-span extraction")
            XCTAssertFalse(target.contains { $0.end > 5 })
        }
    }

    func testProfileSettingsAndOptionalRecognitionDataPersistWithoutLoadingModels() async throws {
        let root = try temporary(), settings = defaults()
        try await MainActor.run {
            let store = AppStore(root: root, initializeSystemServices: false, audioRetentionDefaults: settings)
            XCTAssertFalse(store.speakerRecognitionEnabled)
            store.speakerRecognitionEnabled = true
            let meeting = store.newMeeting()
            let turns = [SpeakerTurn(speakerID: "system:A", source: .system, start: 0, end: 5)]
            XCTAssertTrue(store.update(meeting.id) {
                $0.segments = [TranscriptSegment(id: "s1", speaker: "system:A", start: 0, end: 5, text: "Bir konuşma.",
                    words: [TranscriptWord(text: "Bir konuşma.", start: 0, end: 5)], audioSource: .system)]
                $0.speakerTurns = turns
                $0.speakerRecognitionEngine = "synthetic-test-engine"
            })
            let reopened = AppStore(root: root, initializeSystemServices: false, audioRetentionDefaults: settings)
            XCTAssertTrue(reopened.speakerRecognitionEnabled)
            XCTAssertFalse(reopened.speakerModelsReady)
            let restored = try XCTUnwrap(reopened.meetings.first)
            XCTAssertEqual(restored.speakerTurns, turns)
            XCTAssertEqual(restored.segments, store.selected?.segments)
            XCTAssertFalse(FileManager.default.fileExists(atPath: root.appendingPathComponent(".speaker-models").path))
        }
    }
}
