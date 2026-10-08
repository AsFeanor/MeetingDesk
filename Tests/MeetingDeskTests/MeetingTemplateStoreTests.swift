import XCTest
@testable import MeetingDesk

final class MeetingTemplateStoreTests: XCTestCase {
    func testGeneratedNotesPersistTheirActualTemplateAndHistoryKeepsPreviousTemplate() async throws {
        let root = temporaryRoot()
        try await MainActor.run {
            let store = AppStore(root: root, initializeSystemServices: false)
            let original = try seedMeeting(in: store)
            store.setTemplate(.customer, for: original.id)
            let source = try XCTUnwrap(store.selected)
            let generated = notes("Müşteri ihtiyaçları ve verilen sözler")
            try store.commitGeneratedNotes(generated, sourceMeeting: source, engine: ProcessingMode.local.rawValue)

            let current = try XCTUnwrap(store.selected)
            XCTAssertEqual(current.notes, generated)
            XCTAssertEqual(current.notesTemplate, .customer)
            XCTAssertEqual(current.notesTemplateRawValue, MeetingTemplate.customer.rawValue)
            XCTAssertEqual(current.template, .customer)
            XCTAssertFalse(current.notesNeedRefresh)
            XCTAssertEqual(current.notesEngine, ProcessingMode.local.rawValue)
            XCTAssertEqual(try store.library.load().meetings, [current])
            let previous = try XCTUnwrap(store.library.latestNotesVersion(for: original.id))
            XCTAssertEqual(previous.notes, original.notes)
            XCTAssertEqual(previous.notesTemplateRawValue, MeetingTemplate.general.rawValue)
            XCTAssertEqual(previous.templateRawValue, MeetingTemplate.customer.rawValue)
            XCTAssertTrue(previous.notesNeedRefresh)
            XCTAssertEqual(current.segments, original.segments)
            XCTAssertEqual(current.personalNotes, original.personalNotes)
        }
    }

    func testSelectingNewTemplateOrLanguageMarksNotesStaleWithoutRelabelingExistingNotes() async throws {
        let root = temporaryRoot()
        try await MainActor.run {
            let store = AppStore(root: root, initializeSystemServices: false)
            let original = try seedMeeting(in: store)
            store.markNotesReviewed(original.id)
            XCTAssertNotNil(store.selected?.reviewedAt)
            store.setTemplate(.team, for: original.id)
            XCTAssertEqual(store.selected?.template, .team)
            XCTAssertEqual(store.selected?.notesTemplate, .general)
            XCTAssertEqual(store.selected?.notes, original.notes)
            XCTAssertTrue(try XCTUnwrap(store.selected).notesNeedRefresh)
            XCTAssertNil(store.selected?.reviewedAt)
            store.setOutputLanguage("English", for: original.id)
            let current = try XCTUnwrap(store.selected)
            XCTAssertEqual(current.outputLanguage, "English")
            XCTAssertEqual(current.notesTemplateRawValue, original.notesTemplateRawValue)
            XCTAssertEqual(current.notes, original.notes)
            XCTAssertTrue(current.notesNeedRefresh)
            XCTAssertEqual(try store.library.load().meetings, [current])
            XCTAssertFalse(store.library.hasNotesVersion(for: original.id))
        }
    }

    func testChangingSettingsBeforeFirstSummaryDoesNotMakeMissingNotesStale() async throws {
        let root = temporaryRoot()
        try await MainActor.run {
            let store = AppStore(root: root, initializeSystemServices: false)
            let meeting = store.newMeeting()
            store.setTemplate(.product, for: meeting.id)
            store.setOutputLanguage("English", for: meeting.id)
            let current = try XCTUnwrap(store.selected)
            XCTAssertEqual(current.template, .product)
            XCTAssertEqual(current.outputLanguage, "English")
            XCTAssertNil(current.notes)
            XCTAssertNil(current.notesTemplateRawValue)
            XCTAssertFalse(current.notesNeedRefresh)
        }
    }

    func testBusyWorkAndMicrophoneCheckBlockSettingsEditsAndHistoryRestore() async throws {
        let root = temporaryRoot()
        try await MainActor.run {
            let store = AppStore(root: root, initializeSystemServices: false)
            let original = try seedMeeting(in: store)
            var earlier = original
            earlier.notes = notes("Önceki notlar")
            earlier.templateRawValue = MeetingTemplate.team.rawValue
            earlier.notesTemplateRawValue = MeetingTemplate.team.rawValue
            try store.library.saveNotesVersion(earlier)
            let historyBefore = try historyFiles(in: store.library, meetingID: original.id)
            for microphoneCheck in [false, true] {
                store.isBusy = !microphoneCheck
                store.showMicrophoneCheck = microphoneCheck
                XCTAssertTrue(store.workInProgress)
                store.setTemplate(.customer, for: original.id)
                store.setOutputLanguage("English", for: original.id)
                store.restorePreviousNotes()
                XCTAssertThrowsError(try store.saveEditedNotes(notes("Kaydedilmemeli"), meetingID: original.id))
                XCTAssertEqual(store.selected, original)
                XCTAssertEqual(try historyFiles(in: store.library, meetingID: original.id), historyBefore)
                XCTAssertEqual(try store.library.load().meetings, [original])
            }
            store.isBusy = false
            store.showMicrophoneCheck = false
            XCTAssertFalse(store.workInProgress)
            store.setTemplate(.customer, for: original.id)
            XCTAssertEqual(store.selected?.template, .customer)
        }
    }

