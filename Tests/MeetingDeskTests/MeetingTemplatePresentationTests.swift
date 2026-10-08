import XCTest
@testable import MeetingDesk

final class MeetingTemplatePresentationTests: XCTestCase {
    func testFourTemplatesHaveTheirOwnSectionOrderAndTheSameOrderInMarkdownAndNotion() {
        let expected: [MeetingTemplate: [String]] = [
            .general: ["summary", "decisions", "actions", "questions", "ideas", "context-discussion", "context-other"],
            .team: ["summary", "context-progress", "context-blockers", "context-other", "actions", "decisions", "questions", "ideas"],
            .product: ["summary", "context-needs", "context-feedback", "context-alternatives", "context-other", "decisions", "ideas", "questions", "actions"],
            .customer: ["summary", "context-needs", "context-concerns", "context-other", "questions", "actions", "decisions", "ideas"]
        ]
        for template in MeetingTemplate.allCases {
            let meeting = fixture(template: template)
            let presentation = MeetingNotesPresentation(meeting: meeting)
            XCTAssertEqual(presentation.sections.map(\.id), expected[template] ?? [], template.rawValue)
            let document = MeetingExport.document(meeting, options: .init(scope: .fullTranscript))
            let expectedHeadings = presentation.sections.map(\.title)
            XCTAssertEqual(document.blocks.filter { $0.kind == .section }.map(\.text), expectedHeadings + ["Transkript"])
            let notion = NotionExportPlan(document: document)
            XCTAssertTrue(notion.hasTranscript)
            XCTAssertEqual(notion.beforeTranscript.filter { $0.type == "heading_2" }.map { $0.text.joined() }, expectedHeadings)
            XCTAssertTrue(notion.transcript.contains { $0.text.joined().contains("TRANSCRIPT-SENTINEL") })
            let topics = presentation.sections.flatMap(\.topics)
            XCTAssertEqual(topics.count, meeting.notes?.topics.count)
            XCTAssertEqual(Set(topics.map(\.id)), Set(meeting.notes?.topics.map(\.id) ?? []))
            XCTAssertTrue(topics.allSatisfy { $0.evidence == ["s1"] })
        }
    }

    func testLegacyNotesKeepGeneralLayoutUntilTheSelectedTemplateIsGenerated() {
        var meeting = fixture(template: .team)
        meeting.notesTemplateRawValue = nil
        meeting.notes?.topics = [TopicNote(id: "old", title: "Eski konu", text: "OLD-TEXT", evidence: ["s1"])]
        let presentation = MeetingNotesPresentation(meeting: meeting)
        XCTAssertEqual(presentation.template, .general)
        XCTAssertNotNil(presentation.templateChangeMessage)
        XCTAssertEqual(presentation.sections.map(\.id), ["summary", "decisions", "actions", "questions", "ideas", "context-other"])
        XCTAssertEqual(presentation.sections.flatMap(\.topics).map(\.sectionID), [nil])
        let markdown = MeetingExport.markdown(meeting)
        XCTAssertTrue(markdown.contains("Not düzeni: Genel toplantı"))
        XCTAssertTrue(markdown.contains("OLD-TEXT"))
        XCTAssertFalse(markdown.contains("## Durum ve ilerleme"))
        XCTAssertFalse(markdown.contains("## Engeller ve bağımlılıklar"))
        XCTAssertTrue(markdown.contains("‘Özeti yenile’yi kullan"))
    }

    func testChangingSelectionDoesNotPretendOldNotesWereRegenerated() {
        var meeting = fixture(template: .product)
        meeting.templateRawValue = MeetingTemplate.customer.rawValue
        let presentation = MeetingNotesPresentation(meeting: meeting)
        XCTAssertEqual(presentation.template, .product)
        XCTAssertNotNil(presentation.templateChangeMessage)
        XCTAssertTrue(presentation.sections.contains { $0.title == "Ürün geri bildirimleri" })
        XCTAssertFalse(presentation.sections.contains { $0.title == "Endişeler ve beklentiler" })
    }

    func testEmptyFocusedSectionsSayThereIsNoRecordedInformationWithoutDiscardingUnknownTopics() {
        for template in [MeetingTemplate.team, .product, .customer] {
            var meeting = fixture(template: template)
            meeting.notes?.topics = [TopicNote(id: "unknown", title: "Elle eklenen", text: "MANUAL-TEXT", evidence: [], sectionID: "old-section")]
            let sections = MeetingNotesPresentation(meeting: meeting).sections.filter { $0.kind == .contexts }
            XCTAssertEqual(sections.last?.id, "context-other")
            XCTAssertEqual(sections.last?.topics.first?.sectionID, "old-section")
            XCTAssertTrue(sections.dropLast().allSatisfy { $0.topics.isEmpty && $0.emptyMessage == "Bu başlık için kayda geçmiş bilgi yok." })
            XCTAssertEqual(sections.flatMap(\.topics).count, 1)
            let markdown = MeetingExport.markdown(meeting)
            XCTAssertTrue(markdown.contains("Bu başlık için kayda geçmiş bilgi yok."))
            XCTAssertTrue(markdown.contains("MANUAL-TEXT"))
            XCTAssertFalse(markdown.contains("Öncelik:"))
        }
    }

