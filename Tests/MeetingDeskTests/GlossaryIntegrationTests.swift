import Foundation
import XCTest
@testable import MeetingDesk

@MainActor
final class GlossaryIntegrationTests: XCTestCase {
    private func withStore(_ body: (AppStore, URL) throws -> Void) throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("glossary-app-test-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let store = AppStore(root: root, initializeSystemServices: false, audioRetentionDefaults: UserDefaults(suiteName: UUID().uuidString)!)
        try body(store, root)
    }
    private var term: GlossaryEntry { GlossaryEntry(canonical: "Lifesycle", variants: ["life cycle"]) }
    private func prepare(_ store: AppStore) throws -> (Meeting, GlossarySuggestion) {
        let term = term
        XCTAssertTrue(store.saveGlossaryEntry(term))
        let original = Meeting(title: "Synthetic", segments: [TranscriptSegment(id: "s1", speaker: "system:A", start: 1, end: 4, text: "life cycle")])
        try store.library.save(original)
        store.meetings = [original]; store.selectedID = original.id
        return (original, try XCTUnwrap(TranscriptGlossary.suggestions(segments: original.segments, entries: [term]).first))
    }

    func testCRUDAndRootScopedLoadingNeverTouchesAnotherLibrary() throws {
        try withStore { store, root in
            var entry = term
            XCTAssertTrue(store.saveGlossaryEntry(entry))
            entry.variants.append("layf saykıl")
            XCTAssertTrue(store.saveGlossaryEntry(entry))
            let reloaded = AppStore(root: root, initializeSystemServices: false, audioRetentionDefaults: UserDefaults(suiteName: UUID().uuidString)!)
            XCTAssertEqual(reloaded.glossaryEntries, [entry])
            let other = AppStore(root: root.appendingPathComponent("other"), initializeSystemServices: false,
                audioRetentionDefaults: UserDefaults(suiteName: UUID().uuidString)!)
            XCTAssertEqual(other.glossaryEntries, [])
            XCTAssertTrue(store.deleteGlossaryEntry(id: entry.id))
            XCTAssertEqual(try GlossaryStore(root: root).load(), [])
        }
    }

    func testReadOrPersistenceFailureNeverPublishesChangedDictionary() throws {
        try withStore { store, root in
            let entry = term
            XCTAssertTrue(store.saveGlossaryEntry(entry))
            let corrupt = Data("broken".utf8)
            try corrupt.write(to: GlossaryStore(root: root).fileURL)
            XCTAssertFalse(store.deleteGlossaryEntry(id: entry.id))
            XCTAssertEqual(store.glossaryEntries, [entry])
            XCTAssertEqual(try Data(contentsOf: GlossaryStore(root: root).fileURL), corrupt)
            let reloaded = AppStore(root: root, initializeSystemServices: false, audioRetentionDefaults: UserDefaults(suiteName: UUID().uuidString)!)
            XCTAssertTrue(reloaded.glossaryEntries.isEmpty)
            XCTAssertNotNil(reloaded.errorMessage)
            XCTAssertFalse(reloaded.saveGlossaryEntry(term))
            XCTAssertEqual(try Data(contentsOf: GlossaryStore(root: root).fileURL), corrupt)
        }
    }

    func testApplyingRequiresExplicitSuggestionAndSavesRestorableHistory() throws {
        try withStore { store, root in
            let (original, suggestion) = try prepare(store)
            XCTAssertEqual(store.selected, original, "Saving a dictionary entry does not mutate any transcript")
            XCTAssertTrue(store.applyGlossarySuggestion(suggestion, meetingID: original.id))
            XCTAssertEqual(store.selected?.segments[0].text, "Lifesycle")
            XCTAssertEqual(try store.library.latestTranscriptVersion(for: original.id), original)
            XCTAssertEqual(try MeetingLibrary(root: root).load().meetings.first, store.selected)
            XCTAssertFalse(store.applyGlossarySuggestion(suggestion, meetingID: original.id))
        }
    }

