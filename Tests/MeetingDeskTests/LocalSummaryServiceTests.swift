import XCTest
@testable import MeetingDesk

final class LocalSummaryServiceTests: XCTestCase {
    func testLongUnicodeTranscriptIsEntirelyCoveredInOrder() throws {
        let first = String(repeating: "Ödeme tarihi netleşmedi. İstanbul 👩🏽‍💻\n", count: 320)
        let second = String(repeating: "Consider Stripe later, no agreed owner.\n", count: 120)
        let meeting = Meeting(title: "Uzun toplantı", segments: [
            TranscriptSegment(id: "s1", speaker: "A", start: 0, end: 60, text: first),
            TranscriptSegment(id: "s2", speaker: "B", start: 60, end: 120, text: second)
        ])
        let chunks = try LocalSummaryService.sourceChunks(meeting: meeting)
        XCTAssertGreaterThan(chunks.count, 1)
        XCTAssertTrue(try chunks.allSatisfy { try JSONEncoder().encode($0).count <= 4_800 })
        let flattened = chunks.flatMap { $0 }
        XCTAssertEqual(flattened.filter { $0.id == "s1" }.map(\.text).joined(), first)
        XCTAssertEqual(flattened.filter { $0.id == "s2" }.map(\.text).joined(), second)
        XCTAssertEqual(flattened.first?.id, "s1")
        XCTAssertEqual(flattened.last?.id, "s2")
        XCTAssertTrue(flattened.filter { $0.id == "s1" }.allSatisfy { $0.start == 0 && $0.end == 60 })
    }

    func testRejectsDuplicateSourceIDsAndInvalidTimes() {
        var meeting = sampleMeeting()
        meeting.segments.append(meeting.segments[0])
        XCTAssertThrowsError(try LocalSummaryService.sourceChunks(meeting: meeting))
        meeting = sampleMeeting()
        meeting.segments[0].end = .infinity
        XCTAssertThrowsError(try LocalSummaryService.sourceChunks(meeting: meeting))
    }

    func testEscapedJSONDoesNotExceedChunkBudget() throws {
        var meeting = sampleMeeting()
        meeting.segments[0].text = String(repeating: "\\\"\n\t🙂", count: 3_000)
        let chunks = try LocalSummaryService.sourceChunks(meeting: meeting, maximumBytes: 1_800)
        XCTAssertTrue(try chunks.allSatisfy { try JSONEncoder().encode($0).count <= 1_800 })
        XCTAssertEqual(chunks.flatMap { $0 }.map(\.text).joined(), meeting.segments[0].text)
    }

    func testEvidenceMustBelongToCurrentChunk() throws {
        var meeting = sampleMeeting()
        meeting.segments.append(TranscriptSegment(id: "s2", speaker: "B", start: 5, end: 8, text: "No deadline was agreed."))
        let notes = MeetingNotes(summary: "A date was discussed.", decisions: [], actions: [],
                                 questions: [EvidenceItem(id: "q1", text: "Deadline remains open.", evidence: ["s2"])], ideas: [], topics: [])
        XCTAssertThrowsError(try LocalSummaryService.validate(notes: notes, meeting: meeting, allowedEvidence: ["s1"]))
        XCTAssertNoThrow(try LocalSummaryService.validate(notes: notes, meeting: meeting, allowedEvidence: ["s2"]))
    }

    func testGroundedActionOwnerAndExactDuePhrase() throws {
        let meeting = sampleMeeting()
        var notes = blankNotes()
        notes.actions = [ActionItem(id: "a1", text: "Revise the design.", owner: "Ali", due: "next Friday", evidence: ["s1"])]
        XCTAssertNoThrow(try LocalSummaryService.validate(notes: notes, meeting: meeting))
        notes.actions[0].due = "2026-10-16"
        XCTAssertThrowsError(try LocalSummaryService.validate(notes: notes, meeting: meeting))
        notes.actions[0].owner = "Al"
        XCTAssertThrowsError(try LocalSummaryService.validate(notes: notes, meeting: meeting))
        notes.actions[0].owner = "Ali"
        notes.actions[0].due = "next Friday"
        XCTAssertThrowsError(try LocalSummaryService.validate(notes: notes, meeting: meeting,
                                                             allowedEvidence: ["s1"], scopedText: ["s1": "The design needs revision."]))
        notes.actions[0].due = nil
        notes.actions[0].owner = "Ayşe"
        XCTAssertThrowsError(try LocalSummaryService.validate(notes: notes, meeting: meeting))
    }

    func testKnownSpeakerMayOwnActionButAnonymousLabelMayNot() {
        var meeting = sampleMeeting()
        meeting.segments[0].text = "I will revise the design."
        var notes = blankNotes()
        notes.actions = [ActionItem(id: "a1", text: "Revise the design.", owner: "A", due: nil, evidence: ["s1"])]
        XCTAssertThrowsError(try LocalSummaryService.validate(notes: notes, meeting: meeting))
        meeting.speakerNames = ["A": "Ali"]
        notes.actions[0].owner = "Ali"
        XCTAssertNoThrow(try LocalSummaryService.validate(notes: notes, meeting: meeting))
    }

