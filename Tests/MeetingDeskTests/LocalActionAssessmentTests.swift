import XCTest
import FoundationModels
@testable import MeetingDesk

/// These synthetic tests cover the production inventory/assessment boundaries.
/// Handwritten verdicts cannot prove a model classified a real task correctly.
final class LocalActionAssessmentTests: XCTestCase {
    private let commitmentStates: Set<String> = ["agreed_or_committed_future_task", "only_proposed_or_unaccepted", "cancelled_or_rejected", "already_completed"]

    func testInventorySchemaContainsOnlyTaskTextAndClosedChunkEvidence() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        let schema = try inventorySchema(evidenceIDs: ["s1", "s2"])
        let fields = try objectFields(schema, required: ["candidates"])
        let array = try resolve(try XCTUnwrap(fields["candidates"] as? [String: Any]), in: schema)
        XCTAssertEqual(array["type"] as? String, "array")
        XCTAssertEqual(array["minItems"] as? Int, 0)
        XCTAssertEqual(array["maxItems"] as? Int, 12)
        let inventoryDescription = try XCTUnwrap(array["description"] as? String)
        XCTAssertTrue(inventoryDescription.contains("Only explicitly agreed OR committed concrete future tasks"))
        XCTAssertTrue(inventoryDescription.contains("Exclude discussion, proposals, completed and cancelled work"))
        XCTAssertTrue(inventoryDescription.contains("separate agreed follow-up survives cancellation of another task"))
        let item = try resolve(try XCTUnwrap(array["items"] as? [String: Any]), in: schema)
        let itemFields = try objectFields(item, required: ["text", "evidence"])
        let text = try resolve(try XCTUnwrap(itemFields["text"] as? [String: Any]), in: schema)
        XCTAssertEqual(text["type"] as? String, "string")
        XCTAssertTrue(try XCTUnwrap(text["description"] as? String).contains("explicitly agreed OR clearly committed"))
        let evidence = try resolve(try XCTUnwrap(itemFields["evidence"] as? [String: Any]), in: schema)
        XCTAssertEqual(evidence["type"] as? String, "array")
        XCTAssertEqual(evidence["minItems"] as? Int, 1)
        XCTAssertEqual(evidence["maxItems"] as? Int, 4)
        XCTAssertEqual(try finiteStrings(try XCTUnwrap(evidence["items"] as? [String: Any]), in: schema), ["s1", "s2"])
        for forbidden in ["owner", "due", "responsiblePersonName", "deadlinePhrase", "status", "commitmentState", "category", "sectionID"] {
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
        for field in ["owner", "due", "responsiblePersonName", "deadlinePhrase", "status", "commitmentState", "category", "unexpected"] {
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

    func testCommitmentSchemaHasOnlyTheSameFourClosedStatesInBothLanguages() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        for language in ["English", "Turkish"] {
            let schema = try commitmentSchema(language: language)
            let fields = try objectFields(schema, required: ["commitmentState"])
            let commitment = try resolve(try XCTUnwrap(fields["commitmentState"] as? [String: Any]), in: schema)
            XCTAssertEqual(try finiteStrings(commitment, in: schema), commitmentStates)
            let description = try XCTUnwrap(commitment["description"] as? String)
            if language == "Turkish" {
                XCTAssertTrue(description.contains("açıkça kararlaştırılmış VEYA üstlenilmiş"))
                XCTAssertTrue(description.contains("kabul edilmemiş/onay bekleyen teklif"))
                XCTAssertTrue(description.contains("Sorumlu/tarih bulunmaması taahhütten bağımsızdır"))
            } else {
                XCTAssertTrue(description.contains("explicit agreement OR commitment to future work"))
                XCTAssertTrue(description.contains("unaccepted offer"))
                XCTAssertTrue(description.contains("Missing owner/date is independent of commitment"))
            }
        }
    }

    func testOnlyAnExplicitAgreedFutureTaskAllowsTheMetadataStage() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        for state in commitmentStates {
            XCTAssertEqual(try LocalSummaryService.commitmentAllowsAction(try generated(commitment(state))),
                           state == "agreed_or_committed_future_task")
            var mixed = commitment(state)
            mixed["hasResponsiblePersonName"] = false
            mixed["hasTemporalDeadline"] = false
            XCTAssertThrowsError(try LocalSummaryService.commitmentAllowsAction(try generated(mixed)),
                                "Metadata presence fields must not influence or be accepted in the commitment result")
        }
    }