    func testHistoryFailureStopsBeforeCurrentTranscriptChanges() throws {
        try withStore { store, _ in
            let (original, suggestion) = try prepare(store)
            try Data("obstruction".utf8).write(to: store.library.directory(for: original.id).appendingPathComponent(".transcript-history"))
            XCTAssertFalse(store.applyGlossarySuggestion(suggestion, meetingID: original.id))
            XCTAssertEqual(store.selected, original)
            XCTAssertEqual(try store.library.load().meetings.first, original)
        }
    }

    func testMeetingSaveFailureKeepsPublishedStateAndOriginalHistory() throws {
        try withStore { store, _ in
            let (original, suggestion) = try prepare(store)
            let file = store.library.directory(for: original.id).appendingPathComponent("meeting.json")
            try FileManager.default.removeItem(at: file)
            try FileManager.default.createDirectory(at: file, withIntermediateDirectories: true)
            XCTAssertFalse(store.applyGlossarySuggestion(suggestion, meetingID: original.id))
            XCTAssertEqual(store.selected, original)
            XCTAssertEqual(try store.library.latestTranscriptVersion(for: original.id), original)
        }
    }

    func testBusySelectionAndDuplicateMeetingIdentityGuardsPreventMutations() throws {
        try withStore { store, _ in
            let (original, suggestion) = try prepare(store)
            store.isBusy = true
            XCTAssertFalse(store.applyGlossarySuggestion(suggestion, meetingID: original.id))
            XCTAssertFalse(store.saveGlossaryEntry(term))
            XCTAssertFalse(store.deleteGlossaryEntry(id: store.glossaryEntries[0].id))
            store.isBusy = false; store.selectedID = nil
            XCTAssertFalse(store.applyGlossarySuggestion(suggestion, meetingID: original.id))
            store.selectedID = original.id; store.meetings.append(original)
            XCTAssertFalse(store.applyGlossarySuggestion(suggestion, meetingID: original.id))
            XCTAssertEqual(store.meetings, [original, original])
            XCTAssertFalse(store.library.hasTranscriptVersion(for: original.id))
        }
    }

    func testDictionaryChangedExternallyCannotOverwriteOrPublishStaleState() throws {
        try withStore { store, root in
            let original = term
            XCTAssertTrue(store.saveGlossaryEntry(original))
            let external = GlossaryEntry(canonical: "Örnek", variants: ["ornek"])
            try GlossaryStore(root: root).save([external])
            XCTAssertFalse(store.deleteGlossaryEntry(id: original.id))
            XCTAssertEqual(store.glossaryEntries, [original])
            XCTAssertEqual(try GlossaryStore(root: root).load(), [external])
        }
    }

    func testReviewCacheInvalidatesOnlyWithRelevantInputAndMeetingScope() async throws {
        let model = GlossaryReviewModel()
        let input = GlossaryReviewInput(meetingID: UUID(), segments: [
            TranscriptSegment(id: "s1", speaker: "system:A", start: 1, end: 4, text: "life cycle")], entries: [term])
        await model.update(input)
        XCTAssertEqual(model.preparationCount, 1)
        XCTAssertEqual(model.suggestions.count, 1)
        await model.update(input)
        XCTAssertEqual(model.preparationCount, 1, "Unrelated publications such as playback never enter this input")
        var otherMeeting = input; otherMeeting.meetingID = UUID()
        await model.update(otherMeeting)
        XCTAssertEqual(model.preparationCount, 2)
        var noDictionary = otherMeeting; noDictionary.entries = []
        await model.update(noDictionary)
        XCTAssertEqual(model.preparationCount, 3)
        XCTAssertTrue(model.suggestions.isEmpty)
        XCTAssertTrue(model.matches(noDictionary))
        XCTAssertFalse(model.matches(input))
    }
}
