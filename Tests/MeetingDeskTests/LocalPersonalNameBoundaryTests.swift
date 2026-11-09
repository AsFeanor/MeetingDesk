import XCTest
import FoundationModels
@testable import MeetingDesk

private actor NameBoundaryRetryCounter {
    private var count = 0
    func increment() { count += 1 }
    func value() -> Int { count }
}

/// Whole-word provenance is structural grounding, not personal-name recognition
/// or proof that an accepted action exists. No model or real archive is used.
final class LocalPersonalNameBoundaryTests: XCTestCase {
    func testCompleteWordsNamesAndLaterValidOccurrencesRemainAccepted() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        let scope = try scope([source("👩🏽‍💻 Alina spoke to Ali. Ada Lovelace met Jean-Luc and O’Neil. Ali’nin notu hazır.")])
        let names = ["Alina", "Ali", "Ada Lovelace", "Jean-Luc", "O’Neil"]
        let catalog = try parse(["s1": names], scope: scope)
        XCTAssertEqual(catalog.namesByAlias["s1"], names,
                       "A partial early occurrence must not hide a later complete occurrence; apostrophes/hyphens are not autocompletion")
    }

    func testLiteralPrefixesSuffixesDigitsAndPartialGraphemesAreTypedBoundaryFailures() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        for (text, name) in [("Alina", "Ali"), ("Malina", "lina"), ("Ali2", "Ali"), ("XAli", "Ali"),
                             ("Лина", "Ли"), ("A\u{0301}na", "A"), ("A\u{0301}na", "A\u{0301}")] {
            let scope = try scope([source(text)])
            XCTAssertThrowsError(try parse(["s1": [name]], scope: scope)) { error in
                XCTAssertEqual(error as? LocalSummaryService.PersonalNameCatalogValidationError, .wordBoundary)
            }
        }
        let decomposed = "A\u{0301}na"
        XCTAssertEqual(try parse(["s1": [decomposed]], scope: scope([source(decomposed)])).namesByAlias["s1"], [decomposed])
    }

    func testArtificialOuterEdgesRejectOnlyNamesTouchingThoseEdges() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        for fragment in [source("Ali", trailing: false), source("lina", leading: false), source("lin", leading: false, trailing: false)] {
            XCTAssertThrowsError(try parse(["s1": [fragment.text]], scope: scope([fragment]))) { error in
                XCTAssertEqual(error as? LocalSummaryService.PersonalNameCatalogValidationError, .wordBoundary)
            }
        }
        let interior = source("tail Alina head", leading: false, trailing: false)
        XCTAssertEqual(try parse(["s1": ["Alina"]], scope: scope([interior])).namesByAlias["s1"], ["Alina"])
        XCTAssertThrowsError(try parse(["s1": ["Alina"]], scope: scope([source("Ali", trailing: false)]))) { error in
            XCTAssertFalse(error is LocalSummaryService.PersonalNameCatalogValidationError,
                           "Missing letters are nonliteral, not a boundary retry or permission to autocomplete")
        }
    }

    func testNameInputJoinsOnlySameAliasAndUsesOriginalOuterFlagsWithoutContextWireLeakage() throws {
        let sources = [source("pre Al", id: "first", leading: false, trailing: false),
                       source("Unrelated.", id: "second"),
                       source("ina post", id: "first", leading: false, trailing: false)]
        let scope = try scope(sources)
        let input = LocalSummaryService.personalNameCatalogInput(evidenceScope: scope)
        XCTAssertEqual(input.map(\.sourceAlias), ["s1", "s2"])
        XCTAssertEqual(input.map(\.text), ["pre Alina post", "Unrelated."])
        XCTAssertFalse(input[0].leadingWholeWordBoundary)
        XCTAssertFalse(input[0].trailingWholeWordBoundary)
        let nameRows = try XCTUnwrap(JSONSerialization.jsonObject(with: LocalSummaryService.modelInputData(input)) as? [[String: Any]])
        XCTAssertEqual(Set(nameRows[0].keys), ["sourceAlias", "text", "leadingWholeWordBoundary", "trailingWholeWordBoundary"])
        for (original, aliased) in zip(sources, scope.sources) {
            XCTAssertEqual(original.leadingWholeWordBoundary, aliased.leadingWholeWordBoundary)
            XCTAssertEqual(original.trailingWholeWordBoundary, aliased.trailingWholeWordBoundary)
            let encoded = try object(aliased)
            XCTAssertNil(encoded["leadingWholeWordBoundary"])
            XCTAssertNil(encoded["trailingWholeWordBoundary"])
            XCTAssertNil(encoded["speaker"])
            XCTAssertNil(encoded["speakerLabel"])
        }
        let candidate = LocalSummaryService.ActionCandidate(id: "task", text: "A task.", evidence: ["first"])
        let assessment = try object(LocalSummaryService.actionAssessmentInput(candidate: candidate, evidenceScope: scope))
        let metadata = try object(LocalSummaryService.actionMetadataInput(candidate: candidate, evidenceScope: scope))
        for value in [assessment, metadata] {
            let rows = try XCTUnwrap(value["supportingSources"] as? [[String: Any]])
            for row in rows {
                XCTAssertNil(row["leadingWholeWordBoundary"])
                XCTAssertNil(row["trailingWholeWordBoundary"])
            }
        }
    }

    func testProductionTokenSplitPreservesInheritedEdgesIdentityAndCompleteText() throws {
        let original = source("Annabelle", provided: "Beatrice")
        let halves = try LocalSummaryService.splitSourceForTokenFit(original)
        XCTAssertEqual(halves.map(\.text), ["Anna", "belle"])
        XCTAssertTrue(halves[0].leadingWholeWordBoundary)
        XCTAssertFalse(halves[0].trailingWholeWordBoundary)
        XCTAssertFalse(halves[1].leadingWholeWordBoundary)
        XCTAssertTrue(halves[1].trailingWholeWordBoundary)
        XCTAssertEqual(Array(halves.map(\.text).joined().utf8), Array(original.text.utf8))
        for fragment in halves {
            XCTAssertEqual(fragment.id, original.id)
            XCTAssertEqual(fragment.speaker, original.speaker)
            XCTAssertEqual(fragment.start, original.start)
            XCTAssertEqual(fragment.end, original.end)
            XCTAssertEqual(fragment.providedSpeakerName, original.providedSpeakerName)
        }
        let quarters = try LocalSummaryService.splitSourceForTokenFit(halves[0])
        XCTAssertTrue(quarters[0].leadingWholeWordBoundary)
        XCTAssertFalse(quarters[0].trailingWholeWordBoundary)
        XCTAssertFalse(quarters[1].leadingWholeWordBoundary)
        XCTAssertFalse(quarters[1].trailingWholeWordBoundary, "Inherited clipped trailing edge must not reset to true")
        XCTAssertThrowsError(try LocalSummaryService.splitSourceForTokenFit(source("A")))
        XCTAssertThrowsError(try LocalSummaryService.splitSourceForTokenFit(source("")))
    }

    func testSplitNameCannotBecomeAFullNameButRejoinedCurrentFragmentsCan() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        let halves = try LocalSummaryService.splitSourceForTokenFit(source("Annabelle"))
        for fragment in halves {
            XCTAssertThrowsError(try parse(["s1": [fragment.text]], scope: scope([fragment]))) { error in
                XCTAssertEqual(error as? LocalSummaryService.PersonalNameCatalogValidationError, .wordBoundary)
            }
        }
        XCTAssertEqual(try parse(["s1": ["Annabelle"]], scope: scope(halves)).namesByAlias["s1"], ["Annabelle"])
        let crossAlias = [source("Anna", id: "first", trailing: false), source("belle", id: "second", leading: false)]
        XCTAssertThrowsError(try parse(["s1": ["Annabelle"], "s2": []], scope: scope(crossAlias))) { error in
            XCTAssertFalse(error is LocalSummaryService.PersonalNameCatalogValidationError)
        }
    }

    func testSourceChunkByteSplitsPreserveOriginalWordProvenanceAndUnicodeBytes() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        for text in ["A" + String(repeating: "b", count: 2200) + "Z", "Ç" + String(repeating: "e\u{0301}", count: 700) + "Z"] {
            var meeting = Meeting(title: "Synthetic original-word splitting", segments: [
                .init(id: "original", speaker: "A", start: 1.25, end: 9.75, text: text)
            ])
            meeting.speakerNames = ["A": "Beatrice"]
            let pieces = try LocalSummaryService.sourceChunks(meeting: meeting, maximumBytes: 1_024).flatMap { $0 }
            XCTAssertGreaterThan(pieces.count, 1)
            XCTAssertEqual(Array(pieces.map(\.text).joined().utf8), Array(text.utf8))
            for (index, piece) in pieces.enumerated() {
                XCTAssertEqual(piece.leadingWholeWordBoundary, index == 0)
                XCTAssertEqual(piece.trailingWholeWordBoundary, index == pieces.count - 1)
                XCTAssertEqual(piece.providedSpeakerName, "Beatrice")
                XCTAssertThrowsError(try parse(["s1": [piece.text]], scope: scope([piece]))) { error in
                    XCTAssertEqual(error as? LocalSummaryService.PersonalNameCatalogValidationError, .wordBoundary)
                }
            }
        }
    }

    func testValidInitialCatalogNeverRequestsRetry() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        let calls = NameBoundaryRetryCounter()
        let value = try await LocalSummaryService.parsePersonalNameCatalogWithBoundaryRetry(
            try generated(["s1": ["Alina"]]), evidenceScope: scope([source("Alina accepted.")])) {
                await calls.increment(); throw CancellationError()
            }
        XCTAssertEqual(value.namesByAlias["s1"], ["Alina"])
        let count = await calls.value(); XCTAssertEqual(count, 0)
    }

    func testOnlyLiteralBoundaryFailureGetsOneExplicitFreshCatalog() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        let calls = NameBoundaryRetryCounter(), scope = try scope([source("Alina accepted.")])
        let replacement = try generated(["s1": ["Alina"]])
        let value = try await LocalSummaryService.parsePersonalNameCatalogWithBoundaryRetry(
            try generated(["s1": ["Ali"]]), evidenceScope: scope) {
                await calls.increment(); return replacement
            }
        XCTAssertEqual(value.namesByAlias["s1"], ["Alina"], "The retry supplies the complete literal name; the parser never autocompletes Ali")
        let count = await calls.value(); XCTAssertEqual(count, 1)
    }

    func testFreshExplicitEmptyCatalogIsValidAndDoesNotDiscardProvidedIdentity() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        let calls = NameBoundaryRetryCounter(), scope = try scope([source("Alina accepted.", provided: "Beatrice")])
        let replacement = try generated(["s1": []])
        let value = try await LocalSummaryService.parsePersonalNameCatalogWithBoundaryRetry(
            try generated(["s1": ["Ali"]]), evidenceScope: scope) {
                await calls.increment(); return replacement
            }
        XCTAssertEqual(value.namesByAlias["s1"], [])
        let candidate = LocalSummaryService.ActionCandidate(id: "task", text: "A task.", evidence: ["original"])
        let domain = try LocalSummaryService.personChoiceDomain(candidate: candidate, evidenceScope: scope, catalog: value)
        XCTAssertEqual(domain.choices.map(\.name), ["Beatrice"])
        XCTAssertTrue(domain.choices.allSatisfy { $0.provenance == .providedSpeakerName })
        let count = await calls.value(); XCTAssertEqual(count, 1)
    }

    func testSecondBoundaryFailureAbortsWithoutAThirdGenerationOrForcedEmptyCatalog() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        let calls = NameBoundaryRetryCounter(), initial = try generated(["s1": ["Ali"]])
        do {
            _ = try await LocalSummaryService.parsePersonalNameCatalogWithBoundaryRetry(initial, evidenceScope: scope([source("Alina")])) {
                await calls.increment(); return initial
            }
            XCTFail("A second invalid catalog must abort")
        } catch { XCTAssertTrue(error is MeetingError) }
        let count = await calls.value(); XCTAssertEqual(count, 1)
    }

    func testMalformedNonliteralAndMixedInvalidCatalogsNeverQualifyForRetry() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        let scope = try scope([source("Alina", id: "first"), source("Beatrice", id: "second")])
        let invalid: [[String: Any]] = [
            [:], ["s1": []], ["s1": [], "s2": [], "s3": []],
            ["s1": NSNull(), "s2": []], ["s1": [1], "s2": []],
            ["s1": [""], "s2": []], ["s1": [" \t\n"], "s2": []],
            ["s1": Array(repeating: "Alina", count: 7), "s2": []],
            ["s1": ["ALINA"], "s2": []], ["s1": ["Beatrice"], "s2": []],
            ["s1": ["Ali"], "s2": ["Not in source"]],
            ["s1": ["Ali"], "s2": NSNull()],
            ["original": [], "s2": []]
        ]
        for wire in invalid {
            let calls = NameBoundaryRetryCounter(), replacement = try generated(["s1": [], "s2": []])
            do {
                _ = try await LocalSummaryService.parsePersonalNameCatalogWithBoundaryRetry(try generated(wire), evidenceScope: scope) {
                    await calls.increment(); return replacement
                }
                XCTFail("Invalid wire/literal scope must not be repaired into an empty catalog")
            } catch { XCTAssertFalse(error is LocalSummaryService.PersonalNameCatalogValidationError) }
            let count = await calls.value(); XCTAssertEqual(count, 0)
        }
    }

    func testMalformedRetryAndCancellationPropagateWithoutFallback() async throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        let scope = try scope([source("Alina")]), initial = try generated(["s1": ["Ali"]])
        for replacement in [try generated([:]), try generated(["s1": ["Unknown"]])] {
            let calls = NameBoundaryRetryCounter()
            do {
                _ = try await LocalSummaryService.parsePersonalNameCatalogWithBoundaryRetry(initial, evidenceScope: scope) {
                    await calls.increment(); return replacement
                }
                XCTFail("A malformed retry must abort, never become nil/empty")
            } catch { XCTAssertFalse(error is LocalSummaryService.PersonalNameCatalogValidationError) }
            let count = await calls.value(); XCTAssertEqual(count, 1)
        }
        let calls = NameBoundaryRetryCounter()
        do {
            _ = try await LocalSummaryService.parsePersonalNameCatalogWithBoundaryRetry(initial, evidenceScope: scope) {
                await calls.increment(); throw CancellationError()
            }
            XCTFail("Cancellation must propagate")
        } catch { XCTAssertTrue(error is CancellationError) }
        let count = await calls.value(); XCTAssertEqual(count, 1)
    }

    private func source(_ text: String, id: String = "original", leading: Bool = true, trailing: Bool = true, provided: String? = nil) -> LocalSummaryService.Source {
        .init(id: id, speaker: "A", start: 1.25, end: 9.75, text: text, providedSpeakerName: provided,
              leadingWholeWordBoundary: leading, trailingWholeWordBoundary: trailing)
    }
    private func scope(_ sources: [LocalSummaryService.Source]) throws -> LocalSummaryService.EvidenceScope {
        try LocalSummaryService.evidenceScope(sources: sources)
    }
    @available(macOS 26.0, *)
    private func parse(_ object: [String: Any], scope: LocalSummaryService.EvidenceScope) throws -> LocalSummaryService.PersonalNameCatalog {
        try LocalSummaryService.parsePersonalNameCatalog(try generated(object), evidenceScope: scope)
    }
    @available(macOS 26.0, *)
    private func generated(_ object: [String: Any]) throws -> GeneratedContent {
        try GeneratedContent(json: String(decoding: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self))
    }
    private func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }
}
