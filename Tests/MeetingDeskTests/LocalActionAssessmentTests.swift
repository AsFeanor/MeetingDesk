import XCTest
import FoundationModels
@testable import MeetingDesk

/// These synthetic tests cover the production inventory/assessment boundaries.
/// Handwritten verdicts cannot prove a model classified a real task correctly.
final class LocalActionAssessmentTests: XCTestCase {
    private let commitmentStates: Set<String> = ["agreed_or_committed_future_task", "only_proposed_or_unaccepted", "cancelled_or_rejected", "already_completed", "not_a_future_execution_task"]

    func testInventorySchemaRequiresEveryAliasAndOnlyLiteralClausesWithClosedEvidence() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        let schema = try inventorySchema(evidenceIDs: ["s1", "s2"])
        let fields = try objectFields(schema, required: ["s1", "s2"])
        for alias in ["s1", "s2"] {
            let array = try resolve(try XCTUnwrap(fields[alias] as? [String: Any]), in: schema)
            XCTAssertEqual(array["type"] as? String, "array")
            XCTAssertEqual(array["minItems"] as? Int, 0)
            XCTAssertEqual(array["maxItems"] as? Int, 12)
            let description = try XCTUnwrap(array["description"] as? String)
            XCTAssertTrue(description.contains("REQUIRED even when empty"))
            XCTAssertTrue(description.contains("Maximum 12 candidates across ALL source properties"))
            XCTAssertTrue(description.contains("including proposed, cancelled/rejected or completed work"))
            XCTAssertTrue(description.contains("do not decide eligibility"))
            let item = try resolve(try XCTUnwrap(array["items"] as? [String: Any]), in: schema)
            let properties = try objectFields(item, required: ["taskClause", "evidence"])
            let clause = try resolve(try XCTUnwrap(properties["taskClause"] as? [String: Any]), in: schema)
            XCTAssertEqual(clause["type"] as? String, "string")
            XCTAssertTrue(try XCTUnwrap(clause["description"] as? String).contains("EXACTLY VERBATIM"))
            let clauseDescription = try XCTUnwrap(clause["description"] as? String)
            XCTAssertTrue(clauseDescription.contains("complete object/purpose"))
            XCTAssertTrue(clauseDescription.contains("proposal, decision, undertaking, cancellation, completion or negation words"))
            XCTAssertTrue(clauseDescription.contains("Do not judge action eligibility here"))
            let evidence = try resolve(try XCTUnwrap(properties["evidence"] as? [String: Any]), in: schema)
            XCTAssertEqual(evidence["type"] as? String, "array")
            XCTAssertEqual(evidence["minItems"] as? Int, 1)
            XCTAssertEqual(evidence["maxItems"] as? Int, 4)
            XCTAssertEqual(try finiteStrings(try XCTUnwrap(evidence["items"] as? [String: Any]), in: schema), ["s1", "s2"])
            XCTAssertTrue(try XCTUnwrap(evidence["description"] as? String).contains("MUST include"))
            for forbidden in ["text", "owner", "due", "responsibleIdentityKind", "hasExplicitTaskTime", "commitmentState", "category"] {
                XCTAssertNil(properties[forbidden])
            }
        }
    }

    func testMentionInventoryPreservesPositiveProposedCancelledCompletedAndSeparateFollowupClauses() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        let clauses = [
            "We decided to replace the office lamps; nobody is assigned yet.",
            "We could repaint the sign; nobody accepted that work.",
            "We cancelled moving the cabinets; they will not be moved.",
            "The shelf repair was completed yesterday.",
            "The team agreed to tell the reception staff about the cancellation."
        ]
        let scope = try LocalSummaryService.evidenceScope(sources: clauses.enumerated().map {
            .init(id: "mention-\($0.offset)", speaker: "A", start: Double($0.offset), end: Double($0.offset + 1), text: $0.element)
        })
        var wire: [String: Any] = [:]
        for (index, alias) in scope.evidenceIDs.enumerated() {
            wire[alias] = [["taskClause": clauses[index], "evidence": [alias]]]
        }
        let candidates = try LocalSummaryService.convertActionCandidates(try generated(wire), part: 2, evidenceScope: scope)
        XCTAssertEqual(candidates.map(\.text), clauses, "Inventory decoding must retain negation and status qualifiers, not silently prefilter work mentions")
        XCTAssertEqual(candidates.map(\.evidence), (0..<clauses.count).map { ["mention-\($0)"] })
        XCTAssertEqual(candidates.map(\.id), (1...clauses.count).map { "local-2-action-\($0)" })
        // These are candidates, not accepted actions. Existing closed commitment
        // verdict tests remain the later eligibility boundary.
    }

    func testInventorySchemaRejectsAnInvalidOrUnboundedEvidenceDomain() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        for aliases in [[], [""], ["s1", "s1"], ["original-source"], ["s0"], ["s1\n"]] as [[String]] {
            XCTAssertThrowsError(try LocalSummaryService.actionInventorySchema(evidenceIDs: aliases))
        }
    }

    func testInventoryFlatteningUsesDomainAndArrayOrderWithStableIDsAndOriginalEvidence() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        let scope = try LocalSummaryService.evidenceScope(sources: [
            .init(id: "original-a", speaker: "A", start: 0, end: 3, text: "Prepare the report. Review the form."),
            .init(id: "original-b", speaker: "B", start: 4, end: 7, text: "Notify the customer.")
        ])
        // JSON key order is deliberately reversed; source domain order owns IDs.
        let json = #"{"s2":[{"taskClause":"Notify the customer.","evidence":["s2"]}],"s1":[{"taskClause":"Prepare the report.","evidence":["s2","s1"]},{"taskClause":"Review the form.","evidence":["s1"]}]}"#
        let payload = try GeneratedContent(json: json)
        let first = try LocalSummaryService.convertActionCandidates(payload, part: 7, evidenceScope: scope)
        let repeated = try LocalSummaryService.convertActionCandidates(payload, part: 7, evidenceScope: scope)
        let otherPart = try LocalSummaryService.convertActionCandidates(payload, part: 8, evidenceScope: scope)
        XCTAssertEqual(first, repeated)
        XCTAssertEqual(first.map(\.text), ["Prepare the report.", "Review the form.", "Notify the customer."])
        XCTAssertEqual(first.map(\.evidence), [["original-a", "original-b"], ["original-a"], ["original-b"]])
        XCTAssertEqual(first.map(\.id), ["local-7-action-1", "local-7-action-2", "local-7-action-3"])
        XCTAssertTrue(Set(first.map(\.id)).isDisjoint(with: Set(otherPart.map(\.id))))
        XCTAssertEqual(Set(try jsonObject(first[0]).keys), ["id", "text", "evidence"])
    }

    func testInventoryAcceptsOnlyExplicitEmptyArraysForEverySource() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        let scope = try sourceScope()
        XCTAssertTrue(try LocalSummaryService.convertActionCandidates(try generated(["s1": [], "s2": []]), part: 1, evidenceScope: scope).isEmpty)
        let invalid: [[String: Any]] = [
            [:], ["s1": []], ["s2": []], ["s1": [], "s2": [], "s3": []],
            ["s1": [], "s2": [], "unexpected": true], ["candidates": []], ["actions": []],
            ["original-a": [], "s2": []], ["S1": [], "s2": []],
            ["s1": NSNull(), "s2": []], ["s1": "not-an-array", "s2": []],
            ["s1": [:], "s2": []]
        ]
        for wire in invalid {
            XCTAssertThrowsError(try LocalSummaryService.convertActionCandidates(try generated(wire), part: 1, evidenceScope: scope))
        }
    }

    func testInventoryRejectsMalformedItemsAndOldOrPrematureMetadata() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        let scope = try sourceScope()
        let valid: [String: Any] = ["taskClause": "The design needs revision.", "evidence": ["s1"]]
        for field in ["taskClause", "evidence"] {
            for invalid in [nil, NSNull(), 1, true, [], ["unexpected": "value"], "", " \t\n"] as [Any?] {
                var item = valid
                item[field] = invalid
                XCTAssertThrowsError(try LocalSummaryService.convertActionCandidates(try generated(["s1": [item], "s2": []]), part: 1, evidenceScope: scope))
            }
        }
        for field in ["text", "owner", "due", "responsiblePersonName", "taskTimePhrase", "responsibleIdentityKind", "hasExplicitTaskTime", "commitmentState", "unexpected"] {
            var item = valid
            item[field] = "not permitted"
            XCTAssertThrowsError(try LocalSummaryService.convertActionCandidates(try generated(["s1": [item], "s2": []]), part: 1, evidenceScope: scope), field)
        }
        let oldItem: [String: Any] = ["text": "The design needs revision.", "evidence": ["s1"]]
        XCTAssertThrowsError(try LocalSummaryService.convertActionCandidates(try generated(["s1": [oldItem], "s2": []]), part: 1, evidenceScope: scope))
    }

    func testOwningAliasMustBeCitedAndLiteralClauseCannotComeFromAnotherSource() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        let scope = try sourceScope()
        let invalidEvidence: [Any] = [NSNull(), "s1", [1], [] as [String], [""], ["s2"], ["s3"],
            ["original-a"], ["foreign-source"], ["s1", "foreign-source"], ["s1", "s1", "s1", "s1", "s1"]]
        for evidence in invalidEvidence {
            let item: [String: Any] = ["taskClause": "The design needs revision.", "evidence": evidence]
            XCTAssertThrowsError(try LocalSummaryService.convertActionCandidates(try generated(["s1": [item], "s2": []]), part: 1, evidenceScope: scope))
        }
        let misplaced: [String: Any] = ["taskClause": "Ali will revise the design by next Friday.", "evidence": ["s1", "s2"]]
        XCTAssertThrowsError(try LocalSummaryService.convertActionCandidates(try generated(["s1": [misplaced], "s2": []]), part: 1, evidenceScope: scope),
                            "Additional evidence does not change the source that must contain the literal clause")
        for changed in ["The design needs revisions.", "Revise the design.", "The design needs revision. "] {
            let item: [String: Any] = ["taskClause": changed, "evidence": ["s1"]]
            XCTAssertThrowsError(try LocalSummaryService.convertActionCandidates(try generated(["s1": [item], "s2": []]), part: 1, evidenceScope: scope), changed)
        }
    }

    func testInventoryPreservesMultiSourceAcceptanceOwnerAndTimingGrounding() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        let sources: [LocalSummaryService.Source] = [
            .init(id: "task-original", speaker: "A", start: 0, end: 2, text: "The report will be prepared."),
            .init(id: "assignment-original", speaker: "B", start: 3, end: 5, text: "Ali accepted responsibility for that report by next Friday."),
            .init(id: "unrelated-original", speaker: "C", start: 6, end: 7, text: "An unrelated topic remains open.")
        ]
        let scope = try LocalSummaryService.evidenceScope(sources: sources)
        let item: [String: Any] = ["taskClause": "The report will be prepared.", "evidence": ["s2", "s1"]]
        let candidates = try LocalSummaryService.convertActionCandidates(try generated(["s1": [item], "s2": [], "s3": []]), part: 1, evidenceScope: scope)
        let candidate = try XCTUnwrap(candidates.first)
        XCTAssertEqual(candidate.evidence, ["assignment-original", "task-original"])
        let input = try LocalSummaryService.actionAssessmentInput(candidate: candidate, evidenceScope: scope)
        XCTAssertEqual(input.supportingSources.map(\.id), ["s1", "s2"])
        XCTAssertEqual(input.otherSources.map(\.id), ["s3"])
        let metadataInput = try LocalSummaryService.actionMetadataInput(candidate: candidate, evidenceScope: scope)
        XCTAssertEqual(metadataInput.supportingSources, input.supportingSources)
        let action = try selectedAction(candidate: candidate, scope: scope,
            catalog: ["s1": [], "s2": ["Ali"], "s3": []], ownerName: "Ali", deadline: "by next Friday")
        let meeting = Meeting(title: "Synthetic separated commitment", segments: sources.map {
            .init(id: $0.id, speaker: $0.speaker, start: $0.start, end: $0.end, text: $0.text)
        })
        XCTAssertNoThrow(try LocalSummaryService.validate(notes: notes([action]), meeting: meeting, requireTemplateSections: true))
        var uncited = candidate
        uncited.evidence = ["task-original"]
        let catalog = try LocalSummaryService.parsePersonalNameCatalog(try generated(["s1": [], "s2": ["Ali"], "s3": []]), evidenceScope: scope)
        let uncitedDomain = try LocalSummaryService.personChoiceDomain(candidate: uncited, evidenceScope: scope, catalog: catalog)
        XCTAssertTrue(uncitedDomain.choices.isEmpty, "Uncited assignment names cannot enter the closed owner domain")
        let unsupportedDate = try selectedAction(candidate: uncited, scope: scope,
            catalog: ["s1": [], "s2": ["Ali"], "s3": []], ownerName: nil, deadline: "by next Friday")
        XCTAssertThrowsError(try LocalSummaryService.validate(notes: notes([unsupportedDate]), meeting: meeting, requireTemplateSections: true))
    }

    func testInventoryKeepsTheGlobalTwelveTaskBoundAcrossSourceArraysWithoutTruncation() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        let first = (1...7).map { "Complete operation \($0)." }
        let second = (8...13).map { "Complete operation \($0)." }
        let scope = try LocalSummaryService.evidenceScope(sources: [
            .init(id: "first", speaker: "A", start: 0, end: 2, text: first.joined(separator: " ")),
            .init(id: "second", speaker: "B", start: 3, end: 5, text: second.joined(separator: " "))
        ])
        let items1 = first.map { ["taskClause": $0, "evidence": ["s1"]] as [String: Any] }
        let items2 = second.map { ["taskClause": $0, "evidence": ["s2"]] as [String: Any] }
        let twelve = try LocalSummaryService.convertActionCandidates(try generated(["s1": items1, "s2": Array(items2.prefix(5))]), part: 1, evidenceScope: scope)
        XCTAssertEqual(twelve.count, 12)
        XCTAssertEqual(Set(twelve.map(\.id)).count, 12)
        XCTAssertThrowsError(try LocalSummaryService.convertActionCandidates(try generated(["s1": items1, "s2": items2]), part: 1, evidenceScope: scope),
                            "Thirteen returned tasks must abort, not silently truncate or drop a source")
    }

    func testLiteralClausePreservesUTF8AndBridgesOnlySameAliasFragmentsWithinCurrentScope() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        let prefix = "O\u{0308}deme hatası için "
        let suffix = "bir Jira kaydı açılacak."
        let clause = prefix + suffix
        let fragments: [LocalSummaryService.Source] = [
            .init(id: "same-original", speaker: "A", start: 0, end: 8, text: prefix),
            .init(id: "other-original", speaker: "B", start: 9, end: 10, text: "DO NOT INSERT THIS TEXT"),
            .init(id: "same-original", speaker: "A", start: 0, end: 8, text: suffix)
        ]
        let scope = try LocalSummaryService.evidenceScope(sources: fragments)
        let item: [String: Any] = ["taskClause": clause, "evidence": ["s1"]]
        let result = try LocalSummaryService.convertActionCandidates(try generated(["s1": [item], "s2": []]), part: 1, evidenceScope: scope)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result[0].evidence, ["same-original"])
        XCTAssertEqual(Array(result[0].text.utf8), Array(clause.utf8))
        let normalized = "Ödeme hatası için bir Jira kaydı açılacak."
        XCTAssertEqual(normalized, clause, "These strings are canonically equivalent but have different UTF8 bytes")
        XCTAssertNotEqual(Array(normalized.utf8), Array(clause.utf8))
        let normalizedItem: [String: Any] = ["taskClause": normalized, "evidence": ["s1"]]
        XCTAssertThrowsError(try LocalSummaryService.convertActionCandidates(try generated(["s1": [normalizedItem], "s2": []]), part: 1, evidenceScope: scope))
        let currentChunkOnly = try LocalSummaryService.evidenceScope(sources: [fragments[0]])
        XCTAssertThrowsError(try LocalSummaryService.convertActionCandidates(try generated(["s1": [item]]), part: 1, evidenceScope: currentChunkOnly),
                            "The same original ID must not import unseen text from another chunk")
        let crossAlias = try LocalSummaryService.evidenceScope(sources: [fragments[0],
            .init(id: "different-original", speaker: "B", start: 0, end: 8, text: suffix)])
        XCTAssertThrowsError(try LocalSummaryService.convertActionCandidates(try generated(["s1": [item], "s2": []]), part: 1, evidenceScope: crossAlias),
                            "Text from different aliases must never be concatenated to validate a quote")
    }

    func testCommitmentSchemaRequiresFactualObservationFirstAndTheSameFiveClosedStatesInBothLanguages() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        for language in ["English", "Turkish"] {
            let schema = try commitmentSchema(language: language)
            let fields = try objectFields(schema, required: ["sourceObservation", "commitmentState"])
            XCTAssertEqual(schema["x-order"] as? [String], ["sourceObservation", "commitmentState"])
            let observation = try resolve(try XCTUnwrap(fields["sourceObservation"] as? [String: Any]), in: schema)
            XCTAssertEqual(observation["type"] as? String, "string")
            let observationDescription = try XCTUnwrap(observation["description"] as? String)
            XCTAssertTrue(observationDescription.contains(language == "English" ? "brief factual sentence" : "kısa olgusal cümle"))
            XCTAssertTrue(observationDescription.contains(language == "English" ? "No new facts or step-by-step reasoning" : "Yeni bilgi veya adım adım akıl yürütme üretme"))
            let commitment = try resolve(try XCTUnwrap(fields["commitmentState"] as? [String: Any]), in: schema)
            XCTAssertEqual(try finiteStrings(commitment, in: schema), commitmentStates)
            let description = try XCTUnwrap(commitment["description"] as? String)
            if language == "Turkish" {
                XCTAssertTrue(description.contains("açıkça kararlaştırılmış VEYA üstlenilmiş"))
                XCTAssertTrue(description.contains("kabul edilmemiş/onay bekleyen teklif"))
                XCTAssertTrue(description.contains("Sorumlu/tarih bulunmaması taahhütten bağımsızdır"))
            } else {
                XCTAssertTrue(description.contains("explicitly agreed OR committed concrete future operation, deliverable or investigation"))
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
            mixed["responsibleIdentityKind"] = "not_identified"
            mixed["hasExplicitTaskTime"] = false
            XCTAssertThrowsError(try LocalSummaryService.commitmentAllowsAction(try generated(mixed)),
                                "Metadata presence fields must not influence or be accepted in the commitment result")
        }
    }

    func testLocalizedCommitmentObservationsUseTheSameClosedStateCodesWithoutLocaleFallback() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        let observations = [
            ("agreed_or_committed_future_task", "İş açıkça kararlaştırıldı; sorumlu veya tarih belirtilmedi.", "The work was explicitly agreed; no person or time was stated."),
            ("only_proposed_or_unaccepted", "Yalnız öneri var; işi yapma kararı veya kabulü yok.", "Only a proposal is reported; no decision or acceptance to perform it exists."),
            ("cancelled_or_rejected", "Bu işi yapma kararı iptal edildi; iş yapılmayacak.", "The work was cancelled and will not happen."),
            ("already_completed", "Kaynak, işin zaten tamamlandığını bildiriyor.", "The source reports the work already completed."),
            ("not_a_future_execution_task", "Yalnız durum veya tercih üzerinde anlaşma var; somut uygulama işi bildirilmedi.", "Only a state or preference agreement is reported; no concrete execution work is stated.")
        ]
        for (state, turkish, english) in observations {
            for observation in [turkish, english] {
                let result = try LocalSummaryService.commitmentAllowsAction(try generated([
                    "sourceObservation": observation, "commitmentState": state
                ]))
                XCTAssertEqual(result, state == "agreed_or_committed_future_task",
                               "Instruction/observation language must not change the only positive wire state")
            }
        }
        for localizedAlias in ["kararlaştırıldı", "üstlenildi", "öneri", "iptal_edildi", "tamamlandı", "durum_kararı"] {
            XCTAssertThrowsError(try LocalSummaryService.commitmentAllowsAction(try generated([
                "sourceObservation": "Türkçe bir olgusal gözlem.", "commitmentState": localizedAlias
            ])), "Localized instructions never permit translated enum aliases or a default false result")
        }
    }

    func testCommitmentParserRejectsMissingExtraWrongTypedUnknownAndObsoleteWireWithoutDefaults() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        for invalid in [nil, NSNull(), 42, true, [] as [String], [:] as [String: String]] as [Any?] {
            var value = commitment()
            value["commitmentState"] = invalid
            XCTAssertThrowsError(try LocalSummaryService.commitmentAllowsAction(try generated(value)))
        }
        for state in commitmentStates {
            for invalid in [nil, NSNull(), true, 1, [] as [String], ["text": "observation"], "", " \t\n"] as [Any?] {
                var value = commitment(state)
                value["sourceObservation"] = invalid
                XCTAssertThrowsError(try LocalSummaryService.commitmentAllowsAction(try generated(value)),
                                    "Every state requires a valid factual observation; malformed responses never become false")
            }
        }
        XCTAssertThrowsError(try LocalSummaryService.commitmentAllowsAction(try generated(["commitmentState": "agreed_or_committed_future_task"])),
                            "The old one-field response is no longer valid production wire")
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

    func testWorkNatureSchemaKeepsOnlyTwoClosedStringCodesInBothLanguages() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        for language in ["English", "Turkish"] {
            let schema = try jsonObject(LocalSummaryService.workNatureSchema(language: language))
            let fields = try objectFields(schema, required: ["workKind"])
            XCTAssertEqual(schema["x-order"] as? [String], ["workKind"])
            let kind = try resolve(try XCTUnwrap(fields["workKind"] as? [String: Any]), in: schema)
            XCTAssertEqual(try finiteStrings(kind, in: schema), ["operation_specified", "state_preference_or_discussion"])
            let description = try XCTUnwrap(kind["description"] as? String)
            if language == "Turkish" {
                XCTAssertTrue(description.contains("anlaşma tek başına ayrıca bir müdahale değildir"))
                XCTAssertTrue(description.contains("aynı karar/öneri/üstlenme/iptal/tamamlanma cümlesinde"))
                XCTAssertTrue(description.contains("Yapılmış iş, gelecek zaman eki, kabul kesinliği, sorumlu veya tarih gerekmez"))
                XCTAssertTrue(description.contains("Korunacak sonuçtan işlem türetme"))
                XCTAssertTrue(description.contains("tarif edilmiş müdahale/çıktı/inceleme/bakım-kontrol işlemi"))
            } else {
                XCTAssertTrue(description.contains("agreement alone is not a separate intervention"))
                XCTAssertTrue(description.contains("within the same decision/proposal/undertaking/cancellation/completion statement"))
                XCTAssertTrue(description.contains("Performed work, future tense, acceptance certainty, owner/date are not required"))
                XCTAssertTrue(description.contains("Infer no procedure from a retained outcome"))
                XCTAssertTrue(description.contains("specified intervention/deliverable/investigation/maintenance-checking activity"))
            }
        }
    }

    func testWorkNatureDecoderRejectsMalformedOrUnknownResponsesWithoutDefaultingToAChoice() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        XCTAssertTrue(try LocalSummaryService.workNatureIsExecution(try generated(["workKind": "operation_specified"])))
        XCTAssertFalse(try LocalSummaryService.workNatureIsExecution(try generated(["workKind": "state_preference_or_discussion"])))
        for invalid in [nil, NSNull(), true, false, 0, 1, [], [:], "", "execution", "state", "pending", "agreed_or_committed_future_task", "somut_is", "concrete_execution", "Concrete_execution", "Operation_specified", " operation_specified", "operation_specified "] as [Any?] {
            var wire: [String: Any] = [:]; wire["workKind"] = invalid
            XCTAssertThrowsError(try LocalSummaryService.workNatureIsExecution(try generated(wire)))
        }
        for field in ["sourceObservation", "commitmentState", "status", "personChoice", "hasExplicitTaskTime", "taskTimePhrase", "unexpected"] {
            for extra in [NSNull(), "", true, "not permitted"] as [Any] {
                XCTAssertThrowsError(try LocalSummaryService.workNatureIsExecution(try generated([
                    "workKind": "operation_specified", field: extra
                ])), field)
            }
        }
        for json in ["null", "[]", "true", "42", "\"concrete_execution\""] {
            XCTAssertThrowsError(try LocalSummaryService.workNatureIsExecution(GeneratedContent(json: json)))
        }
    }

    func testSpecifiedOperationDoesNotReplaceTheIndependentFiveStateCommitmentContract() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        let natureOnly = try generated(["workKind": "operation_specified"])
        XCTAssertTrue(try LocalSummaryService.workNatureIsExecution(natureOnly))
        XCTAssertThrowsError(try LocalSummaryService.commitmentAllowsAction(natureOnly))
        for state in ["agreed_or_committed_future_task", "only_proposed_or_unaccepted", "cancelled_or_rejected", "already_completed", "not_a_future_execution_task"] {
            let stateOnly = try generated(commitment(state))
            XCTAssertEqual(try LocalSummaryService.commitmentAllowsAction(stateOnly), state == "agreed_or_committed_future_task")
            XCTAssertThrowsError(try LocalSummaryService.workNatureIsExecution(stateOnly),
                                "Work state cannot substitute for task nature; no source, person or date is inferred")
        }
    }

    func testPersonalNameCatalogSchemaRequiresEveryAliasAndBoundedLiteralNameArrays() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        let schema = try jsonObject(LocalSummaryService.personalNameCatalogSchema(evidenceIDs: ["s1", "s2"]))
        let fields = try objectFields(schema, required: ["s1", "s2"])
        for alias in ["s1", "s2"] {
            let array = try resolve(try XCTUnwrap(fields[alias] as? [String: Any]), in: schema)
            XCTAssertEqual(array["type"] as? String, "array")
            XCTAssertEqual(array["minItems"] as? Int, 0)
            XCTAssertEqual(array["maxItems"] as? Int, 6)
            let name = try resolve(try XCTUnwrap(array["items"] as? [String: Any]), in: schema)
            XCTAssertEqual(name["type"] as? String, "string")
        }
        for aliases in [[], [""], ["s1", "s1"], ["original-a"], ["s0"], ["s1\n"]] as [[String]] {
            XCTAssertThrowsError(try LocalSummaryService.personalNameCatalogSchema(evidenceIDs: aliases))
        }
    }

    func testCatalogInputIncludesOnlyOwnedTextAndPreservesSameAliasFragmentOrder() throws {
        let scope = try LocalSummaryService.evidenceScope(sources: [
            .init(id: "first", speaker: "A", start: 0, end: 3, text: "Ay", providedSpeakerName: "Deniz"),
            .init(id: "other", speaker: "B", start: 4, end: 5, text: "An unrelated source."),
            .init(id: "first", speaker: "A", start: 0, end: 3, text: "şe will prepare it.", providedSpeakerName: "Deniz")
        ])
        let input = LocalSummaryService.personalNameCatalogInput(evidenceScope: scope)
        let rows = try XCTUnwrap(JSONSerialization.jsonObject(with: LocalSummaryService.modelInputData(input)) as? [[String: Any]])
        let canonical = String(decoding: try LocalSummaryService.modelInputData(input), as: UTF8.self)
        let prompt = try LocalSummaryService.personalNameCatalogPrompt(evidenceScope: scope)
        XCTAssertTrue(prompt.hasSuffix(canonical), "The actual catalog request must use the canonical encoder and complete text input")
        for _ in 0..<32 {
            XCTAssertEqual(try LocalSummaryService.personalNameCatalogPrompt(evidenceScope: scope), prompt)
        }
        XCTAssertEqual(rows.count, 2)
        XCTAssertEqual(rows.compactMap { $0["sourceAlias"] as? String }, ["s1", "s2"])
        XCTAssertEqual(rows.compactMap { $0["text"] as? String }, ["Ayşe will prepare it.", "An unrelated source."])
        XCTAssertEqual(rows.filter { $0["sourceAlias"] as? String == "s1" }.compactMap { $0["text"] as? String }.joined(), "Ayşe will prepare it.")
        for row in rows {
            XCTAssertEqual(Set(row.keys), ["sourceAlias", "text", "leadingWholeWordBoundary", "trailingWholeWordBoundary"])
            for forbidden in ["speaker", "speakerLabel", "providedSpeakerName", "start", "end", "sourcePosition"] {
                XCTAssertNil(row[forbidden], "Name recognition must not receive channel labels or metadata as text names")
            }
        }
    }

    func testCatalogRequiresLiteralOwnedUTF8SpansAndDistinguishesEmptyFromMalformed() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        let scope = try LocalSummaryService.evidenceScope(sources: [
            .init(id: "first", speaker: "A", start: 0, end: 3, text: "Ay"),
            .init(id: "other", speaker: "B", start: 4, end: 5, text: "Mert accepted another task."),
            .init(id: "first", speaker: "A", start: 0, end: 3, text: "şe and O\u{0308}mer will prepare it.")
        ])
        let catalog = try LocalSummaryService.parsePersonalNameCatalog(try generated(["s1": ["Ayşe", "O\u{0308}mer"], "s2": ["Mert"]]), evidenceScope: scope)
        XCTAssertEqual(catalog.namesByAlias["s1"], ["Ayşe", "O\u{0308}mer"])
        XCTAssertEqual(catalog.namesByAlias["s2"], ["Mert"])
        let empty = try LocalSummaryService.parsePersonalNameCatalog(try generated(["s1": [], "s2": []]), evidenceScope: scope)
        XCTAssertTrue(empty.namesByAlias.values.allSatisfy(\.isEmpty))
        let invalid: [[String: Any]] = [
            [:], ["s1": []], ["s1": [], "s2": [], "s3": []], ["personalNames": []],
            ["original-a": [], "s2": []], ["S1": [], "s2": []],
            ["s1": NSNull(), "s2": []], ["s1": "Ayşe", "s2": []], ["s1": [:], "s2": []],
            ["s1": [NSNull()], "s2": []], ["s1": [1], "s2": []], ["s1": [true], "s2": []],
            ["s1": [["name": "Ayşe"]], "s2": []], ["s1": [""], "s2": []], ["s1": [" \t\n"], "s2": []],
            ["s1": ["Mert"], "s2": []], ["s1": ["Ayşe Mert"], "s2": []],
            ["s1": ["Ömer"], "s2": []], ["s1": ["B"], "s2": []],
            ["s1": Array(repeating: "Ayşe", count: 7), "s2": []]
        ]
        for wire in invalid {
            XCTAssertThrowsError(try LocalSummaryService.parsePersonalNameCatalog(try generated(wire), evidenceScope: scope))
        }
        for json in ["null", "[]", "true", "42", "\"Ayşe\""] {
            XCTAssertThrowsError(try LocalSummaryService.parsePersonalNameCatalog(GeneratedContent(json: json), evidenceScope: scope))
        }
        let earlierChunk = try LocalSummaryService.evidenceScope(sources: [scope.sources[0]])
        XCTAssertThrowsError(try LocalSummaryService.parsePersonalNameCatalog(try generated(["s1": ["Ayşe"]]), evidenceScope: earlierChunk),
                            "A shared original ID cannot import a name from unseen fragments")
    }

    func testCatalogRetainsRepeatedReturnedNamesAsDistinctChoicesWithoutSilentDeduplication() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        let scope = try sourceScope()
        let repeated = Array(repeating: "Ali", count: 6)
        let catalog = try LocalSummaryService.parsePersonalNameCatalog(try generated(["s1": [], "s2": repeated]), evidenceScope: scope)
        XCTAssertEqual(catalog.namesByAlias["s2"], repeated)
        let candidate = LocalSummaryService.ActionCandidate(id: "repeated-names", text: "Revise the design.", evidence: ["original-b"])
        let domain = try LocalSummaryService.personChoiceDomain(candidate: candidate, evidenceScope: scope, catalog: catalog)
        XCTAssertEqual(domain.choices.map(\.name), repeated)
        XCTAssertEqual(Set(domain.choices.map(\.id)).count, repeated.count)
        let changedScope = try LocalSummaryService.evidenceScope(sources: [
            .init(id: "original-a", speaker: "A", start: 0, end: 3, text: "First source."),
            .init(id: "original-b", speaker: "B", start: 4, end: 7, text: "No supplied personal name in this chunk.")
        ])
        XCTAssertThrowsError(try LocalSummaryService.personChoiceDomain(candidate: candidate, evidenceScope: changedScope, catalog: catalog),
                            "A catalog validated in another source scope must not import unseen names")
    }

    func testClosedPersonDomainUsesEveryCitedSourceAndPreservesNameProvenance() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        let scope = try LocalSummaryService.evidenceScope(sources: [
            .init(id: "task", speaker: "A", start: 0, end: 2, text: "I will update the guide.", providedSpeakerName: "Deniz"),
            .init(id: "assignment", speaker: "B", start: 3, end: 5, text: "Ayşe accepted that work."),
            .init(id: "unrelated", speaker: "C", start: 6, end: 7, text: "Mert will do something else.", providedSpeakerName: "Selin")
        ])
        let catalog = try LocalSummaryService.parsePersonalNameCatalog(try generated(["s1": [], "s2": ["Ayşe"], "s3": ["Mert"]]), evidenceScope: scope)
        let candidate = LocalSummaryService.ActionCandidate(id: "cross-source", text: "Update the guide.", evidence: ["assignment", "task"])
        let domain = try LocalSummaryService.personChoiceDomain(candidate: candidate, evidenceScope: scope, catalog: catalog)
        XCTAssertEqual(domain.candidateID, candidate.id)
        XCTAssertEqual(Set(domain.candidateEvidence), Set(candidate.evidence))
        XCTAssertEqual(Set(domain.choices.map(\.name)), ["Deniz", "Ayşe"])
        XCTAssertEqual(Set(domain.choices.map(\.id)).count, domain.choices.count)
        XCTAssertFalse(domain.choices.contains { $0.name == "Mert" || $0.name == "Selin" || $0.name == "A" })
        let explicit = try XCTUnwrap(domain.choices.first { $0.name == "Ayşe" })
        XCTAssertEqual(explicit.sourceAlias, "s2")
        XCTAssertEqual(explicit.provenance, .sourceText)
        let mapped = try XCTUnwrap(domain.choices.first { $0.name == "Deniz" })
        XCTAssertEqual(mapped.sourceAlias, "s1")
        XCTAssertEqual(mapped.provenance, .providedSpeakerName)
        let ownerInput = try LocalSummaryService.ownerChoiceInput(candidate: candidate, evidenceScope: scope, domain: domain)
        XCTAssertEqual(ownerInput.supportingSources.map(\.id), ["s1", "s2"])
        XCTAssertEqual(ownerInput.personChoices, domain.choices)
        let ownerObject = try jsonObject(ownerInput)
        XCTAssertEqual(Set(ownerObject.keys), ["candidate", "supportingSources", "personChoices"])
        XCTAssertNil(ownerObject["otherSources"])
        let choices = try XCTUnwrap(ownerObject["personChoices"] as? [[String: Any]])
        for choice in choices { XCTAssertEqual(Set(choice.keys), ["id", "name", "sourceAlias", "provenance"]) }
        let reversed = LocalSummaryService.ActionCandidate(id: candidate.id, text: candidate.text, evidence: Array(candidate.evidence.reversed()))
        let repeated = try LocalSummaryService.personChoiceDomain(candidate: reversed, evidenceScope: scope, catalog: catalog)
        XCTAssertEqual(domain.choices, repeated.choices, "Evidence array order must not silently reassign closed person IDs")
        for evidence in [[], ["foreign-source"], ["task", "foreign-source"], ["s1"]] as [[String]] {
            let invalid = LocalSummaryService.ActionCandidate(id: "invalid", text: "A task.", evidence: evidence)
            XCTAssertThrowsError(try LocalSummaryService.personChoiceDomain(candidate: invalid, evidenceScope: scope, catalog: catalog))
        }
    }

    func testProvidedNamesKeepTypedProvenanceAndOnlyBlankUserFieldsAreAbsent() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        for mapping in [nil, "", " \t\n", " Ali "] as [String?] {
            let scope = try LocalSummaryService.evidenceScope(sources: [
                .init(id: "original-a", speaker: "A", start: 0, end: 3, text: "I accepted the task.", providedSpeakerName: mapping)
            ])
            let catalog = try LocalSummaryService.parsePersonalNameCatalog(try generated(["s1": []]), evidenceScope: scope)
            let domain = try LocalSummaryService.personChoiceDomain(candidate: sampleCandidate(), evidenceScope: scope, catalog: catalog)
            if mapping == " Ali " {
                XCTAssertEqual(domain.choices.map(\.name), [" Ali "], "A nonblank user value is preserved exactly, not cleaned as a model repair")
                XCTAssertTrue(domain.choices.allSatisfy { $0.provenance == .providedSpeakerName })
            } else {
                XCTAssertTrue(domain.choices.isEmpty)
            }
        }
    }

    func testOwnerSchemaIsClosedAndOnlyExplicitNoneOrAValidatedChoiceCanResolve() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        let scope = try sourceScope()
        let candidate = LocalSummaryService.ActionCandidate(id: "named", text: "Revise the design.", evidence: ["original-b"])
        let catalog = try LocalSummaryService.parsePersonalNameCatalog(try generated(["s1": [], "s2": ["Ali"]]), evidenceScope: scope)
        let domain = try LocalSummaryService.personChoiceDomain(candidate: candidate, evidenceScope: scope, catalog: catalog)
        let person = try XCTUnwrap(domain.choices.first)
        let schema = try jsonObject(LocalSummaryService.ownerChoiceSchema(domain: domain))
        let fields = try objectFields(schema, required: ["sourceObservation", "personChoice"])
        XCTAssertEqual(schema["x-order"] as? [String], ["sourceObservation", "personChoice"])
        let choice = try resolve(try XCTUnwrap(fields["personChoice"] as? [String: Any]), in: schema)
        XCTAssertEqual(try finiteStrings(choice, in: schema), Set(domain.choices.map(\.id)).union(["none"]))
        let owner = try LocalSummaryService.resolveOwnerChoice(try generated(observedChoice(person.id)), domain: domain)
        XCTAssertEqual(owner.name, "Ali")
        let none = try LocalSummaryService.resolveOwnerChoice(try generated(observedChoice("none")), domain: domain)
        XCTAssertNil(none.name)
        XCTAssertThrowsError(try LocalSummaryService.resolveOwnerChoice(nil, domain: domain),
                            "A nonempty domain needs an explicit valid choice, including an explicit none")
        let another = LocalSummaryService.ActionCandidate(id: "another-task", text: candidate.text, evidence: candidate.evidence)
        let foreignDomain = try LocalSummaryService.personChoiceDomain(candidate: another, evidenceScope: scope, catalog: catalog)
        let foreignID = try XCTUnwrap(foreignDomain.choices.first).id
        XCTAssertThrowsError(try LocalSummaryService.resolveOwnerChoice(try generated(observedChoice(foreignID)), domain: domain))
        for json in ["null", "[]", "true", "42", "\"none\""] {
            XCTAssertThrowsError(try LocalSummaryService.resolveOwnerChoice(GeneratedContent(json: json), domain: domain))
        }
        for invalid in [nil, NSNull(), true, 1, [], [:], "", "Ali", "original-b", "s2", "foreign-person", "None", " none", "none "] as [Any?] {
            var wire = observedChoice("none"); wire["personChoice"] = invalid
            XCTAssertThrowsError(try LocalSummaryService.resolveOwnerChoice(try generated(wire), domain: domain))
        }
        for invalid in [nil, NSNull(), true, 1, [], [:], "", " \t\n"] as [Any?] {
            var wire = observedChoice(person.id); wire["sourceObservation"] = invalid
            XCTAssertThrowsError(try LocalSummaryService.resolveOwnerChoice(try generated(wire), domain: domain))
        }
        for field in ["owner", "responsiblePersonName", "responsibleIdentityKind", "hasExplicitTaskTime", "taskTimePhrase", "commitmentState", "unexpected"] {
            var wire = observedChoice(person.id); wire[field] = "not permitted"
            XCTAssertThrowsError(try LocalSummaryService.resolveOwnerChoice(try generated(wire), domain: domain))
        }
    }

    func testValidatedEmptyPersonDomainRequiresSkippingTheOwnerRequestAndDoesNotMaskMalformedCatalogs() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        let scope = try sourceScope()
        let catalog = try LocalSummaryService.parsePersonalNameCatalog(try generated(["s1": [], "s2": []]), evidenceScope: scope)
        let domain = try LocalSummaryService.personChoiceDomain(candidate: sampleCandidate(), evidenceScope: scope, catalog: catalog)
        XCTAssertTrue(domain.choices.isEmpty)
        XCTAssertThrowsError(try LocalSummaryService.ownerChoiceSchema(domain: domain))
        XCTAssertNil(try LocalSummaryService.resolveOwnerChoice(nil, domain: domain).name)
        for wire in [[:], observedChoice("none"), ["personChoice": "none"], ["owner": "A"]] {
            XCTAssertThrowsError(try LocalSummaryService.resolveOwnerChoice(try generated(wire), domain: domain),
                                "Validated absence permits no request; unsolicited or malformed output is not converted to nil")
        }
    }

    func testTimePresenceSchemaAndParserRequireOnlyAnExactBooleanWithoutDefaultsOrObservation() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        for language in ["English", "Turkish"] {
            let schema = try jsonObject(LocalSummaryService.timePresenceSchema(language: language))
            let fields = try objectFields(schema, required: ["hasExplicitTaskTime"])
            XCTAssertEqual(schema["x-order"] as? [String], ["hasExplicitTaskTime"])
            let bool = try resolve(try XCTUnwrap(fields["hasExplicitTaskTime"] as? [String: Any]), in: schema)
            XCTAssertEqual(try booleanDomain(bool, in: schema), [false, true])
            let description = try XCTUnwrap(bool["description"] as? String)
            if language == "Turkish" {
                XCTAssertTrue(description.contains("olaydan önce/sonra"))
                XCTAssertTrue(description.contains("Kesin tarih gerekmez"))
                XCTAssertTrue(description.contains("Ölçüm/konu süresi, zaman yokluğu"))
            } else {
                XCTAssertTrue(description.contains("before/after-event timing"))
                XCTAssertTrue(description.contains("No precise date required"))
                XCTAssertTrue(description.contains("Measurements/subject durations, absence"))
            }
        }
        XCTAssertThrowsError(try LocalSummaryService.parseTimePresence(try generated(["hasTemporalDeadline": true])),
                             "The former deadline flag is not a compatibility alias")
        for json in ["null", "[]", "true", "42", "\"false\""] {
            XCTAssertThrowsError(try LocalSummaryService.parseTimePresence(GeneratedContent(json: json)))
        }
        for flag in [false, true] {
            let valid = observedTime(flag)
            XCTAssertEqual(try LocalSummaryService.parseTimePresence(try generated(valid)).hasExplicitTaskTime, flag)
            for invalid in [nil, NSNull(), "true", "false", 0, 1, [], [:]] as [Any?] {
                var wire = valid; wire["hasExplicitTaskTime"] = invalid
                XCTAssertThrowsError(try LocalSummaryService.parseTimePresence(try generated(wire)))
            }
            for extra in [NSNull(), true, 1, [], [:], "", "A factual observation."] as [Any] {
                var oldWire = valid; oldWire["sourceObservation"] = extra
                XCTAssertThrowsError(try LocalSummaryService.parseTimePresence(try generated(oldWire)),
                                     "The previous observation-and-flag shape is forbidden, not ignored")
            }
            for field in ["responsibleIdentityKind", "hasResponsiblePersonName", "personChoice", "taskTimePhrase", "hasTemporalDeadline", "deadlinePhrase", "commitmentState", "workKind", "unexpected"] {
                var wire = valid; wire[field] = "not permitted"
                XCTAssertThrowsError(try LocalSummaryService.parseTimePresence(try generated(wire)))
            }
        }
    }

    func testOnlyValidatedTrueTimePresenceAcceptsAStrictNonblankTaskTimeValue() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        let absent = try LocalSummaryService.parseTimePresence(try generated(observedTime(false)))
        XCTAssertNil(try LocalSummaryService.taskTimeValue(nil, presence: absent))
        for wire in [[:], ["taskTimePhrase": ""], ["taskTimePhrase": "tomorrow"], ["deadline": ["type": "notStated"]]] as [[String: Any]] {
            XCTAssertThrowsError(try LocalSummaryService.taskTimeValue(try generated(wire), presence: absent))
        }
        let schema = try jsonObject(LocalSummaryService.taskTimeValuesSchema())
        let fields = try objectFields(schema, required: ["taskTimePhrase"])
        let valueSchema = try resolve(try XCTUnwrap(fields["taskTimePhrase"] as? [String: Any]), in: schema)
        XCTAssertEqual(valueSchema["type"] as? String, "string")
        let present = try LocalSummaryService.parseTimePresence(try generated(observedTime(true)))
        XCTAssertThrowsError(try LocalSummaryService.taskTimeValue(try generated(["deadlinePhrase": "tomorrow"]), presence: present),
                            "The former deadline-only value key is not a valid compatibility alias")
        XCTAssertThrowsError(try LocalSummaryService.taskTimeValue(nil, presence: present))
        for json in ["null", "[]", "true", "42", "\"tomorrow\""] {
            XCTAssertThrowsError(try LocalSummaryService.taskTimeValue(GeneratedContent(json: json), presence: present))
        }
        for literal in ["cuma günü", "yeni sürümden önce", "by next Friday", " yarına kadar "] {
            XCTAssertEqual(try LocalSummaryService.taskTimeValue(try generated(["taskTimePhrase": literal]), presence: present), literal,
                           "Literal time text must not be trimmed, translated or converted to a guessed date")
        }
        for invalid in [nil, NSNull(), true, 1, [], [:], "", " \t\n"] as [Any?] {
            var wire: [String: Any] = [:]; wire["taskTimePhrase"] = invalid
            XCTAssertThrowsError(try LocalSummaryService.taskTimeValue(try generated(wire), presence: present))
        }
        for field in ["owner", "responsiblePersonName", "sourceObservation", "hasExplicitTaskTime", "hasTemporalDeadline", "deadlinePhrase", "deadline", "type", "verbatimValue", "commitmentState", "unexpected"] {
            for extra in [NSNull(), "", "stray value"] as [Any] {
                XCTAssertThrowsError(try LocalSummaryService.taskTimeValue(try generated(["taskTimePhrase": "tomorrow", field: extra]), presence: present), field)
            }
        }
    }

    func testEveryOwnerAndTimeCombinationPreservesTaskArchiveFieldsAndCandidateBinding() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        let scope = try sourceScope()
        let candidate = LocalSummaryService.ActionCandidate(id: "original-candidate", text: " Revise the design. \n", evidence: ["original-b", "original-a"])
        for named in [false, true] {
            for deadline in [false, true] {
                let action = try selectedAction(candidate: candidate, scope: scope,
                    catalog: ["s1": [], "s2": named ? ["Ali"] : []], ownerName: named ? "Ali" : nil,
                    deadline: deadline ? "by next Friday" : nil)
                XCTAssertEqual(action.id, candidate.id)
                XCTAssertEqual(action.text, candidate.text)
                XCTAssertEqual(action.evidence, candidate.evidence)
                XCTAssertEqual(action.owner, named ? "Ali" : nil)
                XCTAssertEqual(action.due, deadline ? "by next Friday" : nil)
                XCTAssertEqual(try JSONDecoder().decode(ActionItem.self, from: JSONEncoder().encode(action)), action)
                let archive = try jsonObject(action)
                for field in ["sourceObservation", "personChoice", "responsibleIdentityKind", "hasExplicitTaskTime", "responsiblePersonName", "taskTimePhrase"] {
                    XCTAssertNil(archive[field], "Generation-only protocol fields must not change the persisted action format")
                }
            }
        }
        let catalog = try LocalSummaryService.parsePersonalNameCatalog(try generated(["s1": [], "s2": ["Ali"]]), evidenceScope: scope)
        let domain = try LocalSummaryService.personChoiceDomain(candidate: candidate, evidenceScope: scope, catalog: catalog)
        let owner = try LocalSummaryService.resolveOwnerChoice(try generated(observedChoice(try XCTUnwrap(domain.choices.first).id)), domain: domain)
        var wrongID = candidate; wrongID.id = "other-candidate"
        XCTAssertThrowsError(try LocalSummaryService.actionFromSelections(candidate: wrongID, owner: owner, deadline: nil))
        XCTAssertThrowsError(try LocalSummaryService.ownerChoiceInput(candidate: wrongID, evidenceScope: scope, domain: domain))
        var wrongEvidence = candidate; wrongEvidence.evidence = ["original-a"]
        XCTAssertThrowsError(try LocalSummaryService.actionFromSelections(candidate: wrongEvidence, owner: owner, deadline: nil))
        XCTAssertThrowsError(try LocalSummaryService.ownerChoiceInput(candidate: wrongEvidence, evidenceScope: scope, domain: domain))
        var wrongText = candidate; wrongText.text = "Notify a different customer."
        XCTAssertThrowsError(try LocalSummaryService.ownerChoiceInput(candidate: wrongText, evidenceScope: scope, domain: domain),
                            "An owner-choice domain belongs to the exact task text, even if ID and evidence are reused")
        XCTAssertThrowsError(try LocalSummaryService.actionFromSelections(candidate: wrongText, owner: owner, deadline: nil))
        let explicitNone = try LocalSummaryService.resolveOwnerChoice(try generated(observedChoice("none")), domain: domain)
        XCTAssertThrowsError(try LocalSummaryService.actionFromSelections(candidate: wrongText, owner: explicitNone, deadline: nil))
        let emptyCatalog = try LocalSummaryService.parsePersonalNameCatalog(try generated(["s1": [], "s2": []]), evidenceScope: scope)
        let emptyDomain = try LocalSummaryService.personChoiceDomain(candidate: candidate, evidenceScope: scope, catalog: emptyCatalog)
        let absentOwner = try LocalSummaryService.resolveOwnerChoice(nil, domain: emptyDomain)
        XCTAssertThrowsError(try LocalSummaryService.ownerChoiceInput(candidate: wrongText, evidenceScope: scope, domain: emptyDomain))
        XCTAssertThrowsError(try LocalSummaryService.actionFromSelections(candidate: wrongText, owner: absentOwner, deadline: nil),
                            "Skipping an empty owner domain must not weaken exact candidate binding")
    }

    func testVerbatimTaskSchedulesRemainGroundedAndUnsupportedDatesStillAbort() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        for (text, literal) in [
            ("Ekip, yeni sürümden önce erişilebilirlik kontrolü yapılmasını kararlaştırdı.", "yeni sürümden önce"),
            ("Mert, arama performansını araştırıp sonuçları cuma günü paylaşmayı üstlendi.", "cuma günü")
        ] {
            let scope = try LocalSummaryService.evidenceScope(sources: [.init(id: "source", speaker: "A", start: 0, end: 5, text: text)])
            let candidate = LocalSummaryService.ActionCandidate(id: "scheduled", text: text, evidence: ["source"])
            let action = try selectedAction(candidate: candidate, scope: scope, catalog: ["s1": []], ownerName: nil, deadline: literal)
            XCTAssertEqual(action.due, literal)
            let meeting = Meeting(title: "Synthetic agreed task time", segments: [.init(id: "source", speaker: "A", start: 0, end: 5, text: text)])
            XCTAssertNoThrow(try LocalSummaryService.validate(notes: notes([action]), meeting: meeting, requireTemplateSections: true))
        }
        let scope = try sourceScope()
        let candidate = sampleCandidate()
        let meeting = Meeting(title: "Synthetic scoped task", segments: [
            .init(id: "original-a", speaker: "A", start: 0, end: 3, text: "The team agreed to revise the design; no date was set."),
            .init(id: "original-b", speaker: "B", start: 4, end: 7, text: "Ali will revise the design by next Friday.")
        ])
        for unsupported in ["null", "None", "Belirtilmedi", "nil", "N/A", "2030-01-01", "next Friday"] {
            let action = try selectedAction(candidate: candidate, scope: scope, catalog: ["s1": [], "s2": []], ownerName: nil, deadline: unsupported)
            XCTAssertEqual(action.due, unsupported)
            XCTAssertThrowsError(try LocalSummaryService.validate(notes: notes([action]), meeting: meeting, requireTemplateSections: true))
        }
        var fragmented = meeting
        fragmented.segments[0].text += " by next Friday"
        let action = try selectedAction(candidate: candidate, scope: scope, catalog: ["s1": [], "s2": []], ownerName: nil, deadline: "next Friday")
        XCTAssertThrowsError(try LocalSummaryService.validate(notes: notes([action]), meeting: fragmented,
            scopedText: ["original-a": meeting.segments[0].text], requireTemplateSections: true))
    }

    func testProvidedMappedNameCanBeSelectedWithoutExposingRawSpeakerLabel() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        let source = LocalSummaryService.Source(id: "original-a", speaker: "A", start: 0, end: 3, text: "I commit to revising the design.", providedSpeakerName: "Ali")
        let scope = try LocalSummaryService.evidenceScope(sources: [source])
        let action = try selectedAction(candidate: sampleCandidate(), scope: scope, catalog: ["s1": []], ownerName: "Ali", deadline: nil)
        var meeting = Meeting(title: "Synthetic explicit speaker mapping", segments: [.init(id: source.id, speaker: source.speaker, start: source.start, end: source.end, text: source.text)])
        meeting.speakerNames = ["A": "Ali"]
        XCTAssertEqual(action.owner, "Ali")
        XCTAssertNoThrow(try LocalSummaryService.validate(notes: notes([action]), meeting: meeting, requireTemplateSections: true))
        meeting.speakerNames = [:]
        XCTAssertThrowsError(try LocalSummaryService.validate(notes: notes([action]), meeting: meeting, requireTemplateSections: true))
        let unmappedScope = try LocalSummaryService.evidenceScope(sources: [.init(id: source.id, speaker: "A", start: source.start, end: source.end, text: source.text)])
        let catalog = try LocalSummaryService.parsePersonalNameCatalog(try generated(["s1": []]), evidenceScope: unmappedScope)
        let domain = try LocalSummaryService.personChoiceDomain(candidate: sampleCandidate(), evidenceScope: unmappedScope, catalog: catalog)
        XCTAssertTrue(domain.choices.isEmpty)
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

    func testNatureContentInputRetainsAllCitedFragmentsWhileCommitmentKeepsLaterCancellation() throws {
        let sources: [LocalSummaryService.Source] = [
            .init(id: "operation", speaker: "A", start: 0, end: 2, text: "Leila will inspect ", providedSpeakerName: "Leila"),
            .init(id: "later-status", speaker: "B", start: 9, end: 10, text: "The inspection was later cancelled."),
            .init(id: "assignment", speaker: "C", start: 3, end: 4, text: "Leila accepted this work."),
            .init(id: "operation", speaker: "A", start: 0, end: 2, text: "the storage diagram.", providedSpeakerName: "Leila")
        ]
        let scope = try LocalSummaryService.evidenceScope(sources: sources)
        let candidate = LocalSummaryService.ActionCandidate(id: "operation-task", text: "Inspect the storage diagram.",
                                                            evidence: ["assignment", "operation"])
        // These are the actual production builders used by the two distinct requests.
        let nature = try LocalSummaryService.actionMetadataInput(candidate: candidate, evidenceScope: scope)
        let commitment = try LocalSummaryService.actionAssessmentInput(candidate: candidate, evidenceScope: scope)
        XCTAssertEqual(nature.candidate, commitment.candidate)
        XCTAssertEqual(nature.candidate.id, candidate.id)
        XCTAssertEqual(nature.candidate.text, candidate.text)
        XCTAssertEqual(nature.supportingSources.map(\.sourcePosition), [0, 2, 3])
        XCTAssertEqual(nature.supportingSources.map(\.text), [sources[0].text, sources[2].text, sources[3].text])
        XCTAssertEqual(nature.supportingSources, commitment.supportingSources)
        XCTAssertEqual(commitment.otherSources.map(\.text), [sources[1].text],
                       "Nature scope reduction must not remove a later cancellation from commitment")
        let object = try jsonObject(nature)
        XCTAssertEqual(Set(object.keys), ["candidate", "supportingSources"])
        XCTAssertNil(object["otherSources"])
        let bytes = try LocalSummaryService.modelInputData(nature)
        XCTAssertFalse(String(decoding: bytes, as: UTF8.self).contains(sources[1].text))
        XCTAssertEqual(commitment.supportingSources.count + commitment.otherSources.count, sources.count)
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
        let scope = try LocalSummaryService.evidenceScope(sources: [
            .init(id: "shared", speaker: "A", start: 0, end: 5,
                  text: "Sunumu hazırlama işini iptal ettik. Selin, iptal kararını müşteriye yarın bildirmeyi üstlendi.")
        ])
        let action = try selectedAction(candidate: pending, scope: scope, catalog: ["s1": ["Selin"]], ownerName: "Selin", deadline: "yarın")
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
        ["sourceObservation": "The source reports the task and its latest agreement state.", "commitmentState": state]
    }
    private func observedChoice(_ id: String) -> [String: Any] {
        ["sourceObservation": "The cited source identifies the responsible person or records no named assignment.", "personChoice": id]
    }
    private func observedTime(_ present: Bool) -> [String: Any] {
        ["hasExplicitTaskTime": present]
    }
    @available(macOS 26.0, *)
    private func selectedAction(candidate: LocalSummaryService.ActionCandidate, scope: LocalSummaryService.EvidenceScope,
                                catalog wire: [String: Any], ownerName: String?, deadline: String?) throws -> ActionItem {
        let catalog = try LocalSummaryService.parsePersonalNameCatalog(try generated(wire), evidenceScope: scope)
        let domain = try LocalSummaryService.personChoiceDomain(candidate: candidate, evidenceScope: scope, catalog: catalog)
        let response: GeneratedContent?
        if domain.choices.isEmpty {
            XCTAssertNil(ownerName)
            response = nil
        } else {
            let id = try ownerName.map { name in try XCTUnwrap(domain.choices.first { $0.name == name }).id } ?? "none"
            response = try generated(observedChoice(id))
        }
        let owner = try LocalSummaryService.resolveOwnerChoice(response, domain: domain)
        let presence = try LocalSummaryService.parseTimePresence(try generated(observedTime(deadline != nil)))
        let timeResponse = try deadline.map { try generated(["taskTimePhrase": $0]) }
        let time = try LocalSummaryService.taskTimeValue(timeResponse, presence: presence)
        return try LocalSummaryService.actionFromSelections(candidate: candidate, owner: owner, deadline: time)
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
