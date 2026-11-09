import XCTest
import FoundationModels
@testable import MeetingDesk

/// Synthetic generated content checks schema/conversion contracts. These tests
/// cannot establish action recall from a language model; native fixtures do that.
final class LocalSummaryGenerationSchemaTests: XCTestCase {
    private let categories = ["actions", "decisions", "questions", "ideas", "topics"]

    func testEachCategoryHasAnIndependentRequiredArrayAndOnlyTopicsUseTemplateSections() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        let everySection = Set(MeetingTemplate.allCases.flatMap { $0.contextSections.map(\.id) })
        for template in MeetingTemplate.allCases {
            let schema = try schemaObject(for: template)
            let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
            XCTAssertEqual(Set(properties.keys), Set(categories + ["summary"]))
            XCTAssertEqual(Set(try XCTUnwrap(schema["required"] as? [String])), Set(categories + ["summary"]))
            XCTAssertNil(properties["items"], "A shared item inventory lets context topics displace actions")
            for category in categories {
                let array = try resolve(try XCTUnwrap(properties[category] as? [String: Any]), in: schema)
                XCTAssertEqual(array["type"] as? String, "array")
                XCTAssertEqual(array["maxItems"] as? Int, 12)
                XCTAssertEqual(array["minItems"] as? Int, 0, "Absent categories must explicitly allow an empty inventory")
                let item = try resolve(try XCTUnwrap(array["items"] as? [String: Any]), in: schema)
                XCTAssertNil(item["anyOf"], "Each category has its own structure, not a topic-first category union")
                XCTAssertEqual(item["additionalProperties"] as? Bool, false)
                let fields = try XCTUnwrap(item["properties"] as? [String: Any])
                XCTAssertNil(fields["category"], "The array defines category; the model must not classify each item again")
                let required = Set(try XCTUnwrap(item["required"] as? [String]))
                XCTAssertTrue(required.isSuperset(of: ["text", "evidence"]))
                let evidence = try resolve(try XCTUnwrap(fields["evidence"] as? [String: Any]), in: schema)
                XCTAssertEqual(evidence["minItems"] as? Int, 1)
                XCTAssertEqual(evidence["maxItems"] as? Int, 4)
                if category == "topics" {
                    XCTAssertTrue(required.isSuperset(of: ["title", "sectionID"]))
                    let choices = try finiteStringDomain(try XCTUnwrap(fields["sectionID"] as? [String: Any]), in: schema)
                    let expected = Set(template.contextSections.map(\.id))
                    XCTAssertEqual(choices, expected, template.rawValue)
                    XCTAssertTrue(choices.isDisjoint(with: everySection.subtracting(expected)))
                } else {
                    XCTAssertNil(fields["sectionID"])
                    XCTAssertNil(fields["title"])
                }
                if category == "actions" {
                    XCTAssertNotNil(fields["responsiblePersonName"])
                    XCTAssertNotNil(fields["deadlinePhrase"])
                    for metadata in ["responsiblePersonName", "deadlinePhrase"] {
                        let field = try resolve(try XCTUnwrap(fields[metadata] as? [String: Any]), in: schema)
                        XCTAssertTrue(required.contains(metadata),
                                      "Guided generation must consider \(metadata) instead of silently omitting it")
                        XCTAssertEqual(field["type"] as? String, "string",
                                       "Action metadata uses a required string with an exact empty-string absence marker")
                        XCTAssertFalse(try permitsNull(field, in: schema),
                                       "The generated wire format must not offer a nullable alternative")
                    }
                } else {
                    XCTAssertNil(fields["responsiblePersonName"])
                    XCTAssertNil(fields["deadlinePhrase"])
                }
            }
        }
    }

    func testAllSelectedSectionsSurviveConversionWithGroundedActionsAndStableEvidence() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        for template in MeetingTemplate.allCases {
            let notes = try LocalSummaryService.convert(try generated(payload(for: template)), part: 2)
            XCTAssertEqual(notes.topics.map(\.sectionID), template.contextSections.map { Optional($0.id) })
            XCTAssertEqual(notes.topics.map(\.title), template.contextSections.map { "Synthetic \($0.id) context" })
            XCTAssertEqual(notes.decisions.count, 1)
            XCTAssertEqual(notes.actions.count, 1)
            XCTAssertEqual(notes.questions.count, 1)
            XCTAssertEqual(notes.ideas.count, 1)
            XCTAssertEqual(notes.actions.first?.owner, "Ali")
            XCTAssertEqual(notes.actions.first?.due, "next Friday")
            XCTAssertTrue(notes.topics.allSatisfy { $0.evidence == ["s1"] })
            XCTAssertEqual(Set(allIDs(notes)).count, allIDs(notes).count)
            XCTAssertNoThrow(try LocalSummaryService.validate(notes: notes, meeting: meeting(for: template),
                allowedEvidence: ["s1"], requireTemplateSections: true))
        }
    }

    func testEveryCategoryArrayIsRequiredAndMalformedOrLegacyOutputDoesNotBecomeCompleteNotes() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        let body = payload(for: .team)
        for required in categories + ["summary"] {
            for invalid in [nil, NSNull(), 42] as [Any?] {
                var missing = body
                missing[required] = invalid
                XCTAssertThrowsError(try LocalSummaryService.convert(try generated(missing), part: 1), required)
            }
        }
        XCTAssertThrowsError(try LocalSummaryService.convert(try generated([
            "summary": "Legacy inventory is incomplete for the new generation contract.", "items": []
        ]), part: 1), "No fallback may turn a missing action array into a successful empty inventory")
        for category in categories {
            for (field, invalid) in [("text", 42 as Any), ("evidence", "s1" as Any)] {
                var malformed = body
                var items = try XCTUnwrap(malformed[category] as? [[String: Any]])
                items[0][field] = invalid
                malformed[category] = items
                XCTAssertThrowsError(try LocalSummaryService.convert(try generated(malformed), part: 1), "\(category).\(field)")
            }
        }
    }

    func testMissingNullOrWrongTypedGeneratedSectionFailsConversion() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        for template in MeetingTemplate.allCases {
            for value in [nil, NSNull(), 42] as [Any?] {
                var body = payload(for: template)
                var topics = try XCTUnwrap(body["topics"] as? [[String: Any]])
                topics[0]["sectionID"] = value
                body["topics"] = topics
                XCTAssertThrowsError(try LocalSummaryService.convert(try generated(body), part: 1), template.rawValue)
            }
        }
    }

    func testGeneratedContextNeedsItsOwnNonemptyTitle() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        for template in MeetingTemplate.allCases {
            for value in [nil, NSNull(), " "] as [Any?] {
                var body = payload(for: template)
                var topics = try XCTUnwrap(body["topics"] as? [[String: Any]])
                topics[0]["title"] = value
                body["topics"] = topics
                XCTAssertThrowsError(try LocalSummaryService.convert(try generated(body), part: 1), template.rawValue)
            }
        }
    }

    func testCrossTemplateAndInventedSectionsRemainRejectedAfterConversion() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        let everySection = Set(MeetingTemplate.allCases.flatMap { $0.contextSections.map(\.id) })
        for template in MeetingTemplate.allCases {
            for section in everySection.subtracting(template.contextSections.map(\.id)).union(["invented", ""]) {
                var body = payload(for: template)
                var topics = try XCTUnwrap(body["topics"] as? [[String: Any]])
                topics[0]["sectionID"] = section
                body["topics"] = topics
                XCTAssertThrowsError(try {
                    let notes = try LocalSummaryService.convert(try generated(body), part: 1)
                    try LocalSummaryService.validate(notes: notes, meeting: meeting(for: template), requireTemplateSections: true)
                }(), "\(template.rawValue) must reject \(section)")
            }
        }
    }

    func testNonTopicsNeedNoSectionAssignmentAndKeepTheirOriginalCategoryMeaning() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        for template in MeetingTemplate.allCases {
            var body = payload(for: template)
            body["topics"] = [] as [[String: Any]]
            let notes = try LocalSummaryService.convert(try generated(body), part: 1)
            XCTAssertTrue(notes.topics.isEmpty)
            XCTAssertEqual(notes.decisions.count, 1)
            XCTAssertEqual(notes.actions.count, 1)
            XCTAssertEqual(notes.questions.count, 1)
            XCTAssertEqual(notes.ideas.count, 1)
            XCTAssertNoThrow(try LocalSummaryService.validate(notes: notes, meeting: meeting(for: template), requireTemplateSections: true))
        }
    }

    func testConversionDoesNotRelaxUnknownOrOutOfChunkEvidenceValidation() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        for template in MeetingTemplate.allCases {
            for evidence in [["invented-source"], []] as [[String]] {
                var body = payload(for: template)
                var topics = try XCTUnwrap(body["topics"] as? [[String: Any]])
                topics[0]["evidence"] = evidence
                body["topics"] = topics
                let notes = try LocalSummaryService.convert(try generated(body), part: 1)
                XCTAssertThrowsError(try LocalSummaryService.validate(notes: notes, meeting: meeting(for: template), requireTemplateSections: true))
            }
            var body = payload(for: template)
            var topics = try XCTUnwrap(body["topics"] as? [[String: Any]])
            topics[0]["evidence"] = ["s2"]
            body["topics"] = topics
            let notes = try LocalSummaryService.convert(try generated(body), part: 1)
            XCTAssertThrowsError(try LocalSummaryService.validate(notes: notes, meeting: meeting(for: template),
                allowedEvidence: ["s1"], requireTemplateSections: true))
        }
    }

    func testConversionKeepsOwnerAndDueValidationAndAllowsUnassignedActions() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        for template in MeetingTemplate.allCases {
            let meeting = meeting(for: template)
            let body = payload(for: template)
            for (field, value) in [("responsiblePersonName", "Ayşe"), ("deadlinePhrase", "2026-10-16")] {
                var invalid = body
                var actions = try XCTUnwrap(invalid["actions"] as? [[String: Any]])
                actions[0][field] = value
                invalid["actions"] = actions
                let notes = try LocalSummaryService.convert(try generated(invalid), part: 1)
                XCTAssertThrowsError(try LocalSummaryService.validate(notes: notes, meeting: meeting, requireTemplateSections: true), field)
            }
            let grounded = try LocalSummaryService.convert(try generated(body), part: 1)
            XCTAssertThrowsError(try LocalSummaryService.validate(notes: grounded, meeting: meeting,
                scopedText: ["s1": "The design needs revision."], requireTemplateSections: true))
            var unassignedBody = body
            var actions = try XCTUnwrap(unassignedBody["actions"] as? [[String: Any]])
            actions[0]["responsiblePersonName"] = ""
            actions[0]["deadlinePhrase"] = ""
            unassignedBody["actions"] = actions
            let unassigned = try LocalSummaryService.convert(try generated(unassignedBody), part: 1)
            XCTAssertEqual(unassigned.actions.count, 1)
            XCTAssertNil(unassigned.actions[0].owner)
            XCTAssertNil(unassigned.actions[0].due)
            XCTAssertNoThrow(try LocalSummaryService.validate(notes: unassigned, meeting: meeting, requireTemplateSections: true))
        }
    }

    func testMissingNullOrWrongTypedActionMetadataCannotDecodeAsCompleteNotes() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        let malformedValues: [Any?] = [nil, NSNull(), 42, true, [] as [String], ["unexpected": "value"]]
        for template in MeetingTemplate.allCases {
            let meeting = meeting(for: template)
            let sources = try LocalSummaryService.sourceChunks(meeting: meeting)
            let scope = try LocalSummaryService.evidenceScope(sources: try XCTUnwrap(sources.first))
            for field in ["responsiblePersonName", "deadlinePhrase"] {
                for invalid in malformedValues {
                    var body = payload(for: template)
                    var actions = try XCTUnwrap(body["actions"] as? [[String: Any]])
                    // Start from an explicit complete valid action, then remove
                    // or corrupt only the field under test. No helper fills it.
                    actions[0][field] = invalid
                    body["actions"] = actions
                    let generated = try generated(body)
                    XCTAssertThrowsError(try LocalSummaryService.convert(generated, part: 1), field)
                    XCTAssertThrowsError(try LocalSummaryService.convert(generated, part: 1, evidenceScope: scope), field)
                }
            }
        }
    }

    func testOnlyExactEmptyActionMetadataBecomesNilAndOtherStringsStillRequireGrounding() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        for template in MeetingTemplate.allCases {
            var meeting = meeting(for: template)
            meeting.segments[0].text = "The team agreed to revise the design; no responsible person or deadline was stated."
            var body = emptyBody()
            let unknown: [String: Any] = ["text": "Revise the design.", "responsiblePersonName": "", "deadlinePhrase": "", "evidence": ["s1"]]
            body["actions"] = [unknown]
            let unassigned = try LocalSummaryService.convert(try generated(body), part: 11)
            XCTAssertEqual(unassigned.actions.count, 1)
            XCTAssertNil(unassigned.actions[0].owner)
            XCTAssertNil(unassigned.actions[0].due)
            XCTAssertNoThrow(try LocalSummaryService.validate(notes: unassigned, meeting: meeting,
                allowedEvidence: ["s1"], requireTemplateSections: true))

            for metadata in ["responsiblePersonName", "deadlinePhrase"] {
                for unsupported in [" ", "\t", "\n", "null", "None", "Belirtilmedi", "nil", "N/A", "2026-10-16"] {
                    var invalid = body
                    var action = unknown
                    action[metadata] = unsupported
                    invalid["actions"] = [action]
                    let notes = try LocalSummaryService.convert(try generated(invalid), part: 11)
                    XCTAssertEqual(metadata == "responsiblePersonName" ? notes.actions[0].owner : notes.actions[0].due, unsupported,
                                   "Only the exact empty string may become nil; a bogus \(metadata) must remain visible to validation")
                    XCTAssertThrowsError(try LocalSummaryService.validate(notes: notes, meeting: meeting,
                        allowedEvidence: ["s1"], requireTemplateSections: true), "\(metadata): \(unsupported)")
                }
            }
        }
    }

    func testEmptyCategoriesRemainEmptyWithoutInventedActionsOrTemplateTopics() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        for template in MeetingTemplate.allCases {
            let notes = try LocalSummaryService.convert(try generated(emptyBody()), part: 1)
            XCTAssertTrue(allIDs(notes).isEmpty)
            XCTAssertNoThrow(try LocalSummaryService.validate(notes: notes, meeting: meeting(for: template), requireTemplateSections: true))
        }
    }

    func testConvertedChunksRetainEveryCategoryAndTemplateContextWhenCombined() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        for template in MeetingTemplate.allCases {
            let meeting = meeting(for: template)
            let sources = try LocalSummaryService.sourceChunks(meeting: meeting)
            let body = payload(for: template)
            let first = try LocalSummaryService.convert(try generated(body), part: 1)
            let second = try LocalSummaryService.convert(try generated(body), part: 2)
            let combined = LocalSummaryService.combine([first, second], sources: [sources[0], sources[0]], english: false)
            XCTAssertEqual(combined.topics.map(\.sectionID), (template.contextSections + template.contextSections).map { Optional($0.id) })
            XCTAssertEqual(combined.actions.count, 2)
            XCTAssertEqual(combined.decisions.count, 2)
            XCTAssertEqual(combined.questions.count, 2)
            XCTAssertEqual(combined.ideas.count, 2)
            XCTAssertEqual(Set(allIDs(combined)).count, allIDs(combined).count)
            XCTAssertTrue(combined.topics.allSatisfy { $0.evidence == ["s1"] })
            XCTAssertNoThrow(try LocalSummaryService.validate(notes: combined, meeting: meeting, requireTemplateSections: true))
        }
    }

    func testTopicInventoryCannotDisplaceActionsAndUnrelatedTopicEditsDoNotChangeActionIDs() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        var body = payload(for: .general)
        let action: [String: Any] = ["text": "Revise the design.", "responsiblePersonName": "", "deadlinePhrase": "", "evidence": ["s1"]]
        body["actions"] = [action, action, action]
        let topic: [String: Any] = ["title": "Context", "text": "The design was discussed.",
                                   "sectionID": try XCTUnwrap(MeetingTemplate.general.contextSections.first?.id), "evidence": ["s1"]]
        body["topics"] = Array(repeating: topic, count: 12)
        let withTopics = try LocalSummaryService.convert(try generated(body), part: 4)
        XCTAssertEqual(withTopics.actions.count, 3)
        XCTAssertEqual(withTopics.topics.count, 12)
        body["topics"] = [] as [[String: Any]]
        let withoutTopics = try LocalSummaryService.convert(try generated(body), part: 4)
        XCTAssertEqual(withTopics.actions.map(\.id), withoutTopics.actions.map(\.id))
        XCTAssertEqual(Set(allIDs(withTopics)).count, allIDs(withTopics).count)
        XCTAssertNoThrow(try LocalSummaryService.validate(notes: withTopics, meeting: meeting(for: .general), requireTemplateSections: true))
    }

    func testProductionContextSchemaForcesEmptyActionsWithoutWeakeningOtherCategories() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        for template in MeetingTemplate.allCases {
            let full = try schemaObject(for: template)
            let context = try schemaObject(for: template, includeActions: false)
            let fullFields = try XCTUnwrap(full["properties"] as? [String: Any])
            let contextFields = try XCTUnwrap(context["properties"] as? [String: Any])
            XCTAssertEqual(Set(fullFields.keys), Set(contextFields.keys))
            XCTAssertEqual(Set(try XCTUnwrap(full["required"] as? [String])),
                           Set(try XCTUnwrap(context["required"] as? [String])))
            let actions = try resolve(try XCTUnwrap(contextFields["actions"] as? [String: Any]), in: context)
            XCTAssertEqual(actions["type"] as? String, "array")
            XCTAssertEqual(actions["minItems"] as? Int, 0)
            XCTAssertEqual(actions["maxItems"] as? Int, 0,
                           "The context request must not reclassify or displace the separately extracted tasks")
            for category in ["decisions", "questions", "ideas", "topics", "summary"] {
                let original = try resolve(try XCTUnwrap(fullFields[category] as? [String: Any]), in: full)
                let actual = try resolve(try XCTUnwrap(contextFields[category] as? [String: Any]), in: context)
                XCTAssertEqual(try schemaJSON(actual), try schemaJSON(original),
                               "A context-only pass must retain the template/evidence constraints of \(category)")
            }
        }
    }

    private func permitsNull(_ value: [String: Any], in root: [String: Any]) throws -> Bool {
        let schema = try resolve(value, in: root)
        if schema["type"] as? String == "null" { return true }
        if let types = schema["type"] as? [String], types.contains("null") { return true }
        if let choices = schema["anyOf"] as? [[String: Any]] {
            for choice in choices {
                if try permitsNull(choice, in: root) { return true }
            }
        }
        return false
    }

    private func allIDs(_ notes: MeetingNotes) -> [String] {
        notes.actions.map(\.id) + notes.decisions.map(\.id) + notes.questions.map(\.id)
            + notes.ideas.map(\.id) + notes.topics.map(\.id)
    }

    private func emptyBody() -> [String: Any] {
        ["summary": "No supported task or discussion context was established.", "actions": [] as [[String: Any]],
         "decisions": [] as [[String: Any]], "questions": [] as [[String: Any]],
         "ideas": [] as [[String: Any]], "topics": [] as [[String: Any]]]
    }

    @available(macOS 26.0, *)
    private func schemaObject(for template: MeetingTemplate, includeActions: Bool = true) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(
            LocalSummaryService.generationSchema(template: template, evidenceIDs: ["s1"], includeActions: includeActions))) as? [String: Any])
    }

    /// The SDK encodes string choices either as one enum or as anyOf enum
    /// leaves. Every leaf must remain a finite, non-null string domain.
    private func finiteStringDomain(_ value: [String: Any], in root: [String: Any]) throws -> Set<String> {
        let schema = try resolve(value, in: root)
        if let choices = schema["anyOf"] as? [[String: Any]] {
            guard !choices.isEmpty, schema["enum"] == nil,
                  schema["type"] == nil || schema["type"] as? String == "string" else {
                throw SchemaInspectionError.unboundedStringChoices
            }
            return try choices.reduce(into: Set<String>()) { domain, choice in
                domain.formUnion(try finiteStringDomain(choice, in: root))
            }
        }
        guard schema["type"] as? String == "string",
              let choices = schema["enum"] as? [String], !choices.isEmpty else {
            throw SchemaInspectionError.unboundedStringChoices
        }
        return Set(choices)
    }

    private func schemaJSON(_ schema: [String: Any]) throws -> String {
        String(decoding: try JSONSerialization.data(withJSONObject: schema, options: [.sortedKeys]), as: UTF8.self)
    }

    /// FoundationModels may inline a schema or place any nested property in
    /// $defs. Resolve the full subtree before inspecting semantic constraints.
    private func resolve(_ value: [String: Any], in root: [String: Any],
                         visiting: Set<String> = []) throws -> [String: Any] {
        var resolved = value
        var references = visiting
        if let reference = value["$ref"] as? String {
            guard reference.hasPrefix("#/"), !references.contains(reference) else {
                throw SchemaInspectionError.unsupportedReference(reference)
            }
            references.insert(reference)
            let components = reference.dropFirst(2).split(separator: "/").map {
                $0.replacingOccurrences(of: "~1", with: "/").replacingOccurrences(of: "~0", with: "~")
            }
            var target: Any = root
            for component in components {
                let dictionary = try XCTUnwrap(target as? [String: Any])
                target = try XCTUnwrap(dictionary[component])
            }
            resolved = try resolve(try XCTUnwrap(target as? [String: Any]), in: root, visiting: references)
            // Preserve constraints beside $ref as well as those on its target.
            for (name, sibling) in value where name != "$ref" { resolved[name] = sibling }
        }
        for (name, property) in resolved {
            if let object = property as? [String: Any] {
                resolved[name] = try resolve(object, in: root, visiting: references)
            } else if let choices = property as? [[String: Any]] {
                resolved[name] = try choices.map { try resolve($0, in: root, visiting: references) }
            }
        }
        return resolved
    }

    private enum SchemaInspectionError: Error {
        case unsupportedReference(String)
        case unboundedStringChoices
    }

    @available(macOS 26.0, *)
    private func generated(_ value: [String: Any]) throws -> GeneratedContent {
        try GeneratedContent(json: String(decoding: JSONSerialization.data(withJSONObject: value), as: UTF8.self))
    }

    private func meeting(for template: MeetingTemplate) -> Meeting {
        var meeting = Meeting(title: "Synthetic regression", segments: [
            TranscriptSegment(id: "s1", speaker: "A", start: 0, end: 5,
                text: "Ali will revise the design by next Friday. We agreed to retain the approved design. Which option should we investigate? An option remains under consideration."),
            TranscriptSegment(id: "s2", speaker: "B", start: 5, end: 8, text: "Which option should we investigate?")
        ])
        meeting.templateRawValue = template.rawValue
        return meeting
    }

    private func payload(for template: MeetingTemplate) -> [String: Any] {
        ["summary": "The design revision was discussed; options remain open.",
         "actions": [["text": "Revise the design.", "responsiblePersonName": "Ali", "deadlinePhrase": "next Friday", "evidence": ["s1"]]],
         "decisions": [["text": "Retain the approved design.", "evidence": ["s1"]]],
         "questions": [["text": "Which option should we investigate?", "evidence": ["s1"]]],
         "ideas": [["text": "An option remains under consideration.", "evidence": ["s1"]]],
         "topics": template.contextSections.map {
             ["sectionID": $0.id, "title": "Synthetic \($0.id) context", "text": "The design revision was discussed.", "evidence": ["s1", "s1"]] as [String: Any]
         }]
    }
}
