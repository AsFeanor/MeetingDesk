import XCTest
import FoundationModels
@testable import MeetingDesk

/// These synthetic tests cover the production inventory/assessment boundaries.
/// Handwritten verdicts cannot prove a model classified a real task correctly.
final class LocalActionAssessmentTests: XCTestCase {
    private let statuses: Set<String> = ["pending", "cancelled", "completed", "not_committed"]

    func testInventorySchemaContainsOnlyTaskTextAndClosedChunkEvidence() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        let schema = try inventorySchema(evidenceIDs: ["s1", "s2"])
        let fields = try objectFields(schema, required: ["candidates"])
        let array = try resolve(try XCTUnwrap(fields["candidates"] as? [String: Any]), in: schema)
        XCTAssertEqual(array["type"] as? String, "array")
        XCTAssertEqual(array["minItems"] as? Int, 0)
        XCTAssertEqual(array["maxItems"] as? Int, 12)
        let item = try resolve(try XCTUnwrap(array["items"] as? [String: Any]), in: schema)
        let itemFields = try objectFields(item, required: ["text", "evidence"])
        let text = try resolve(try XCTUnwrap(itemFields["text"] as? [String: Any]), in: schema)
        XCTAssertEqual(text["type"] as? String, "string")
        let evidence = try resolve(try XCTUnwrap(itemFields["evidence"] as? [String: Any]), in: schema)
        XCTAssertEqual(evidence["type"] as? String, "array")
        XCTAssertEqual(evidence["minItems"] as? Int, 1)
        XCTAssertEqual(evidence["maxItems"] as? Int, 4)
        XCTAssertEqual(try finiteStrings(try XCTUnwrap(evidence["items"] as? [String: Any]), in: schema), ["s1", "s2"])
        for forbidden in ["owner", "due", "responsiblePersonName", "deadlinePhrase", "status", "category", "sectionID"] {
            XCTAssertNil(itemFields[forbidden], "Inventory must not assign metadata or classify status")
        }
    }

    func testInventorySchemaRejectsAnInvalidOrUnboundedEvidenceDomain() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        for aliases in [[], [""], ["s1", "s1"], ["original-source"], ["s0"], ["s1\n"]] as [[String]] {
            XCTAssertThrowsError(try LocalSummaryService.actionInventorySchema(evidenceIDs: aliases))
        }
    }

    func testInventoryConversionRestoresOriginalSourcesAndCreatesStableDistinctIDs() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        let scope = try sourceScope()
        let payload = try generated(["candidates": [
            ["text": "Revise the design.", "evidence": ["s2", "s1"]],
            ["text": "Notify the customer.", "evidence": ["s1"]]
        ]])
        let first = try LocalSummaryService.convertActionCandidates(payload, part: 7, evidenceScope: scope)
        let repeatResult = try LocalSummaryService.convertActionCandidates(payload, part: 7, evidenceScope: scope)
        let otherPart = try LocalSummaryService.convertActionCandidates(payload, part: 8, evidenceScope: scope)
        XCTAssertEqual(first, repeatResult)
        XCTAssertEqual(first.map(\.text), ["Revise the design.", "Notify the customer."])
        XCTAssertEqual(first.map(\.evidence), [["original-a", "original-b"], ["original-a"]])
        XCTAssertEqual(Set(first.map(\.id)).count, 2)
        XCTAssertTrue(first.allSatisfy { !$0.id.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty })
        XCTAssertTrue(Set(first.map(\.id)).isDisjoint(with: Set(otherPart.map(\.id))))
        let encoded = try jsonObject(first[0])
        XCTAssertEqual(Set(encoded.keys), ["id", "text", "evidence"])
    }

    func testInventoryAcceptsAnExplicitEmptyListAndRejectsMissingOrExtraRootFields() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        let scope = try sourceScope()
        XCTAssertTrue(try LocalSummaryService.convertActionCandidates(try generated(["candidates": []]), part: 1, evidenceScope: scope).isEmpty)
        for root in [[:], ["candidates": NSNull()], ["candidates": "not-an-array"],
                     ["candidates": [], "actions": []], ["candidates": [], "unexpected": true]] as [[String: Any]] {
            XCTAssertThrowsError(try LocalSummaryService.convertActionCandidates(try generated(root), part: 1, evidenceScope: scope))
        }
    }

    func testInventoryRejectsMalformedTaskFieldsAndPrematureMetadata() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        let scope = try sourceScope()
        let valid: [String: Any] = ["text": "Revise the design.", "evidence": ["s1"]]
        let invalidText: [Any?] = [nil, NSNull(), 1, true, [], ["text": "task"], "", " \n\t"]
        for text in invalidText {
            var item = valid
            item["text"] = text
            XCTAssertThrowsError(try LocalSummaryService.convertActionCandidates(try generated(["candidates": [item]]), part: 1, evidenceScope: scope))
        }
        for field in ["owner", "due", "responsiblePersonName", "deadlinePhrase", "status", "category", "unexpected"] {
            var item = valid
            item[field] = "not permitted here"
            XCTAssertThrowsError(try LocalSummaryService.convertActionCandidates(try generated(["candidates": [item]]), part: 1, evidenceScope: scope), field)
        }
    }

    func testInventoryRejectsMissingMalformedUnknownAndOutOfScopeEvidenceBeforeAssessment() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        let scope = try sourceScope()
        let invalidEvidence: [Any?] = [nil, NSNull(), "s1", [1], [] as [String], [""], ["s3"],
            ["original-a"], ["foreign-source"], ["s1", "foreign-source"], ["s1", "s1", "s1", "s1", "s1"]]
        for evidence in invalidEvidence {
            var item: [String: Any] = ["text": "Revise the design."]
            item["evidence"] = evidence
            XCTAssertThrowsError(try LocalSummaryService.convertActionCandidates(try generated(["candidates": [item]]), part: 1, evidenceScope: scope))
        }
        let oversized = (1...13).map { ["text": "Independent task \($0).", "evidence": ["s1"]] as [String: Any] }
        XCTAssertThrowsError(try LocalSummaryService.convertActionCandidates(try generated(["candidates": oversized]), part: 1, evidenceScope: scope))
    }

    func testAssessmentSchemaHasTheSameFourStatusesAndClosedPresenceChoicesInBothLanguages() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        for language in ["English", "Turkish"] {
            let schema = try assessmentSchema(language: language)
            let fields = try objectFields(schema, required: ["status", "responsiblePerson", "deadline"])
            XCTAssertEqual(try finiteStrings(try XCTUnwrap(fields["status"] as? [String: Any]), in: schema), statuses)
            for name in ["responsiblePerson", "deadline"] {
                let choice = try resolve(try XCTUnwrap(fields[name] as? [String: Any]), in: schema)
                let branches = try XCTUnwrap(choice["anyOf"] as? [[String: Any]])
                XCTAssertEqual(branches.count, 2)
                var observed = Set<String>()
                for branchValue in branches {
                    let branch = try resolve(branchValue, in: schema)
                    let properties = try XCTUnwrap(branch["properties"] as? [String: Any])
                    let tag = try finiteStrings(try XCTUnwrap(properties["type"] as? [String: Any]), in: schema)
                    XCTAssertEqual(tag.count, 1)
                    let type = try XCTUnwrap(tag.first)
                    XCTAssertTrue(observed.insert(type).inserted)
                    if type == "notStated" {
                        _ = try objectFields(branch, required: ["type"])
                        XCTAssertNil(properties["verbatimValue"], "Absence cannot carry a free phrase that is silently discarded")
                    } else {
                        XCTAssertEqual(type, "stated")
                        _ = try objectFields(branch, required: ["type", "verbatimValue"])
                        let value = try resolve(try XCTUnwrap(properties["verbatimValue"] as? [String: Any]), in: schema)
                        XCTAssertEqual(value["type"] as? String, "string")
                        XCTAssertNil(value["anyOf"], "A stated value cannot offer null as an alternative")
                    }
                }
                XCTAssertEqual(observed, ["notStated", "stated"], "\(language).\(name)")
            }
        }
    }

    func testPendingAssessmentPreservesTaskIdentityAndEvidenceWhileExtractingVerbatimMetadata() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        let candidate = LocalSummaryService.ActionCandidate(id: "original-candidate", text: " Revise the design. \n", evidence: ["original-b", "original-a"])
        let action = try XCTUnwrap(LocalSummaryService.assessedAction(try generated(assessment(
            person: stated("Ali"), deadline: stated("by next Friday"))), candidate: candidate))
        XCTAssertEqual(action.id, candidate.id)
        XCTAssertEqual(action.text, candidate.text)
        XCTAssertEqual(action.evidence, candidate.evidence)
        XCTAssertEqual(action.owner, "Ali")
        XCTAssertEqual(action.due, "by next Friday")
        let archive = try jsonObject(action)
        XCTAssertEqual(archive["owner"] as? String, "Ali")
        XCTAssertEqual(archive["due"] as? String, "by next Friday")
        XCTAssertNil(archive["responsiblePerson"])
        XCTAssertNil(archive["deadline"])
        XCTAssertEqual(try JSONDecoder().decode(ActionItem.self, from: JSONEncoder().encode(action)), action)
    }

    func testExplicitAbsenceChoicesYieldNilWithoutCopyingAnAbsencePhraseFromSource() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        let candidate = LocalSummaryService.ActionCandidate(id: "ownerless", text: "Rehberi güncelle.", evidence: ["source"])
        let action = try XCTUnwrap(LocalSummaryService.assessedAction(try generated(assessment()), candidate: candidate))
        XCTAssertNil(action.owner)
        XCTAssertNil(action.due)
        let meeting = Meeting(title: "Synthetic explicit absence", segments: [
            .init(id: "source", speaker: "A", start: 0, end: 3,
                  text: "Rehberi güncelleme işini kararlaştırdık. Sorumlu ve teslim tarihi belirlenmedi.")
        ])
        XCTAssertNoThrow(try LocalSummaryService.validate(notes: notes([action]), meeting: meeting, requireTemplateSections: true))
    }

    func testExplicitTemporalBoundaryRemainsVerbatimWithoutInventingACalendarDate() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        let candidate = LocalSummaryService.ActionCandidate(id: "release-check", text: "Erişilebilirlik kontrolü yap.", evidence: ["source"])
        let action = try XCTUnwrap(LocalSummaryService.assessedAction(try generated(assessment(deadline: stated("yeni sürümden önce"))), candidate: candidate))
        XCTAssertNil(action.owner)
        XCTAssertEqual(action.due, "yeni sürümden önce")
        let meeting = Meeting(title: "Synthetic temporal boundary", segments: [
            .init(id: "source", speaker: "A", start: 0, end: 3,
                  text: "Ekip, yeni sürümden önce erişilebilirlik kontrolü yapılmasını kararlaştırdı.")
        ])
        XCTAssertNoThrow(try LocalSummaryService.validate(notes: notes([action]), meeting: meeting, requireTemplateSections: true))
    }

    func testAllNonpendingStatusesDiscardOnlyTheirCandidateAfterStrictMetadataParsing() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        let candidate = sampleCandidate()
        for status in statuses.subtracting(["pending"]) {
            XCTAssertNil(try LocalSummaryService.assessedAction(try generated(assessment(status: status)), candidate: candidate))
            for name in ["responsiblePerson", "deadline"] {
                var malformed = assessment(status: status)
                malformed[name] = ["type": "notStated", "verbatimValue": "must not be ignored"]
                XCTAssertThrowsError(try LocalSummaryService.assessedAction(try generated(malformed), candidate: candidate),
                                    "A nonpending classification must not hide a malformed \(name) branch")
            }
        }
    }

    func testAssessmentRejectsMissingExtraAndWrongTypedRootFieldsWithoutDefaults() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        let candidate = sampleCandidate()
        for field in ["status", "responsiblePerson", "deadline"] {
            for invalid in [nil, NSNull(), 42, true, [] as [String], ""] as [Any?] {
                var value = assessment()
                value[field] = invalid
                XCTAssertThrowsError(try LocalSummaryService.assessedAction(try generated(value), candidate: candidate), field)
            }
        }
        for name in ["id", "candidate", "text", "evidence", "owner", "due", "unexpected"] {
            var value = assessment()
            value[name] = "unrequested value"
            XCTAssertThrowsError(try LocalSummaryService.assessedAction(try generated(value), candidate: candidate), name)
        }
        for status in ["", "Pending", "pending ", " pending", "unknown", "not committed", "bekliyor", "true"] {
            XCTAssertThrowsError(try LocalSummaryService.assessedAction(try generated(assessment(status: status)), candidate: candidate), status)
        }
        for json in ["null", "[]", "true", "42", "\"pending\""] {
            XCTAssertThrowsError(try LocalSummaryService.assessedAction(GeneratedContent(json: json), candidate: candidate))
        }
    }

    func testEveryPresenceChoiceRejectsUnknownMissingContradictoryEmptyAndWrongTypedShapes() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        let malformed: [Any] = [
            [:], ["type": NSNull()], ["type": true], ["type": 1], ["type": ""], ["type": "unknown"],
            ["type": "notstated"], ["type": "notStated "], ["type": "notStated", "verbatimValue": ""],
            ["type": "notStated", "verbatimValue": NSNull()], ["type": "notStated", "verbatimValue": "tomorrow"],
            ["type": "notStated", "unexpected": true], ["type": "stated"],
            ["type": "stated", "verbatimValue": ""], ["type": "stated", "verbatimValue": " \t\n"],
            ["type": "stated", "verbatimValue": NSNull()], ["type": "stated", "verbatimValue": true],
            ["type": "stated", "verbatimValue": 42], ["type": "stated", "verbatimValue": []],
            ["type": "stated", "verbatimValue": ["text": "tomorrow"]],
            ["type": "stated", "verbatimValue": "tomorrow", "unexpected": false],
            ["type": "stated", "verbatimValue": "tomorrow", "notStated": true],
            ["verbatimValue": "tomorrow"]
        ]
        for name in ["responsiblePerson", "deadline"] {
            for branch in malformed {
                var value = assessment()
                value[name] = branch
                XCTAssertThrowsError(try LocalSummaryService.assessedAction(try generated(value), candidate: sampleCandidate()), name)
            }
        }
    }

    func testStatedValuesAreNotNormalizedOrRepairedAndStillRequireSourceGrounding() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        let candidate = sampleCandidate()
        let meeting = Meeting(title: "Synthetic unassigned task", segments: [
            .init(id: "original-a", speaker: "A", start: 0, end: 3, text: "The team agreed to revise the design.")
        ])
        for name in ["responsiblePerson", "deadline"] {
            for unsupported in ["null", "None", "Belirtilmedi", "nil", "N/A", "Ayşe", "2030-01-01"] {
                var value = assessment()
                value[name] = stated(unsupported)
                let action = try XCTUnwrap(LocalSummaryService.assessedAction(try generated(value), candidate: candidate))
                XCTAssertEqual(name == "responsiblePerson" ? action.owner : action.due, unsupported)
                XCTAssertThrowsError(try LocalSummaryService.validate(notes: notes([action]), meeting: meeting, requireTemplateSections: true))
            }
        }
    }

    func testAssessmentCannotBorrowMetadataFromOtherSourcesOrAnotherFragment() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        let candidate = sampleCandidate()
        let meeting = Meeting(title: "Synthetic separate assignment", segments: [
            .init(id: "original-a", speaker: "A", start: 0, end: 3, text: "The team agreed to revise the design; assignment remains open."),
            .init(id: "original-b", speaker: "B", start: 4, end: 7, text: "Ali will revise the design by next Friday.")
        ])
        for value in [assessment(person: stated("Ali")), assessment(deadline: stated("next Friday"))] {
            let action = try XCTUnwrap(LocalSummaryService.assessedAction(try generated(value), candidate: candidate))
            XCTAssertThrowsError(try LocalSummaryService.validate(notes: notes([action]), meeting: meeting, requireTemplateSections: true))
        }
        var fragmented = meeting
        fragmented.segments[0].text += " Ali will revise the design by next Friday."
        let action = try XCTUnwrap(LocalSummaryService.assessedAction(try generated(assessment(person: stated("Ali"), deadline: stated("next Friday"))), candidate: candidate))
        XCTAssertThrowsError(try LocalSummaryService.validate(notes: notes([action]), meeting: fragmented,
            scopedText: ["original-a": meeting.segments[0].text], requireTemplateSections: true))
    }

    func testAssessmentRetainsProvidedIdentityGroundingAndRejectsAnonymousChannelAsOwner() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        let candidate = sampleCandidate()
        var meeting = Meeting(title: "Synthetic explicit speaker mapping", segments: [
            .init(id: "original-a", speaker: "A", start: 0, end: 3, text: "I commit to revising the design.")
        ])
        meeting.speakerNames = ["A": "Ali"]
        let named = try XCTUnwrap(LocalSummaryService.assessedAction(try generated(assessment(person: stated("Ali"))), candidate: candidate))
        XCTAssertNoThrow(try LocalSummaryService.validate(notes: notes([named]), meeting: meeting, requireTemplateSections: true))
        meeting.speakerNames = [:]
        let anonymous = try XCTUnwrap(LocalSummaryService.assessedAction(try generated(assessment(person: stated("A"))), candidate: candidate))
        XCTAssertThrowsError(try LocalSummaryService.validate(notes: notes([anonymous]), meeting: meeting, requireTemplateSections: true))
    }

    func testInputPartitionsAllFragmentsWithoutLosingOriginalOrderOrSourceMetadata() throws {
        let sources: [LocalSummaryService.Source] = [
            .init(id: "original-a", speaker: "A", start: 0, end: 10, text: "First task fragment.", providedSpeakerName: "Ali"),
            .init(id: "original-b", speaker: "B", start: 11, end: 12, text: "The earlier plan was cancelled."),
            .init(id: "original-a", speaker: "A", start: 0, end: 10, text: "Later fragment of the same original source.", providedSpeakerName: "Ali")
        ]
        let scope = try LocalSummaryService.evidenceScope(sources: sources)
        let candidate = sampleCandidate()
        let input = try LocalSummaryService.actionAssessmentInput(candidate: candidate, evidenceScope: scope)
        XCTAssertEqual(input.supportingSources.map(\.sourcePosition), [0, 2])
        XCTAssertEqual(input.otherSources.map(\.sourcePosition), [1])
        let encoded = try jsonObject(input)
        let supporting = try XCTUnwrap(encoded["supportingSources"] as? [[String: Any]])
        let others = try XCTUnwrap(encoded["otherSources"] as? [[String: Any]])
        let reconstructed = (supporting + others).sorted { ($0["sourcePosition"] as? Int ?? -1) < ($1["sourcePosition"] as? Int ?? -1) }
        XCTAssertEqual(reconstructed.count, scope.sources.count)
        for (position, row) in reconstructed.enumerated() {
            let source = scope.sources[position]
            XCTAssertEqual(row["sourcePosition"] as? Int, position)
            XCTAssertEqual(row["id"] as? String, source.id)
            XCTAssertEqual(row["speakerLabel"] as? String, source.speaker)
            XCTAssertEqual(row["providedSpeakerName"] as? String, source.providedSpeakerName)
            XCTAssertEqual(row["text"] as? String, source.text)
            XCTAssertEqual(row["start"] as? Double, source.start)
            XCTAssertEqual(row["end"] as? Double, source.end)
        }
        let inputCandidate = try XCTUnwrap(encoded["candidate"] as? [String: Any])
        XCTAssertEqual(inputCandidate["id"] as? String, candidate.id)
        XCTAssertEqual(inputCandidate["text"] as? String, candidate.text)
        XCTAssertEqual(inputCandidate["evidence"] as? [String], ["s1"])
        XCTAssertNil(others[0]["providedSpeakerName"], "An unmapped source must not acquire a guessed identity")
    }

    func testPartitionOrderDoesNotFollowCandidateEvidenceOrderAndUnknownSourcesCannotBeHidden() throws {
        let scope = try sourceScope()
        let reversedEvidence = LocalSummaryService.ActionCandidate(id: "candidate", text: "Revise the design.", evidence: ["original-b", "original-a"])
        let input = try LocalSummaryService.actionAssessmentInput(candidate: reversedEvidence, evidenceScope: scope)
        XCTAssertEqual(input.supportingSources.map(\.sourcePosition), [0, 1])
        XCTAssertTrue(input.otherSources.isEmpty)
        for evidence in [[], ["foreign-source"], ["original-a", "foreign-source"], ["s1"]] as [[String]] {
            let candidate = LocalSummaryService.ActionCandidate(id: "candidate", text: "Revise the design.", evidence: evidence)
            XCTAssertThrowsError(try LocalSummaryService.actionAssessmentInput(candidate: candidate, evidenceScope: scope))
        }
    }

    func testCandidatePrevalidationRejectsMalformedStructureBeforeAnySemanticAssessment() throws {
        let valid = sampleCandidate()
        XCTAssertNoThrow(try LocalSummaryService.validateActionCandidates([valid], allowedEvidence: ["original-a"]))
        let malformed: [[LocalSummaryService.ActionCandidate]] = [
            [.init(id: "", text: "A task.", evidence: ["original-a"])],
            [.init(id: " \n", text: "A task.", evidence: ["original-a"])],
            [valid, valid],
            [.init(id: "candidate", text: " \n", evidence: ["original-a"])],
            [.init(id: "candidate", text: "A task.", evidence: [])],
            [.init(id: "candidate", text: "A task.", evidence: ["unknown-source"])],
            [.init(id: "candidate", text: "A task.", evidence: ["original-a", "unknown-source"])]
        ]
        for candidates in malformed {
            XCTAssertThrowsError(try LocalSummaryService.validateActionCandidates(candidates, allowedEvidence: ["original-a"]),
                                "Semantic rejection must not conceal a malformed or ungrounded inventory")
        }
        let oversized = (1...13).map { LocalSummaryService.ActionCandidate(id: "candidate-\($0)", text: "A task.", evidence: ["original-a"]) }
        XCTAssertThrowsError(try LocalSummaryService.validateActionCandidates(oversized, allowedEvidence: ["original-a"]))
    }

    func testCancelledAndNotificationTasksSharingOneSourceRemainIndependentAssessments() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        let cancelled = LocalSummaryService.ActionCandidate(id: "cancelled", text: "Prepare the presentation.", evidence: ["shared"])
        let pending = LocalSummaryService.ActionCandidate(id: "pending", text: "Müşteriye iptal kararını bildir.", evidence: ["shared"])
        XCTAssertNil(try LocalSummaryService.assessedAction(try generated(assessment(status: "cancelled")), candidate: cancelled))
        let action = try XCTUnwrap(LocalSummaryService.assessedAction(try generated(assessment(person: stated("Selin"), deadline: stated("yarın"))), candidate: pending))
        XCTAssertEqual(action.id, pending.id)
        XCTAssertEqual(action.text, pending.text)
        XCTAssertEqual(action.evidence, pending.evidence)
        let meeting = Meeting(title: "Synthetic cancellation and follow-up", segments: [
            .init(id: "shared", speaker: "A", start: 0, end: 5,
                  text: "Sunumu hazırlama işini iptal ettik. Selin, iptal kararını müşteriye yarın bildirmeyi üstlendi.")
        ])
        XCTAssertNoThrow(try LocalSummaryService.validate(notes: notes([action]), meeting: meeting, requireTemplateSections: true))
    }

    private func sampleCandidate() -> LocalSummaryService.ActionCandidate {
        .init(id: "candidate-id", text: "Revise the design.", evidence: ["original-a"])
    }

    private func sourceScope() throws -> LocalSummaryService.EvidenceScope {
        try LocalSummaryService.evidenceScope(sources: [
            .init(id: "original-a", speaker: "A", start: 0, end: 3, text: "The design needs revision."),
            .init(id: "original-b", speaker: "B", start: 4, end: 7, text: "Ali will revise the design by next Friday.")
        ])
    }

    private func notes(_ actions: [ActionItem]) -> MeetingNotes {
        MeetingNotes(summary: "Synthetic work was discussed.", decisions: [], actions: actions, questions: [], ideas: [], topics: [])
    }

    private func absent() -> [String: Any] { ["type": "notStated"] }
    private func stated(_ value: String) -> [String: Any] { ["type": "stated", "verbatimValue": value] }
    private func assessment(status: String = "pending", person: [String: Any]? = nil, deadline: [String: Any]? = nil) -> [String: Any] {
        ["status": status, "responsiblePerson": person ?? absent(), "deadline": deadline ?? absent()]
    }

    @available(macOS 26.0, *)
    private func generated(_ object: [String: Any]) throws -> GeneratedContent {
        try GeneratedContent(json: String(decoding: JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]), as: UTF8.self))
    }

    private func jsonObject<T: Encodable>(_ value: T) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(value)) as? [String: Any])
    }

    @available(macOS 26.0, *)
    private func inventorySchema(evidenceIDs: [String]) throws -> [String: Any] {
        try jsonObject(LocalSummaryService.actionInventorySchema(evidenceIDs: evidenceIDs))
    }

    @available(macOS 26.0, *)
    private func assessmentSchema(language: String) throws -> [String: Any] {
        try jsonObject(LocalSummaryService.actionAssessmentSchema(language: language))
    }

    private func objectFields(_ schema: [String: Any], required expected: Set<String>) throws -> [String: Any] {
        XCTAssertEqual(schema["type"] as? String, "object")
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
        let fields = try XCTUnwrap(schema["properties"] as? [String: Any])
        XCTAssertEqual(Set(fields.keys), expected)
        XCTAssertEqual(Set(try XCTUnwrap(schema["required"] as? [String])), expected)
        return fields
    }

    private func finiteStrings(_ value: [String: Any], in root: [String: Any]) throws -> Set<String> {
        let schema = try resolve(value, in: root)
        if let alternatives = schema["anyOf"] as? [[String: Any]] {
            XCTAssertFalse(alternatives.isEmpty)
            XCTAssertNil(schema["enum"])
            if let type = schema["type"] as? String { XCTAssertEqual(type, "string") }
            return try alternatives.reduce(into: Set<String>()) { result, choice in
                result.formUnion(try finiteStrings(choice, in: root))
            }
        }
        // A string const/enum restricts the domain even when JSON Schema omits
        // the redundant type keyword (as associated-case discriminators do).
        if let type = schema["type"] as? String { XCTAssertEqual(type, "string") }
        if let constant = schema["const"] as? String { return [constant] }
        let values = try XCTUnwrap(schema["enum"] as? [String])
        XCTAssertFalse(values.isEmpty)
        return Set(values)
    }

    private func resolve(_ value: [String: Any], in root: [String: Any], visited: Set<String> = []) throws -> [String: Any] {
        guard let reference = value["$ref"] as? String else { return value }
        XCTAssertTrue(reference.hasPrefix("#/"))
        guard !visited.contains(reference) else { throw InspectionError.cyclicReference }
        var target: Any = root
        for component in reference.dropFirst(2).split(separator: "/") {
            let key = component.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
            target = try XCTUnwrap((target as? [String: Any])?[key])
        }
        var result = try resolve(try XCTUnwrap(target as? [String: Any]), in: root, visited: visited.union([reference]))
        for (key, sibling) in value where key != "$ref" { result[key] = sibling }
        return result
    }

    private enum InspectionError: Error { case cyclicReference }
}
