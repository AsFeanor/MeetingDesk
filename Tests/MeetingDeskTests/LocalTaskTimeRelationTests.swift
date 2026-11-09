import XCTest
import FoundationModels
@testable import MeetingDesk

/// Tests typed grounding and verdict interpretation, not a model's semantic accuracy.
final class LocalTaskTimeRelationTests: XCTestCase {
    private let roles = ["execution_schedule", "task_content_or_measurement", "no_supported_temporal_expression"]

    func testRelationSchemaIsOneRequiredClosedThreeCodeStringForBothLanguages() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS26") }
        for language in ["English", "Turkish"] {
            let schema = try object(LocalSummaryService.taskTimeRelationSchema(language: language))
            XCTAssertEqual(schema["type"] as? String, "object")
            XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
            XCTAssertEqual(schema["required"] as? [String], ["timeRelation"])
            XCTAssertEqual(schema["x-order"] as? [String], ["timeRelation"])
            let fields = try XCTUnwrap(schema["properties"] as? [String: Any])
            XCTAssertEqual(Set(fields.keys), ["timeRelation"])
            XCTAssertEqual(try finiteStrings(try XCTUnwrap(fields["timeRelation"] as? [String: Any]), root: schema), Set(roles))
        }
    }

    func testScheduleVerdictPreservesCalendarRelativeEventAndNumericPhraseBytes() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS26") }
        for (text, phrase) in [
            ("We will deliver at 07:15.", "07:15"),
            ("We will finish in 5 days.", "in 5 days"),
            ("We will deliver before the inspection window.", "before the inspection window"),
            ("We will deliver at 5.", "5"),
            ("We will deliver on Friday.", "FRIDAY"),
            ("We will deliver after café closes.", "after cafe closes"),
            ("We will deliver next Friday before the review.", " next Friday ")
        ] {
            let input = input(text)
            let proposal = try LocalSummaryService.validatedTaskTimeProposal(phrase, input: input)
            let selected = try LocalSummaryService.resolveTaskTimeRelation(try verdict("execution_schedule"),
                proposal: proposal, input: input, proposedPhrase: phrase)
            XCTAssertEqual(Array(try XCTUnwrap(selected).utf8), Array(phrase.utf8),
                           "Legacy source support is retained; the resolver never trims, translates or converts the proposal")
        }
    }

    func testOnlyExplicitNonTemporalVerdictsProduceAbsenceAndSnapshotsStayOutOfModelJSON() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS26") }
        let phrase = "the crane's rotation duration"
        let input = input("The team agreed to measure the crane's rotation duration.")
        let proposal = try LocalSummaryService.validatedTaskTimeProposal(phrase, input: input)
        XCTAssertEqual(proposal.candidate, input.candidate)
        XCTAssertEqual(proposal.supportingSources, input.supportingSources)
        XCTAssertEqual(proposal.proposedTaskTimePhrase, phrase)
        let encoded = try object(proposal)
        XCTAssertEqual(Set(encoded.keys), ["candidate", "supportingSources", "proposedTaskTimePhrase"])
        XCTAssertNil(encoded["inputSnapshot"])
        XCTAssertNil(encoded["phraseSnapshot"])
        let sources = try XCTUnwrap(encoded["supportingSources"] as? [[String: Any]])
        XCTAssertEqual(Set(sources[0].keys), ["id", "text"])
        for role in roles.dropFirst() {
            XCTAssertNil(try LocalSummaryService.resolveTaskTimeRelation(try verdict(role), proposal: proposal,
                input: input, proposedPhrase: phrase), "Only a valid explicit semantic classification permits absence")
        }
    }

    func testUnsupportedBlankAndIncompleteSourceProposalsAbortBeforeAnySemanticVerdict() throws {
        let source = input("The team agreed to inspect the form; no time was set.")
        for phrase in ["", " \t\n", "5", "2035-03-07", "tomorrow"] {
            XCTAssertThrowsError(try LocalSummaryService.validatedTaskTimeProposal(phrase, input: source),
                                "A later non-temporal verdict must never hide an invalid or unsupported raw value")
        }
        let candidate = LocalSummaryService.ActionCandidate(id: "task", text: "Inspect the form.", evidence: ["s1"])
        let supported = LocalSummaryService.TaskTimeSource(id: "s1", providedSpeakerName: nil, text: "Inspect tomorrow.")
        let foreign = LocalSummaryService.TaskTimeSource(id: "s2", providedSpeakerName: nil, text: "Another task next week.")
        let invalid: [LocalSummaryService.TaskTimeInput] = [
            .init(candidate: candidate, supportingSources: []),
            .init(candidate: candidate, supportingSources: [supported, foreign]),
            .init(candidate: .init(id: "task", text: candidate.text, evidence: ["s1", "s2"]), supportingSources: [supported]),
            .init(candidate: .init(id: "task", text: candidate.text, evidence: []), supportingSources: [])
        ]
        for value in invalid { XCTAssertThrowsError(try LocalSummaryService.validatedTaskTimeProposal("tomorrow", input: value)) }
    }

    func testGroundingJoinsOnlyDeclaredAliasFragmentsAndKeepsLegacyEvidenceOrderAndRepeats() throws {
        let fragments = LocalSummaryService.TaskTimeInput(
            candidate: .init(id: "task", text: "Deliver after review.", evidence: ["s1"]),
            supportingSources: [
                .init(id: "s1", providedSpeakerName: nil, text: "Deliver after the "),
                .init(id: "s1", providedSpeakerName: nil, text: "review.")
            ])
        XCTAssertNoThrow(try LocalSummaryService.validatedTaskTimeProposal("after the review", input: fragments))
        let joined = LocalSummaryService.TaskTimeInput(
            candidate: .init(id: "task", text: "Deliver after review.", evidence: ["s2", "s1"]),
            supportingSources: [
                .init(id: "s1", providedSpeakerName: nil, text: "review."),
                .init(id: "s2", providedSpeakerName: nil, text: "Deliver after the")
            ])
        XCTAssertNoThrow(try LocalSummaryService.validatedTaskTimeProposal("after the review", input: joined))
        let reversedEvidence = LocalSummaryService.TaskTimeInput(
            candidate: .init(id: "task", text: joined.candidate.text, evidence: ["s1", "s2"]), supportingSources: joined.supportingSources)
        XCTAssertThrowsError(try LocalSummaryService.validatedTaskTimeProposal("after the review", input: reversedEvidence))
        let repeated = LocalSummaryService.TaskTimeInput(
            candidate: .init(id: "task", text: "Deliver tomorrow.", evidence: ["s1", "s1"]),
            supportingSources: [.init(id: "s1", providedSpeakerName: nil, text: "Deliver tomorrow.")])
        let proposal = try LocalSummaryService.validatedTaskTimeProposal("tomorrow", input: repeated)
        XCTAssertEqual(proposal.candidate.evidence, ["s1", "s1"], "Do not add a new deduplication rule to legacy grounding")
    }

    func testEveryCandidateSourceIdentityOrderAndPhraseChangeRejectsEvenANonTemporalVerdict() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS26") }
        let base = LocalSummaryService.TaskTimeInput(
            candidate: .init(id: "task", text: "Deliver the form.", evidence: ["s1", "s2"]),
            supportingSources: [
                .init(id: "s1", providedSpeakerName: "Nora", text: "Deliver tomorrow after review."),
                .init(id: "s2", providedSpeakerName: nil, text: "The assignment was accepted.")
            ])
        let phrase = "tomorrow"
        let proposal = try LocalSummaryService.validatedTaskTimeProposal(phrase, input: base)
        var variants: [LocalSummaryService.TaskTimeInput] = []
        for candidate in [
            LocalSummaryService.ActionCandidate(id: "other-task", text: base.candidate.text, evidence: base.candidate.evidence),
            .init(id: base.candidate.id, text: "A different task.", evidence: base.candidate.evidence),
            .init(id: base.candidate.id, text: base.candidate.text, evidence: ["s2", "s1"])
        ] { variants.append(.init(candidate: candidate, supportingSources: base.supportingSources)) }
        variants.append(.init(candidate: base.candidate, supportingSources: Array(base.supportingSources.reversed())))
        variants.append(.init(candidate: base.candidate, supportingSources: [
            .init(id: "s1", providedSpeakerName: "Nora", text: "Deliver tomorrow after a different review."), base.supportingSources[1]]))
        variants.append(.init(candidate: base.candidate, supportingSources: [
            .init(id: "s1", providedSpeakerName: "Mira", text: base.supportingSources[0].text), base.supportingSources[1]]))
        variants.append(.init(candidate: .init(id: base.candidate.id, text: base.candidate.text, evidence: ["s9", "s2"]),
            supportingSources: [.init(id: "s9", providedSpeakerName: "Nora", text: base.supportingSources[0].text), base.supportingSources[1]]))
        for role in roles {
            for changed in variants {
                XCTAssertThrowsError(try LocalSummaryService.resolveTaskTimeRelation(try verdict(role), proposal: proposal,
                    input: changed, proposedPhrase: phrase), "Binding mismatch must not be repaired into nil")
            }
            for changedPhrase in ["Tomorrow", " tomorrow", "tomorrow ", "tomorrow\u{0000}"] {
                XCTAssertThrowsError(try LocalSummaryService.resolveTaskTimeRelation(try verdict(role), proposal: proposal,
                    input: base, proposedPhrase: changedPhrase))
            }
        }
        for _ in 0..<8 {
            XCTAssertEqual(try LocalSummaryService.resolveTaskTimeRelation(try verdict("execution_schedule"), proposal: proposal,
                input: base, proposedPhrase: phrase), phrase)
        }
    }

    func testCanonicalUnicodeEqualityCannotBypassExactInputOrPhraseByteBinding() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS26") }
        let composed = "café sonrası", decomposed = "cafe\u{0301} sonrası"
        XCTAssertEqual(composed, decomposed)
        XCTAssertNotEqual(Array(composed.utf8), Array(decomposed.utf8))
        let original = input("We agreed to deliver café sonrası.")
        let changed = input("We agreed to deliver cafe\u{0301} sonrası.")
        let proposal = try LocalSummaryService.validatedTaskTimeProposal(composed, input: original)
        for role in roles {
            XCTAssertThrowsError(try LocalSummaryService.resolveTaskTimeRelation(try verdict(role), proposal: proposal,
                input: original, proposedPhrase: decomposed))
            XCTAssertThrowsError(try LocalSummaryService.resolveTaskTimeRelation(try verdict(role), proposal: proposal,
                input: changed, proposedPhrase: composed))
        }
    }

    func testMalformedMissingExtraUnknownAndWrongTypedVerdictsNeverDefaultToAbsence() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS26") }
        let input = input("We will deliver tomorrow.")
        let proposal = try LocalSummaryService.validatedTaskTimeProposal("tomorrow", input: input)
        for value in [nil, NSNull(), true, false, 0, 1, [], [:], "", "execution_schedule ", "Execution_schedule", "schedule", "none", "task_content", "unknown"] as [Any?] {
            var wire: [String: Any] = [:]; wire["timeRelation"] = value
            XCTAssertThrowsError(try LocalSummaryService.resolveTaskTimeRelation(try generated(wire), proposal: proposal,
                input: input, proposedPhrase: "tomorrow"))
        }
        for role in roles {
            for field in ["sourceObservation", "taskTimePhrase", "hasExplicitTaskTime", "date", "owner", "unexpected"] {
                for extra in [NSNull(), "", true] as [Any] {
                    XCTAssertThrowsError(try LocalSummaryService.resolveTaskTimeRelation(
                        try generated(["timeRelation": role, field: extra]), proposal: proposal, input: input, proposedPhrase: "tomorrow"))
                }
            }
        }
        for json in ["null", "[]", "true", "42", "\"execution_schedule\""] {
            XCTAssertThrowsError(try LocalSummaryService.resolveTaskTimeRelation(GeneratedContent(json: json), proposal: proposal,
                input: input, proposedPhrase: "tomorrow"))
        }
    }

    private func input(_ text: String) -> LocalSummaryService.TaskTimeInput {
        .init(candidate: .init(id: "task", text: "Deliver the approved form.", evidence: ["s1"]),
              supportingSources: [.init(id: "s1", providedSpeakerName: nil, text: text)])
    }
    @available(macOS 26.0, *)
    private func verdict(_ role: String) throws -> GeneratedContent { try generated(["timeRelation": role]) }
    @available(macOS 26.0, *)
    private func generated(_ value: [String: Any]) throws -> GeneratedContent {
        try GeneratedContent(json: String(decoding: JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]), as: UTF8.self))
    }
    private func object<T: Encodable>(_ value: T) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: LocalSummaryService.modelInputData(value)) as? [String: Any])
    }
    private func resolve(_ value: [String: Any], root: [String: Any], seen: Set<String> = []) throws -> [String: Any] {
        guard let ref = value["$ref"] as? String else { return value }
        guard ref.hasPrefix("#/"), !seen.contains(ref) else { throw InspectionError.invalidSchema }
        var current: Any = root
        for part in ref.dropFirst(2).split(separator: "/") {
            let key = part.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
            current = try XCTUnwrap((current as? [String: Any])?[key])
        }
        var result = try resolve(try XCTUnwrap(current as? [String: Any]), root: root, seen: seen.union([ref]))
        for (key, value) in value where key != "$ref" { result[key] = value }
        return result
    }
    private func finiteStrings(_ value: [String: Any], root: [String: Any]) throws -> Set<String> {
        let value = try resolve(value, root: root)
        if let type = value["type"] as? String { XCTAssertEqual(type, "string") }
        if let choices = value["anyOf"] as? [[String: Any]] {
            XCTAssertFalse(choices.isEmpty)
            return try choices.reduce(into: Set<String>()) { result, choice in result.formUnion(try finiteStrings(choice, root: root)) }
        }
        if let constant = value["const"] as? String { return [constant] }
        let values = try XCTUnwrap(value["enum"] as? [String]); XCTAssertFalse(values.isEmpty); return Set(values)
    }
    private enum InspectionError: Error { case invalidSchema }
}