    func testCommitmentParserRejectsMissingExtraWrongTypedUnknownAndObsoleteWireWithoutDefaults() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        for invalid in [nil, NSNull(), 42, true, [] as [String], [:] as [String: String]] as [Any?] {
            var value: [String: Any] = [:]
            value["commitmentState"] = invalid
            XCTAssertThrowsError(try LocalSummaryService.commitmentAllowsAction(try generated(value)))
        }
        for name in ["id", "candidate", "text", "evidence", "owner", "due", "responsiblePerson", "deadline", "status", "unexpected"] {
            var value = commitment()
            if name == "responsiblePerson" || name == "deadline" {
                value[name] = absent()
            } else {
                value[name] = "unrequested value"
            }
            XCTAssertThrowsError(try LocalSummaryService.commitmentAllowsAction(try generated(value)), name)
        }
        XCTAssertThrowsError(try LocalSummaryService.commitmentAllowsAction(try generated(["status": "pending"])))
        for state in ["", "pending", "cancelled", "completed", "not_committed", "Pending", "pending ", " pending", "unknown", "not committed", "bekliyor", "true",
                      "Agreed_or_committed_future_task", "AGREED_OR_COMMITTED_FUTURE_TASK", " agreed_or_committed_future_task", "agreed_or_committed_future_task "] {
            XCTAssertThrowsError(try LocalSummaryService.commitmentAllowsAction(try generated(commitment(state))), state)
        }
        for json in ["null", "[]", "true", "42", "\"pending\"", "\"agreed_or_committed_future_task\""] {
            XCTAssertThrowsError(try LocalSummaryService.commitmentAllowsAction(GeneratedContent(json: json)))
        }
    }

    func testPresenceSchemaRequiresExactlyTwoIndependentBooleanFlagsInBothLanguages() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        for language in ["English", "Turkish"] {
            let schema = try jsonObject(LocalSummaryService.actionMetadataPresenceSchema(language: language))
            let fields = try objectFields(schema, required: ["hasResponsiblePersonName", "hasTemporalDeadline"])
            for name in fields.keys {
                let value = try resolve(try XCTUnwrap(fields[name] as? [String: Any]), in: schema)
                XCTAssertEqual(try booleanDomain(value, in: schema), [false, true],
                               "Absence must be a permitted explicit answer, never a missing-field default")
                let description = try XCTUnwrap(value["description"] as? String)
                if language == "English" {
                    XCTAssertTrue(description.contains(name == "hasResponsiblePersonName" ? "explicitly named REAL PERSON" : "explicit TEMPORAL deadline"))
                } else {
                    XCTAssertTrue(description.contains(name == "hasResponsiblePersonName" ? "GERÇEK KİŞİNİN ADI" : "açık ZAMANSAL teslim ifadesi"))
                }
                XCTAssertTrue(description.contains("false"))
            }
        }
    }

    func testAllFourValidatedPresenceCombinationsControlSchemaKeysAndPreserveTaskIdentity() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        let candidate = LocalSummaryService.ActionCandidate(id: "original-candidate", text: " Revise the design. \n", evidence: ["original-b", "original-a"])
        for person in [false, true] {
            for deadline in [false, true] {
                let parsed = try LocalSummaryService.parseMetadataPresence(try generated([
                    "hasResponsiblePersonName": person, "hasTemporalDeadline": deadline
                ]))
                XCTAssertEqual(parsed, presence(person: person, deadline: deadline))
                let payload = values(person: person ? "Ali" : nil, deadline: deadline ? "by next Friday" : nil)
                let action: ActionItem
                if person || deadline {
                    for language in ["English", "Turkish"] {
                        let schema = try jsonObject(LocalSummaryService.actionMetadataValuesSchema(presence: parsed, language: language))
                        let fields = try objectFields(schema, required: Set(payload.keys))
                        for (name, rawValue) in fields {
                            let value = try resolve(try XCTUnwrap(rawValue as? [String: Any]), in: schema)
                            XCTAssertEqual(value["type"] as? String, "string")
                            XCTAssertNil(value["anyOf"])
                            let description = try XCTUnwrap(value["description"] as? String)
                            if language == "English" {
                                XCTAssertTrue(description.contains(name == "responsiblePersonName" ? "REAL RESPONSIBLE PERSON'S NAME" : "TEMPORAL DEADLINE EXPRESSION"))
                            } else {
                                XCTAssertTrue(description.contains(name == "responsiblePersonName" ? "GERÇEK SORUMLU KİŞİNİN ADI" : "ZAMANSAL TESLİM İFADESİNİN KENDİSİ"))
                            }
                        }
                    }
                    action = try LocalSummaryService.actionFromMetadataValues(try generated(payload), presence: parsed, candidate: candidate)
                    XCTAssertThrowsError(try LocalSummaryService.actionFromMetadataValues(nil, presence: parsed, candidate: candidate),
                                        "A present field cannot turn into nil when its value response is missing")
                } else {
                    XCTAssertThrowsError(try LocalSummaryService.actionMetadataValuesSchema(presence: parsed))
                    action = try LocalSummaryService.actionFromMetadataValues(nil, presence: parsed, candidate: candidate)
                    XCTAssertThrowsError(try LocalSummaryService.actionFromMetadataValues(try generated([:]), presence: parsed, candidate: candidate),
                                        "Both false means skip generation, not accept an unsolicited empty response")
                }
                XCTAssertEqual(action.id, candidate.id)
                XCTAssertEqual(action.text, candidate.text)
                XCTAssertEqual(action.evidence, candidate.evidence)
                XCTAssertEqual(action.owner, person ? "Ali" : nil)
                XCTAssertEqual(action.due, deadline ? "by next Friday" : nil)
                XCTAssertEqual(try JSONDecoder().decode(ActionItem.self, from: JSONEncoder().encode(action)), action)
                if person && deadline {
                    let archive = try jsonObject(action)
                    XCTAssertEqual(archive["owner"] as? String, "Ali")
                    XCTAssertEqual(archive["due"] as? String, "by next Friday")
                    XCTAssertNil(archive["hasResponsiblePersonName"])
                    XCTAssertNil(archive["responsiblePersonName"])
                    XCTAssertNil(archive["deadlinePhrase"])
                }
            }
        }
    }

    func testMalformedPresenceCannotDefaultToFalseOrIgnoreUnexpectedFields() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        for field in ["hasResponsiblePersonName", "hasTemporalDeadline"] {
            for invalid in [nil, NSNull(), "true", "false", "TRUE", 0, 1, [] as [Bool], ["value": false]] as [Any?] {
                var wire: [String: Any] = ["hasResponsiblePersonName": false, "hasTemporalDeadline": false]
                wire[field] = invalid
                XCTAssertThrowsError(try LocalSummaryService.parseMetadataPresence(try generated(wire)), field)
            }
        }
        for extra in ["responsiblePersonName", "deadlinePhrase", "responsiblePerson", "deadline", "commitmentState", "status", "type", "unexpected"] {
            var wire: [String: Any] = ["hasResponsiblePersonName": false, "hasTemporalDeadline": false]
            wire[extra] = "not permitted"
            XCTAssertThrowsError(try LocalSummaryService.parseMetadataPresence(try generated(wire)), extra)
        }
        let wrongKeys: [[String: Any]] = [
            [:], ["hasResponsiblePersonName": false], ["hasTemporalDeadline": false],
            ["hasResponsiblepersonName": false, "hasTemporalDeadline": false],
            ["hasResponsiblePersonName": false, "HasTemporalDeadline": false],
            ["responsiblePerson": ["type": "notStated"], "deadline": ["type": "notStated"]]
        ]
        for wire in wrongKeys { XCTAssertThrowsError(try LocalSummaryService.parseMetadataPresence(try generated(wire))) }
        for json in ["null", "[]", "true", "false", "42", "\"false\""] {
            XCTAssertThrowsError(try LocalSummaryService.parseMetadataPresence(GeneratedContent(json: json)))
        }
    }

    func testConditionalValuesRejectMissingWrongTypedBlankFalseFlagAndObsoleteFields() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        for person in [false, true] {
            for deadline in [false, true] {
                let flags = presence(person: person, deadline: deadline)
                let valid = values(person: person ? "Ali" : nil, deadline: deadline ? "tomorrow" : nil)
                if !person && !deadline {
                    for wire in [[:], ["responsiblePersonName": "Ali"], ["deadlinePhrase": "tomorrow"],
                                 ["responsiblePerson": ["type": "notStated"]]] as [[String: Any]] {
                        XCTAssertThrowsError(try LocalSummaryService.actionFromMetadataValues(try generated(wire), presence: flags, candidate: sampleCandidate()))
                    }
                    continue
                }
                for field in valid.keys {
                    for invalid in [nil, NSNull(), true, 42, [] as [String], ["type": "notStated"], "", " \t\n"] as [Any?] {
                        var wire = valid
                        wire[field] = invalid
                        XCTAssertThrowsError(try LocalSummaryService.actionFromMetadataValues(try generated(wire), presence: flags, candidate: sampleCandidate()), field)
                    }
                    for wrongKey in [field.lowercased(), field.uppercased(), " " + field, field + " "] {
                        var wire = valid
                        wire.removeValue(forKey: field)
                        wire[wrongKey] = "not an alias"
                        XCTAssertThrowsError(try LocalSummaryService.actionFromMetadataValues(try generated(wire), presence: flags, candidate: sampleCandidate()), wrongKey)
                    }
                }
                var forbidden = ["hasResponsiblePersonName", "hasTemporalDeadline", "responsiblePerson", "deadline",
                                 "type", "verbatimValue", "commitmentState", "owner", "due", "unexpected"]
                if !person { forbidden.append("responsiblePersonName") }
                if !deadline { forbidden.append("deadlinePhrase") }
                for field in forbidden {
                    for extraValue in [NSNull(), "", "stray value"] as [Any] {
                        var wire = valid
                        wire[field] = extraValue
                        XCTAssertThrowsError(try LocalSummaryService.actionFromMetadataValues(try generated(wire), presence: flags, candidate: sampleCandidate()), field)
                    }
                }
                for oldWire in [
                    ["responsiblePerson": ["type": "namedPerson", "responsiblePersonName": "Ali"], "deadline": ["type": "temporalDeadline", "deadlinePhrase": "tomorrow"]],
                    ["responsiblePerson": ["type": "stated", "verbatimValue": "Ali"], "deadline": ["type": "notStated"]]
                ] as [[String: Any]] {
                    XCTAssertThrowsError(try LocalSummaryService.actionFromMetadataValues(try generated(oldWire), presence: flags, candidate: sampleCandidate()))
                }
                for json in ["null", "[]", "true", "42", "\"Ali\""] {
                    XCTAssertThrowsError(try LocalSummaryService.actionFromMetadataValues(GeneratedContent(json: json), presence: flags, candidate: sampleCandidate()))
                }
            }
        }
    }

    func testValidatedFalsePresenceYieldsNilWithoutCopyingAnExplicitAbsencePhrase() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        let candidate = LocalSummaryService.ActionCandidate(id: "ownerless", text: "Rehberi güncelle.", evidence: ["source"])
        let flags = try LocalSummaryService.parseMetadataPresence(try generated(["hasResponsiblePersonName": false, "hasTemporalDeadline": false]))
        let action = try LocalSummaryService.actionFromMetadataValues(nil, presence: flags, candidate: candidate)
        XCTAssertNil(action.owner)
        XCTAssertNil(action.due)
        let meeting = Meeting(title: "Synthetic explicit absence", segments: [
            .init(id: "source", speaker: "A", start: 0, end: 3, text: "Rehberi güncelleme işini kararlaştırdık. Sorumlu ve teslim tarihi belirlenmedi.")
        ])
        XCTAssertNoThrow(try LocalSummaryService.validate(notes: notes([action]), meeting: meeting, requireTemplateSections: true))
    }

    func testExplicitTemporalBoundaryRemainsVerbatimWithoutInventingACalendarDate() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        let candidate = LocalSummaryService.ActionCandidate(id: "release-check", text: "Erişilebilirlik kontrolü yap.", evidence: ["source"])
        let action = try LocalSummaryService.actionFromMetadataValues(try generated(values(deadline: "yeni sürümden önce")), presence: presence(person: false, deadline: true), candidate: candidate)
        XCTAssertNil(action.owner)
        XCTAssertEqual(action.due, "yeni sürümden önce")
        let meeting = Meeting(title: "Synthetic temporal boundary", segments: [
            .init(id: "source", speaker: "A", start: 0, end: 3, text: "Ekip, yeni sürümden önce erişilebilirlik kontrolü yapılmasını kararlaştırdı.")
        ])
        XCTAssertNoThrow(try LocalSummaryService.validate(notes: notes([action]), meeting: meeting, requireTemplateSections: true))
    }

    func testPresentValuesAreNotNormalizedOrRepairedAndStillRequireSourceGrounding() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        let meeting = Meeting(title: "Synthetic unassigned task", segments: [
            .init(id: "original-a", speaker: "A", start: 0, end: 3, text: "The team agreed to revise the design.")
        ])
        for person in [false, true] {
            for unsupported in ["null", "None", "Belirtilmedi", "nil", "N/A", "Ayşe", "2030-01-01"] {
                let wire = person ? values(person: unsupported) : values(deadline: unsupported)
                let action = try LocalSummaryService.actionFromMetadataValues(try generated(wire), presence: presence(person: person, deadline: !person), candidate: sampleCandidate())
                XCTAssertEqual(person ? action.owner : action.due, unsupported)
                XCTAssertThrowsError(try LocalSummaryService.validate(notes: notes([action]), meeting: meeting, requireTemplateSections: true))
            }
        }
    }

    func testMetadataCannotBorrowAnOwnerOrDateFromOtherSourcesOrAnotherFragment() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        let candidate = sampleCandidate()
        let meeting = Meeting(title: "Synthetic separate assignment", segments: [
            .init(id: "original-a", speaker: "A", start: 0, end: 3, text: "The team agreed to revise the design; assignment remains open."),
            .init(id: "original-b", speaker: "B", start: 4, end: 7, text: "Ali will revise the design by next Friday.")
        ])
        for person in [false, true] {
            let wire = person ? values(person: "Ali") : values(deadline: "next Friday")
            let action = try LocalSummaryService.actionFromMetadataValues(try generated(wire), presence: presence(person: person, deadline: !person), candidate: candidate)
            XCTAssertThrowsError(try LocalSummaryService.validate(notes: notes([action]), meeting: meeting, requireTemplateSections: true))
        }
        var fragmented = meeting
        fragmented.segments[0].text += " Ali will revise the design by next Friday."
        let action = try LocalSummaryService.actionFromMetadataValues(try generated(values(person: "Ali", deadline: "next Friday")), presence: presence(person: true, deadline: true), candidate: candidate)
        XCTAssertThrowsError(try LocalSummaryService.validate(notes: notes([action]), meeting: fragmented,
            scopedText: ["original-a": meeting.segments[0].text], requireTemplateSections: true))
    }

    func testMetadataRetainsProvidedIdentityGroundingAndRejectsAnonymousChannelAsOwner() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        var meeting = Meeting(title: "Synthetic explicit speaker mapping", segments: [
            .init(id: "original-a", speaker: "A", start: 0, end: 3, text: "I commit to revising the design.")
        ])
        meeting.speakerNames = ["A": "Ali"]
        let named = try LocalSummaryService.actionFromMetadataValues(try generated(values(person: "Ali")), presence: presence(person: true, deadline: false), candidate: sampleCandidate())
        XCTAssertNoThrow(try LocalSummaryService.validate(notes: notes([named]), meeting: meeting, requireTemplateSections: true))
        meeting.speakerNames = [:]
        let anonymous = try LocalSummaryService.actionFromMetadataValues(try generated(values(person: "A")), presence: presence(person: true, deadline: false), candidate: sampleCandidate())
        XCTAssertThrowsError(try LocalSummaryService.validate(notes: notes([anonymous]), meeting: meeting, requireTemplateSections: true))
    }

    func testInputPartitionsAllFragmentsWithoutLosingOriginalOrderOrSourceMetadata() throws {
        let sources: [LocalSummaryService.Source] = [
            .init(id: "original-a", speaker: "A", start: 0, end: 10, text: "First task fragment.", providedSpeakerName: "Ali"),
            .init(id: "original-b", speaker: "B", start: 11, end: 12, text: "The earlier plan was cancelled."),
            .init(id: "original-a", speaker: "A", start: 0, end: 10, text: "Later fragment of the same original source.", providedSpeakerName: "Ali")
        ]
        let scope = try LocalSummaryService.evidenceScope(sources: sources)
        XCTAssertEqual(scope.sources.map(\.speaker), sources.map(\.speaker), "Raw labels remain available locally for grounding")
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
            XCTAssertNil(row["speakerLabel"], "Model assessment input must not expose a channel as a possible person name")
            XCTAssertNil(row["speaker"])
            XCTAssertEqual(row["providedSpeakerName"] as? String, source.providedSpeakerName)
            XCTAssertEqual(row["text"] as? String, source.text)
            XCTAssertEqual(row["start"] as? Double, source.start)
            XCTAssertEqual(row["end"] as? Double, source.end)
            var expected: Set<String> = ["sourcePosition", "id", "start", "end", "text"]
            if source.providedSpeakerName != nil { expected.insert("providedSpeakerName") }
            XCTAssertEqual(Set(row.keys), expected)
        }
        let inputCandidate = try XCTUnwrap(encoded["candidate"] as? [String: Any])
        XCTAssertEqual(inputCandidate["id"] as? String, candidate.id)
        XCTAssertEqual(inputCandidate["text"] as? String, candidate.text)
        XCTAssertEqual(inputCandidate["evidence"] as? [String], ["s1"])
        XCTAssertNil(others[0]["providedSpeakerName"], "An unmapped source must not acquire a guessed identity")
        let metadataInput = try LocalSummaryService.actionMetadataInput(candidate: candidate, evidenceScope: scope)
        XCTAssertEqual(metadataInput.candidate, input.candidate)
        XCTAssertEqual(metadataInput.supportingSources, input.supportingSources)
        let metadataObject = try jsonObject(metadataInput)
        XCTAssertEqual(Set(metadataObject.keys), ["candidate", "supportingSources"])
        XCTAssertNil(metadataObject["otherSources"], "Metadata extraction must not receive unrelated source entries")
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
            XCTAssertThrowsError(try LocalSummaryService.actionMetadataInput(candidate: candidate, evidenceScope: scope))
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
        XCTAssertFalse(try LocalSummaryService.commitmentAllowsAction(try generated(commitment("cancelled_or_rejected"))))
        XCTAssertTrue(try LocalSummaryService.commitmentAllowsAction(try generated(commitment())))
        let action = try LocalSummaryService.actionFromMetadataValues(try generated(values(person: "Selin", deadline: "yarın")), presence: presence(person: true, deadline: true), candidate: pending)
        XCTAssertEqual(action.id, pending.id)
        XCTAssertNotEqual(action.id, cancelled.id)
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
    private func commitment(_ state: String = "agreed_or_committed_future_task") -> [String: Any] {
        ["commitmentState": state]
    }
    private func presence(person: Bool, deadline: Bool) -> LocalSummaryService.ActionMetadataPresence {
        .init(hasResponsiblePersonName: person, hasTemporalDeadline: deadline)
    }
    private func values(person: String? = nil, deadline: String? = nil) -> [String: Any] {
        var result: [String: Any] = [:]
        if let person { result["responsiblePersonName"] = person }
        if let deadline { result["deadlinePhrase"] = deadline }
        return result
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
    private func commitmentSchema(language: String) throws -> [String: Any] {
        try jsonObject(LocalSummaryService.actionCommitmentSchema(language: language))
    }

    private func objectFields(_ schema: [String: Any], required expected: Set<String>) throws -> [String: Any] {
        XCTAssertEqual(schema["type"] as? String, "object")
        XCTAssertEqual(schema["additionalProperties"] as? Bool, false)
        let fields = try XCTUnwrap(schema["properties"] as? [String: Any])
        XCTAssertEqual(Set(fields.keys), expected)
        XCTAssertEqual(Set(try XCTUnwrap(schema["required"] as? [String])), expected)
        return fields
    }

    private func booleanDomain(_ value: [String: Any], in root: [String: Any]) throws -> Set<Bool> {
        let schema = try resolve(value, in: root)
        if let choices = schema["anyOf"] as? [[String: Any]] {
            guard !choices.isEmpty, schema["enum"] == nil, schema["const"] == nil,
                  schema["type"] == nil || schema["type"] as? String == "boolean" else { throw InspectionError.invalidBooleanDomain }
            return try choices.reduce(into: Set<Bool>()) { result, choice in
                result.formUnion(try booleanDomain(choice, in: root))
            }
        }
        guard schema["type"] as? String == "boolean" else { throw InspectionError.invalidBooleanDomain }
        if let constant = schema["const"] { return [try literalBoolean(constant)] }
        if let enumeration = schema["enum"] {
            let values = try XCTUnwrap(enumeration as? [Any])
            guard !values.isEmpty else { throw InspectionError.invalidBooleanDomain }
            return try Set(values.map(literalBoolean))
        }
        return [false, true]
    }

    private func literalBoolean(_ value: Any) throws -> Bool {
        let data = try JSONSerialization.data(withJSONObject: value, options: [.fragmentsAllowed])
        switch String(decoding: data, as: UTF8.self) {
        case "true": return true
        case "false": return false
        default: throw InspectionError.invalidBooleanDomain
        }
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

    private enum InspectionError: Error { case cyclicReference, invalidBooleanDomain }
}
