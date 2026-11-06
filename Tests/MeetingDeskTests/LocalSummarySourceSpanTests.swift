import XCTest
import FoundationModels
@testable import MeetingDesk

/// A case-only alignment may restore one unique owned source span. It never
/// proves the task was agreed, and never permits rewritten words or metadata.
final class LocalSummarySourceSpanTests: XCTestCase {
    func testUniqueCaseOnlyClauseRestoresOriginalSourceBytesAndEvidence() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        let source = "Context. Prepare THE report by Friday. Closing."
        let result = try convert("prepare the REPORT by FRIDAY.", sources: [entry("source-original", source)], part: 4)
        let candidate = try XCTUnwrap(result.first)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(candidate.id, "local-4-action-1")
        XCTAssertEqual(candidate.evidence, ["source-original"])
        XCTAssertEqual(Array(candidate.text.utf8), Array("Prepare THE report by Friday.".utf8))
    }

    func testCaseRepairMayReturnAnActualSubspanWithoutRequiringAdjacentPunctuation() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        let result = try convert("ödeme yapılacak", sources: [entry("source-original", "Ödeme yapılacak.")])
        XCTAssertEqual(result.map(\.text), ["Ödeme yapılacak"],
                       "The contract permits real substrings; adjacent source punctuation need not be included")
        XCTAssertThrowsError(try convert("ödeme bugün yapılacak.", sources: [entry("source-original", "Ödeme, bugün yapılacak.")]),
                            "Removing punctuation inside the matched clause is still a rewrite")
    }

    func testExactBytesKeepExistingPrecedenceEvenWithRepeatedOrCaseEquivalentOccurrences() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        for source in ["KEEP the form. keep THE form.", "KEEP the form. KEEP the form."] {
            let result = try convert("KEEP the form.", sources: [entry("source-original", source)])
            XCTAssertEqual(result.map(\.text), ["KEEP the form."],
                           "The new repair must not reject an already exact source quote")
        }
    }

    func testTurkishCasePairsAndEmojiOffsetsRestoreTheSourceSpelling() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        let expected = "ÇÖZÜM ŞABLONU düzenlenecek."
        let source = "👩🏽‍💻 Önceki konu. " + expected + " Sonraki konu."
        let result = try convert("çözüm şablonu DÜZENLENECEK.", sources: [entry("unicode-original", source)])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(Array(result[0].text.utf8), Array(expected.utf8),
                       "Use original Unicode bytes and original range, not indexes into a lowercased copy")
        let scope = try LocalSummaryService.evidenceScope(sources: [entry("unicode-original", source)])
        XCTAssertEqual(try LocalSummaryService.canonicalSourceTaskClause("çözüm şablonu DÜZENLENECEK.", owningAlias: "s1", evidenceScope: scope), expected)
    }

    func testNormalizationOnlyDiacriticAndLocaleSpecificMappingsStayRejected() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        let cases = [
            ("GİRİŞ denetlenecek.", "giriş denetlenecek."),
            ("IŞIK denetlenecek.", "ışık denetlenecek."),
            ("Ödeme denetlenecek.", "Odeme denetlenecek."),
            ("O\u{0308}deme denetlenecek.", "Ödeme denetlenecek."),
            ("O\u{0308}deme denetlenecek.", "ödeme denetlenecek.")
        ]
        for (source, generated) in cases {
            XCTAssertThrowsError(try convert(generated, sources: [entry("source-original", source)]),
                                "Only the frozen default direct-case comparator is permitted; no locale, accent or normalization fallback")
        }
    }

    func testCaseMappingPreservesAlreadyDecomposedSourceCharactersWithoutNormalizingThem() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        let original = "O\u{0308}DEME formu açılacak."
        let generated = "o\u{0308}deme FORMU açılacak."
        let result = try convert(generated, sources: [entry("decomposed-original", "👩🏽‍💻 " + original)])
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(Array(result[0].text.utf8), Array(original.utf8))
        XCTAssertNotEqual(Array(result[0].text.utf8), Array("ÖDEME formu açılacak.".utf8))
    }

    func testMultiCharacterCaseFoldExpansionsAreNotAOneToOneCaseRepair() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        for (source, generated) in [("Straße kontrollieren.", "STRASSE KONTROLLIEREN."), ("ﬀ prüfen.", "FF PRÜFEN.")] {
            XCTAssertThrowsError(try convert(generated, sources: [entry("source-original", source)]),
                                "A broader Unicode case fold must not enable character expansion or rewritten source text")
        }
    }

    func testRepeatedCaseEquivalentAndOverlappingRepairSpansAreAmbiguous() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        let cases = [
            ("REVIEW the note. REVIEW the note.", "review THE NOTE."),
            ("REVIEW the note. review THE note.", "Review The Note."),
            ("AAAA", "aaa")
        ]
        for (source, generated) in cases {
            XCTAssertThrowsError(try convert(generated, sources: [entry("source-original", source)]),
                                "Do not select the first occurrence, including when another match overlaps it")
        }
    }

    func testCaseOnlyNegatedTextPreservesNegationAndChangedMeaningStillRejects() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        let result = try convert("we will not release.", sources: [entry("negative-original", "WE WILL NOT RELEASE.")])
        XCTAssertEqual(result.map(\.text), ["WE WILL NOT RELEASE."],
                       "Alignment preserves what the source says; later classification must judge eligibility")
        for (source, generated) in [
            ("We will not release.", "We will release."),
            ("We will prepare the form.", "We might prepare the form."),
            ("We will prepare the form.", "We prepared the form."),
            ("Prepare the report.", "Send the report."),
            ("Prepare the report.", "Prepare  the report."),
            ("Ayşe’nin notu hazırlanacak.", "Ayşe'nin notu hazırlanacak.")
        ] {
            XCTAssertThrowsError(try convert(generated, sources: [entry("source-original", source)]),
                                "No negation, wording, tense, punctuation or whitespace repair is allowed")
        }
    }

    func testOnlyOwningSourceControlsUniquenessAndOtherSourcesCannotSupplyTheClause() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        let owned = [entry("own-original", "Prepare THE report."), entry("other-original", "prepare THE REPORT.")]
        let result = try convert("PREPARE the Report.", sources: owned, evidence: ["s1", "s2"])
        XCTAssertEqual(result.map(\.text), ["Prepare THE report."])
        XCTAssertEqual(result.first?.evidence, ["other-original", "own-original"])
        XCTAssertThrowsError(try convert("PREPARE the Report.", sources: owned, evidence: ["s2"]),
                            "A valid owned case match never repairs missing owning evidence")
        let misplaced = [entry("own-original", "Another task remains open."), entry("other-original", "Prepare THE report.")]
        XCTAssertThrowsError(try convert("PREPARE the Report.", sources: misplaced, evidence: ["s1", "s2"]),
                            "Citing another source does not let it supply the owning clause")
    }

    func testOnlySameAliasCurrentFragmentsMayBridgeACaseRepair() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        let fragments = [entry("same-original", "PREPARE "), entry("unrelated-original", "Do not insert this."), entry("same-original", "the report.")]
        let result = try convert("prepare THE REPORT.", sources: fragments)
        XCTAssertEqual(result.map(\.text), ["PREPARE the report."])
        XCTAssertEqual(result.first?.evidence, ["same-original"])
        XCTAssertThrowsError(try convert("prepare THE REPORT.", sources: [fragments[0]]),
                            "The original ID cannot import unseen text from another chunk")
        let crossAlias = [entry("first-original", "PREPARE "), entry("second-original", "the report.")]
        XCTAssertThrowsError(try convert("prepare THE REPORT.", sources: crossAlias, evidence: ["s1", "s2"]),
                            "No repair may concatenate different aliases")
    }

    func testTaskAlignmentDoesNotNormalizePersonalNameOrTaskTimeWireValues() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        let scope = try LocalSummaryService.evidenceScope(sources: [entry("source-original", "Ali will prepare the report on Friday.")])
        XCTAssertThrowsError(try LocalSummaryService.parsePersonalNameCatalog(try generated(["s1": ["ali"]]), evidenceScope: scope),
                            "Only task-clause alignment changed; names remain exact source quotes")
        let presence = try LocalSummaryService.parseTimePresence(try generated(["sourceObservation": "The source states Friday.", "hasExplicitTaskTime": true]))
        XCTAssertEqual(try LocalSummaryService.taskTimeValue(try generated(["taskTimePhrase": "FRIDAY"]), presence: presence), "FRIDAY",
                       "The isolated time parser preserves returned text; it does not perform source alignment")
    }

    private func entry(_ id: String, _ text: String) -> LocalSummaryService.Source {
        .init(id: id, speaker: "A", start: 0, end: 5, text: text)
    }

    @available(macOS 26.0, *)
    private func convert(_ clause: String, sources: [LocalSummaryService.Source], evidence: [String] = ["s1"], part: Int = 1) throws -> [LocalSummaryService.ActionCandidate] {
        let scope = try LocalSummaryService.evidenceScope(sources: sources)
        var wire: [String: Any] = Dictionary(uniqueKeysWithValues: scope.evidenceIDs.map { ($0, [] as [[String: Any]]) })
        wire["s1"] = [["taskClause": clause, "evidence": evidence]]
        return try LocalSummaryService.convertActionCandidates(try generated(wire), part: part, evidenceScope: scope)
    }

    @available(macOS 26.0, *)
    private func generated(_ object: [String: Any]) throws -> GeneratedContent {
        try GeneratedContent(json: String(decoding: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self))
    }
}
