import XCTest
@testable import MeetingDesk

final class ArchiveQuestionSchemaTests: XCTestCase {
    func testResponseSchemaRestrictsEvidenceToExactRetrievedAliases() async throws {
        var meeting = Meeting(title: "Synthetic schema")
        meeting.segments = [
            .init(id: "first", speaker: "a", start: 0, end: 4, text: "Ödeme entegrasyonu kontrol edilecek."),
            .init(id: "second", speaker: "a", start: 5, end: 9, text: "Ödeme kararı ekipçe onaylandı."),
            .init(id: "unrelated", speaker: "a", start: 10, end: 14, text: "Öğle molasına çıkıldı.")
        ]
        let index = ArchiveQuestionIndex()
        try await index.replace(meetings: [meeting])
        let context = try await index.retrieve(question: "ödeme")
        XCTAssertEqual(context.sources.count, 2)
        let body = try ArchiveQuestionPrompt.requestBody(context: context)
        let format = try XCTUnwrap(body["format"] as? [String: Any])
        let properties = try XCTUnwrap(format["properties"] as? [String: Any])
        let facts = try XCTUnwrap(properties["facts"] as? [String: Any])
        let item = try XCTUnwrap(facts["items"] as? [String: Any])
        let factFields = try XCTUnwrap(item["properties"] as? [String: Any])
        let source = try XCTUnwrap(factFields["source"] as? [String: Any])
        XCTAssertEqual(source["type"] as? String, "string")
        XCTAssertEqual(source["enum"] as? [String], context.sources.map(\.id))
        XCTAssertFalse((source["enum"] as? [String] ?? []).contains(ArchiveQuestionSource.alias(meetingID: meeting.id, segmentID: "unrelated")))
    }
}