    func testCompleteChunkNotesAreRetainedWithScopeAndTimeRanges() throws {
        let meeting = sampleMeeting()
        let sources = try LocalSummaryService.sourceChunks(meeting: meeting)
        var first = blankNotes()
        first.summary = "First section summary."
        first.decisions = [EvidenceItem(id: "local-1-1", text: "An outcome was accepted in this section.", evidence: ["s1"])]
        var second = blankNotes()
        second.summary = "Second section changes an earlier outcome."
        second.questions = [EvidenceItem(id: "local-2-1", text: "What will the final outcome be?", evidence: ["s1"])]
        let notes = LocalSummaryService.combine([first, second], sources: [sources[0], sources[0]], english: false)
        XCTAssertTrue(notes.summary.contains(first.summary))
        XCTAssertTrue(notes.summary.contains(second.summary))
        XCTAssertTrue(notes.summary.contains("otomatik uzlaştırmaz"))
        XCTAssertTrue(notes.decisions[0].text.contains("Bölüm 1 (00:00–00:05)"))
        XCTAssertTrue(notes.questions[0].text.contains("Bölüm 2"))
        XCTAssertNoThrow(try LocalSummaryService.validate(notes: notes, meeting: meeting))
    }

    func testNoMissingEvidenceOrDuplicateItemIDsAreAccepted() {
        let meeting = sampleMeeting()
        var notes = blankNotes()
        notes.ideas = [EvidenceItem(id: "i1", text: "Explore a provider.", evidence: [])]
        XCTAssertThrowsError(try LocalSummaryService.validate(notes: notes, meeting: meeting))
        notes.ideas[0].evidence = ["s1"]
        notes.questions = [EvidenceItem(id: "i1", text: "Which provider?", evidence: ["s1"])]
        XCTAssertThrowsError(try LocalSummaryService.validate(notes: notes, meeting: meeting))
    }

    func testNewTemplateTopicsRequireAValidSectionWithoutChangingLegacyValidation() throws {
        for template in MeetingTemplate.allCases where template != .general {
            var meeting = sampleMeeting()
            meeting.templateRawValue = template.rawValue
            var notes = blankNotes()
            notes.topics = [TopicNote(id: "t1", title: "Context", text: "Design revision was discussed.", evidence: ["s1"])]
            XCTAssertNoThrow(try LocalSummaryService.validate(notes: notes, meeting: meeting), "Older notes remain readable")
            XCTAssertThrowsError(try LocalSummaryService.validate(notes: notes, meeting: meeting, requireTemplateSections: true))
            notes.topics[0].sectionID = try XCTUnwrap(template.contextSections.first?.id)
            XCTAssertNoThrow(try LocalSummaryService.validate(notes: notes, meeting: meeting, requireTemplateSections: true))
            notes.topics[0].sectionID = "invented-section"
            XCTAssertThrowsError(try LocalSummaryService.validate(notes: notes, meeting: meeting, requireTemplateSections: true))
        }
    }

    func testGeneralLegacyTopicAndEmptyTemplateCategoriesRemainValid() throws {
        var meeting = sampleMeeting()
        var notes = blankNotes()
        notes.topics = [TopicNote(id: "t1", title: "Context", text: "Design revision was discussed.", evidence: ["s1"])]
        XCTAssertNoThrow(try LocalSummaryService.validate(notes: notes, meeting: meeting, requireTemplateSections: true))
        notes.topics[0].sectionID = "discussion"
        XCTAssertNoThrow(try LocalSummaryService.validate(notes: notes, meeting: meeting, requireTemplateSections: true))
        notes.topics[0].sectionID = "progress"
        XCTAssertThrowsError(try LocalSummaryService.validate(notes: notes, meeting: meeting, requireTemplateSections: true))
        meeting.templateRawValue = MeetingTemplate.customer.rawValue
        notes.topics = []
        XCTAssertNoThrow(try LocalSummaryService.validate(notes: notes, meeting: meeting, requireTemplateSections: true),
                         "Templates must not fabricate context just to fill a category")
    }

    func testLongMeetingCombinationRetainsTemplateSectionsAndEvidence() throws {
        var meeting = sampleMeeting()
        meeting.templateRawValue = MeetingTemplate.team.rawValue
        let sources = try LocalSummaryService.sourceChunks(meeting: meeting)
        var first = blankNotes()
        first.topics = [TopicNote(id: "local-1-1", title: "Progress", text: "The design revision was discussed.", evidence: ["s1"], sectionID: "progress")]
        var second = blankNotes()
        second.topics = [TopicNote(id: "local-2-1", title: "Blocker", text: "The design needs further discussion.", evidence: ["s1"], sectionID: "blockers")]
        let notes = LocalSummaryService.combine([first, second], sources: [sources[0], sources[0]], english: true)
        XCTAssertEqual(notes.topics.map(\.sectionID), ["progress", "blockers"])
        XCTAssertEqual(notes.topics.map(\.evidence), [["s1"], ["s1"]])
        XCTAssertTrue(notes.topics[0].title.contains("Section 1"))
        XCTAssertTrue(notes.topics[1].title.contains("Section 2"))
        XCTAssertTrue(notes.actions.isEmpty)
        XCTAssertTrue(notes.decisions.isEmpty)
        XCTAssertNoThrow(try LocalSummaryService.validate(notes: notes, meeting: meeting, requireTemplateSections: true))
    }

    private func sampleMeeting() -> Meeting {
        Meeting(title: "Synthetic", segments: [TranscriptSegment(id: "s1", speaker: "A", start: 0, end: 5,
            text: "Ali will revise the design by next Friday.")])
    }

    private func blankNotes() -> MeetingNotes {
        MeetingNotes(summary: "Design revision discussed.", decisions: [], actions: [], questions: [], ideas: [], topics: [])
    }
}