    func testEveryTemplateKeepsSharingScopePrivacyCompletedActionsAndEvidence() {
        for template in MeetingTemplate.allCases {
            let meeting = fixture(template: template)
            let summary = MeetingExport.document(meeting, options: .init(scope: .summary))
            XCTAssertTrue(summary.markdown.contains("SUMMARY-SENTINEL"))
            XCTAssertTrue(summary.markdown.contains("DECISION-SENTINEL"))
            XCTAssertFalse(summary.markdown.contains("ACTION-SENTINEL"))
            XCTAssertFalse(summary.markdown.contains("PERSONAL-SENTINEL"))
            XCTAssertFalse(summary.markdown.contains("TRANSCRIPT-SENTINEL"))
            XCTAssertFalse(summary.markdown.contains("](#"))
            let actions = MeetingExport.document(meeting, options: .init(scope: .actions))
            XCTAssertEqual(actions.blocks.filter { $0.kind == .section }.map(\.text), [template.actionsTitle(english: false)])
            XCTAssertTrue(actions.markdown.contains("- [x] ACTION-SENTINEL"))
            XCTAssertTrue(actions.markdown.contains("Sorumlu: Belirtilmedi · Tarih: Belirtilmedi"))
            XCTAssertTrue(actions.markdown.contains("Kaynak: 02:14"))
            XCTAssertFalse(actions.markdown.contains("SUMMARY-SENTINEL"))
            XCTAssertFalse(actions.markdown.contains("TOPIC-SENTINEL"))
            XCTAssertFalse(actions.markdown.contains("PERSONAL-SENTINEL"))
            let sharedPersonal = MeetingExport.document(meeting, options: .init(scope: .actions, includePersonalNotes: true))
            XCTAssertTrue(sharedPersonal.markdown.contains("PERSONAL-SENTINEL"))
        }
    }

    func testEnglishTemplatesUseEnglishFocusedHeadingsAndEmptyMessages() {
        var meeting = fixture(template: .customer)
        meeting.outputLanguage = "English"
        meeting.notes?.topics = []
        let presentation = MeetingNotesPresentation(meeting: meeting)
        XCTAssertEqual(presentation.sections.map(\.title), ["Customer conversation summary", "Customer needs", "Concerns and expectations", "Customer questions awaiting answers", "Explicit commitments and follow-up", "Agreed outcomes", "Ideas under consideration"])
        XCTAssertTrue(presentation.sections.filter { $0.kind == .contexts }.allSatisfy { $0.emptyMessage == "No information was recorded for this section." })
        // The Notion export parser intentionally uses the stable transcript heading.
        XCTAssertTrue(NotionExportPlan(document: MeetingExport.document(meeting, options: .init(scope: .fullTranscript))).hasTranscript)
    }

    private func fixture(template: MeetingTemplate) -> Meeting {
        var meeting = Meeting(title: "Synthetic template fixture")
        meeting.templateRawValue = template.rawValue
        meeting.notesTemplateRawValue = template.rawValue
        meeting.segments = [.init(id: "s1", speaker: "Source", start: 134, end: 160, text: "TRANSCRIPT-SENTINEL")]
        meeting.personalNotes = "PERSONAL-SENTINEL"
        let typed = template.contextSections.map { context in
            TopicNote(id: context.id, title: "Topic \(context.id)", text: "TOPIC-SENTINEL-\(context.id)", evidence: ["s1"], sectionID: context.id)
        }
        let manual = TopicNote(id: "manual", title: "Manual topic", text: "MANUAL-SENTINEL", evidence: ["s1"])
        let unknown = TopicNote(id: "unknown", title: "Unknown section", text: "UNKNOWN-SENTINEL", evidence: ["s1"], sectionID: "unknown-section")
        meeting.notes = .init(summary: "SUMMARY-SENTINEL",
                              decisions: [.init(id: "d1", text: "DECISION-SENTINEL", evidence: ["s1"])],
                              actions: [.init(id: "a1", text: "ACTION-SENTINEL", owner: nil, due: nil, evidence: ["s1"])],
                              questions: [.init(id: "q1", text: "QUESTION-SENTINEL", evidence: ["s1"])],
                              ideas: [.init(id: "i1", text: "IDEA-SENTINEL", evidence: ["s1"])], topics: typed + [manual, unknown])
        meeting.completedActions = ["a1"]
        return meeting
    }
}