    func testSourceOrConfigurationChangesRejectAsynchronousResultBeforeCreatingHistory() async throws {
        let changes: [(String, (inout Meeting) -> Void)] = [
            ("şablon", { $0.templateRawValue = MeetingTemplate.team.rawValue }),
            ("özet dili", { $0.outputLanguage = "English" }),
            ("transkript", { $0.segments[0].text = "Aynı kimlikte değiştirilmiş kaynak" }),
            ("konuşmacı", { $0.speakerNames["A"] = "Yeni konuşmacı adı" }),
            ("başlık", { $0.title = "Değiştirilmiş başlık" })
        ]
        for (name, change) in changes {
            let root = temporaryRoot()
            try await MainActor.run {
                let store = AppStore(root: root, initializeSystemServices: false)
                let source = try seedMeeting(in: store)
                try store.library.saveNotesVersion(source)
                let historyBefore = try historyFiles(in: store.library, meetingID: source.id)
                XCTAssertTrue(store.update(source.id, change), name)
                let current = try XCTUnwrap(store.selected)
                XCTAssertThrowsError(try store.commitGeneratedNotes(notes("Eski girdiden gelen sonuç"),
                    sourceMeeting: source, engine: ProcessingMode.local.rawValue), name)
                XCTAssertEqual(store.selected, current, name)
                XCTAssertEqual(try store.library.load().meetings, [current], name)
                XCTAssertEqual(try historyFiles(in: store.library, meetingID: source.id), historyBefore, name)
            }
        }
    }

    func testRestoringHistoryRestoresSelectedAndActualGeneratedTemplatesIndependently() async throws {
        let root = temporaryRoot()
        try await MainActor.run {
            let store = AppStore(root: root, initializeSystemServices: false)
            var previous = try seedMeeting(in: store)
            previous.templateRawValue = MeetingTemplate.product.rawValue
            previous.notesTemplateRawValue = MeetingTemplate.team.rawValue
            previous.notesNeedRefresh = true
            previous.outputLanguage = "English"
            previous.notes = notes("Önceki ekip özeti")
            try store.library.saveNotesVersion(previous)
            XCTAssertTrue(store.update(previous.id) {
                $0.templateRawValue = MeetingTemplate.customer.rawValue
                $0.notesTemplateRawValue = MeetingTemplate.customer.rawValue
                $0.notesNeedRefresh = false
                $0.notes = notes("Yeni müşteri özeti")
                $0.personalNotes = "Güncel kişisel not korunmalı"
                $0.audioFileName = "current-recording.m4a"
            })
            let sourceBeforeRestore = try XCTUnwrap(store.selected)
            store.restorePreviousNotes()
            let restored = try XCTUnwrap(store.selected)
            XCTAssertEqual(restored.template, .product)
            XCTAssertEqual(restored.notesTemplate, .team)
            XCTAssertEqual(restored.notesTemplateRawValue, MeetingTemplate.team.rawValue)
            XCTAssertEqual(restored.notes, previous.notes)
            XCTAssertEqual(restored.outputLanguage, "English")
            XCTAssertTrue(restored.notesNeedRefresh)
            XCTAssertEqual(restored.segments, sourceBeforeRestore.segments)
            XCTAssertEqual(restored.audioFileName, sourceBeforeRestore.audioFileName)
            XCTAssertEqual(restored.personalNotes, sourceBeforeRestore.personalNotes)
            XCTAssertEqual(try store.library.load().meetings, [restored])
            XCTAssertEqual(try store.library.latestNotesVersion(for: previous.id)?.notes, sourceBeforeRestore.notes)
        }
    }

    func testLegacyHistoryWithoutGeneratedTemplateProvenanceDecodesAndRestoresAsGeneral() async throws {
        let root = temporaryRoot()
        try await MainActor.run {
            let store = AppStore(root: root, initializeSystemServices: false)
            var previous = try seedMeeting(in: store)
            previous.templateRawValue = MeetingTemplate.customer.rawValue
            previous.notesNeedRefresh = true
            try store.library.saveNotesVersion(previous)
            let history = store.library.directory(for: previous.id).appendingPathComponent(".notes-history")
            let file = try XCTUnwrap(FileManager.default.contentsOfDirectory(at: history, includingPropertiesForKeys: nil).first)
            var legacy = try XCTUnwrap(JSONSerialization.jsonObject(with: Data(contentsOf: file)) as? [String: Any])
            legacy.removeValue(forKey: "notesTemplateRawValue")
            try JSONSerialization.data(withJSONObject: legacy).write(to: file, options: .atomic)
            let decoded = try XCTUnwrap(store.library.latestNotesVersion(for: previous.id))
            XCTAssertNil(decoded.notesTemplateRawValue)
            XCTAssertEqual(decoded.notes, previous.notes)
            XCTAssertTrue(decoded.matchesTranscript(of: previous))
            XCTAssertTrue(store.update(previous.id) {
                $0.templateRawValue = MeetingTemplate.team.rawValue
                $0.notesTemplateRawValue = MeetingTemplate.team.rawValue
                $0.notes = notes("Yeni ekip özeti")
            })
            store.restorePreviousNotes()
            XCTAssertEqual(store.selected?.template, .customer)
            XCTAssertEqual(store.selected?.notesTemplate, .general)
            XCTAssertNil(store.selected?.notesTemplateRawValue)
            XCTAssertEqual(store.selected?.notes, previous.notes)
        }
    }

