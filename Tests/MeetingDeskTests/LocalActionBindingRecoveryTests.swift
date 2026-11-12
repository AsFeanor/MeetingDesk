import FoundationModels
import XCTest
@testable import MeetingDesk

private actor ActionBindingRetryCounter {
    private var count = 0
    func increment() { count += 1 }
    func value() -> Int { count }
}

final class LocalActionBindingRecoveryTests: XCTestCase {
    func testMissingOwningCitationIsRepairedOnlyWithLiteralProofAndPreservesOtherCitations() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires macOS 26") }
        let scope = try sourceScope(["Rapor hazırlanacak.", "Onur üstlendi.", "Yarın paylaşılacak."])
        let initial = try generated(wire(scope, clause: "Rapor hazırlanacak.", evidence: ["s3", "s2", "s2"]))
        let calls = ActionBindingRetryCounter()
        let result = try await LocalSummaryService.convertActionCandidatesWithSourceBindingRetry(initial, part: 3, evidenceScope: scope) {
            await calls.increment(); throw CancellationError()
        }
        XCTAssertEqual(result.map(\.text), ["Rapor hazırlanacak."])
        XCTAssertEqual(result[0].evidence, ["archive-1", "archive-2", "archive-3"])
        XCTAssertEqual(result[0].id, "local-3-action-1")
        let count = await calls.value(); XCTAssertEqual(count, 0)
        XCTAssertThrowsError(try LocalSummaryService.convertActionCandidates(initial, part: 3, evidenceScope: scope, allowParaphrasedTasks: true),
                            "Default conversion keeps the original owning-citation requirement")
    }

    func testRepairUsesExistingCaseAndSameSourceFragmentRules() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires macOS 26") }
        let exact = "Ödeme kaydı açılacak."
        let fragments = [source("archive-1", "Ödeme kaydı "), source("archive-1", "açılacak."), source("archive-2", "Onaylandı.")]
        let scope = try LocalSummaryService.evidenceScope(sources: fragments)
        let result = try LocalSummaryService.convertActionCandidates(generated(wire(scope, clause: "ödeme kaydı açılacak.", evidence: ["s2"])),
            part: 1, evidenceScope: scope, allowParaphrasedTasks: true, resolveSourceBindings: true)
        XCTAssertEqual(result[0].text, exact)
        XCTAssertEqual(result[0].evidence, ["archive-1", "archive-2"])
    }

    func testOtherSourceLiteralAndCrossAliasConcatenationCannotProveMissingOwner() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires macOS 26") }
        for texts in [["Başka konu.", "Rapor hazırlanacak."], ["Rapor ", "hazırlanacak."]] {
            let scope = try sourceScope(texts)
            XCTAssertThrowsError(try LocalSummaryService.convertActionCandidates(generated(wire(scope, clause: "Rapor hazırlanacak.", evidence: ["s2"])),
                part: 1, evidenceScope: scope, allowParaphrasedTasks: true, resolveSourceBindings: true)) { error in
                XCTAssertEqual(error as? LocalSummaryService.ActionSourceBindingError, .unresolved)
            }
        }
    }

    func testBlankTaskGetsOneCompleteFreshInventoryInsteadOfPartialMerge() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires macOS 26") }
        let scope = try sourceScope(["Rapor hazırlanacak.", "Eski görev iptal. Yeni kayıt açılacak."])
        var initial = wire(scope, clause: " \n", evidence: ["s1"])
        initial["s2"] = [["taskClause": "Eski görev iptal.", "evidence": ["s2"]]]
        var replacement = wire(scope, clause: "Rapor hazırlanacak.", evidence: ["s1"])
        replacement["s2"] = [["taskClause": "Yeni kayıt açılacak.", "evidence": ["s2"]]]
        let fresh = try generated(replacement), calls = ActionBindingRetryCounter()
        let result = try await LocalSummaryService.convertActionCandidatesWithSourceBindingRetry(generated(initial), part: 2, evidenceScope: scope) {
            await calls.increment(); return fresh
        }
        XCTAssertEqual(result.map(\.text), ["Rapor hazırlanacak.", "Yeni kayıt açılacak."])
        XCTAssertEqual(result.map(\.id), ["local-2-action-1", "local-2-action-2"])
        let count = await calls.value(); XCTAssertEqual(count, 1)
    }

    func testParaphrasedTaskMissingOwnerIsNotAutoBoundButFreshExplicitBindingCanPass() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires macOS 26") }
        let scope = try sourceScope(["Rapor hazırlanacak.", "Bu işi Onur üstlendi."])
        let text = "Toplantı raporunun hazırlanması."
        let fresh = try generated(wire(scope, clause: text, evidence: ["s1", "s2"]))
        let calls = ActionBindingRetryCounter()
        let result = try await LocalSummaryService.convertActionCandidatesWithSourceBindingRetry(
            generated(wire(scope, clause: text, evidence: ["s2"])), part: 1, evidenceScope: scope) {
                await calls.increment(); return fresh
            }
        XCTAssertEqual(result[0].text, text)
        XCTAssertEqual(result[0].evidence, ["archive-1", "archive-2"])
        let count = await calls.value(); XCTAssertEqual(count, 1)
    }

    func testSecondBindingFailureUsesExistingLocalizedMessageAndNeverLoops() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires macOS 26") }
        let scope = try sourceScope(["Rapor hazırlanacak.", "Onaylandı."])
        let invalid = try generated(wire(scope, clause: "", evidence: ["s1"]))
        let calls = ActionBindingRetryCounter()
        do {
            _ = try await LocalSummaryService.convertActionCandidatesWithSourceBindingRetry(invalid, part: 1, evidenceScope: scope) {
                await calls.increment(); return invalid
            }
            XCTFail("A second invalid response cannot become empty or partial actions")
        } catch {
            XCTAssertTrue(error is MeetingError)
            XCTAssertEqual(error.localizedDescription, LocalSummaryService.ActionSourceBindingError.unresolved.localizedDescription)
        }
        let count = await calls.value(); XCTAssertEqual(count, 1)
    }

    func testFreshResponseStillRejectsUnknownAliasesWithoutAnotherRetry() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires macOS 26") }
        let scope = try sourceScope(["Rapor hazırlanacak.", "Onaylandı."])
        let fresh = try generated(wire(scope, clause: "Rapor hazırlanacak.", evidence: ["foreign"]))
        let calls = ActionBindingRetryCounter()
        do {
            _ = try await LocalSummaryService.convertActionCandidatesWithSourceBindingRetry(
                generated(wire(scope, clause: "", evidence: ["s1"])), part: 1, evidenceScope: scope) {
                    await calls.increment(); return fresh
                }
            XCTFail("The replacement must pass the same scope checks")
        } catch { XCTAssertTrue(error is MeetingError) }
        let count = await calls.value(); XCTAssertEqual(count, 1)
    }

    func testWholeWireInvalidityWinsOverEarlierBlankTaskAndNeverRetries() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires macOS 26") }
        let scope = try sourceScope(["Rapor hazırlanacak.", "Kayıt açılacak.", "Kaynak üç.", "Kaynak dört.", "Kaynak beş."])
        var invalid: [[String: Any]] = []
        var unknown = wire(scope, clause: "", evidence: ["s1"])
        unknown["s2"] = [["taskClause": "Kayıt açılacak.", "evidence": ["s2", "foreign"]]]
        invalid.append(unknown)
        var extraField = wire(scope, clause: "", evidence: ["s1"])
        extraField["s2"] = [["taskClause": "Kayıt açılacak.", "evidence": ["s2"], "owner": "not allowed"]]
        invalid.append(extraField)
        invalid.append(wire(scope, clause: "", evidence: ["s1", "s2", "s3", "s4", "s5"]))
        var tooMany = wire(scope, clause: "", evidence: ["s1"])
        tooMany["s1"] = [["taskClause": "", "evidence": ["s1"]]] + Array(repeating: ["taskClause": "Rapor hazırlanacak.", "evidence": ["s1"]] as [String: Any], count: 6)
        tooMany["s2"] = Array(repeating: ["taskClause": "Kayıt açılacak.", "evidence": ["s2"]] as [String: Any], count: 6)
        invalid.append(tooMany)
        for payload in invalid {
            let calls = ActionBindingRetryCounter()
            do {
                _ = try await LocalSummaryService.convertActionCandidatesWithSourceBindingRetry(generated(payload), part: 1, evidenceScope: scope) {
                    await calls.increment(); throw CancellationError()
                }
                XCTFail("Malformed source data is not a retryable binding problem")
            } catch { XCTAssertTrue(error is MeetingError) }
            let count = await calls.value(); XCTAssertEqual(count, 0)
        }
    }

    func testBlankCitedSourceIsRejectedBeforeAnyBindingRecovery() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires macOS 26") }
        let scope = try sourceScope(["Rapor hazırlanacak.", " \t\n"])
        let calls = ActionBindingRetryCounter()
        do {
            _ = try await LocalSummaryService.convertActionCandidatesWithSourceBindingRetry(
                generated(wire(scope, clause: "", evidence: ["s2"])), part: 1, evidenceScope: scope) {
                    await calls.increment(); throw CancellationError()
                }
            XCTFail("Blank cited sources must not be repaired or retried")
        } catch { XCTAssertTrue(error is MeetingError) }
        let count = await calls.value(); XCTAssertEqual(count, 0)
    }

    func testUniqueEvidenceUnionNeverDropsCitationsToMeetFourSourceCap() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires macOS 26") }
        let scope = try sourceScope(["Rapor hazırlanacak.", "İkinci destek.", "Üçüncü destek.", "Dördüncü destek.", "Beşinci destek."])
        let valid = try LocalSummaryService.convertActionCandidates(generated(wire(scope, clause: "Rapor hazırlanacak.", evidence: ["s2", "s2", "s3", "s4"])),
            part: 1, evidenceScope: scope, allowParaphrasedTasks: true, resolveSourceBindings: true)
        XCTAssertEqual(valid[0].evidence, ["archive-1", "archive-2", "archive-3", "archive-4"])
        XCTAssertThrowsError(try LocalSummaryService.convertActionCandidates(generated(wire(scope, clause: "Rapor hazırlanacak.", evidence: ["s2", "s3", "s4", "s5"])),
            part: 1, evidenceScope: scope, allowParaphrasedTasks: true, resolveSourceBindings: true)) { error in
                XCTAssertEqual(error as? LocalSummaryService.ActionSourceBindingError, .unresolved)
            }
    }

    func testUnrelatedStrictQuotationFailureNeverCallsRetry() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires macOS 26") }
        let scope = try sourceScope(["Rapor hazırlanacak."])
        let calls = ActionBindingRetryCounter()
        do {
            _ = try await LocalSummaryService.convertActionCandidatesWithSourceBindingRetry(
                generated(wire(scope, clause: "Başka bir görev.", evidence: ["s1"])), part: 1, evidenceScope: scope, allowParaphrasedTasks: false) {
                    await calls.increment(); throw CancellationError()
                }
            XCTFail("Strict quotation errors are outside binding recovery")
        } catch { XCTAssertTrue(error is MeetingError) }
        let count = await calls.value(); XCTAssertEqual(count, 0)
    }

    func testRetryClosureCancellationPropagatesWithoutForcedActions() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("Requires macOS 26") }
        let scope = try sourceScope(["Rapor hazırlanacak."])
        let calls = ActionBindingRetryCounter()
        do {
            _ = try await LocalSummaryService.convertActionCandidatesWithSourceBindingRetry(
                generated(wire(scope, clause: "", evidence: ["s1"])), part: 1, evidenceScope: scope) {
                    await calls.increment(); throw CancellationError()
                }
            XCTFail("Cancellation must stop action extraction")
        } catch { XCTAssertTrue(error is CancellationError) }
        let count = await calls.value(); XCTAssertEqual(count, 1)
    }

    private func source(_ id: String, _ text: String) -> LocalSummaryService.Source {
        .init(id: id, speaker: "A", start: 0, end: 5, text: text)
    }

    private func sourceScope(_ texts: [String]) throws -> LocalSummaryService.EvidenceScope {
        try LocalSummaryService.evidenceScope(sources: texts.enumerated().map { source("archive-\($0.offset + 1)", $0.element) })
    }

    private func wire(_ scope: LocalSummaryService.EvidenceScope, clause: String, evidence: [String]) -> [String: Any] {
        var result: [String: Any] = Dictionary(uniqueKeysWithValues: scope.evidenceIDs.map { ($0, [] as [[String: Any]]) })
        result["s1"] = [["taskClause": clause, "evidence": evidence]]
        return result
    }

    @available(macOS 26.0, *)
    private func generated(_ value: [String: Any]) throws -> GeneratedContent {
        try GeneratedContent(json: String(decoding: JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self))
    }
}
