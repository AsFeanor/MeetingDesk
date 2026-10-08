import XCTest
@testable import MeetingDesk

final class NotesTemplateRevisionTests: XCTestCase {
    func testLegacyManualSummaryWithoutTemplateProvenanceStillBelongsToGeneral() throws {
        let json = #"{"summary":"Eski elle düzeltilen özet","decisions":[],"actions":[],"questions":[],"ideas":[],"topics":[]}"#
        var meeting = sampleMeeting()
        meeting.notesManualEdits = try JSONDecoder().decode(NotesManualEdits.self, from: Data(json.utf8))
        XCTAssertNil(meeting.notesManualEdits?.summaryTemplateRawValue)
        let result = NotesRevisionPolicy.reconcileGenerated(notes("Yeni model özeti"), into: meeting)
        XCTAssertEqual(result.notes?.summary, "Eski elle düzeltilen özet")
        XCTAssertEqual(result.notesTemplateRawValue, MeetingTemplate.general.rawValue)
    }

    func testEditingSummaryRecordsActualGeneratedTemplateRatherThanNewSelection() throws {
        var meeting = sampleMeeting()
        meeting.notesTemplateRawValue = MeetingTemplate.team.rawValue
        meeting.templateRawValue = MeetingTemplate.customer.rawValue
        var draft = try XCTUnwrap(meeting.notes)
        draft.summary = "Ekip özetindeki düzeltmem"
        let edited = NotesRevisionPolicy.applyEdits(to: meeting, editedNotes: draft)
        XCTAssertEqual(edited.notesManualEdits?.summaryTemplateRawValue, MeetingTemplate.team.rawValue)
        let result = NotesRevisionPolicy.reconcileGenerated(notes("Müşteri görüşmesi özeti"), into: edited)
        XCTAssertEqual(result.notes?.summary, "Müşteri görüşmesi özeti")
        XCTAssertEqual(result.notes?.topics.map(\.text), [draft.summary])
    }

    func testSameTemplateKeepsManualSummaryWhileRefreshingOtherNotes() throws {
        var meeting = sampleMeeting()
        meeting.templateRawValue = MeetingTemplate.product.rawValue
        meeting.notesTemplateRawValue = MeetingTemplate.product.rawValue
        var draft = try XCTUnwrap(meeting.notes)
        draft.summary = "Düzeltilen ürün değerlendirmesi"
        let edited = NotesRevisionPolicy.applyEdits(to: meeting, editedNotes: draft)
        let fresh = notes("Modelin yeni ürün özeti", topics: [TopicNote(id: "fresh", title: "Geri bildirim",
            text: "Kaynakta verilen geri bildirim", evidence: ["s1"], sectionID: "feedback")])
        let result = NotesRevisionPolicy.reconcileGenerated(fresh, into: edited)
        XCTAssertEqual(result.notes?.summary, draft.summary)
        XCTAssertEqual(result.notes?.topics, fresh.topics)
    }

    func testTemplateSwitchShowsFreshSummaryAndPreservesOldCorrectionOnceAcrossRefreshes() throws {
        var draft = try XCTUnwrap(sampleMeeting().notes)
        draft.summary = "Eski şablona yaptığım düzeltme"
        var state = NotesRevisionPolicy.applyEdits(to: sampleMeeting(), editedNotes: draft)
        state.templateRawValue = MeetingTemplate.team.rawValue
        for _ in 0..<4 {
            state = NotesRevisionPolicy.reconcileGenerated(notes("Ekip ilerlemesi ve engelleri"), into: state)
            XCTAssertEqual(state.notes?.summary, "Ekip ilerlemesi ve engelleri")
            let topics = try XCTUnwrap(state.notes?.topics)
            XCTAssertEqual(topics.count, 1)
            XCTAssertEqual(topics[0].id, "manual-summary-preserved")
            XCTAssertEqual(topics[0].text, draft.summary)
            XCTAssertTrue(topics[0].evidence.isEmpty)
            XCTAssertNil(topics[0].sectionID)
            XCTAssertEqual(state.notesTemplateRawValue, MeetingTemplate.team.rawValue)
            XCTAssertEqual(state.notesManualEdits?.summaryTemplateRawValue, MeetingTemplate.general.rawValue)
        }
        state.templateRawValue = MeetingTemplate.general.rawValue
        state = NotesRevisionPolicy.reconcileGenerated(notes("Genel model özeti"), into: state)
        XCTAssertEqual(state.notes?.summary, draft.summary)
        XCTAssertEqual(state.notes?.topics, [])
    }

    func testEditingNewTemplateSummaryAlsoKeepsEarlierPreservedCorrection() throws {
        var draft = try XCTUnwrap(sampleMeeting().notes)
        draft.summary = "Genel özetteki eski düzeltmem"
        var state = NotesRevisionPolicy.applyEdits(to: sampleMeeting(), editedNotes: draft)
        state.templateRawValue = MeetingTemplate.team.rawValue
        state = NotesRevisionPolicy.reconcileGenerated(notes("Ekip için yeni model özeti"), into: state)
        var teamDraft = try XCTUnwrap(state.notes)
        teamDraft.summary = "Ekip özetindeki yeni düzeltmem"
        state = NotesRevisionPolicy.applyEdits(to: state, editedNotes: teamDraft)
        for _ in 0..<3 {
            state = NotesRevisionPolicy.reconcileGenerated(notes("Sonraki ekip model özeti"), into: state)
            XCTAssertEqual(state.notes?.summary, teamDraft.summary)
            XCTAssertEqual(state.notes?.topics.map(\.text), [draft.summary])
            XCTAssertEqual(state.notesManualEdits?.summaryTemplateRawValue, MeetingTemplate.team.rawValue)
        }
    }

