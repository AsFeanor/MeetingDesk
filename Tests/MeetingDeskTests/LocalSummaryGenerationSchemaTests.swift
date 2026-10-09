import XCTest
import FoundationModels
@testable import MeetingDesk

/// Uses synthetic generated content to test the local schema and conversion
/// boundary. These checks do not invoke an on-device language model.
final class LocalSummaryGenerationSchemaTests: XCTestCase {
    func testSelectedTemplateRestrictsGeneratedSectionsAtTheSchemaBoundary() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        let everySection = Set(MeetingTemplate.allCases.flatMap { $0.contextSections.map(\.id) })
        for template in MeetingTemplate.allCases {
            let schema = try schemaObject(for: template)
            let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
            let itemArray = try XCTUnwrap(properties["items"] as? [String: Any])
            let union = try resolve(try XCTUnwrap(itemArray["items"] as? [String: Any]), in: schema)
            let branches = try XCTUnwrap(union["anyOf"] as? [[String: Any]]).map { try resolve($0, in: schema) }
            XCTAssertEqual(branches.count, 2, "Context and factual note categories require separate structural constraints")
            let staticSchemaDescription = try schemaJSON(schema)
            let context = try XCTUnwrap(branches.first { branch in
                let properties = branch["properties"] as? [String: Any]
                let category = properties?["category"] as? [String: Any]
                return category?["enum"] as? [String] == ["topic"]
            }, "Missing exact topic category branch in static generated schema: \(staticSchemaDescription)")
            let item = try XCTUnwrap(branches.first { branch in
                let properties = branch["properties"] as? [String: Any]
                let category = properties?["category"] as? [String: Any]
                return Set(category?["enum"] as? [String] ?? []) == Set(["decision", "action", "question", "idea"])
            }, "Missing exact factual category branch in static generated schema: \(staticSchemaDescription)")
            let contextProperties = try XCTUnwrap(context["properties"] as? [String: Any])
            let section = try resolve(try XCTUnwrap(contextProperties["sectionID"] as? [String: Any]), in: schema)
            let choices = try XCTUnwrap(section["enum"] as? [String], "\(template.rawValue) must constrain section IDs")
            let expected = Set(template.contextSections.map(\.id))
            XCTAssertEqual(Set(choices), expected, template.rawValue)
            XCTAssertTrue(Set(choices).isDisjoint(with: everySection.subtracting(expected)), template.rawValue)
            XCTAssertEqual(section["type"] as? String, "string")
            XCTAssertTrue(try XCTUnwrap(context["required"] as? [String]).contains("sectionID"),
                          "Guided topic generation must assign a valid section rather than generating nil or an arbitrary string")
            XCTAssertEqual(context["additionalProperties"] as? Bool, false)
            XCTAssertEqual(item["additionalProperties"] as? Bool, false)
            let itemProperties = try XCTUnwrap(item["properties"] as? [String: Any])
            XCTAssertNil(itemProperties["sectionID"], "Factual note categories do not need a template context assignment")
            for properties in [contextProperties, itemProperties] {
                let evidence = try XCTUnwrap(properties["evidence"] as? [String: Any])
                XCTAssertGreaterThan(try XCTUnwrap(evidence["minItems"] as? Int), 0,
                                     "Every generated note must retain source evidence")
            }
        }
    }

    func testAllSelectedSectionsSurviveConversionWithGroundedActionsAndStableEvidence() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        for template in MeetingTemplate.allCases {
            let meeting = meeting(for: template)
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
            let ids = notes.decisions.map(\.id) + notes.actions.map(\.id) + notes.questions.map(\.id)
                + notes.ideas.map(\.id) + notes.topics.map(\.id)
            XCTAssertEqual(Set(ids).count, ids.count, "Context and other categories need distinct IDs")
            XCTAssertNoThrow(try LocalSummaryService.validate(notes: notes, meeting: meeting,
                                                              allowedEvidence: ["s1"], requireTemplateSections: true))
        }
    }

    func testMissingNullOrWrongTypedGeneratedSectionFailsConversion() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        for template in MeetingTemplate.allCases {
            for value in [nil, NSNull(), 42] as [Any?] {
                var body = payload(for: template)
                var items = try XCTUnwrap(body["items"] as? [[String: Any]])
                let topic = try XCTUnwrap(items.firstIndex { $0["category"] as? String == "topic" })
                items[topic]["sectionID"] = value
                body["items"] = items
                XCTAssertThrowsError(try LocalSummaryService.convert(try generated(body), part: 1), template.rawValue)
            }
        }
    }

    func testGeneratedContextNeedsItsOwnNonemptyTitle() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        for template in MeetingTemplate.allCases {
            for value in [nil, NSNull(), " "] as [Any?] {
                var body = payload(for: template)
                var items = try XCTUnwrap(body["items"] as? [[String: Any]])
                let topic = try XCTUnwrap(items.firstIndex { $0["category"] as? String == "topic" })
                items[topic]["title"] = value
                body["items"] = items
                XCTAssertThrowsError(try LocalSummaryService.convert(try generated(body), part: 1), template.rawValue)
            }
        }
    }

    func testCrossTemplateAndInventedSectionsRemainRejectedAfterConversion() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        let everySection = Set(MeetingTemplate.allCases.flatMap { $0.contextSections.map(\.id) })
        for template in MeetingTemplate.allCases {
            let forbidden = everySection.subtracting(template.contextSections.map(\.id)).union(["invented", ""])
            for section in forbidden {
                var body = payload(for: template)
                var items = try XCTUnwrap(body["items"] as? [[String: Any]])
                let topic = try XCTUnwrap(items.firstIndex { $0["category"] as? String == "topic" })
                items[topic]["sectionID"] = section
                body["items"] = items
                XCTAssertThrowsError(try {
                    let notes = try LocalSummaryService.convert(try generated(body), part: 1)
                    try LocalSummaryService.validate(notes: notes, meeting: meeting(for: template), requireTemplateSections: true)
                }(), "\(template.rawValue) must reject \(section)")
            }
        }
    }

    func testMalformedGeneratedStructureDoesNotBecomeApparentlyCompleteNotes() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        let body = payload(for: .team)
        for required in ["summary", "items"] {
            var missing = body
            missing[required] = nil
            XCTAssertThrowsError(try LocalSummaryService.convert(try generated(missing), part: 1), required)
        }
        var items = try XCTUnwrap(body["items"] as? [[String: Any]])
        items[0]["category"] = "invented"
        XCTAssertThrowsError(try LocalSummaryService.convert(try generated(body.merging(["items": items]) { _, new in new }), part: 1))
        items = try XCTUnwrap(body["items"] as? [[String: Any]])
        items[0]["evidence"] = "s1"
        XCTAssertThrowsError(try LocalSummaryService.convert(try generated(body.merging(["items": items]) { _, new in new }), part: 1))
        items = try XCTUnwrap(body["items"] as? [[String: Any]])
        items[0]["text"] = 42
        XCTAssertThrowsError(try LocalSummaryService.convert(try generated(body.merging(["items": items]) { _, new in new }), part: 1))
    }

    func testNonTopicsNeedNoSectionAssignmentAndKeepTheirOriginalCategoryMeaning() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        for template in MeetingTemplate.allCases {
            let body = payload(for: template)
            let items = try XCTUnwrap(body["items"] as? [[String: Any]]).filter { $0["category"] as? String != "topic" }
            let notes = try LocalSummaryService.convert(try generated(body.merging(["items": items]) { _, new in new }), part: 1)
            XCTAssertTrue(notes.topics.isEmpty, "A decision, action, question or idea remains in its original category")
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
            let body = payload(for: template)
            var items = try XCTUnwrap(body["items"] as? [[String: Any]])
            let topic = try XCTUnwrap(items.firstIndex { $0["category"] as? String == "topic" })
            for evidence in [["invented-source"], []] as [[String]] {
                items[topic]["evidence"] = evidence
                let notes = try LocalSummaryService.convert(try generated(body.merging(["items": items]) { _, new in new }), part: 1)
                XCTAssertThrowsError(try LocalSummaryService.validate(notes: notes, meeting: meeting(for: template), requireTemplateSections: true))
            }
            items[topic]["evidence"] = ["s2"]
            let notes = try LocalSummaryService.convert(try generated(body.merging(["items": items]) { _, new in new }), part: 1)
            XCTAssertThrowsError(try LocalSummaryService.validate(notes: notes, meeting: meeting(for: template),
                                                                   allowedEvidence: ["s1"], requireTemplateSections: true),
                                 "A source from another chunk cannot support this chunk's topic")
        }
    }

    func testConversionKeepsOwnerAndDueValidationAndAllowsUnassignedActions() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        for template in MeetingTemplate.allCases {
            let meeting = meeting(for: template)
            let body = payload(for: template)
            var items = try XCTUnwrap(body["items"] as? [[String: Any]])
            let action = try XCTUnwrap(items.firstIndex { $0["category"] as? String == "action" })
            for (field, value) in [("owner", "Ayşe"), ("due", "2026-10-16")] {
                var invalidItems = items
                invalidItems[action][field] = value
                let notes = try LocalSummaryService.convert(try generated(body.merging(["items": invalidItems]) { _, new in new }), part: 1)
                XCTAssertThrowsError(try LocalSummaryService.validate(notes: notes, meeting: meeting, requireTemplateSections: true), field)
            }
            let grounded = try LocalSummaryService.convert(try generated(body), part: 1)
            XCTAssertThrowsError(try LocalSummaryService.validate(notes: grounded, meeting: meeting,
                                                                   scopedText: ["s1": "The design needs revision."],
                                                                   requireTemplateSections: true),
                                 "A chunk cannot use an owner or due phrase occurring only in a different text fragment")
            items[action]["owner"] = NSNull()
            items[action]["due"] = NSNull()
            let unassigned = try LocalSummaryService.convert(try generated(body.merging(["items": items]) { _, new in new }), part: 1)
            XCTAssertNil(unassigned.actions.first?.owner)
            XCTAssertNil(unassigned.actions.first?.due)
            XCTAssertNoThrow(try LocalSummaryService.validate(notes: unassigned, meeting: meeting, requireTemplateSections: true))
        }
    }

    func testEmptyGeneratedContextDoesNotInventSectionsToFillTheTemplate() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        for template in MeetingTemplate.allCases {
            let body: [String: Any] = ["summary": "No supported context was discussed.", "items": []]
            let notes = try LocalSummaryService.convert(try generated(body), part: 1)
            XCTAssertTrue(notes.topics.isEmpty)
            XCTAssertTrue(notes.actions.isEmpty)
            XCTAssertNoThrow(try LocalSummaryService.validate(notes: notes, meeting: meeting(for: template), requireTemplateSections: true))
        }
    }

    func testConvertedChunksRetainEveryTemplateContextWhenCombined() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        for template in MeetingTemplate.allCases {
            let meeting = meeting(for: template)
            let sources = try LocalSummaryService.sourceChunks(meeting: meeting)
            let body = payload(for: template)
            let topics = try XCTUnwrap(body["items"] as? [[String: Any]]).filter { $0["category"] as? String == "topic" }
            let first = try LocalSummaryService.convert(try generated(body.merging(["items": topics]) { _, new in new }), part: 1)
            let second = try LocalSummaryService.convert(try generated(body.merging(["items": topics]) { _, new in new }), part: 2)
            let combined = LocalSummaryService.combine([first, second], sources: [sources[0], sources[0]], english: false)
            XCTAssertEqual(combined.topics.map(\.sectionID), (template.contextSections + template.contextSections).map { Optional($0.id) })
            XCTAssertEqual(Set(combined.topics.map(\.id)).count, combined.topics.count)
            XCTAssertTrue(combined.topics.allSatisfy { $0.evidence == ["s1"] })
            XCTAssertNoThrow(try LocalSummaryService.validate(notes: combined, meeting: meeting, requireTemplateSections: true))
        }
    }

    @available(macOS 26.0, *)
    private func schemaObject(for template: MeetingTemplate) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(LocalSummaryService.generationSchema(template: template))) as? [String: Any])
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
        let items: [[String: Any]] = [
            ["category": "decision", "text": "Retain the approved design.", "evidence": ["s1"]],
            ["category": "action", "text": "Revise the design.", "owner": "Ali", "due": "next Friday", "evidence": ["s1"]],
            ["category": "question", "text": "Which option should we investigate?", "evidence": ["s1"]],
            ["category": "idea", "text": "An option remains under consideration.", "evidence": ["s1"]]
        ]
        let topics: [[String: Any]] = template.contextSections.map {
            ["category": "topic", "sectionID": $0.id, "title": "Synthetic \($0.id) context", "text": "The design revision was discussed.", "evidence": ["s1", "s1"]]
        }
        return ["summary": "The design revision was discussed; options remain open.", "items": items + topics]
    }
}
