import XCTest
import FoundationModels
@testable import MeetingDesk

final class LocalActionSourceSelectionTests: XCTestCase {
    func testSelectionRestoresOriginalUnicodeAndWhitespaceWithoutModelCopying() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires macOS 26") }
        let text = "  O\u{0308}zgün görev yapılacak; henüz tamamlanmadı.\r\n"
        let scope = try LocalSummaryService.evidenceScope(sources: [source("original", text)])
        let input = try LocalSummaryService.selectedActionInventoryInput(evidenceScope: scope)
        let units = try XCTUnwrap(input.sources.first).units
        let result = try LocalSummaryService.convertSelectedActionCandidates(
            generated(["s1": [row(units.first!.id, units.last!.id)]]),
            part: 2, evidenceScope: scope, input: input)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(Data(result[0].text.utf8), Data(text.utf8))
        XCTAssertEqual(result[0].evidence, ["original"])
        XCTAssertEqual(result[0].id, "local-2-action-1")
        let payload = String(decoding: try LocalSummaryService.modelInputData(input), as: UTF8.self)
        XCTAssertFalse(payload.contains("scopeSnapshot"))
        XCTAssertFalse(payload.contains("\"start\""))
    }

    func testInvalidSelectionsRejectTheEntireResponse() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires macOS 26") }
        let scope = try LocalSummaryService.evidenceScope(sources: [source("one", "Rapor hazırlanacak."), source("two", "Başka iş.")])
        let input = try LocalSummaryService.selectedActionInventoryInput(evidenceScope: scope)
        let first = input.sources[0].units.first!.id, last = input.sources[0].units.last!.id
        let cases: [[String: Any]] = [
            ["s1": [row("unknown", last)], "s2": []],
            ["s1": [row(input.sources[1].units[0].id, last)], "s2": []],
            ["s1": [row(last, first)], "s2": []],
            ["s1": [row(first, last, evidence: ["s2"])], "s2": []],
            ["s1": [row(first, last, evidence: ["s1", "unknown"])], "s2": []],
            ["s1": []], ["s1": [], "s2": [], "extra": []],
            ["s1": [["firstUnitID": first, "lastUnitID": last, "evidence": ["s1"], "text": "invented"]], "s2": []],
            ["s1": Array(repeating: row(first, last), count: 13), "s2": []]
        ]
        for payload in cases {
            XCTAssertThrowsError(try LocalSummaryService.convertSelectedActionCandidates(
                generated(payload), part: 1, evidenceScope: scope, input: input))
        }
    }

    func testSelectionInputCannotBeReusedForDifferentSourceBytes() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires macOS 26") }
        let original = try LocalSummaryService.evidenceScope(sources: [source("one", "O\u{0308}deme yapılacak.")])
        let changed = try LocalSummaryService.evidenceScope(sources: [source("one", "Ödeme yapılacak.")])
        let input = try LocalSummaryService.selectedActionInventoryInput(evidenceScope: original)
        XCTAssertThrowsError(try LocalSummaryService.convertSelectedActionCandidates(
            generated(["s1": [row(input.sources[0].units.first!.id, input.sources[0].units.last!.id)]]),
            part: 1, evidenceScope: changed, input: input))
    }

    func testLongSourceSplittingKeepsAllBytesAndEvidenceMetadata() throws {
        let text = String(repeating: "Sözcük, 👩🏽‍💻 veri.\n", count: 120)
        var meeting = Meeting(title: "Synthetic")
        meeting.segments = [.init(id: "original", speaker: "A", start: 3, end: 7, text: text)]
        let fragments = try LocalSummaryService.sourceChunks(meeting: meeting, maximumBytes: 1_024,
            inventoryWordSafeSplits: true).flatMap { $0 }
        XCTAssertEqual(Data(fragments.map(\.text).joined().utf8), Data(text.utf8))
        XCTAssertTrue(fragments.allSatisfy { $0.id == "original" && $0.start == 3 && $0.end == 7 })
    }

    private func source(_ id: String, _ text: String) -> LocalSummaryService.Source {
        .init(id: id, speaker: "A", start: 3, end: 7, text: text)
    }
    private func row(_ first: String, _ last: String, evidence: [String] = ["s1"]) -> [String: Any] {
        ["firstUnitID": first, "lastUnitID": last, "evidence": evidence]
    }
    @available(macOS 26.0, *)
    private func generated(_ object: [String: Any]) throws -> GeneratedContent {
        try GeneratedContent(json: String(decoding: JSONSerialization.data(withJSONObject: object), as: UTF8.self))
    }
}