    func testMatchedEditedTopicKeepsFreshCategoryAndUnmatchedCorrectionRemainsUntagged() throws {
        let oldMatched = TopicNote(id: "old-matched", title: "Eski başlık", text: "Kaynakta anlatılan ilk konu",
            evidence: ["s1"], sectionID: "old-general-category")
        let oldRetained = TopicNote(id: "old-retained", title: "Diğer başlık", text: "Kaynakta anlatılan ikinci konu",
            evidence: ["s1"], sectionID: "old-general-category")
        var meeting = sampleMeeting()
        meeting.notes = notes("Genel özet", topics: [oldMatched, oldRetained])
        var draft = try XCTUnwrap(meeting.notes)
        draft.topics[0].text = "Birinci konu için düzelttiğim ifade"
        draft.topics[1].text = "İkinci konu için düzelttiğim ifade"
        var state = NotesRevisionPolicy.applyEdits(to: meeting, editedNotes: draft)
        state.templateRawValue = MeetingTemplate.team.rawValue
        let freshTopic = TopicNote(id: "fresh", title: "İlerleme", text: oldMatched.text,
            evidence: ["s1"], sectionID: "progress")
        state = NotesRevisionPolicy.reconcileGenerated(notes("Ekip özeti", topics: [freshTopic]), into: state)
        let result = try XCTUnwrap(state.notes?.topics)
        XCTAssertEqual(result.count, 2)
        XCTAssertEqual(result[0].text, draft.topics[0].text)
        XCTAssertEqual(result[0].sectionID, freshTopic.sectionID)
        XCTAssertEqual(result[1].text, draft.topics[1].text)
        XCTAssertNil(result[1].sectionID)
        state = NotesRevisionPolicy.reconcileGenerated(notes("Ekip özeti", topics: [freshTopic]), into: state)
        XCTAssertEqual(state.notes?.topics.last?.sectionID, nil)
        XCTAssertEqual(state.notes?.topics.count, 2)
    }

    func testEditingCannotChangeGeneratedTopicCategoryOrInventCategoryForManualAddition() throws {
        var meeting = sampleMeeting()
        meeting.notes = notes("Özet", topics: [TopicNote(id: "existing", title: "Konu", text: "Kaynak bağlamı",
            evidence: ["s1"], sectionID: "progress")])
        var draft = try XCTUnwrap(meeting.notes)
        draft.topics[0].text = "Düzeltilen bağlam"
        draft.topics[0].sectionID = "invented"
        draft.topics[0].evidence = ["invented"]
        draft.topics.append(TopicNote(id: "manual", title: "Benim konum", text: "Elle eklenen bağlam",
            evidence: ["invented"], sectionID: "invented"))
        let result = NotesRevisionPolicy.applyEdits(to: meeting, editedNotes: draft)
        XCTAssertEqual(result.notes?.topics[0].sectionID, "progress")
        XCTAssertEqual(result.notes?.topics[0].evidence, ["s1"])
        XCTAssertNil(result.notes?.topics[1].sectionID)
        XCTAssertEqual(result.notes?.topics[1].evidence, [])
    }

    func testDeletingPreservedSummaryTopicRemainsDeletedOnRefresh() throws {
        var draft = try XCTUnwrap(sampleMeeting().notes)
        draft.summary = "Eski düzeltmem"
        var state = NotesRevisionPolicy.applyEdits(to: sampleMeeting(), editedNotes: draft)
        state.templateRawValue = MeetingTemplate.team.rawValue
        state = NotesRevisionPolicy.reconcileGenerated(notes("Ekip özeti"), into: state)
        var withoutPreserved = try XCTUnwrap(state.notes)
        withoutPreserved.topics = []
        state = NotesRevisionPolicy.applyEdits(to: state, editedNotes: withoutPreserved)
        for _ in 0..<3 {
            state = NotesRevisionPolicy.reconcileGenerated(notes("Ekip özeti"), into: state)
            XCTAssertEqual(state.notes?.summary, "Ekip özeti")
            XCTAssertEqual(state.notes?.topics, [])
        }
    }

    func testLegacyTopicDecodesWithoutCategory() throws {
        let json = #"{"id":"old","title":"Konu","text":"Eski bağlam","evidence":["s1"]}"#
        let topic = try JSONDecoder().decode(TopicNote.self, from: Data(json.utf8))
        XCTAssertNil(topic.sectionID)
    }

    private func sampleMeeting() -> Meeting {
        Meeting(title: "Sentetik toplantı", segments: [TranscriptSegment(id: "s1", speaker: "A", start: 0, end: 10,
            text: "Kaynak bağlamı")], notes: notes("Genel kaynak özeti"))
    }

    private func notes(_ summary: String, topics: [TopicNote] = []) -> MeetingNotes {
        MeetingNotes(summary: summary, decisions: [], actions: [], questions: [], ideas: [], topics: topics)
    }
}
