import XCTest
import FoundationModels
@testable import MeetingDesk

final class LocalActionSourceRecoveryTests: XCTestCase {
    func testTaskDescriptionDoesNotRequireAnExactSourceQuotation() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires macOS 26") }
        let original = "O\u{0308}deme için kayıt açılacak. Sorumlu henüz belirlenmedi."
        let result = try convert(["Yeni bir ödeme kaydı oluşturulacak."], sources: [source("original", original)])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].text, "Yeni bir ödeme kaydı oluşturulacak.")
        XCTAssertEqual(result[0].evidence, ["original"])
        XCTAssertEqual(result[0].id, "local-1-action-1")
    }

    func testAlreadyValidQuoteAndDefaultStrictBehaviorStayUnchanged() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires macOS 26") }
        let sources = [source("original", "Başlangıç. Rapor hazırlanacak. Bitiş.")]
        XCTAssertEqual(try convert(["Rapor hazırlanacak."], sources: sources).map(\.text), ["Rapor hazırlanacak."])
        let scope = try LocalSummaryService.evidenceScope(sources: sources)
        XCTAssertThrowsError(try LocalSummaryService.convertActionCandidates(
            generated(["s1": [["taskClause": "Özet yazılacak.", "evidence": ["s1"]]]]), part: 1, evidenceScope: scope))
    }

    func testTaskDescriptionsStillRejectAmbiguousForeignAndBlankSources() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires macOS 26") }
        XCTAssertThrowsError(try convert(["review THE report."], sources: [source("one", "REVIEW the report. REVIEW the report.")]))
        XCTAssertThrowsError(try convert(["Başka görev."], sources: [source("one", "Rapor hazırlanacak."), source("two", "Başka görev.")]))
        XCTAssertEqual(try convert(["Raporu hazırlamak.", "Kaydı kontrol etmek."], sources: [source("one", "Rapor hazırlanacak ve kayıt denetlenecek.")]).map(\.text), ["Raporu hazırlamak.", "Kaydı kontrol etmek."])
        XCTAssertThrowsError(try convert(["Görev."], sources: [source("one", " \t\n")]))
    }

    func testRecoveryKeepsSameSourceFragmentsAndRejectsUnknownEvidence() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires macOS 26") }
        let result = try convert(["Özet çıkarılacak."], sources: [source("one", "Rapor "), source("one", "hazırlanacak.")])
        XCTAssertEqual(result.map(\.text), ["Özet çıkarılacak."])
        let scope = try LocalSummaryService.evidenceScope(sources: [source("one", "Rapor hazırlanacak.")])
        XCTAssertThrowsError(try LocalSummaryService.convertActionCandidates(
            generated(["s1": [["taskClause": "Özet çıkarılacak.", "evidence": ["s1", "unknown"]]]]),
            part: 1, evidenceScope: scope, allowParaphrasedTasks: true))
    }

    private func source(_ id: String, _ text: String) -> LocalSummaryService.Source {
        .init(id: id, speaker: "A", start: 0, end: 5, text: text)
    }
    @available(macOS 26.0, *)
    private func convert(_ clauses: [String], sources: [LocalSummaryService.Source]) throws -> [LocalSummaryService.ActionCandidate] {
        let scope = try LocalSummaryService.evidenceScope(sources: sources)
        var payload: [String: Any] = Dictionary(uniqueKeysWithValues: scope.evidenceIDs.map { ($0, [] as [[String: Any]]) })
        payload["s1"] = clauses.map { ["taskClause": $0, "evidence": ["s1"]] as [String: Any] }
        return try LocalSummaryService.convertActionCandidates(generated(payload), part: 1, evidenceScope: scope, allowParaphrasedTasks: true)
    }
    @available(macOS 26.0, *)
    private func generated(_ value: [String: Any]) throws -> GeneratedContent {
        try GeneratedContent(json: String(decoding: JSONSerialization.data(withJSONObject: value), as: UTF8.self))
    }
}