    func testTranscriptRestoreKeepsCurrentConfigButRestoresActualNotesTemplateAndMarksMismatchStale() async throws {
        let configurations: [(MeetingTemplate, String)] = [(.product, "Türkçe"), (.team, "English")]
        for (selectedTemplate, outputLanguage) in configurations {
            let root = temporaryRoot()
            try await MainActor.run {
                let store = AppStore(root: root, initializeSystemServices: false)
                var previous = try seedMeeting(in: store)
                previous.templateRawValue = MeetingTemplate.team.rawValue
                previous.notesTemplateRawValue = MeetingTemplate.team.rawValue
                previous.notes = notes("Eski transkriptten hazırlanan ekip özeti")
                previous.speakerNames = ["A": "Sentetik ekip konuşmacısı"]
                previous.reviewedAt = Date(timeIntervalSince1970: 1_000)
                try store.library.saveTranscriptVersion(previous)
                XCTAssertTrue(store.update(previous.id) {
                    $0.templateRawValue = selectedTemplate.rawValue
                    $0.notesTemplateRawValue = selectedTemplate.rawValue
                    $0.outputLanguage = outputLanguage
                    $0.segments = [TranscriptSegment(id: "new", speaker: "B", start: 0, end: 4, text: "Yeni sentetik konuşma")]
                    $0.speakerNames = ["B": "Güncel sentetik konuşmacı"]
                    $0.notes = notes("Güncel şablonla yenilenen özet")
                    $0.notesNeedRefresh = false
                    $0.personalNotes = "Güncel kişisel not değiştirilmemeli"
                    $0.audioFileName = "current-recording.m4a"
                })
                store.markNotesReviewed(previous.id)
                XCTAssertNotNil(store.selected?.reviewedAt)
                let current = try XCTUnwrap(store.selected)
                store.restorePreviousTranscript()
                let restored = try XCTUnwrap(store.selected)
                XCTAssertEqual(restored.template, selectedTemplate)
                XCTAssertEqual(restored.outputLanguage, outputLanguage)
                XCTAssertEqual(restored.notesTemplate, .team)
                XCTAssertEqual(restored.notesTemplateRawValue, MeetingTemplate.team.rawValue)
                XCTAssertEqual(restored.notes, previous.notes)
                XCTAssertEqual(restored.segments, previous.segments)
                XCTAssertEqual(restored.speakerNames, previous.speakerNames)
                XCTAssertTrue(restored.notesNeedRefresh)
                XCTAssertNil(restored.reviewedAt)
                XCTAssertEqual(restored.audioFileName, current.audioFileName)
                XCTAssertEqual(restored.personalNotes, current.personalNotes)
                XCTAssertEqual(try store.library.load().meetings, [restored])
                XCTAssertEqual(try store.library.latestTranscriptVersion(for: previous.id)?.notes, current.notes)
            }
        }
    }

    private func temporaryRoot() -> URL {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("MeetingDesk-TemplateStoreTests-\(UUID())")
        addTeardownBlock { try? FileManager.default.removeItem(at: root) }
        return root
    }

    @MainActor private func seedMeeting(in store: AppStore) throws -> Meeting {
        var meeting = store.newMeeting()
        meeting.title = "Sentetik şablon testi"
        meeting.segments = [TranscriptSegment(id: "s1", speaker: "A", start: 0, end: 3, text: "Sentetik kaynak bağlamı")]
        meeting.notes = notes("Önceki genel özet")
        meeting.templateRawValue = MeetingTemplate.general.rawValue
        meeting.notesTemplateRawValue = MeetingTemplate.general.rawValue
        meeting.personalNotes = "Sentetik kişisel not"
        XCTAssertTrue(store.update(meeting.id) { $0 = meeting })
        return try XCTUnwrap(store.selected)
    }

    private func notes(_ summary: String) -> MeetingNotes {
        MeetingNotes(summary: summary, decisions: [], actions: [], questions: [], ideas: [], topics: [])
    }

    private func historyFiles(in library: MeetingLibrary, meetingID: UUID) throws -> [String: Data] {
        let folder = library.directory(for: meetingID).appendingPathComponent(".notes-history")
        guard FileManager.default.fileExists(atPath: folder.path) else { return [:] }
        return try Dictionary(uniqueKeysWithValues: FileManager.default.contentsOfDirectory(at: folder,
            includingPropertiesForKeys: nil).map { ($0.lastPathComponent, try Data(contentsOf: $0)) })
    }
}
