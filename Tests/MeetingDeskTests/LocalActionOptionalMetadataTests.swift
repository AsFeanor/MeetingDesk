import XCTest
import FoundationModels
@testable import MeetingDesk

final class LocalActionOptionalMetadataTests: XCTestCase {
    func testUnsupportedOptionalNamesAreOmittedWithoutLosingValidNamesOrSourceKeys() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires macOS 26") }
        let scope = try LocalSummaryService.evidenceScope(sources: [
            .init(id: "one", speaker: "A", start: 0, end: 5, text: "Alina raporu hazırlayacak. Ayşe destek verecek."),
            .init(id: "two", speaker: "B", start: 5, end: 10, text: "Deniz işi üstlendi.")
        ])
        let wire = try generated(["s1": ["Alina", "Ali", "Olmayan", "Ayşe", ""], "s2": ["Deniz"]])
        XCTAssertThrowsError(try LocalSummaryService.parsePersonalNameCatalog(wire, evidenceScope: scope))
        let result = try LocalSummaryService.parsePersonalNameCatalog(wire, evidenceScope: scope, discardUnsupportedNames: true)
        XCTAssertEqual(result.namesByAlias, ["s1": ["Alina", "Ayşe"], "s2": ["Deniz"]])
        let candidate = LocalSummaryService.ActionCandidate(id: "task", text: "Raporu hazırlamak.", evidence: ["one"])
        let choices = try LocalSummaryService.personChoiceDomain(candidate: candidate, evidenceScope: scope, catalog: result)
        XCTAssertEqual(choices.choices.map(\.name), ["Alina", "Ayşe"])
    }

    func testOptionalNameCleanupDoesNotHideMalformedOrForeignSourceMaps() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires macOS 26") }
        let scope = try LocalSummaryService.evidenceScope(sources: [
            .init(id: "one", speaker: "A", start: 0, end: 5, text: "Alina raporu hazırlayacak.")
        ])
        let cases: [[String: Any]] = [
            ["foreign": ["Alina"]], ["s1": "Alina"], ["s1": Array(repeating: "Alina", count: 7)]
        ]
        for object in cases {
            XCTAssertThrowsError(try LocalSummaryService.parsePersonalNameCatalog(
                generated(object), evidenceScope: scope, discardUnsupportedNames: true))
        }
        let empty = try LocalSummaryService.parsePersonalNameCatalog(
            generated(["s1": ["Olmayan"]]), evidenceScope: scope, discardUnsupportedNames: true)
        XCTAssertEqual(empty.namesByAlias, ["s1": []])
    }

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

    @available(macOS 26.0, *)
    private func generated(_ object: [String: Any]) throws -> GeneratedContent {
        try GeneratedContent(json: String(decoding: JSONSerialization.data(withJSONObject: object), as: UTF8.self))
    }
}
