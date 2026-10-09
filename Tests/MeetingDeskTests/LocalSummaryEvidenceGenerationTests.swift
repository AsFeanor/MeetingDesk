import XCTest
import FoundationModels
@testable import MeetingDesk

/// Synthetic source IDs and generated JSON exercise guided-generation boundaries
/// without invoking Apple Intelligence or reading the user's meeting archive.
final class LocalSummaryEvidenceGenerationTests: XCTestCase {
    func testEvidenceSchemaHasExactlyTheCurrentChunkAliasesForEveryTemplateAndCategory() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        let scope = try LocalSummaryService.evidenceScope(sources: [
            source(id: "opaque-first-identifier", text: "A design option was discussed."),
            source(id: "opaque-second-identifier", text: "The deadline remains open."),
            source(id: "opaque-first-identifier", text: "A later fragment of the same source.")
        ])
        for template in MeetingTemplate.allCases {
            let schema = try schemaObject(template: template, evidenceIDs: scope.evidenceIDs)
            let properties = try XCTUnwrap(schema["properties"] as? [String: Any])
            let itemArray = try resolve(try XCTUnwrap(properties["items"] as? [String: Any]), in: schema)
            let union = try resolve(try XCTUnwrap(itemArray["items"] as? [String: Any]), in: schema)
            let branches = try XCTUnwrap(union["anyOf"] as? [[String: Any]])
            XCTAssertEqual(branches.count, 2)
            var categories = Set<String>()
            for branch in branches {
                let resolved = try resolve(branch, in: schema)
                let itemProperties = try XCTUnwrap(resolved["properties"] as? [String: Any])
                categories.formUnion(try finiteStringDomain(try XCTUnwrap(itemProperties["category"] as? [String: Any]), in: schema))
                XCTAssertTrue(try XCTUnwrap(resolved["required"] as? [String]).contains("evidence"))
                let evidence = try resolve(try XCTUnwrap(itemProperties["evidence"] as? [String: Any]), in: schema)
                XCTAssertEqual(evidence["type"] as? String, "array")
                XCTAssertEqual(evidence["minItems"] as? Int, 1)
                XCTAssertEqual(evidence["maxItems"] as? Int, 4)
                let choices = try finiteStringDomain(try XCTUnwrap(evidence["items"] as? [String: Any]), in: schema)
                XCTAssertEqual(choices, Set(scope.evidenceIDs), template.rawValue)
                XCTAssertTrue(choices.isDisjoint(with: ["opaque-first-identifier", "opaque-second-identifier", "foreign-chunk-id", "", "s3"]))
            }
            XCTAssertEqual(categories, ["topic", "decision", "action", "question", "idea"])
        }
    }

    func testEmptyOrBlankEvidenceDomainsCannotEnableUnconstrainedGeneration() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        for ids in [[], [""], ["s1", ""], ["s1", "s1"], ["opaque-source"], ["s0"], ["s1\n"]] as [[String]] {
            XCTAssertThrowsError(try LocalSummaryService.generationSchema(template: .general, evidenceIDs: ids))
        }
        XCTAssertThrowsError(try LocalSummaryService.evidenceScope(sources: []))
        for invalidID in ["", " ", String(repeating: "a", count: 257)] {
            XCTAssertThrowsError(try LocalSummaryService.evidenceScope(sources: [source(id: invalidID, text: "Synthetic discussion.")]))
        }
    }

    func testOpaqueLongAndUnicodeIDsRoundTripWithoutChangingSourceTextOrMetadata() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        let opaque = "65fe93838d20-c4ea-01"
        let long = String(repeating: "a", count: 240)
        let unicode = "İstanbul/özel 👩🏽‍💻 kimliği \"\\"
        let original = [
            source(id: opaque, speaker: "Konuşmacı A", start: 0, end: 3, text: "First synthetic source."),
            source(id: long, speaker: "Konuşmacı B", start: 3, end: 7, text: "Second synthetic source."),
            source(id: unicode, speaker: "Konuşmacı C", start: 7, end: 9, text: "Third synthetic source.")
        ]
        let scope = try LocalSummaryService.evidenceScope(sources: original)
        XCTAssertEqual(scope.evidenceIDs, ["s1", "s2", "s3"])
        XCTAssertEqual(scope.sources.map(\.id), ["s1", "s2", "s3"])
        XCTAssertEqual(scope.originalIDsByAlias, ["s1": opaque, "s2": long, "s3": unicode])
        for (source, aliased) in zip(original, scope.sources) {
            XCTAssertEqual(aliased.speaker, source.speaker)
            XCTAssertEqual(aliased.start, source.start)
            XCTAssertEqual(aliased.end, source.end)
            XCTAssertEqual(aliased.text, source.text)
        }
        let notes = try LocalSummaryService.convert(try generated([
            "summary": "Three synthetic sources were discussed.",
            "items": [["category": "question", "text": "Which option remains open?", "evidence": ["s3", "s1", "s2", "s1"]]]
        ]), part: 1, evidenceScope: scope)
        XCTAssertEqual(notes.questions.first?.evidence, [opaque, long, unicode].sorted())
        let meeting = Meeting(title: "Synthetic IDs", segments: original.map { .init(id: $0.id, speaker: $0.speaker, start: $0.start, end: $0.end, text: $0.text) })
        XCTAssertNoThrow(try LocalSummaryService.validate(notes: notes, meeting: meeting,
            allowedEvidence: Set(original.map(\.id)), requireTemplateSections: true))
    }

    func testOriginalIDsThatLookLikeAliasesStillUseTheCurrentChunkMapping() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        let originals = [source(id: "s2", text: "First synthetic option."), source(id: "s1", text: "Second synthetic option.")]
        let scope = try LocalSummaryService.evidenceScope(sources: originals)
        XCTAssertEqual(scope.evidenceIDs, ["s1", "s2"])
        XCTAssertEqual(scope.originalIDsByAlias, ["s1": "s2", "s2": "s1"])
        let notes = try LocalSummaryService.convert(try generated([
            "summary": "Two synthetic options remain open.", "items": [
                ["category": "question", "text": "First option?", "evidence": ["s1"]],
                ["category": "idea", "text": "Second option remains open.", "evidence": ["s2"]]
            ]
        ]), part: 1, evidenceScope: scope)
        XCTAssertEqual(notes.questions.first?.evidence, ["s2"])
        XCTAssertEqual(notes.ideas.first?.evidence, ["s1"])
        XCTAssertNoThrow(try LocalSummaryService.validate(notes: notes,
            meeting: meeting(template: .general, sources: originals), requireTemplateSections: true))
    }

    func testEveryGeneratedCategoryResolvesAliasesToOriginalEvidence() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        let originalID = "opaque-original-19b"
        let originals = [source(id: originalID, text: "Ali will revise the design by next Friday. The team agreed to retain it; alternatives remain open.")]
        let scope = try LocalSummaryService.evidenceScope(sources: originals)
        for template in MeetingTemplate.allCases {
            let notes = try LocalSummaryService.convert(try generated(payload(template: template, evidence: ["s1"])), part: 7, evidenceScope: scope)
            XCTAssertEqual(notes.decisions.first?.evidence, [originalID])
            XCTAssertEqual(notes.actions.first?.evidence, [originalID])
            XCTAssertEqual(notes.questions.first?.evidence, [originalID])
            XCTAssertEqual(notes.ideas.first?.evidence, [originalID])
            XCTAssertEqual(notes.topics.first?.evidence, [originalID])
            XCTAssertEqual(notes.actions.first?.owner, "Ali")
            XCTAssertEqual(notes.actions.first?.due, "next Friday")
            let meeting = meeting(template: template, sources: originals)
            XCTAssertNoThrow(try LocalSummaryService.validate(notes: notes, meeting: meeting,
                allowedEvidence: [originalID], scopedText: [originalID: originals[0].text], requireTemplateSections: true))
        }
    }

    func testUnknownOriginalEmptyNullOrWrongTypedEvidenceIsRejectedAtConversionBoundary() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        let scope = try LocalSummaryService.evidenceScope(sources: [source(id: "opaque-current-source", text: "A synthetic option remains open.")])
        let invalid: [Any] = [["foreign-source"], ["s2"], ["opaque-current-source"], [""], [], NSNull(), "s1", [1], ["s1", "foreign-source"]]
        for template in MeetingTemplate.allCases {
            for category in ["decision", "action", "question", "idea", "topic"] {
                for evidence in invalid {
                    var item: [String: Any] = ["category": category, "text": "A synthetic option remains open.", "evidence": evidence]
                    if category == "topic" {
                        item["title"] = "Synthetic context"
                        item["sectionID"] = try XCTUnwrap(template.contextSections.first?.id)
                    }
                    XCTAssertThrowsError(try LocalSummaryService.convert(try generated([
                        "summary": "Synthetic context remains open.", "items": [item]
                    ]), part: 1, evidenceScope: scope), "\(template.rawValue) \(category) evidence: \(evidence)")
                }
            }
        }
    }

    func testAnOriginalSourceFromAnotherChunkCannotBeRecoveredByGuessing() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        let originals = [source(id: "first-original", text: "First option remains open."), source(id: "second-original", text: "Second option remains open.")]
        let first = try LocalSummaryService.evidenceScope(sources: [originals[0]])
        let second = try LocalSummaryService.evidenceScope(sources: [originals[1]])
        let response = try generated(["summary": "An option remains open.", "items": [["category": "question", "text": "Which option?", "evidence": ["s1"]]]])
        let firstNotes = try LocalSummaryService.convert(response, part: 1, evidenceScope: first)
        let secondNotes = try LocalSummaryService.convert(response, part: 2, evidenceScope: second)
        XCTAssertEqual(firstNotes.questions.first?.evidence, ["first-original"])
        XCTAssertEqual(secondNotes.questions.first?.evidence, ["second-original"])
        let meeting = meeting(template: .general, sources: originals)
        XCTAssertThrowsError(try LocalSummaryService.validate(notes: firstNotes, meeting: meeting, allowedEvidence: ["second-original"]))
        XCTAssertThrowsError(try LocalSummaryService.validate(notes: secondNotes, meeting: meeting, allowedEvidence: ["first-original"]))
        for forbidden in ["second-original", "s2"] {
            XCTAssertThrowsError(try LocalSummaryService.convert(try generated([
                "summary": "An option remains open.", "items": [["category": "question", "text": "Which option?", "evidence": [forbidden]]]
            ]), part: 1, evidenceScope: first))
        }
    }

    func testRepeatedOriginalFragmentsKeepOneAliasAndExactPerChunkTextScope() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        let originalID = "one-opaque-source"
        let firstText = String(repeating: "Ödeme koşulu tartışıldı; karar verilmedi. 👩🏽‍💻\n", count: 70)
        let finalText = "Ali will revise the design by next Friday."
        let meeting = Meeting(title: "Synthetic fragmented source", segments: [
            .init(id: originalID, speaker: "A", start: 0, end: 90, text: firstText + finalText)
        ])
        let chunks = try LocalSummaryService.sourceChunks(meeting: meeting, maximumBytes: 1_024)
        XCTAssertGreaterThan(chunks.count, 1)
        let flattened = chunks.flatMap { $0 }
        XCTAssertEqual(flattened.map(\.text).joined(), firstText + finalText)
        XCTAssertTrue(flattened.allSatisfy { $0.id == originalID && $0.start == 0 && $0.end == 90 })
        for chunk in chunks {
            let scope = try LocalSummaryService.evidenceScope(sources: chunk)
            XCTAssertEqual(scope.evidenceIDs, ["s1"])
            XCTAssertEqual(Set(scope.sources.map(\.id)), ["s1"])
            XCTAssertEqual(scope.sources.map(\.text).joined(), chunk.map(\.text).joined())
            XCTAssertEqual(scope.originalIDsByAlias, ["s1": originalID])
        }
        let firstScope = try LocalSummaryService.evidenceScope(sources: chunks[0])
        let unsupportedAction = try LocalSummaryService.convert(try generated([
            "summary": "A design revision remains open.",
            "items": [["category": "action", "text": "Revise the design.", "owner": "Ali", "due": "next Friday", "evidence": ["s1"]]]
        ]), part: 1, evidenceScope: firstScope)
        XCTAssertThrowsError(try LocalSummaryService.validate(notes: unsupportedAction, meeting: meeting,
            allowedEvidence: [originalID], scopedText: [originalID: chunks[0].map(\.text).joined()], requireTemplateSections: true),
            "A repeated original ID cannot import owner/date details from its later fragment")
    }

    func testAliasResolutionDoesNotPermitFabricatedOrUncitedOwnersAndDates() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        let originals = [
            source(id: "unassigned-original", text: "The design needs revision; no owner or deadline was agreed."),
            source(id: "assigned-original", text: "Ali will revise the design by next Friday.")
        ]
        let scope = try LocalSummaryService.evidenceScope(sources: originals)
        let meeting = meeting(template: .general, sources: originals)
        let invalidActions: [[String: Any]] = [
            ["category": "action", "text": "Revise the design.", "owner": "Ali", "evidence": ["s1"]],
            ["category": "action", "text": "Revise the design.", "due": "next Friday", "evidence": ["s1"]],
            ["category": "action", "text": "Revise the design.", "owner": "Ayşe", "evidence": ["s2"]],
            ["category": "action", "text": "Revise the design.", "due": "2026-10-16", "evidence": ["s2"]]
        ]
        for action in invalidActions {
            let notes = try LocalSummaryService.convert(try generated([
                "summary": "The design needs revision.", "items": [action]
            ]), part: 1, evidenceScope: scope)
            XCTAssertThrowsError(try LocalSummaryService.validate(notes: notes, meeting: meeting,
                allowedEvidence: Set(originals.map(\.id)), requireTemplateSections: true))
        }
        let grounded = try LocalSummaryService.convert(try generated([
            "summary": "A design revision was assigned.",
            "items": [["category": "action", "text": "Revise the design.", "owner": "Ali", "due": "next Friday", "evidence": ["s2"]]]
        ]), part: 1, evidenceScope: scope)
        XCTAssertNoThrow(try LocalSummaryService.validate(notes: grounded, meeting: meeting,
            allowedEvidence: Set(originals.map(\.id)), requireTemplateSections: true))
    }

    func testCombiningAliasedChunkResponsesPreservesOriginalEvidenceAndSectionIdentity() throws {
        guard #available(macOS 26.0, *) else { throw XCTSkip("FoundationModels requires macOS 26") }
        let chunks = [[source(id: "original-shared", start: 0, end: 30, text: "First synthetic fragment.")],
                      [source(id: "original-shared", start: 0, end: 30, text: "Second synthetic fragment.")]]
        var meeting = Meeting(title: "Synthetic chunk combination", segments: [
            .init(id: "original-shared", speaker: "A", start: 0, end: 30, text: chunks.flatMap { $0 }.map(\.text).joined())
        ])
        meeting.templateRawValue = MeetingTemplate.team.rawValue
        var parts: [MeetingNotes] = []
        for (index, chunk) in chunks.enumerated() {
            let scope = try LocalSummaryService.evidenceScope(sources: chunk)
            let section = index == 0 ? "progress" : "blockers"
            let notes = try LocalSummaryService.convert(try generated([
                "summary": "Synthetic section \(index + 1) remains open.",
                "items": [["category": "topic", "title": "Synthetic section \(index + 1)", "text": chunk[0].text,
                           "sectionID": section, "evidence": ["s1"]]]
            ]), part: index + 1, evidenceScope: scope)
            XCTAssertNoThrow(try LocalSummaryService.validate(notes: notes, meeting: meeting,
                allowedEvidence: ["original-shared"], scopedText: ["original-shared": chunk[0].text], requireTemplateSections: true))
            parts.append(notes)
        }
        let combined = LocalSummaryService.combine(parts, sources: chunks, english: false)
        XCTAssertEqual(combined.topics.map(\.evidence), [["original-shared"], ["original-shared"]])
        XCTAssertEqual(combined.topics.map(\.sectionID), ["progress", "blockers"])
        XCTAssertEqual(Set(combined.topics.map(\.id)).count, 2)
        XCTAssertTrue(combined.topics[0].title.contains("Bölüm 1"))
        XCTAssertTrue(combined.topics[1].title.contains("Bölüm 2"))
        XCTAssertEqual(combined.topics.map(\.text), chunks.map { $0[0].text })
        XCTAssertTrue(combined.summary.contains(parts[0].summary))
        XCTAssertTrue(combined.summary.contains(parts[1].summary))
        XCTAssertNoThrow(try LocalSummaryService.validate(notes: combined, meeting: meeting, requireTemplateSections: true))
    }

    private func source(id: String, speaker: String = "A", start: Double = 0, end: Double = 5, text: String) -> LocalSummaryService.Source {
        .init(id: id, speaker: speaker, start: start, end: end, text: text)
    }

    private func meeting(template: MeetingTemplate, sources: [LocalSummaryService.Source]) -> Meeting {
        var meeting = Meeting(title: "Synthetic evidence scope", segments: sources.map {
            .init(id: $0.id, speaker: $0.speaker, start: $0.start, end: $0.end, text: $0.text)
        })
        meeting.templateRawValue = template.rawValue
        return meeting
    }

    private func payload(template: MeetingTemplate, evidence: [String]) throws -> [String: Any] {
        let section = try XCTUnwrap(template.contextSections.first?.id)
        return ["summary": "A design revision was discussed; alternatives remain open.", "items": [
            ["category": "decision", "text": "Retain the approved design.", "evidence": evidence],
            ["category": "action", "text": "Revise the design.", "owner": "Ali", "due": "next Friday", "evidence": evidence],
            ["category": "question", "text": "Which alternative?", "evidence": evidence],
            ["category": "idea", "text": "Consider an alternative.", "evidence": evidence],
            ["category": "topic", "title": "Synthetic context", "text": "A design revision was discussed.", "sectionID": section, "evidence": evidence]
        ]]
    }

    @available(macOS 26.0, *)
    private func generated(_ value: [String: Any]) throws -> GeneratedContent {
        try GeneratedContent(json: String(decoding: JSONSerialization.data(withJSONObject: value), as: UTF8.self))
    }

    @available(macOS 26.0, *)
    private func schemaObject(template: MeetingTemplate, evidenceIDs: [String]) throws -> [String: Any] {
        try XCTUnwrap(JSONSerialization.jsonObject(with: JSONEncoder().encode(
            LocalSummaryService.generationSchema(template: template, evidenceIDs: evidenceIDs))) as? [String: Any])
    }

    /// Inspect the permitted values rather than assuming one SDK's serialization.
    /// A finite anyOf tree may encode enum leaves directly or through $ref.
    private func finiteStringDomain(_ value: [String: Any], in root: [String: Any]) throws -> Set<String> {
        let schema = try resolve(value, in: root)
        if let choices = schema["anyOf"] as? [[String: Any]] {
            guard !choices.isEmpty, schema["enum"] == nil,
                  schema["type"] == nil || schema["type"] as? String == "string" else {
                throw SchemaInspectionError.unboundedStringChoices
            }
            return try choices.reduce(into: Set<String>()) { result, choice in
                result.formUnion(try finiteStringDomain(choice, in: root))
            }
        }
        guard schema["type"] as? String == "string", let choices = schema["enum"] as? [String], !choices.isEmpty else {
            throw SchemaInspectionError.unboundedStringChoices
        }
        return Set(choices)
    }

    private func resolve(_ value: [String: Any], in root: [String: Any], visiting: Set<String> = []) throws -> [String: Any] {
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
}
