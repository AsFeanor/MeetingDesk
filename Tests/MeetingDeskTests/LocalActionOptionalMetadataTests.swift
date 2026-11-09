import XCTest
@testable import MeetingDesk

final class LocalActionOptionalMetadataTests: XCTestCase {
    func testUnsupportedTimeIsAbsentAndKnownTimeStillUsesStrictValidation() throws {
        let source = LocalSummaryService.Source(id: "original", speaker: "A", start: 0, end: 5,
            text: "Ayşe raporu cuma hazırlayacak.")
        let scope = try LocalSummaryService.evidenceScope(sources: [source])
        let candidate = LocalSummaryService.ActionCandidate(id: "task", text: "Raporu hazırlamak.", evidence: ["original"])
        let input = try LocalSummaryService.taskTimeInput(candidate: candidate, evidenceScope: scope)
        XCTAssertNil(try LocalSummaryService.optionalValidatedTaskTimeProposal("yarın", input: input))
        XCTAssertNil(try LocalSummaryService.optionalValidatedTaskTimeProposal(" ", input: input))
        XCTAssertNotNil(try LocalSummaryService.optionalValidatedTaskTimeProposal("cuma", input: input))
        XCTAssertThrowsError(try LocalSummaryService.validatedTaskTimeProposal("yarın", input: input))
    }

    func testUnsupportedOptionalFieldsDoNotDiscardTheAction() throws {
        let meeting = Meeting(title: "Synthetic", segments: [
            .init(id: "source", speaker: "A", start: 0, end: 5, text: "Ayşe raporu cuma hazırlayacak.")
        ])
        let action = ActionItem(id: "task", text: "Raporu hazırlamak.", owner: "Desteksiz kişi", due: "yarın", evidence: ["source"])
        let notes = MeetingNotes(summary: "Rapor hazırlanacak.", decisions: [], actions: [action], questions: [], ideas: [], topics: [])
        let result = try LocalSummaryService.removingUnsupportedActionMetadata(notes, meeting: meeting)
        XCTAssertEqual(result.actions.count, 1)
        XCTAssertEqual(result.actions[0].id, action.id)
        XCTAssertEqual(result.actions[0].text, action.text)
        XCTAssertEqual(result.actions[0].evidence, action.evidence)
        XCTAssertNil(result.actions[0].owner)
        XCTAssertNil(result.actions[0].due)
        XCTAssertNoThrow(try LocalSummaryService.validate(notes: result, meeting: meeting))
        var supported = notes
        supported.actions[0].owner = "Ayşe"
        supported.actions[0].due = "cuma"
        XCTAssertEqual(try LocalSummaryService.removingUnsupportedActionMetadata(supported, meeting: meeting), supported)
    }

    func testInvalidEvidenceStillFailsBeforeOptionalFieldsAreRemoved() throws {
        let meeting = Meeting(title: "Synthetic", segments: [
            .init(id: "source", speaker: "A", start: 0, end: 5, text: "Rapor hazırlanacak.")
        ])
        let notes = MeetingNotes(summary: "Rapor hazırlanacak.", decisions: [], actions: [
            .init(id: "task", text: "Raporu hazırlamak.", owner: "Unknown", due: "Unknown", evidence: ["foreign"])
        ], questions: [], ideas: [], topics: [])
        XCTAssertThrowsError(try LocalSummaryService.removingUnsupportedActionMetadata(notes, meeting: meeting))
    }
}
